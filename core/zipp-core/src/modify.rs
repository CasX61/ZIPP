//! Bestehende Archive bearbeiten: hinzufügen, löschen, umbenennen, neuer Ordner.
//! Außerdem Konvertieren und Passwortprüfung.
//!
//! - **ZIP**: Vorhandene Einträge werden roh kopiert, also ohne Neukomprimierung
//!   und ohne Passwort, auch wenn sie verschlüsselt sind.
//! - **7z und TAR.\***: Das Archiv wird in einen temporären Ordner entpackt,
//!   dort geändert und mit denselben Einstellungen (Format, Passwort,
//!   verschlüsselte Namen) neu geschrieben.
//!
//! In beiden Fällen entsteht das neue Archiv zuerst neben dem alten und
//! ersetzt es erst bei Erfolg.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::BufWriter;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use filetime::FileTime;
use walkdir::WalkDir;
use zip::ZipWriter;
use zip::write::SimpleFileOptions;

use crate::create::{
    CreateFormat, CreateOptions, CreateSummary, Item, ItemKind, TempFile, add_zip_items, collect,
    create_from_sources, is_mac_junk, zip_time,
};
use crate::detect::detect_format;
use crate::error::{Result, ZippError};
use crate::extract::{ExtractOptions, OverwritePolicy, extract_archive, test_selection};
use crate::formats::zipfile;
use crate::model::ArchiveFormat;
use crate::progress::{NoProgress, Progress, Tracker};
use crate::safety::{normalize, sanitize};
use crate::volume::{all_volumes, first_volume};

const QUARANTINE_XATTR: &str = "com.apple.quarantine";

/// Optionen für [`add_to_archive`].
#[derive(Debug, Clone)]
pub struct AddOptions {
    pub level: u8,
    /// ZIP: neue Dateien mit AES-256 verschlüsseln. 7z: Passwort des Archivs
    /// (wird zum Lesen gebraucht; das neu geschriebene Archiv behält seine Verschlüsselung).
    pub password: Option<String>,
    pub exclude_mac_metadata: bool,
}

impl Default for AddOptions {
    fn default() -> Self {
        Self {
            level: 6,
            password: None,
            exclude_mac_metadata: true,
        }
    }
}

/// Wie ein Archiv bearbeitet wird.
enum Strategy {
    Zip,
    Rebuild(CreateFormat),
}

fn strategy(archive: &Path) -> Result<Strategy> {
    if all_volumes(archive).len() > 1 {
        return Err(ZippError::Unsupported(
            "Mehrteilige Archive können nicht bearbeitet werden".into(),
        ));
    }
    Ok(match detect_format(archive)? {
        ArchiveFormat::Zip => Strategy::Zip,
        ArchiveFormat::SevenZip => Strategy::Rebuild(CreateFormat::SevenZip),
        ArchiveFormat::Tar => Strategy::Rebuild(CreateFormat::Tar),
        ArchiveFormat::TarGz => Strategy::Rebuild(CreateFormat::TarGz),
        ArchiveFormat::TarBz2 => Strategy::Rebuild(CreateFormat::TarBz2),
        ArchiveFormat::TarXz => Strategy::Rebuild(CreateFormat::TarXz),
        ArchiveFormat::TarZst => Strategy::Rebuild(CreateFormat::TarZst),
        other => {
            return Err(ZippError::Unsupported(format!(
                "{}-Archive können nicht bearbeitet werden",
                other.label()
            )));
        }
    })
}

/// Ein Name für eine Datei oder einen Ordner (ohne `/`).
fn validate_name(name: &str) -> Result<String> {
    let trimmed = name.trim();
    if trimmed.is_empty()
        || trimmed == "."
        || trimmed == ".."
        || trimmed.contains('/')
        || trimmed.contains('\0')
        || trimmed.len() > 255
    {
        return Err(ZippError::Unsupported(format!("„{name}“ ist kein gültiger Name")));
    }
    Ok(trimmed.to_string())
}

fn join(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{dir}/{name}")
    }
}

