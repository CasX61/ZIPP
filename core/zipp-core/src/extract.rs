//! Entpacken und Testen.
//!
//! Alle Formate liefern ihre Einträge an eine [`Sink`]. Der [`Extractor`]
//! schreibt sie sicher auf die Platte, der [`Tester`] liest sie nur und prüft
//! dabei die Prüfsummen.

use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use filetime::FileTime;

use crate::detect::detect_format;
use crate::error::{Result, ZippError};
use crate::formats;
use crate::progress::{Progress, ProgressWriter, Tracker};
use crate::safety::{sanitize, symlink_target_is_safe};

const QUARANTINE_XATTR: &str = "com.apple.quarantine";

/// Was passiert, wenn eine Datei am Ziel schon existiert?
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OverwritePolicy {
    /// Vorhandene Datei ersetzen.
    Replace,
    /// Vorhandene Datei behalten, Eintrag überspringen.
    Skip,
    /// Beide behalten: neue Datei bekommt „Name 2.ext“.
    #[default]
    KeepBoth,
}

/// Optionen für [`extract_archive`].
#[derive(Debug, Clone, Default)]
pub struct ExtractOptions {
    pub password: Option<String>,
    /// Pfade im Archiv. Ein Ordner schließt seinen Inhalt ein. Leer = alles.
    pub selection: Vec<String>,
    /// Wird vom Anfang jedes Pfads entfernt (z. B. der aktuelle Ordner beim
    /// Herausziehen einzelner Dateien).
    pub strip_prefix: Option<String>,
    pub overwrite: OverwritePolicy,
    /// Quarantäne-Markierung des Archivs auf alle entpackten Dateien übertragen.
    pub apply_quarantine: bool,
}

/// Ergebnis von [`extract_archive`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExtractSummary {
    pub files: u64,
    pub directories: u64,
    pub symlinks: u64,
    pub bytes: u64,
    /// Einträge, die aus Sicherheitsgründen oder als unbekannter Typ übersprungen wurden.
    pub skipped_unsafe: Vec<String>,
    /// Wegen „Überspringen“ nicht geschriebene Dateien.
    pub skipped_existing: u64,
    /// Wegen „Beide behalten“ umbenannte Dateien.
    pub renamed: u64,
}

/// Ergebnis von [`test_archive`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TestSummary {
    pub files: u64,
    pub bytes: u64,
}

/// Entpackt ein Archiv (oder eine Auswahl daraus) nach `dest`.
pub fn extract_archive(
    archive: &Path,
    dest: &Path,
    options: &ExtractOptions,
    progress: &dyn Progress,
) -> Result<ExtractSummary> {
    let archive = &crate::volume::first_volume(archive);
    let format = detect_format(archive)?;
    let tracker = Tracker::new(progress, 0);
    let selection = Selection::new(&options.selection, options.strip_prefix.as_deref());
    configure_totals(archive, format, options.password.as_deref(), &selection, &tracker)?;

    fs::create_dir_all(dest)?;
    let quarantine = if options.apply_quarantine {
        xattr::get(archive, QUARANTINE_XATTR).ok().flatten()
    } else {
        None
    };
    let mut extractor = Extractor {
        root: dest.to_path_buf(),
        selection,
        overwrite: options.overwrite,
        quarantine,
        tracker: &tracker,
        summary: ExtractSummary::default(),
        verified_dirs: HashSet::new(),
        dir_times: Vec::new(),
    };
    formats::process(
        archive,
        format,
        options.password.as_deref(),
        &mut extractor,
        &tracker,
    )?;
    tracker.finish();
    Ok(extractor.finish())
}

/// Liest alle (ausgewählten) Einträge und prüft die Prüfsummen, ohne zu schreiben.
pub fn test_archive(archive: &Path, password: Option<&str>, progress: &dyn Progress) -> Result<TestSummary> {
    test_selection(archive, password, &[], progress)
}

/// Wie [`test_archive`], aber nur für die angegebenen Einträge.
pub(crate) fn test_selection(
    archive: &Path,
    password: Option<&str>,
    selection: &[String],
    progress: &dyn Progress,
) -> Result<TestSummary> {
    let archive = &crate::volume::first_volume(archive);
    let format = detect_format(archive)?;
    let tracker = Tracker::new(progress, 0);
    let selection = Selection::new(selection, None);
    configure_totals(archive, format, password, &selection, &tracker)?;
    let mut tester = Tester {
        tracker: &tracker,
        selection,
        summary: TestSummary::default(),
    };
    formats::process(archive, format, password, &mut tester, &tracker)?;
    tracker.finish();
    Ok(tester.summary)
}

