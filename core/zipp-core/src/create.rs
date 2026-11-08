//! Archive erstellen: ZIP (AES-256), 7z (AES-256, Dateinamen verschlüsselt), TAR.*

use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, BufWriter, Cursor, Seek, Write};
use std::path::{Path, PathBuf};

use sevenz_rust2::encoder_options::{AesEncoderOptions, Lzma2Options};
use sevenz_rust2::{ArchiveEntry, ArchiveWriter, EncoderConfiguration, EncoderMethod, Password};
use walkdir::WalkDir;
use zip::write::SimpleFileOptions;
use zip::{AesMode, CompressionMethod, DateTime, ZipWriter};

use crate::error::{Result, ZippError};
use crate::progress::{Progress, ProgressReader, Tracker};
use crate::timeutil::{system_time_to_unix, unix_to_local_parts};
use crate::volume::OutputFile;

/// Formate, die ZIPP erstellen kann (RAR ist aus Lizenzgründen nicht möglich).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CreateFormat {
    #[default]
    Zip,
    SevenZip,
    TarGz,
    TarXz,
    TarZst,
    TarBz2,
    /// TAR ohne Kompression
    Tar,
}

impl CreateFormat {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Tar => "tar",
            Self::Zip => "zip",
            Self::SevenZip => "7z",
            Self::TarGz => "tar.gz",
            Self::TarXz => "tar.xz",
            Self::TarZst => "tar.zst",
            Self::TarBz2 => "tar.bz2",
        }
    }

    pub fn supports_password(self) -> bool {
        matches!(self, Self::Zip | Self::SevenZip)
    }
}

/// Optionen für [`create_archive`].
#[derive(Debug, Clone)]
pub struct CreateOptions {
    pub format: CreateFormat,
    /// 0 = nur speichern, 9 = maximal.
    pub level: u8,
    pub password: Option<String>,
    /// Nur 7z: auch die Dateinamen verschlüsseln.
    pub encrypt_file_names: bool,
    /// `.DS_Store`, `__MACOSX`, `._*` usw. weglassen.
    pub exclude_mac_metadata: bool,
    /// In Teile dieser Größe aufteilen (`.001`, `.002` …). `None` = eine Datei.
    pub volume_size: Option<u64>,
}

impl Default for CreateOptions {
    fn default() -> Self {
        Self {
            format: CreateFormat::Zip,
            level: 6,
            password: None,
            encrypt_file_names: false,
            exclude_mac_metadata: true,
            volume_size: None,
        }
    }
}

/// Ergebnis von [`create_archive`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CreateSummary {
    pub files: u64,
    pub directories: u64,
    pub bytes_in: u64,
    pub bytes_out: u64,
    /// Geschriebene Dateien: eine, oder bei aufgeteilten Archiven alle Teile.
    pub outputs: Vec<PathBuf>,
}

/// Erstellt ein neues Archiv aus Dateien und Ordnern.
///
/// Es wird zuerst in eine temporäre Datei neben `dest` geschrieben; erst bei
/// Erfolg wird umbenannt. Bei Fehler oder Abbruch bleibt nichts zurück.
pub fn create_archive(
    sources: &[PathBuf],
    dest: &Path,
    options: &CreateOptions,
    progress: &dyn Progress,
) -> Result<CreateSummary> {
    if sources.is_empty() {
        return Err(ZippError::Io("Keine Dateien ausgewählt".into()));
    }
    create_from_sources(sources, dest, options, progress)
}