/// `name` ist `path` selbst oder liegt darin.
fn is_within(name: &str, path: &str) -> bool {
    name == path || (name.starts_with(path) && name.as_bytes().get(path.len()) == Some(&b'/'))
}

fn already_exists(path: &str) -> ZippError {
    ZippError::Io(format!("„{path}“ gibt es im Archiv bereits"))
}

// MARK: - Öffentliche Funktionen

/// Fügt Dateien/Ordner in den Ordner `inner_dir` des Archivs ein ("" = oberste Ebene).
/// Gleichnamige Einträge werden ersetzt.
pub fn add_to_archive(
    archive: &Path,
    sources: &[PathBuf],
    inner_dir: &str,
    options: &AddOptions,
    progress: &dyn Progress,
) -> Result<CreateSummary> {
    let prefix = normalize(inner_dir);
    let password = options.password.as_deref().filter(|p| !p.is_empty());
    match strategy(archive)? {
        Strategy::Zip => {
            let temp = TempFile::new(archive)?;
            let items = collect(sources, options.exclude_mac_metadata, &[archive, temp.path()])?;
            let new_names: HashSet<String> = items.iter().map(|i| join(&prefix, &i.name)).collect();
            let plan = ZipPlan {
                keep: &|name| !new_names.contains(name),
                additions: &items,
                prefix: &prefix,
                level: options.level.min(9),
                password,
                ..ZipPlan::default()
            };
            rewrite_zip(archive, &temp, progress, &plan)?;
            let bytes_out = fs::metadata(temp.path())?.len();
            temp.commit(archive)?;
            Ok(summary_for(&items, bytes_out, archive))
        }
        Strategy::Rebuild(format) => {
            let items = collect(sources, options.exclude_mac_metadata, &[archive])?;
            let exclude = options.exclude_mac_metadata;
            let mut result = rebuild(archive, format, password, progress, |root| {
                let target_dir = resolve_dir(root, &prefix)?;
                fs::create_dir_all(&target_dir)?;
                for source in sources {
                    copy_tree(source, &target_dir, exclude)?;
                }
                Ok(())
            })?;
            let added = summary_for(&items, result.bytes_out, archive);
            result.files = added.files;
            result.directories = added.directories;
            result.bytes_in = added.bytes_in;
            Ok(result)
        }
    }
}

/// Löscht Einträge (Ordner samt Inhalt). Gibt die Zahl der entfernten Einträge zurück.
pub fn delete_from_archive(
    archive: &Path,
    paths: &[String],
    password: Option<&str>,
    progress: &dyn Progress,
) -> Result<u64> {
    let targets: Vec<String> = paths
        .iter()
        .map(|p| normalize(p))
        .filter(|p| !p.is_empty())
        .collect();
    let matches = |name: &str| targets.iter().any(|t| is_within(name, t));
    match strategy(archive)? {
        Strategy::Zip => {
            let before = zipfile::open(archive)?.0.len() as u64;
            let temp = TempFile::new(archive)?;
            let plan = ZipPlan {
                keep: &|name| !matches(name),
                ..ZipPlan::default()
            };
            rewrite_zip(archive, &temp, progress, &plan)?;
            let after = zipfile::open(temp.path())?.0.len() as u64;
            temp.commit(archive)?;
            Ok(before.saturating_sub(after))
        }
        Strategy::Rebuild(format) => {
            let listing = crate::list_archive(archive, password)?;
            let removed = listing.entries.iter().filter(|e| matches(&e.path)).count() as u64;
            rebuild(archive, format, password, progress, |root| {
                for t in &targets {
                    let Some(rel) = sanitize(t) else { continue };
                    let path = root.join(rel);
                    match fs::symlink_metadata(&path) {
                        Ok(m) if m.is_dir() => fs::remove_dir_all(&path)?,
                        Ok(_) => fs::remove_file(&path)?,
                        Err(_) => {}
                    }
                }
                Ok(())
            })?;
            Ok(removed)
        }
    }
}