fn configure_totals(
    archive: &Path,
    format: crate::ArchiveFormat,
    password: Option<&str>,
    selection: &Selection,
    tracker: &Tracker<'_>,
) -> Result<()> {
    if format.tar_stream().is_some() || format.single_stream().is_some() {
        // Keine Größen ohne vollständiges Lesen: Fortschritt über gelesene Archiv-Bytes.
        tracker.set_total(crate::volume::total_size(archive)?);
        tracker.set_count_output(false);
    } else {
        let listing = formats::list(archive, format, password)?;
        let total = listing
            .entries
            .iter()
            .filter(|e| !e.is_dir && selection.matches(&e.path))
            .map(|e| e.size)
            .sum();
        tracker.set_total(total);
    }
    Ok(())
}

// MARK: - Auswahl

/// Welche Einträge verarbeitet werden und welcher Präfix entfernt wird.
pub(crate) struct Selection {
    items: Vec<String>,
    strip: String,
}

impl Selection {
    pub(crate) fn new(items: &[String], strip: Option<&str>) -> Self {
        Self {
            items: items
                .iter()
                .map(|s| crate::safety::normalize(s))
                .filter(|s| !s.is_empty())
                .collect(),
            strip: strip.map(crate::safety::normalize).unwrap_or_default(),
        }
    }

    pub(crate) fn matches(&self, path: &str) -> bool {
        self.items.is_empty()
            || self.items.iter().any(|sel| {
                path == sel
                    || (path.starts_with(sel.as_str()) && path.as_bytes().get(sel.len()) == Some(&b'/'))
            })
    }

    fn relative<'p>(&self, path: &'p str) -> &'p str {
        if !self.strip.is_empty()
            && path.starts_with(self.strip.as_str())
            && path.as_bytes().get(self.strip.len()) == Some(&b'/')
        {
            &path[self.strip.len() + 1..]
        } else {
            path
        }
    }
}

// MARK: - Sink

/// Was ein Format mit einem Eintrag tun soll, das selbst auf die Platte schreibt (RAR).
pub(crate) enum ExternalAction {
    Extract(PathBuf),
    Test,
    Skip,
}

/// Empfänger für die Einträge eines Archivs.
pub(crate) trait Sink {
    fn wants(&self, path: &str) -> bool;
    fn directory(&mut self, path: &str, mtime: Option<i64>) -> Result<()>;
    fn file(&mut self, path: &str, data: &mut dyn Read, mtime: Option<i64>, mode: Option<u32>) -> Result<()>;
    fn symlink(&mut self, path: &str, target: &str) -> Result<()>;
    /// Unbekannte Eintragstypen (Hardlinks, Geräte …).
    fn unsupported(&mut self, path: &str);
    fn external(&mut self, path: &str) -> Result<ExternalAction>;
    fn external_done(&mut self, target: Option<&Path>, size: u64, mtime: Option<i64>) -> Result<()>;
}

// MARK: - Tester

struct Tester<'t, 'a> {
    tracker: &'t Tracker<'a>,
    selection: Selection,
    summary: TestSummary,
}

impl Sink for Tester<'_, '_> {
    fn wants(&self, path: &str) -> bool {
        self.selection.matches(path)
    }

    fn directory(&mut self, _path: &str, _mtime: Option<i64>) -> Result<()> {
        Ok(())
    }

    fn file(&mut self, path: &str, data: &mut dyn Read, _: Option<i64>, _: Option<u32>) -> Result<()> {
        self.tracker.set_current(path)?;
        let mut out = ProgressWriter::new(io::sink(), self.tracker);
        let n = io::copy(data, &mut out).map_err(|e| read_error(e, path))?;
        self.summary.files += 1;
        self.summary.bytes += n;
        Ok(())
    }

    fn symlink(&mut self, _path: &str, _target: &str) -> Result<()> {
        self.summary.files += 1;
        Ok(())
    }

    fn unsupported(&mut self, _path: &str) {}

    fn external(&mut self, path: &str) -> Result<ExternalAction> {
        self.tracker.set_current(path)?;
        Ok(ExternalAction::Test)
    }

    fn external_done(&mut self, _: Option<&Path>, size: u64, _: Option<i64>) -> Result<()> {
        self.summary.files += 1;
        self.summary.bytes += size;
        self.tracker.add(size)?;
        Ok(())
    }
}

/// Lesefehler einordnen: Prüfsummenfehler von anderen I/O-Fehlern trennen.
pub(crate) fn read_error(e: io::Error, path: &str) -> ZippError {
    let converted = ZippError::from(e);
    match &converted {
        ZippError::Io(msg) | ZippError::Corrupt(msg)
            if msg.to_lowercase().contains("checksum") || msg.to_lowercase().contains("crc") =>
        {
            ZippError::ChecksumMismatch(path.to_string())
        }
        _ => converted,
    }
}