/// Wie [`create_archive`], erlaubt aber leere Quellen (für Bearbeiten und Konvertieren).
pub(crate) fn create_from_sources(
    sources: &[PathBuf],
    dest: &Path,
    options: &CreateOptions,
    progress: &dyn Progress,
) -> Result<CreateSummary> {
    let password = options.password.as_deref().filter(|p| !p.is_empty());
    if password.is_some() && !options.format.supports_password() {
        return Err(ZippError::Unsupported(
            "Passwortschutz gibt es nur bei ZIP und 7z".into(),
        ));
    }
    let mut out = OutputFile::new(dest, options.volume_size)?;
    let mut skip: Vec<&Path> = vec![dest];
    let temps = out.temp_paths();
    skip.extend(temps.iter().map(PathBuf::as_path));
    let items = collect(sources, options.exclude_mac_metadata, &skip)?;
    let total: u64 = items.iter().map(|i| i.size).sum();
    let tracker = Tracker::new(progress, total);
    let level = options.level.min(9);

    {
        let buffered = BufWriter::with_capacity(1 << 20, &mut out);
        match options.format {
            CreateFormat::Zip => {
                let mut zip = ZipWriter::new(buffered);
                add_zip_items(&mut zip, &items, "", level, password, &tracker)?;
                flush(zip.finish()?)?;
            }
            CreateFormat::SevenZip => write_7z(
                &items,
                buffered,
                level,
                password,
                options.encrypt_file_names,
                &tracker,
            )?,
            CreateFormat::Tar => flush(write_tar(&items, buffered, &tracker)?)?,
            CreateFormat::TarGz => {
                let enc = flate2::write::GzEncoder::new(buffered, flate2::Compression::new(u32::from(level)));
                flush(write_tar(&items, enc, &tracker)?.finish()?)?;
            }
            CreateFormat::TarXz => {
                let enc = liblzma::write::XzEncoder::new(buffered, u32::from(level));
                flush(write_tar(&items, enc, &tracker)?.finish()?)?;
            }
            CreateFormat::TarZst => {
                let enc = zstd::stream::write::Encoder::new(buffered, zstd_level(level))?;
                flush(write_tar(&items, enc, &tracker)?.finish()?)?;
            }
            CreateFormat::TarBz2 => {
                let enc = bzip2::write::BzEncoder::new(
                    buffered,
                    bzip2::Compression::new(u32::from(level.clamp(1, 9))),
                );
                flush(write_tar(&items, enc, &tracker)?.finish()?)?;
            }
        }
    }
    tracker.finish();
    let bytes_out = out.len();
    let outputs = out.commit()?;
    Ok(CreateSummary {
        files: items.iter().filter(|i| !matches!(i.kind, ItemKind::Dir)).count() as u64,
        directories: items.iter().filter(|i| matches!(i.kind, ItemKind::Dir)).count() as u64,
        bytes_in: total,
        bytes_out,
        outputs,
    })
}

fn zstd_level(level: u8) -> i32 {
    [1, 1, 2, 3, 5, 8, 11, 14, 17, 19][usize::from(level.min(9))]
}

/// Puffer leeren; Fehler beim Schreiben dürfen nicht im `Drop` verloren gehen.
fn flush<W: Write>(mut writer: BufWriter<W>) -> Result<()> {
    writer.flush()?;
    writer.into_inner().map_err(|e| ZippError::from(e.into_error()))?;
    Ok(())
}

// MARK: - Dateien einsammeln

#[derive(Debug)]
pub(crate) enum ItemKind {
    Dir,
    File,
    Symlink(String),
}

#[derive(Debug)]
pub(crate) struct Item {
    pub(crate) path: PathBuf,
    /// Name im Archiv (mit `/`)
    pub(crate) name: String,
    pub(crate) kind: ItemKind,
    pub(crate) size: u64,
    pub(crate) mode: u32,
    pub(crate) mtime: Option<i64>,
}

pub(crate) fn is_mac_junk(name: &OsStr) -> bool {
    let name = name.to_string_lossy();
    matches!(
        name.as_ref(),
        ".DS_Store"
            | "__MACOSX"
            | ".fseventsd"
            | ".Spotlight-V100"
            | ".Trashes"
            | ".TemporaryItems"
            | "Icon\r"
    ) || name.starts_with("._")
}

