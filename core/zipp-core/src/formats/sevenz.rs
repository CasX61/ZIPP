//! 7z lesen (inkl. AES-256 und verschlüsselter Dateinamen).

use std::io::Read as _;
use std::path::Path;
use std::time::SystemTime;

use sevenz_rust2::{Archive, ArchiveEntry, ArchiveReader, EntryDecision, Password};

use crate::error::{Result, ZippError};
use crate::extract::Sink;
use crate::model::{ArchiveFormat, Entry, Listing};
use crate::progress::Tracker;
use crate::safety::normalize;
use crate::timeutil::system_time_to_unix;
use crate::volume::{self, Source};

/// Windows-Attribut-Flag von p7zip: in den oberen 16 Bit stehen Unix-Rechte.
const UNIX_EXTENSION: u32 = 0x8000;
const S_IFMT: u32 = 0o170_000;
const S_IFLNK: u32 = 0o120_000;

pub(crate) fn password(password: Option<&str>) -> Password {
    password.map_or_else(Password::empty, Password::new)
}

fn unix_mode(entry: &ArchiveEntry) -> Option<u32> {
    (entry.has_windows_attributes && entry.windows_attributes & UNIX_EXTENSION != 0)
        .then_some(entry.windows_attributes >> 16)
}

fn is_symlink(entry: &ArchiveEntry) -> bool {
    unix_mode(entry).is_some_and(|m| m & S_IFMT == S_IFLNK)
}

fn modified(entry: &ArchiveEntry) -> Option<i64> {
    entry
        .has_last_modified_date
        .then(|| system_time_to_unix(SystemTime::from(entry.last_modified_date)))
        .flatten()
}

pub(crate) fn list(path: &Path, pw: Option<&str>) -> Result<Listing> {
    let archive = Archive::read(&mut Source::open(path)?, &password(pw))?;
    let mut any_encrypted = false;
    let mut entries = Vec::with_capacity(archive.files.len());
    for (i, f) in archive.files.iter().enumerate() {
        if f.is_anti_item {
            continue;
        }
        let name = normalize(f.name());
        if name.is_empty() {
            continue;
        }
        let encrypted = archive.is_file_encrypted(i);
        any_encrypted |= encrypted;
        entries.push(Entry {
            path: name,
            is_dir: f.is_directory(),
            is_symlink: is_symlink(f),
            size: f.size(),
            packed_size: (f.compressed_size > 0).then_some(f.compressed_size),
            crc32: (f.has_crc).then(|| u32::try_from(f.crc & 0xFFFF_FFFF).unwrap_or(0)),
            modified: modified(f),
            encrypted,
            method: None,
            unix_mode: unix_mode(f),
        });
    }
    Ok(Listing {
        format: ArchiveFormat::SevenZip,
        entries,
        has_encrypted_entries: any_encrypted,
        // Ohne Passwort wäre das Auflisten schon gescheitert; mit Passwort nachprüfen.
        header_encrypted: pw.is_some() && header_needs_password(path),
        is_solid: archive.is_solid,
        comment: None,
        archive_size: volume::total_size(path)?,
        name_encoding: None,
    })
}

fn header_needs_password(path: &Path) -> bool {
    let Ok(mut source) = Source::open(path) else {
        return false;
    };
    matches!(
        Archive::read(&mut source, &Password::empty()),
        Err(sevenz_rust2::Error::PasswordRequired)
    )
}

pub(crate) fn process(
    path: &Path,
    pw: Option<&str>,
    sink: &mut dyn Sink,
    _tracker: &Tracker<'_>,
) -> Result<()> {
    let mut reader = ArchiveReader::new(Source::open(path)?, password(pw))?;
    let mut failure: Option<ZippError> = None;
    let result = reader.for_each_entries_with_decision(|entry, data| {
        let name = normalize(entry.name());
        if entry.is_anti_item || name.is_empty() || !sink.wants(&name) {
            return Ok(EntryDecision::Continue);
        }
        let step = if entry.is_directory() {
            sink.directory(&name, modified(entry))
        } else if is_symlink(entry) {
            let mut target = String::new();
            match data.take(4096).read_to_string(&mut target) {
                Ok(_) => sink.symlink(&name, &target),
                Err(e) => Err(crate::extract::read_error(e, &name)),
            }
        } else {
            sink.file(&name, data, modified(entry), unix_mode(entry))
        };
        match step {
            Ok(()) => Ok(EntryDecision::Continue),
            Err(e) => {
                failure = Some(e);
                Ok(EntryDecision::Stop)
            }
        }
    });
    if let Some(e) = failure {
        return Err(e);
    }
    result.map_err(|e| match ZippError::from(e) {
        // Ohne Passwort meldet 7z bei verschlüsseltem Inhalt oft nur „Daten fehlerhaft“.
        ZippError::Corrupt(_) | ZippError::ChecksumMismatch(_) if pw.is_none() => ZippError::PasswordRequired,
        other => other,
    })
}