// MARK: - Extractor

struct Extractor<'t, 'a> {
    root: PathBuf,
    selection: Selection,
    overwrite: OverwritePolicy,
    quarantine: Option<Vec<u8>>,
    tracker: &'t Tracker<'a>,
    summary: ExtractSummary,
    /// Bereits geprüfte Ordner (keine Symlinks darin).
    verified_dirs: HashSet<PathBuf>,
    /// Ordner-Zeiten werden zum Schluss gesetzt, sonst überschreibt das
    /// Anlegen der Dateien sie wieder.
    dir_times: Vec<(PathBuf, i64)>,
}

impl Extractor<'_, '_> {
    /// Zielpfad für einen Archivpfad oder `None`, wenn er unsicher ist.
    fn resolve(&mut self, path: &str) -> Option<(PathBuf, PathBuf)> {
        let rel = self.selection.relative(path);
        match sanitize(rel) {
            Some(rel) => Some((self.root.join(&rel), rel)),
            None => {
                self.summary.skipped_unsafe.push(path.to_string());
                None
            }
        }
    }

    /// Legt `dir` (unterhalb von `root`) an und stellt sicher, dass kein Teil
    /// des Pfads ein Symlink ist. Sonst könnte ein Archiv erst einen Link nach
    /// außen anlegen und dann durch ihn hindurch schreiben.
    fn ensure_dir(&mut self, dir: &Path) -> Result<()> {
        if self.verified_dirs.contains(dir) {
            return Ok(());
        }
        let rel = dir
            .strip_prefix(&self.root)
            .map_err(|_| ZippError::Io("Pfad außerhalb des Ziels".into()))?;
        let mut current = self.root.clone();
        for comp in rel.components() {
            current.push(comp);
            if self.verified_dirs.contains(&current) {
                continue;
            }
            match fs::symlink_metadata(&current) {
                Ok(meta) if meta.file_type().is_symlink() => {
                    return Err(ZippError::Io(format!(
                        "„{}“ ist ein symbolischer Link, Schreiben blockiert",
                        current.display()
                    )));
                }
                Ok(meta) if meta.is_dir() => {}
                Ok(_) => {
                    return Err(ZippError::Io(format!(
                        "„{}“ existiert bereits als Datei",
                        current.display()
                    )));
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    fs::create_dir(&current)?;
                    self.mark(&current);
                    self.summary.directories += 1;
                }
                Err(e) => return Err(e.into()),
            }
            self.verified_dirs.insert(current.clone());
        }
        Ok(())
    }

    /// Bereitet den Zielpfad einer Datei vor (Elternordner, Konflikte).
    /// `None` heißt: überspringen.
    fn prepare_target(&mut self, target: PathBuf) -> Result<Option<PathBuf>> {
        if let Some(parent) = target.parent() {
            self.ensure_dir(parent)?;
        }
        let Ok(meta) = fs::symlink_metadata(&target) else {
            return Ok(Some(target));
        };
        match self.overwrite {
            OverwritePolicy::Skip => {
                self.summary.skipped_existing += 1;
                Ok(None)
            }
            OverwritePolicy::KeepBoth => {
                self.summary.renamed += 1;
                Ok(Some(unique_path(&target)))
            }
            OverwritePolicy::Replace => {
                if meta.is_dir() && !meta.file_type().is_symlink() {
                    // Ordner nicht durch eine Datei ersetzen: lieber beide behalten.
                    self.summary.renamed += 1;
                    return Ok(Some(unique_path(&target)));
                }
                // Auch Symlinks entfernen, damit nie durch sie hindurch geschrieben wird.
                fs::remove_file(&target)?;
                Ok(Some(target))
            }
        }
    }

    /// Quarantäne-Markierung setzen (Fehler sind nicht kritisch).
    fn mark(&self, path: &Path) {
        if let Some(value) = &self.quarantine {
            let _ = xattr::set(path, QUARANTINE_XATTR, value);
        }
    }

    fn finish_file(&mut self, target: &Path, mtime: Option<i64>, mode: Option<u32>) {
        if let Some(mode) = mode {
            use std::os::unix::fs::PermissionsExt;
            // Nur Rechte-Bits, kein setuid/setgid; Besitzer darf immer lesen/schreiben.
            let bits = (mode & 0o777) | 0o600;
            let _ = fs::set_permissions(target, fs::Permissions::from_mode(bits));
        }
        if let Some(t) = mtime {
            let ft = FileTime::from_unix_time(t, 0);
            let _ = filetime::set_file_times(target, ft, ft);
        }
        self.mark(target);
    }

    fn finish(self) -> ExtractSummary {
        for (dir, t) in self.dir_times.iter().rev() {
            let ft = FileTime::from_unix_time(*t, 0);
            let _ = filetime::set_file_times(dir, ft, ft);
        }
        self.summary
    }
}