/// Benennt eine Datei oder einen Ordner um (bleibt im selben Ordner).
/// Gibt den neuen Pfad im Archiv zurück.
pub fn rename_in_archive(
    archive: &Path,
    path: &str,
    new_name: &str,
    password: Option<&str>,
    progress: &dyn Progress,
) -> Result<String> {
    let from = normalize(path);
    if from.is_empty() {
        return Err(ZippError::Unsupported("Nichts zum Umbenennen ausgewählt".into()));
    }
    let name = validate_name(new_name)?;
    let parent = from.rsplit_once('/').map_or("", |(p, _)| p);
    let to = join(parent, &name);
    if to == from {
        return Ok(to);
    }
    match strategy(archive)? {
        Strategy::Zip => {
            let (source, codec) = zipfile::open(archive)?;
            let mut found = false;
            for i in 0..source.len() {
                let e = source.by_index_data(i)?;
                let n = zipfile::entry_name(&e, &codec);
                if is_within(&n, &from) {
                    found = true;
                } else if is_within(&n, &to) {
                    return Err(already_exists(&to));
                }
            }
            if !found {
                return Err(ZippError::Io(format!("„{from}“ wurde im Archiv nicht gefunden")));
            }
            let temp = TempFile::new(archive)?;
            let rename = |n: &str| is_within(n, &from).then(|| format!("{to}{}", &n[from.len()..]));
            let plan = ZipPlan {
                rename: Some(&rename),
                ..ZipPlan::default()
            };
            rewrite_zip(archive, &temp, progress, &plan)?;
            temp.commit(archive)?;
        }
        Strategy::Rebuild(format) => {
            rebuild(archive, format, password, progress, |root| {
                let src = root.join(sanitize(&from).ok_or_else(|| ZippError::Io("Ungültiger Pfad".into()))?);
                let dst = src.with_file_name(&name);
                if fs::symlink_metadata(&src).is_err() {
                    return Err(ZippError::Io(format!("„{from}“ wurde im Archiv nicht gefunden")));
                }
                if fs::symlink_metadata(&dst).is_ok() {
                    return Err(already_exists(&to));
                }
                fs::rename(&src, &dst)?;
                Ok(())
            })?;
        }
    }
    Ok(to)
}

/// Legt einen leeren Ordner im Archiv an. Gibt seinen Pfad zurück.
pub fn create_folder_in_archive(
    archive: &Path,
    inner_dir: &str,
    name: &str,
    password: Option<&str>,
    progress: &dyn Progress,
) -> Result<String> {
    let name = validate_name(name)?;
    let path = join(&normalize(inner_dir), &name);
    match strategy(archive)? {
        Strategy::Zip => {
            let (source, codec) = zipfile::open(archive)?;
            for i in 0..source.len() {
                if is_within(&zipfile::entry_name(&source.by_index_data(i)?, &codec), &path) {
                    return Err(already_exists(&path));
                }
            }
            let temp = TempFile::new(archive)?;
            let dirs = [path.clone()];
            let plan = ZipPlan {
                new_dirs: &dirs,
                ..ZipPlan::default()
            };
            rewrite_zip(archive, &temp, progress, &plan)?;
            temp.commit(archive)?;
        }
        Strategy::Rebuild(format) => {
            rebuild(archive, format, password, progress, |root| {
                let dir = resolve_dir(root, &path)?;
                if fs::symlink_metadata(&dir).is_ok() {
                    return Err(already_exists(&path));
                }
                fs::create_dir_all(&dir)?;
                Ok(())
            })?;
        }
    }
    Ok(path)
}