/// Läuft rekursiv durch die Quellen. Symlinks werden als Links gespeichert,
/// nicht verfolgt.
pub(crate) fn collect(sources: &[PathBuf], exclude_mac: bool, skip: &[&Path]) -> Result<Vec<Item>> {
    use std::os::unix::fs::PermissionsExt;

    let mut items = Vec::new();
    let mut top_names = HashSet::new();
    for source in sources {
        let base = source.parent().unwrap_or_else(|| Path::new("/"));
        let top = source
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .ok_or_else(|| ZippError::Io(format!("Ungültiger Pfad: {}", source.display())))?;
        // Gleichnamige Quellen aus verschiedenen Ordnern: „Name 2“
        let mut unique_top = top.clone();
        let mut n = 2;
        while !top_names.insert(unique_top.clone()) {
            unique_top = format!("{top} {n}");
            n += 1;
        }

        let walker = WalkDir::new(source)
            .follow_links(false)
            .sort_by_file_name()
            .into_iter()
            .filter_entry(|e| !(exclude_mac && e.depth() > 0 && is_mac_junk(e.file_name())));
        for entry in walker {
            let entry = entry?;
            if skip.iter().any(|s| entry.path() == *s) {
                continue;
            }
            let rel = entry.path().strip_prefix(base).unwrap_or(entry.path());
            let mut parts: Vec<String> = rel.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            if let Some(first) = parts.first_mut() {
                first.clone_from(&unique_top);
            }
            let name = parts.join("/");
            let meta = entry.path().symlink_metadata()?;
            let ft = meta.file_type();
            let kind = if ft.is_symlink() {
                ItemKind::Symlink(fs::read_link(entry.path())?.to_string_lossy().into_owned())
            } else if ft.is_dir() {
                ItemKind::Dir
            } else if ft.is_file() {
                ItemKind::File
            } else {
                continue; // Sockets, FIFOs …
            };
            items.push(Item {
                path: entry.path().to_path_buf(),
                name,
                size: if matches!(kind, ItemKind::File) {
                    meta.len()
                } else {
                    0
                },
                kind,
                mode: meta.permissions().mode() & 0o7777,
                mtime: meta.modified().ok().and_then(system_time_to_unix),
            });
        }
    }
    Ok(items)
}

// MARK: - ZIP

pub(crate) fn zip_time(mtime: Option<i64>) -> DateTime {
    mtime
        .and_then(unix_to_local_parts)
        .and_then(|(y, mo, d, h, mi, s)| DateTime::from_date_and_time(y, mo, d, h, mi, s).ok())
        .unwrap_or_default()
}

/// Bereits komprimierte Formate nur speichern, das spart Zeit ohne Nachteil.
fn is_precompressed(name: &str) -> bool {
    let lower = name.to_lowercase();
    [
        ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".mp4", ".mov", ".m4v", ".mp3", ".m4a",
        ".aac", ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz", ".zst", ".dmg", ".pkg",
    ]
    .iter()
    .any(|ext| lower.ends_with(ext))
}

pub(crate) fn add_zip_items<W: Write + io::Seek>(
    zip: &mut ZipWriter<W>,
    items: &[Item],
    prefix: &str,
    level: u8,
    password: Option<&str>,
    tracker: &Tracker<'_>,
) -> Result<()> {
    for item in items {
        let name = if prefix.is_empty() {
            item.name.clone()
        } else {
            format!("{prefix}/{}", item.name)
        };
        tracker.set_current(&name)?;
        let base = SimpleFileOptions::default()
            .last_modified_time(zip_time(item.mtime))
            .unix_permissions(item.mode & 0o777);
        match &item.kind {
            ItemKind::Dir => zip.add_directory(name, base)?,
            ItemKind::Symlink(target) => zip.add_symlink(name, target, base)?,
            ItemKind::File => {
                let stored = level == 0 || is_precompressed(&name);
                let base = base
                    .compression_method(if stored {
                        CompressionMethod::Stored
                    } else {
                        CompressionMethod::Deflated
                    })
                    .compression_level((!stored).then_some(i64::from(level)))
                    .large_file(item.size >= 0xFFFF_FFFF);
                let options = match password {
                    Some(pw) => base.with_aes_encryption(AesMode::Aes256, pw),
                    None => base,
                };
                zip.start_file(name, options)?;
                let mut reader = ProgressReader::new(File::open(&item.path)?, tracker);
                io::copy(&mut reader, zip)?;
            }
        }
    }
    Ok(())
}