impl Sink for Extractor<'_, '_> {
    fn wants(&self, path: &str) -> bool {
        self.selection.matches(path)
    }

    fn directory(&mut self, path: &str, mtime: Option<i64>) -> Result<()> {
        let Some((target, _)) = self.resolve(path) else {
            return Ok(());
        };
        self.ensure_dir(&target)?;
        if let Some(t) = mtime {
            self.dir_times.push((target, t));
        }
        Ok(())
    }

    fn file(&mut self, path: &str, data: &mut dyn Read, mtime: Option<i64>, mode: Option<u32>) -> Result<()> {
        let Some((target, _)) = self.resolve(path) else {
            return Ok(());
        };
        self.tracker.set_current(path)?;
        let Some(target) = self.prepare_target(target)? else {
            // Daten trotzdem verbrauchen, damit der Fortschritt stimmt.
            let mut out = ProgressWriter::new(io::sink(), self.tracker);
            io::copy(data, &mut out).map_err(|e| read_error(e, path))?;
            return Ok(());
        };

        // `create_new` folgt keinen Symlinks und überschreibt nichts.
        let file = OpenOptions::new().write(true).create_new(true).open(&target)?;
        let mut out = ProgressWriter::new(io::BufWriter::with_capacity(256 * 1024, file), self.tracker);
        let result = io::copy(data, &mut out)
            .map_err(|e| read_error(e, path))
            .and_then(|n| out.flush().map(|()| n).map_err(ZippError::from));
        drop(out);
        match result {
            Ok(n) => {
                self.summary.files += 1;
                self.summary.bytes += n;
                self.finish_file(&target, mtime, mode);
                Ok(())
            }
            Err(e) => {
                let _ = fs::remove_file(&target);
                Err(e)
            }
        }
    }

    fn symlink(&mut self, path: &str, link_target: &str) -> Result<()> {
        let Some((target, rel)) = self.resolve(path) else {
            return Ok(());
        };
        if !symlink_target_is_safe(&rel, link_target) {
            self.summary.skipped_unsafe.push(path.to_string());
            return Ok(());
        }
        let Some(target) = self.prepare_target(target)? else {
            return Ok(());
        };
        std::os::unix::fs::symlink(link_target, &target)?;
        self.summary.symlinks += 1;
        Ok(())
    }

    fn unsupported(&mut self, path: &str) {
        self.summary.skipped_unsafe.push(path.to_string());
    }

    fn external(&mut self, path: &str) -> Result<ExternalAction> {
        let Some((target, _)) = self.resolve(path) else {
            return Ok(ExternalAction::Skip);
        };
        self.tracker.set_current(path)?;
        Ok(match self.prepare_target(target)? {
            Some(target) => ExternalAction::Extract(target),
            None => ExternalAction::Skip,
        })
    }

    fn external_done(&mut self, target: Option<&Path>, size: u64, mtime: Option<i64>) -> Result<()> {
        if let Some(target) = target {
            self.summary.files += 1;
            self.summary.bytes += size;
            self.finish_file(target, mtime, None);
        }
        self.tracker.add(size)?;
        Ok(())
    }
}

/// „Name.ext“ → „Name 2.ext“, „Name 3.ext“ … (erster freier Name).
pub(crate) fn unique_path(path: &Path) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    // Mehrteilige Endungen wie .tar.gz zusammenhalten
    let (stem, ext) = match name.find('.') {
        Some(0) | None => (name.as_str(), ""),
        Some(i) => (&name[..i], &name[i..]),
    };
    for n in 2.. {
        let candidate = parent.join(format!("{stem} {n}{ext}"));
        if fs::symlink_metadata(&candidate).is_err() {
            return candidate;
        }
    }
    unreachable!("unendlich viele Kandidaten")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_matching() {
        let s = Selection::new(&["Bilder".into()], Some("Dokumente"));
        assert!(s.matches("Bilder"));
        assert!(s.matches("Bilder/a.png"));
        assert!(!s.matches("BilderX/a.png"));
        assert_eq!(s.relative("Dokumente/x.txt"), "x.txt");
        assert_eq!(s.relative("DokumenteX/x.txt"), "DokumenteX/x.txt");
        assert!(Selection::new(&[], None).matches("irgendwas"));
    }

    #[test]
    fn unique_names() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.tar.gz");
        fs::write(&p, b"x").unwrap();
        assert_eq!(unique_path(&p), dir.path().join("a 2.tar.gz"));
        let q = dir.path().join(".hidden");
        fs::write(&q, b"x").unwrap();
        assert_eq!(unique_path(&q), dir.path().join(".hidden 2"));
    }
}
