//! Swift-Schnittstelle (UniFFI) für zipp-core.
//!
//! Bewusst eine dünne Schicht: nur Typen umwandeln, keine Logik. Alle
//! Funktionen blockieren und werden in der App auf einem Hintergrund-Thread
//! aufgerufen.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use zipp_core as core;

uniffi::setup_scaffolding!();

// MARK: - Fehler

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ZippError {
    #[error("Für dieses Archiv wird ein Passwort benötigt.")]
    PasswordRequired,
    #[error("Das Passwort ist falsch.")]
    WrongPassword,
    #[error("Unbekanntes oder nicht unterstütztes Archivformat.")]
    UnsupportedFormat,
    #[error("Das Archiv ist beschädigt: {message}")]
    Corrupt { message: String },
    #[error("Prüfsummenfehler bei „{path}“.")]
    ChecksumMismatch { path: String },
    #[error("Der Vorgang wurde abgebrochen.")]
    Cancelled,
    #[error("Nicht verfügbar: {message}")]
    Unsupported { message: String },
    #[error("Ein-/Ausgabefehler: {message}")]
    Io { message: String },
}

impl From<core::ZippError> for ZippError {
    fn from(e: core::ZippError) -> Self {
        use core::ZippError as E;
        match e {
            E::PasswordRequired => Self::PasswordRequired,
            E::WrongPassword => Self::WrongPassword,
            E::UnsupportedFormat => Self::UnsupportedFormat,
            E::Corrupt(message) => Self::Corrupt { message },
            E::ChecksumMismatch(path) => Self::ChecksumMismatch { path },
            E::Cancelled => Self::Cancelled,
            E::Unsupported(message) => Self::Unsupported { message },
            E::Io(message) => Self::Io { message },
        }
    }
}

type Result<T> = std::result::Result<T, ZippError>;

// MARK: - Fortschritt

/// Wird in Swift implementiert.
#[uniffi::export(foreign)]
pub trait ProgressListener: Send + Sync {
    fn on_progress(&self, done: u64, total: u64, current: String);
    fn is_cancelled(&self) -> bool;
}

struct ProgressAdapter(Arc<dyn ProgressListener>);

impl core::Progress for ProgressAdapter {
    fn update(&self, done: u64, total: u64, current: &str) {
        self.0.on_progress(done, total, current.to_string());
    }

    fn is_cancelled(&self) -> bool {
        self.0.is_cancelled()
    }
}

// MARK: - Modell

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ArchiveFormat {
    Zip,
    SevenZip,
    Rar,
    Tar,
    TarGz,
    TarBz2,
    TarXz,
    TarZst,
    Gzip,
    Bzip2,
    Xz,
    Zstd,
}