/// Wandelt ein Archiv in ein anderes Format um (z. B. RAR → 7z).
/// Die Quarantäne-Markierung des Originals wird übernommen.
pub fn convert_archive(
    archive: &Path,
    password: Option<&str>,
    dest: &Path,
    options: &CreateOptions,
    progress: &dyn Progress,
) -> Result<CreateSummary> {
    let archive = &first_volume(archive);
    if dest == archive.as_path() {
        return Err(ZippError::Unsupported(
            "Ziel und Quelle sind dieselbe Datei".into(),
        ));
    }
    let listing = crate::list_archive(archive, password)?;
    let work = WorkDir::new()?;
    let phases = Phases::new(progress, listing.total_size());
    let root = unpack(archive, password, &work, &phases.first())?;
    let summary = create_from_sources(&top_level(&root)?, dest, options, &phases.second())?;
    if let Ok(Some(q)) = xattr::get(archive, QUARANTINE_XATTR) {
        for out in &summary.outputs {
            let _ = xattr::set(out, QUARANTINE_XATTR, &q);
        }
    }
    Ok(summary)
}

/// Stimmt das Passwort? Prüft dafür die kleinste verschlüsselte Datei.
pub fn check_password(archive: &Path, password: &str) -> Result<bool> {
    let listing = match crate::list_archive(archive, Some(password)) {
        Ok(l) => l,
        Err(ZippError::WrongPassword | ZippError::PasswordRequired) => return Ok(false),
        Err(ZippError::Corrupt(_))
            if matches!(
                crate::list_archive(archive, None),
                Err(ZippError::PasswordRequired)
            ) =>
        {
            return Ok(false);
        }
        Err(e) => return Err(e),
    };
    let probe = listing
        .entries
        .iter()
        .filter(|e| e.encrypted && !e.is_dir)
        .min_by_key(|e| e.size);
    let Some(probe) = probe else {
        return Ok(true);
    };
    match test_selection(
        archive,
        Some(password),
        std::slice::from_ref(&probe.path),
        &NoProgress,
    ) {
        Ok(_) => Ok(true),
        Err(
            ZippError::WrongPassword
            | ZippError::PasswordRequired
            | ZippError::ChecksumMismatch(_)
            | ZippError::Corrupt(_),
        ) => Ok(false),
        Err(e) => Err(e),
    }
}

fn summary_for(items: &[Item], bytes_out: u64, archive: &Path) -> CreateSummary {
    CreateSummary {
        files: items.iter().filter(|i| !matches!(i.kind, ItemKind::Dir)).count() as u64,
        directories: items.iter().filter(|i| matches!(i.kind, ItemKind::Dir)).count() as u64,
        bytes_in: items.iter().map(|i| i.size).sum(),
        bytes_out,
        outputs: vec![archive.to_path_buf()],
    }
}

// MARK: - ZIP roh neu schreiben

type NameFilter<'a> = &'a dyn Fn(&str) -> bool;
type NameMap<'a> = &'a dyn Fn(&str) -> Option<String>;

struct ZipPlan<'a> {
    keep: NameFilter<'a>,
    rename: Option<NameMap<'a>>,
    additions: &'a [Item],
    prefix: &'a str,
    level: u8,
    password: Option<&'a str>,
    new_dirs: &'a [String],
}

impl Default for ZipPlan<'_> {
    fn default() -> Self {
        Self {
            keep: &|_| true,
            rename: None,
            additions: &[],
            prefix: "",
            level: 6,
            password: None,
            new_dirs: &[],
        }
    }
}

