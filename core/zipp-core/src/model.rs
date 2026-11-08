//! Datenmodell: Formate, Einträge, Inhaltsverzeichnis.

use std::collections::BTreeSet;

/// Unterstützte Archivformate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArchiveFormat {
    Zip,
    SevenZip,
    Rar,
    Tar,
    TarGz,
    TarBz2,
    TarXz,
    TarZst,
    /// Einzelne mit gzip komprimierte Datei (z. B. `log.txt.gz`)
    Gzip,
    Bzip2,
    Xz,
    Zstd,
}

/// Kompressionsschicht unter TAR bzw. einer Einzeldatei.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Stream {
    Plain,
    Gzip,
    Bzip2,
    Xz,
    Zstd,
}

impl ArchiveFormat {
    /// Kurzname für die Anzeige.
    pub fn label(self) -> &'static str {
        match self {
            Self::Zip => "ZIP",
            Self::SevenZip => "7z",
            Self::Rar => "RAR",
            Self::Tar => "TAR",
            Self::TarGz => "TAR.GZ",
            Self::TarBz2 => "TAR.BZ2",
            Self::TarXz => "TAR.XZ",
            Self::TarZst => "TAR.ZST",
            Self::Gzip => "GZ",
            Self::Bzip2 => "BZ2",
            Self::Xz => "XZ",
            Self::Zstd => "ZST",
        }
    }

    /// Kann ZIPP Dateien hinzufügen, löschen und umbenennen?
    /// (ZIP direkt, 7z und TAR.* durch Neuschreiben; RAR nie, aus Lizenzgründen.)
    pub fn supports_editing(self) -> bool {
        matches!(
            self,
            Self::Zip | Self::SevenZip | Self::Tar | Self::TarGz | Self::TarBz2 | Self::TarXz | Self::TarZst
        )
    }

    /// Wird beim Bearbeiten das ganze Archiv neu geschrieben (dauert bei großen Archiven)?
    pub fn edit_rewrites_all(self) -> bool {
        self.supports_editing() && self != Self::Zip
    }

    pub(crate) fn tar_stream(self) -> Option<Stream> {
        match self {
            Self::Tar => Some(Stream::Plain),
            Self::TarGz => Some(Stream::Gzip),
            Self::TarBz2 => Some(Stream::Bzip2),
            Self::TarXz => Some(Stream::Xz),
            Self::TarZst => Some(Stream::Zstd),
            _ => None,
        }
    }

    pub(crate) fn single_stream(self) -> Option<Stream> {
        match self {
            Self::Gzip => Some(Stream::Gzip),
            Self::Bzip2 => Some(Stream::Bzip2),
            Self::Xz => Some(Stream::Xz),
            Self::Zstd => Some(Stream::Zstd),
            _ => None,
        }
    }
}

/// Ein Eintrag im Archiv.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Pfad im Archiv, mit `/` getrennt, ohne abschließenden Schrägstrich.
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    /// Entpackte Größe in Bytes.
    pub size: u64,
    /// Gepackte Größe, falls das Format sie pro Eintrag kennt.
    pub packed_size: Option<u64>,
    pub crc32: Option<u32>,
    /// Änderungszeit als Unix-Zeit (UTC).
    pub modified: Option<i64>,
    pub encrypted: bool,
    /// Kompressionsmethode, z. B. „Deflated“.
    pub method: Option<String>,
    /// Unix-Dateirechte, falls gespeichert.
    pub unix_mode: Option<u32>,
}

/// Inhaltsverzeichnis eines Archivs.
#[derive(Debug, Clone)]
pub struct Listing {
    pub format: ArchiveFormat,
    pub entries: Vec<Entry>,
    pub has_encrypted_entries: bool,
    /// Auch die Dateinamen sind verschlüsselt (7z/RAR).
    pub header_encrypted: bool,
    pub is_solid: bool,
    pub comment: Option<String>,
    /// Größe der Archivdatei (bei mehrteiligen Archiven aller Teile).
    pub archive_size: u64,
    /// Zeichensatz der Dateinamen, falls nicht UTF-8 (nur ZIP), z. B. „CP850 (DOS, Westeuropa)“.
    pub name_encoding: Option<String>,
}

impl Listing {
    /// Summe der entpackten Größen.
    pub fn total_size(&self) -> u64 {
        self.entries.iter().filter(|e| !e.is_dir).map(|e| e.size).sum()
    }

    /// Namen der obersten Ebene (auch implizite Ordner).
    pub fn top_level_names(&self) -> BTreeSet<&str> {
        self.entries
            .iter()
            .filter_map(|e| e.path.split('/').next())
            .filter(|s| !s.is_empty())
            .collect()
    }

    /// Liegt alles in genau einem Ordner auf oberster Ebene, dessen Name.
    ///
    /// Grundlage für „intelligentes Entpacken“: dann braucht es keinen
    /// zusätzlichen Ordner.
    pub fn single_root_folder(&self) -> Option<String> {
        let tops = self.top_level_names();
        if tops.len() != 1 {
            return None;
        }
        let root = *tops.iter().next()?;
        let is_folder = self
            .entries
            .iter()
            .any(|e| e.path.contains('/') || (e.is_dir && e.path == root));
        is_folder.then(|| root.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str, is_dir: bool) -> Entry {
        Entry {
            path: path.into(),
            is_dir,
            is_symlink: false,
            size: 1,
            packed_size: None,
            crc32: None,
            modified: None,
            encrypted: false,
            method: None,
            unix_mode: None,
        }
    }

    fn listing(entries: Vec<Entry>) -> Listing {
        Listing {
            format: ArchiveFormat::Zip,
            entries,
            has_encrypted_entries: false,
            header_encrypted: false,
            is_solid: false,
            comment: None,
            archive_size: 0,
            name_encoding: None,
        }
    }

    #[test]
    fn single_root() {
        let l = listing(vec![entry("proj/a.txt", false), entry("proj/b", true)]);
        assert_eq!(l.single_root_folder().as_deref(), Some("proj"));
        let l = listing(vec![entry("a.txt", false), entry("b.txt", false)]);
        assert_eq!(l.single_root_folder(), None);
        let l = listing(vec![entry("only.txt", false)]);
        assert_eq!(l.single_root_folder(), None);
        let l = listing(vec![entry("emptydir", true)]);
        assert_eq!(l.single_root_folder().as_deref(), Some("emptydir"));
    }
}
