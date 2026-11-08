//! Format-spezifischer Code. Jedes Modul kann auflisten und seine Einträge
//! an eine [`Sink`](crate::extract::Sink) liefern.

pub(crate) mod rarfile;
pub(crate) mod sevenz;
pub(crate) mod tarball;
pub(crate) mod zipfile;

use std::path::Path;

use crate::error::Result;
use crate::extract::Sink;
use crate::model::{ArchiveFormat, Listing};
use crate::progress::Tracker;

pub(crate) fn list(path: &Path, format: ArchiveFormat, password: Option<&str>) -> Result<Listing> {
    match format {
        ArchiveFormat::Zip => zipfile::list(path),
        ArchiveFormat::SevenZip => sevenz::list(path, password),
        ArchiveFormat::Rar => rarfile::list(path, password),
        _ => tarball::list(path, format),
    }
}

pub(crate) fn process(
    path: &Path,
    format: ArchiveFormat,
    password: Option<&str>,
    sink: &mut dyn Sink,
    tracker: &Tracker<'_>,
) -> Result<()> {
    match format {
        ArchiveFormat::Zip => zipfile::process(path, password, sink, tracker),
        ArchiveFormat::SevenZip => sevenz::process(path, password, sink, tracker),
        ArchiveFormat::Rar => rarfile::process(path, password, sink, tracker),
        _ => tarball::process(path, format, sink, tracker),
    }
}