impl From<core::ArchiveFormat> for ArchiveFormat {
    fn from(f: core::ArchiveFormat) -> Self {
        use core::ArchiveFormat as F;
        match f {
            F::Zip => Self::Zip,
            F::SevenZip => Self::SevenZip,
            F::Rar => Self::Rar,
            F::Tar => Self::Tar,
            F::TarGz => Self::TarGz,
            F::TarBz2 => Self::TarBz2,
            F::TarXz => Self::TarXz,
            F::TarZst => Self::TarZst,
            F::Gzip => Self::Gzip,
            F::Bzip2 => Self::Bzip2,
            F::Xz => Self::Xz,
            F::Zstd => Self::Zstd,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ArchiveEntry {
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub packed_size: Option<u64>,
    pub crc32: Option<u32>,
    /// Unix-Zeit (UTC)
    pub modified: Option<i64>,
    pub encrypted: bool,
    pub method: Option<String>,
    pub unix_mode: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ArchiveListing {
    pub format: ArchiveFormat,
    pub format_label: String,
    pub entries: Vec<ArchiveEntry>,
    pub has_encrypted_entries: bool,
    pub header_encrypted: bool,
    pub is_solid: bool,
    pub comment: Option<String>,
    pub archive_size: u64,
    pub total_size: u64,
    /// Liegt alles in genau einem Ordner? Dann braucht es beim Entpacken keinen weiteren.
    pub single_root_folder: Option<String>,
    pub top_level_count: u32,
    /// Hinzufügen, Löschen, Umbenennen und neue Ordner sind möglich.
    pub supports_editing: bool,
    /// Bearbeiten schreibt das ganze Archiv neu (7z, TAR.*), dauert also bei großen Archiven.
    pub edit_rewrites_all: bool,
    /// Zeichensatz der Dateinamen, falls nicht UTF-8 (z. B. „CP850 (DOS, Westeuropa)“).
    pub name_encoding: Option<String>,
    /// Anzahl der Teile (1 = normales Archiv).
    pub volume_count: u32,
}

impl ArchiveListing {
    fn new(l: core::Listing, path: &Path) -> Self {
        let volume_count = u32::try_from(core::all_volumes(path).len()).unwrap_or(1);
        let mut listing = Self::from(l);
        listing.volume_count = volume_count;
        if volume_count > 1 {
            listing.supports_editing = false;
            listing.edit_rewrites_all = false;
        }
        listing
    }
}

impl From<core::Listing> for ArchiveListing {
    fn from(l: core::Listing) -> Self {
        let single_root_folder = l.single_root_folder();
        let top_level_count = u32::try_from(l.top_level_names().len()).unwrap_or(u32::MAX);
        let total_size = l.total_size();
        Self {
            format: l.format.into(),
            format_label: l.format.label().to_string(),
            has_encrypted_entries: l.has_encrypted_entries,
            header_encrypted: l.header_encrypted,
            is_solid: l.is_solid,
            comment: l.comment,
            archive_size: l.archive_size,
            total_size,
            single_root_folder,
            top_level_count,
            supports_editing: l.format.supports_editing(),
            edit_rewrites_all: l.format.edit_rewrites_all(),
            name_encoding: l.name_encoding,
            volume_count: 1,
            entries: l
                .entries
                .into_iter()
                .map(|e| ArchiveEntry {
                    path: e.path,
                    is_dir: e.is_dir,
                    is_symlink: e.is_symlink,
                    size: e.size,
                    packed_size: e.packed_size,
                    crc32: e.crc32,
                    modified: e.modified,
                    encrypted: e.encrypted,
                    method: e.method,
                    unix_mode: e.unix_mode,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OverwritePolicy {
    Replace,
    Skip,
    KeepBoth,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ExtractOptions {
    pub password: Option<String>,
    /// Leer = alles
    pub selection: Vec<String>,
    pub strip_prefix: Option<String>,
    pub overwrite: OverwritePolicy,
    pub apply_quarantine: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ExtractSummary {
    pub files: u64,
    pub directories: u64,
    pub symlinks: u64,
    pub bytes: u64,
    pub skipped_unsafe: Vec<String>,
    pub skipped_existing: u64,
    pub renamed: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TestSummary {
    pub files: u64,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CreateFormat {
    Zip,
    SevenZip,
    TarGz,
    TarXz,
    TarZst,
    TarBz2,
    Tar,
}

impl From<CreateFormat> for core::CreateFormat {
    fn from(f: CreateFormat) -> Self {
        match f {
            CreateFormat::Tar => Self::Tar,
            CreateFormat::Zip => Self::Zip,
            CreateFormat::SevenZip => Self::SevenZip,
            CreateFormat::TarGz => Self::TarGz,
            CreateFormat::TarXz => Self::TarXz,
            CreateFormat::TarZst => Self::TarZst,
            CreateFormat::TarBz2 => Self::TarBz2,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CreateOptions {
    pub format: CreateFormat,
    /// 0 = speichern, 9 = maximal
    pub level: u8,
    pub password: Option<String>,
    pub encrypt_file_names: bool,
    pub exclude_mac_metadata: bool,
    /// In Teile dieser Größe aufteilen (Bytes). `None` = eine Datei.
    pub volume_size: Option<u64>,
}

impl From<CreateOptions> for core::CreateOptions {
    fn from(o: CreateOptions) -> Self {
        Self {
            format: o.format.into(),
            level: o.level,
            password: o.password,
            encrypt_file_names: o.encrypt_file_names,
            exclude_mac_metadata: o.exclude_mac_metadata,
            volume_size: o.volume_size,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CreateSummary {
    pub files: u64,
    pub directories: u64,
    pub bytes_in: u64,
    pub bytes_out: u64,
    /// Geschriebene Dateien (bei aufgeteilten Archiven alle Teile).
    pub outputs: Vec<String>,
}

impl From<core::CreateSummary> for CreateSummary {
    fn from(s: core::CreateSummary) -> Self {
        Self {
            files: s.files,
            directories: s.directories,
            bytes_in: s.bytes_in,
            bytes_out: s.bytes_out,
            outputs: s
                .outputs
                .into_iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AddOptions {
    pub level: u8,
    pub password: Option<String>,
    pub exclude_mac_metadata: bool,
}

// MARK: - Funktionen

/// Version des Kerns (für „Über ZIPP“).
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn detect_format(path: String) -> Result<ArchiveFormat> {
    Ok(core::detect_format(Path::new(&path))?.into())
}

#[uniffi::export]
pub fn list_archive(path: String, password: Option<String>) -> Result<ArchiveListing> {
    let path = Path::new(&path);
    Ok(ArchiveListing::new(
        core::list_archive(path, password.as_deref())?,
        path,
    ))
}

#[uniffi::export]
pub fn extract_archive(
    path: String,
    destination: String,
    options: ExtractOptions,
    progress: Arc<dyn ProgressListener>,
) -> Result<ExtractSummary> {
    let options = core::ExtractOptions {
        password: options.password,
        selection: options.selection,
        strip_prefix: options.strip_prefix,
        overwrite: match options.overwrite {
            OverwritePolicy::Replace => core::OverwritePolicy::Replace,
            OverwritePolicy::Skip => core::OverwritePolicy::Skip,
            OverwritePolicy::KeepBoth => core::OverwritePolicy::KeepBoth,
        },
        apply_quarantine: options.apply_quarantine,
    };
    let s = core::extract_archive(
        Path::new(&path),
        Path::new(&destination),
        &options,
        &ProgressAdapter(progress),
    )?;
    Ok(ExtractSummary {
        files: s.files,
        directories: s.directories,
        symlinks: s.symlinks,
        bytes: s.bytes,
        skipped_unsafe: s.skipped_unsafe,
        skipped_existing: s.skipped_existing,
        renamed: s.renamed,
    })
}

#[uniffi::export]
pub fn test_archive(
    path: String,
    password: Option<String>,
    progress: Arc<dyn ProgressListener>,
) -> Result<TestSummary> {
    let s = core::test_archive(Path::new(&path), password.as_deref(), &ProgressAdapter(progress))?;
    Ok(TestSummary {
        files: s.files,
        bytes: s.bytes,
    })
}

#[uniffi::export]
pub fn create_archive(
    sources: Vec<String>,
    destination: String,
    options: CreateOptions,
    progress: Arc<dyn ProgressListener>,
) -> Result<CreateSummary> {
    let sources: Vec<PathBuf> = sources.into_iter().map(PathBuf::from).collect();
    Ok(core::create_archive(
        &sources,
        Path::new(&destination),
        &options.into(),
        &ProgressAdapter(progress),
    )?
    .into())
}

#[uniffi::export]
pub fn add_to_archive(
    path: String,
    sources: Vec<String>,
    inner_dir: String,
    options: AddOptions,
    progress: Arc<dyn ProgressListener>,
) -> Result<CreateSummary> {
    let sources: Vec<PathBuf> = sources.into_iter().map(PathBuf::from).collect();
    let options = core::AddOptions {
        level: options.level,
        password: options.password,
        exclude_mac_metadata: options.exclude_mac_metadata,
    };
    Ok(core::add_to_archive(
        Path::new(&path),
        &sources,
        &inner_dir,
        &options,
        &ProgressAdapter(progress),
    )?
    .into())
}

#[uniffi::export]
pub fn delete_from_archive(
    path: String,
    paths: Vec<String>,
    password: Option<String>,
    progress: Arc<dyn ProgressListener>,
) -> Result<u64> {
    Ok(core::delete_from_archive(
        Path::new(&path),
        &paths,
        password.as_deref(),
        &ProgressAdapter(progress),
    )?)
}

/// Benennt eine Datei oder einen Ordner im Archiv um. Gibt den neuen Pfad zurück.
#[uniffi::export]
pub fn rename_in_archive(
    path: String,
    entry: String,
    new_name: String,
    password: Option<String>,
    progress: Arc<dyn ProgressListener>,
) -> Result<String> {
    Ok(core::rename_in_archive(
        Path::new(&path),
        &entry,
        &new_name,
        password.as_deref(),
        &ProgressAdapter(progress),
    )?)
}

/// Legt einen leeren Ordner im Archiv an. Gibt seinen Pfad zurück.
#[uniffi::export]
pub fn create_folder_in_archive(
    path: String,
    inner_dir: String,
    name: String,
    password: Option<String>,
    progress: Arc<dyn ProgressListener>,
) -> Result<String> {
    Ok(core::create_folder_in_archive(
        Path::new(&path),
        &inner_dir,
        &name,
        password.as_deref(),
        &ProgressAdapter(progress),
    )?)
}

/// Wandelt ein Archiv in ein anderes Format um.
#[uniffi::export]
pub fn convert_archive(
    path: String,
    password: Option<String>,
    destination: String,
    options: CreateOptions,
    progress: Arc<dyn ProgressListener>,
) -> Result<CreateSummary> {
    Ok(core::convert_archive(
        Path::new(&path),
        password.as_deref(),
        Path::new(&destination),
        &options.into(),
        &ProgressAdapter(progress),
    )?
    .into())
}

/// Stimmt das Passwort? (Für die Passwort-Liste: schnell, ohne zu entpacken.)
#[uniffi::export]
pub fn check_password(path: String, password: String) -> Result<bool> {
    Ok(core::check_password(Path::new(&path), &password)?)
}

/// Erster Teil eines mehrteiligen Archivs (oder der Pfad selbst).
#[uniffi::export]
pub fn first_volume(path: String) -> String {
    core::first_volume(Path::new(&path))
        .to_string_lossy()
        .into_owned()
}

/// Alle Teile eines mehrteiligen Archivs in Reihenfolge (oder nur der Pfad selbst).
#[uniffi::export]
pub fn archive_volumes(path: String) -> Vec<String> {
    core::all_volumes(Path::new(&path))
        .into_iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect()
}

/// Archivname ohne Teilnummer: „Fotos.7z.001“ → „Fotos.7z“, „Fotos.part1.rar“ → „Fotos.rar“.
#[uniffi::export]
pub fn archive_logical_name(path: String) -> String {
    core::logical_name(Path::new(&path))
}

/// Kleinste erlaubte Teilgröße in Bytes.
#[uniffi::export]
pub fn min_volume_size() -> u64 {
    core::MIN_VOLUME_SIZE
}

/// Dateiendung ohne Punkt, z. B. „tar.gz“.
#[uniffi::export]
pub fn create_format_extension(format: CreateFormat) -> String {
    core::CreateFormat::from(format).extension().to_string()
}
