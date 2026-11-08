//! zipp-core: die Archiv-Engine von ZIPP.
//!
//! Liest ZIP, 7z, RAR, TAR (+ gz/bz2/xz/zst) und einzeln komprimierte Dateien,
//! erstellt ZIP, 7z und TAR.* (auch aufgeteilt), bearbeitet ZIP, 7z und TAR.*. Alles, was aus einem Archiv
//! kommt, gilt als nicht vertrauenswürdig: Pfade werden bereinigt, Symlinks
//! geprüft, und die Quarantäne-Markierung wird weitergegeben.

mod charset;
mod create;
mod detect;
mod error;
mod extract;
mod formats;
mod model;
mod modify;
mod progress;
mod safety;
mod timeutil;
mod volume;

use std::path::Path;

pub use create::{CreateFormat, CreateOptions, CreateSummary, create_archive};
pub use detect::detect_format;
pub use error::{Result, ZippError};
pub use extract::{
    ExtractOptions, ExtractSummary, OverwritePolicy, TestSummary, extract_archive, test_archive,
};
pub use model::{ArchiveFormat, Entry, Listing};
pub use modify::{
    AddOptions, add_to_archive, check_password, convert_archive, create_folder_in_archive,
    delete_from_archive, rename_in_archive,
};
pub use progress::{NoProgress, Progress};
pub use volume::{MIN_VOLUME_SIZE, all_volumes, first_volume, logical_name};

/// Liest das Inhaltsverzeichnis eines Archivs. Bei mehrteiligen Archiven
/// darf `path` ein beliebiger Teil sein.
pub fn list_archive(path: &Path, password: Option<&str>) -> Result<Listing> {
    let path = &first_volume(path);
    let format = detect_format(path)?;
    formats::list(path, format, password)
}