fn rewrite_zip(archive: &Path, temp: &TempFile, progress: &dyn Progress, plan: &ZipPlan<'_>) -> Result<()> {
    let (mut source, codec) = zipfile::open(archive)?;
    let mut kept = Vec::new();
    let mut total = plan.additions.iter().map(|i| i.size).sum::<u64>();
    for i in 0..source.len() {
        let e = source.by_index_data(i)?;
        let name = zipfile::entry_name(&e, &codec);
        if (plan.keep)(&name) {
            total += e.compressed_size();
            kept.push(i);
        }
    }
    let tracker = Tracker::new(progress, total);

    let mut writer = ZipWriter::new(BufWriter::new(File::create(temp.path())?));
    writer.set_raw_comment(source.comment().to_vec().into_boxed_slice())?;
    for i in kept {
        let raw = source.by_index_raw(i)?;
        let name = zipfile::entry_name(&raw.entry(), &codec);
        tracker.set_current(&name)?;
        tracker.add(raw.compressed_size())?;
        match plan.rename.and_then(|r| r(&name)) {
            Some(new_name) => {
                let stored = if raw.is_dir() {
                    format!("{new_name}/")
                } else {
                    new_name
                };
                writer.raw_copy_file_rename(raw, stored)?;
            }
            None => writer.raw_copy_file(raw)?,
        }
    }
    // Ortszeit setzen: ohne Angabe stempelt die zip-Crate in UTC
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_secs()).ok());
    for dir in plan.new_dirs {
        let options = SimpleFileOptions::default()
            .last_modified_time(zip_time(now))
            .unix_permissions(0o755);
        writer.add_directory(format!("{dir}/"), options)?;
    }
    add_zip_items(
        &mut writer,
        plan.additions,
        plan.prefix,
        plan.level,
        plan.password,
        &tracker,
    )?;
    let file = writer
        .finish()?
        .into_inner()
        .map_err(|e| ZippError::from(e.into_error()))?;
    file.sync_all()?;
    // Rechte der Originaldatei übernehmen
    if let Ok(meta) = fs::metadata(archive) {
        let _ = fs::set_permissions(temp.path(), meta.permissions());
    }
    tracker.finish();
    Ok(())
}

// MARK: - Entpacken, ändern, neu schreiben

/// Temporärer Arbeitsordner, der sich beim Verlassen selbst löscht.
struct WorkDir(PathBuf);

impl WorkDir {
    fn new() -> Result<Self> {
        use std::os::unix::fs::DirBuilderExt;
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("zipp-work-{}-{n}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
}

impl Drop for WorkDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Teilt den Fortschritt auf zwei Schritte auf (Entpacken, Schreiben).
struct Phases<'a> {
    inner: &'a dyn Progress,
    span: u64,
}

impl<'a> Phases<'a> {
    fn new(inner: &'a dyn Progress, estimated_bytes: u64) -> Self {
        Self {
            inner,
            span: estimated_bytes.max(1),
        }
    }

    fn first(&self) -> Phase<'_> {
        Phase {
            phases: self,
            index: 0,
        }
    }

    fn second(&self) -> Phase<'_> {
        Phase {
            phases: self,
            index: 1,
        }
    }
}

struct Phase<'a> {
    phases: &'a Phases<'a>,
    index: u64,
}

impl Progress for Phase<'_> {
    fn update(&self, done: u64, total: u64, current: &str) {
        let span = self.phases.span;
        let part = if total == 0 {
            0
        } else {
            u64::try_from(u128::from(done.min(total)) * u128::from(span) / u128::from(total)).unwrap_or(span)
        };
        self.phases
            .inner
            .update(self.index * span + part, 2 * span, current);
    }

    fn is_cancelled(&self) -> bool {
        self.phases.inner.is_cancelled()
    }
}

/// Entpackt alles nach `work/inhalt`. Bricht ab, wenn dabei Einträge verloren gingen.
fn unpack(
    archive: &Path,
    password: Option<&str>,
    work: &WorkDir,
    progress: &dyn Progress,
) -> Result<PathBuf> {
    let root = work.0.join("inhalt");
    let options = ExtractOptions {
        password: password.map(String::from),
        overwrite: OverwritePolicy::Replace,
        apply_quarantine: false,
        ..ExtractOptions::default()
    };
    let summary = extract_archive(archive, &root, &options, progress)?;
    if let Some(first) = summary.skipped_unsafe.first() {
        return Err(ZippError::Unsupported(format!(
            "Das Archiv enthält Einträge, die ZIPP nicht übernehmen kann (z. B. „{first}“). \
             Es wurde nichts verändert."
        )));
    }
    if summary.skipped_existing > 0 || summary.renamed > 0 {
        return Err(ZippError::Unsupported(
            "Das Archiv enthält doppelte Einträge. Es wurde nichts verändert.".into(),
        ));
    }
    Ok(root)
}

