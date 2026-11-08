//! ZIP lesen (inkl. AES-256 und ZipCrypto).

use std::io::{BufReader, Read};
use std::path::Path;

use zip::ZipArchive;
use zip::read::ZipFileEntry;

use crate::charset::{self, NameCodec};
use crate::error::{Result, ZippError};
use crate::extract::Sink;
use crate::model::{ArchiveFormat, Entry, Listing};
use crate::progress::Tracker;
use crate::safety::normalize;
use crate::timeutil::local_parts_to_unix;
use crate::volume::{self, Source};

/// Maximale Länge eines Symlink-Ziels, die wir einlesen.
const MAX_LINK_LEN: u64 = 4096;

pub(crate) type Reader = ZipArchive<BufReader<Source>>;

/// Öffnet ein ZIP (auch byteweise aufgeteilt) und erkennt den Zeichensatz der Namen.
pub(crate) fn open(path: &Path) -> Result<(Reader, NameCodec)> {
    let archive = ZipArchive::new(BufReader::new(Source::open(path)?))?;
    let codec = name_codec(&archive)?;
    Ok((archive, codec))
}

fn name_codec(archive: &Reader) -> Result<NameCodec> {
    let mut raw = Vec::with_capacity(archive.len());
    for i in 0..archive.len() {
        raw.push(archive.by_index_data(i)?.name_raw().to_vec());
    }
    Ok(charset::detect(raw.iter().map(Vec::as_slice)))
}

/// Anzeigename eines Eintrags: UTF-8, sonst im erkannten Zeichensatz.
pub(crate) fn entry_name(e: &ZipFileEntry<'_>, codec: &NameCodec) -> String {
    normalize(&codec.decode(e.name_raw()))
}

fn modified(e: &ZipFileEntry<'_>) -> Option<i64> {
    let dt = e.last_modified()?;
    local_parts_to_unix(
        dt.year(),
        dt.month(),
        dt.day(),
        dt.hour(),
        dt.minute(),
        dt.second(),
    )
}

pub(crate) fn list(path: &Path) -> Result<Listing> {
    let (archive, codec) = open(path)?;
    let mut entries = Vec::with_capacity(archive.len());
    let mut any_encrypted = false;
    for i in 0..archive.len() {
        let e = archive.by_index_data(i)?;
        let encrypted = e.encrypted();
        any_encrypted |= encrypted;
        let name = entry_name(&e, &codec);
        if name.is_empty() {
            continue;
        }
        entries.push(Entry {
            path: name,
            is_dir: e.is_dir(),
            is_symlink: e.is_symlink(),
            size: e.size(),
            packed_size: Some(e.compressed_size()),
            crc32: (!e.is_dir()).then(|| e.crc32()),
            modified: modified(&e),
            encrypted,
            method: Some(e.compression().to_string()),
            unix_mode: e.unix_mode(),
        });
    }
    let comment = String::from_utf8_lossy(archive.comment()).trim().to_string();
    Ok(Listing {
        format: ArchiveFormat::Zip,
        entries,
        has_encrypted_entries: any_encrypted,
        header_encrypted: false,
        is_solid: false,
        comment: (!comment.is_empty()).then_some(comment),
        archive_size: volume::total_size(path)?,
        name_encoding: codec.needed.then(|| codec.legacy.label().to_string()),
    })
}

pub(crate) fn process(
    path: &Path,
    password: Option<&str>,
    sink: &mut dyn Sink,
    _tracker: &Tracker<'_>,
) -> Result<()> {
    let (mut archive, codec) = open(path)?;
    for i in 0..archive.len() {
        let (name, is_dir, is_symlink, encrypted, mtime, mode) = {
            let e = archive.by_index_data(i)?;
            (
                entry_name(&e, &codec),
                e.is_dir(),
                e.is_symlink(),
                e.encrypted(),
                modified(&e),
                e.unix_mode(),
            )
        };
        if name.is_empty() || !sink.wants(&name) {
            continue;
        }
        if is_dir {
            sink.directory(&name, mtime)?;
            continue;
        }
        let mut file = if encrypted {
            let pw = password.ok_or(ZippError::PasswordRequired)?;
            archive.by_index_decrypt(i, pw.as_bytes())?
        } else {
            archive.by_index(i)?
        };
        if is_symlink {
            let mut target = String::new();
            (&mut file)
                .take(MAX_LINK_LEN)
                .read_to_string(&mut target)
                .map_err(|e| crate::extract::read_error(e, &name))?;
            sink.symlink(&name, &target)?;
        } else {
            sink.file(&name, &mut file, mtime, mode)?;
        }
    }
    Ok(())
}
