//! RAR lesen über den offiziellen UnRAR-Quellcode (nur Entpacken erlaubt).

use std::fs;
use std::path::Path;

use unrar::Archive;

use crate::error::{Result, ZippError};
use crate::extract::{ExternalAction, Sink};
use crate::model::{ArchiveFormat, Entry, Listing};
use crate::progress::Tracker;
use crate::safety::normalize;
use crate::timeutil::dos_packed_to_unix;
use crate::volume;

fn archive<'a>(path: &'a Path, password: Option<&'a str>) -> Archive<'a> {
    match password {
        Some(pw) => Archive::with_password(path, pw.as_bytes()),
        None => Archive::new(path),
    }
}

pub(crate) fn list(path: &Path, password: Option<&str>) -> Result<Listing> {
    let open = archive(path, password).open_for_listing()?;
    let is_solid = open.is_solid();
    let header_encrypted = open.has_encrypted_headers();
    let mut entries = Vec::new();
    let mut any_encrypted = header_encrypted;
    for item in open {
        let h = item?;
        let name = normalize(&h.filename.to_string_lossy());
        if name.is_empty() {
            continue;
        }
        any_encrypted |= h.is_encrypted();
        entries.push(Entry {
            path: name,
            is_dir: h.is_directory(),
            is_symlink: false,
            size: h.unpacked_size,
            packed_size: None,
            crc32: (!h.is_directory()).then_some(h.file_crc),
            modified: dos_packed_to_unix(h.file_time),
            encrypted: h.is_encrypted(),
            method: None,
            unix_mode: None,
        });
    }
    Ok(Listing {
        format: ArchiveFormat::Rar,
        entries,
        has_encrypted_entries: any_encrypted,
        header_encrypted,
        is_solid,
        comment: None,
        archive_size: volume::total_size(path)?,
        name_encoding: None,
    })
}

pub(crate) fn process(
    path: &Path,
    password: Option<&str>,
    sink: &mut dyn Sink,
    _tracker: &Tracker<'_>,
) -> Result<()> {
    let mut open = archive(path, password).open_for_processing()?;
    while let Some(header) = open.read_header()? {
        let (name, is_dir, size, mtime, encrypted) = {
            let e = header.entry();
            (
                normalize(&e.filename.to_string_lossy()),
                e.is_directory(),
                e.unpacked_size,
                dos_packed_to_unix(e.file_time),
                e.is_encrypted(),
            )
        };
        if name.is_empty() || !sink.wants(&name) {
            open = header.skip()?;
            continue;
        }
        if is_dir {
            sink.directory(&name, mtime)?;
            open = header.skip()?;
            continue;
        }
        if encrypted && password.is_none() {
            return Err(ZippError::PasswordRequired);
        }
        open = match sink.external(&name)? {
            ExternalAction::Skip => {
                let next = header.skip()?;
                sink.external_done(None, size, mtime)?;
                next
            }
            ExternalAction::Test => {
                let next = header.test().map_err(|e| checksum_or(e, &name))?;
                sink.external_done(None, size, mtime)?;
                next
            }
            ExternalAction::Extract(target) => match header.extract_to(&target) {
                Ok(next) => {
                    sink.external_done(Some(&target), size, mtime)?;
                    next
                }
                Err(e) => {
                    let _ = fs::remove_file(&target);
                    return Err(checksum_or(e, &name));
                }
            },
        };
    }
    Ok(())
}

fn checksum_or(e: unrar::error::UnrarError, name: &str) -> ZippError {
    match e.code {
        unrar::error::Code::BadData => ZippError::ChecksumMismatch(name.to_string()),
        _ => e.into(),
    }
}