fn top_level(root: &Path) -> Result<Vec<PathBuf>> {
    let mut sources: Vec<PathBuf> = fs::read_dir(root)?
        .map(|e| e.map(|e| e.path()))
        .collect::<std::io::Result<_>>()?;
    sources.sort();
    Ok(sources)
}

/// Ordner im Arbeitsverzeichnis zu einem Archivpfad.
fn resolve_dir(root: &Path, inner: &str) -> Result<PathBuf> {
    if inner.is_empty() {
        return Ok(root.to_path_buf());
    }
    let rel = sanitize(inner).ok_or_else(|| ZippError::Io(format!("Ungültiger Pfad „{inner}“")))?;
    // Kein Teil des Pfads darf ein Symlink sein (sonst würde nach außen geschrieben).
    let mut current = root.to_path_buf();
    for comp in rel.components() {
        current.push(comp);
        if fs::symlink_metadata(&current).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(ZippError::Io(format!("„{inner}“ ist ein symbolischer Link")));
        }
    }
    Ok(current)
}

fn rebuild(
    archive: &Path,
    format: CreateFormat,
    password: Option<&str>,
    progress: &dyn Progress,
    edit: impl FnOnce(&Path) -> Result<()>,
) -> Result<CreateSummary> {
    let password = password.filter(|p| !p.is_empty());
    let listing = crate::list_archive(archive, password)?;
    if listing.has_encrypted_entries && password.is_none() {
        return Err(ZippError::PasswordRequired);
    }
    let work = WorkDir::new()?;
    let phases = Phases::new(progress, listing.total_size());
    let root = unpack(archive, password, &work, &phases.first())?;
    edit(&root)?;
    let options = CreateOptions {
        format,
        level: 6,
        password: listing
            .has_encrypted_entries
            .then(|| password.unwrap_or_default().to_string()),
        encrypt_file_names: listing.header_encrypted,
        exclude_mac_metadata: false,
        volume_size: None,
    };
    let permissions = fs::metadata(archive)?.permissions();
    let summary = create_from_sources(&top_level(&root)?, archive, &options, &phases.second())?;
    let _ = fs::set_permissions(archive, permissions);
    Ok(summary)
}

/// Kopiert eine Datei oder einen Ordner nach `dest_dir` (ersetzt Gleichnamiges).
/// Symlinks bleiben Symlinks, Zeiten und Rechte bleiben erhalten.
fn copy_tree(source: &Path, dest_dir: &Path, exclude_mac: bool) -> Result<()> {
    let base = source.parent().unwrap_or_else(|| Path::new("/"));
    let top = dest_dir.join(
        source
            .file_name()
            .ok_or_else(|| ZippError::Io("Ungültiger Pfad".into()))?,
    );
    match fs::symlink_metadata(&top) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(&top)?,
        Ok(_) => fs::remove_file(&top)?,
        Err(_) => {}
    }
    let mut dir_times = Vec::new();
    let walker = WalkDir::new(source)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| !(exclude_mac && e.depth() > 0 && is_mac_junk(e.file_name())));
    for entry in walker {
        let entry = entry?;
        let rel = entry.path().strip_prefix(base).unwrap_or(entry.path());
        let target = dest_dir.join(rel);
        let meta = entry.path().symlink_metadata()?;
        let ft = meta.file_type();
        if ft.is_symlink() {
            std::os::unix::fs::symlink(fs::read_link(entry.path())?, &target)?;
        } else if ft.is_dir() {
            fs::create_dir_all(&target)?;
            fs::set_permissions(&target, meta.permissions())?;
            dir_times.push((target, FileTime::from_last_modification_time(&meta)));
        } else if ft.is_file() {
            fs::copy(entry.path(), &target)?;
            let t = FileTime::from_last_modification_time(&meta);
            let _ = filetime::set_file_times(&target, t, t);
        }
    }
    for (dir, t) in dir_times.iter().rev() {
        let _ = filetime::set_file_times(dir, *t, *t);
    }
    Ok(())
}