// MARK: - 7z

const UNIX_EXTENSION: u32 = 0x8000;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const FILE_ATTRIBUTE_ARCHIVE: u32 = 0x20;

fn write_7z<W: Write + Seek>(
    items: &[Item],
    out: BufWriter<W>,
    level: u8,
    password: Option<&str>,
    encrypt_names: bool,
    tracker: &Tracker<'_>,
) -> Result<()> {
    let mut writer = ArchiveWriter::new(out)?;
    let mut methods: Vec<EncoderConfiguration> = Vec::new();
    if let Some(pw) = password {
        methods.push(AesEncoderOptions::new(Password::new(pw)).into());
    }
    methods.push(if level == 0 {
        EncoderMethod::COPY.into()
    } else {
        Lzma2Options::from_level(u32::from(level)).into()
    });
    writer.set_content_methods(methods);
    writer.set_encrypt_header(password.is_some() && encrypt_names);

    for item in items {
        tracker.set_current(&item.name)?;
        let mut entry = ArchiveEntry::from_path(&item.path, item.name.clone());
        entry.has_windows_attributes = true;
        match &item.kind {
            ItemKind::Dir => {
                entry.windows_attributes =
                    UNIX_EXTENSION | FILE_ATTRIBUTE_DIRECTORY | ((0o040_000 | item.mode) << 16);
                writer.push_archive_entry::<File>(entry, None)?;
            }
            ItemKind::Symlink(target) => {
                entry.is_directory = false;
                entry.has_stream = true;
                entry.windows_attributes =
                    UNIX_EXTENSION | FILE_ATTRIBUTE_ARCHIVE | ((0o120_000 | 0o777) << 16);
                writer.push_archive_entry(entry, Some(Cursor::new(target.clone().into_bytes())))?;
            }
            ItemKind::File => {
                entry.windows_attributes =
                    UNIX_EXTENSION | FILE_ATTRIBUTE_ARCHIVE | ((0o100_000 | item.mode) << 16);
                let reader = ProgressReader::new(File::open(&item.path)?, tracker);
                writer.push_archive_entry(entry, Some(reader))?;
            }
        }
    }
    flush(writer.finish()?)
}

// MARK: - TAR

fn write_tar<W: Write>(items: &[Item], out: W, tracker: &Tracker<'_>) -> Result<W> {
    let mut builder = tar::Builder::new(out);
    builder.follow_symlinks(false);
    for item in items {
        tracker.set_current(&item.name)?;
        match item.kind {
            ItemKind::Dir | ItemKind::Symlink(_) => builder.append_path_with_name(&item.path, &item.name)?,
            ItemKind::File => {
                let file = File::open(&item.path)?;
                let mut header = tar::Header::new_gnu();
                header.set_metadata(&file.metadata()?);
                builder.append_data(&mut header, &item.name, ProgressReader::new(file, tracker))?;
            }
        }
    }
    Ok(builder.into_inner()?)
}

// MARK: - Temporäre Datei

/// Schreibt neben das Ziel und löscht sich selbst, falls nicht übernommen.
pub(crate) struct TempFile {
    path: PathBuf,
    committed: bool,
}

impl TempFile {
    pub(crate) fn new(dest: &Path) -> Result<Self> {
        let dir = dest.parent().unwrap_or_else(|| Path::new("."));
        let name = dest
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let path = dir.join(format!(".{name}.zipp-{}.tmp", std::process::id()));
        Ok(Self {
            path,
            committed: false,
        })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn commit(mut self, dest: &Path) -> Result<()> {
        fs::rename(&self.path, dest)?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.path);
        }
    }
}
