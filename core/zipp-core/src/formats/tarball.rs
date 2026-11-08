//! TAR (auch .tar.gz/.bz2/.xz/.zst) und einzelne komprimierte Dateien.

use std::fs;
use std::io::{BufReader, Read};
use std::path::Path;

use crate::detect::read_up_to;
use crate::error::Result;
use crate::extract::Sink;
use crate::model::{ArchiveFormat, Entry, Listing, Stream};
use crate::progress::{ProgressReader, Tracker};
use crate::safety::normalize;
use crate::timeutil::system_time_to_unix;
use crate::volume::{self, Source};

/// Öffnet einen Dekompressions-Stream.
pub(crate) fn open_stream<'r, R: Read + 'r>(reader: R, stream: Stream) -> Result<Box<dyn Read + 'r>> {
    Ok(match stream {
        Stream::Plain => Box::new(BufReader::new(reader)),
        Stream::Gzip => Box::new(flate2::read::MultiGzDecoder::new(BufReader::new(reader))),
        Stream::Bzip2 => Box::new(bzip2::read::MultiBzDecoder::new(BufReader::new(reader))),
        Stream::Xz => Box::new(liblzma::read::XzDecoder::new_multi_decoder(BufReader::new(
            reader,
        ))),
        Stream::Zstd => Box::new(zstd::stream::read::Decoder::new(reader)?),
    })
}

/// Name der Datei in einer einzeln komprimierten Datei: „log.txt.gz“ → „log.txt“.
fn single_name(path: &Path) -> String {
    let name = volume::logical_name(path);
    let lower = name.to_lowercase();
    for ext in [".gz", ".gzip", ".bz2", ".bzip2", ".xz", ".zst", ".zstd"] {
        if lower.ends_with(ext) && name.len() > ext.len() {
            return name[..name.len() - ext.len()].to_string();
        }
    }
    format!("{name}.entpackt")
}

fn archive_mtime(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(system_time_to_unix)
}

pub(crate) fn list(path: &Path, format: ArchiveFormat) -> Result<Listing> {
    let archive_size = volume::total_size(path)?;
    if let Some(stream) = format.single_stream() {
        // gzip speichert die Originalgröße (mod 2^32) in den letzten 4 Bytes.
        let size = if stream == Stream::Gzip {
            gzip_isize(path).unwrap_or(0)
        } else {
            0
        };
        return Ok(Listing {
            format,
            entries: vec![Entry {
                path: single_name(path),
                is_dir: false,
                is_symlink: false,
                size,
                packed_size: Some(archive_size),
                crc32: None,
                modified: archive_mtime(path),
                encrypted: false,
                method: Some(format.label().to_string()),
                unix_mode: None,
            }],
            has_encrypted_entries: false,
            header_encrypted: false,
            is_solid: true,
            comment: None,
            archive_size,
            name_encoding: None,
        });
    }

    let stream = format.tar_stream().unwrap_or(Stream::Plain);
    let mut archive = tar::Archive::new(open_stream(Source::open(path)?, stream)?);
    let mut entries = Vec::new();
    for item in archive.entries()? {
        let entry = item?;
        let name = normalize(&entry.path()?.to_string_lossy());
        if name.is_empty() {
            continue;
        }
        let header = entry.header();
        let kind = header.entry_type();
        entries.push(Entry {
            path: name,
            is_dir: kind.is_dir(),
            is_symlink: kind.is_symlink(),
            size: if kind.is_dir() { 0 } else { entry.size() },
            packed_size: None,
            crc32: None,
            modified: header.mtime().ok().and_then(|t| i64::try_from(t).ok()),
            encrypted: false,
            method: None,
            unix_mode: header.mode().ok(),
        });
    }
    Ok(Listing {
        format,
        entries,
        has_encrypted_entries: false,
        header_encrypted: false,
        is_solid: stream != Stream::Plain,
        comment: None,
        archive_size,
        name_encoding: None,
    })
}

fn gzip_isize(path: &Path) -> Option<u64> {
    use std::io::{Seek, SeekFrom};
    let mut f = Source::open(path).ok()?;
    f.seek(SeekFrom::End(-4)).ok()?;
    let mut buf = [0u8; 4];
    (read_up_to(&mut f, &mut buf).ok()? == 4).then(|| u64::from(u32::from_le_bytes(buf)))
}

pub(crate) fn process(
    path: &Path,
    format: ArchiveFormat,
    sink: &mut dyn Sink,
    tracker: &Tracker<'_>,
) -> Result<()> {
    // Fortschritt = gelesene Bytes der (komprimierten) Archivdatei
    let counted = ProgressReader::new(Source::open(path)?, tracker);

    if let Some(stream) = format.single_stream() {
        let name = single_name(path);
        if sink.wants(&name) {
            let mut data = open_stream(counted, stream)?;
            sink.file(&name, &mut data, archive_mtime(path), None)?;
        }
        return Ok(());
    }

    let stream = format.tar_stream().unwrap_or(Stream::Plain);
    let mut archive = tar::Archive::new(open_stream(counted, stream)?);
    for item in archive.entries()? {
        let mut entry = item?;
        let name = normalize(&entry.path()?.to_string_lossy());
        if name.is_empty() || !sink.wants(&name) {
            continue;
        }
        let (kind, mtime, mode) = {
            let h = entry.header();
            (
                h.entry_type(),
                h.mtime().ok().and_then(|t| i64::try_from(t).ok()),
                h.mode().ok(),
            )
        };
        if kind.is_dir() {
            sink.directory(&name, mtime)?;
        } else if kind.is_symlink() {
            let target = entry
                .link_name()?
                .map(|t| t.to_string_lossy().into_owned())
                .unwrap_or_default();
            sink.symlink(&name, &target)?;
        } else if kind.is_file() {
            sink.file(&name, &mut entry, mtime, mode)?;
        } else {
            // Hardlinks, Geräte, FIFOs: bewusst nicht anlegen
            sink.unsupported(&name);
        }
    }
    Ok(())
}
