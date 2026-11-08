//! Mehrteilige Archive.
//!
//! - **Lesen**: `.part1.rar`/`.r00` übernimmt UnRAR selbst; ZIPP muss nur den
//!   ersten Teil finden. Byteweise aufgeteilte Archive (`name.7z.001`, `.002` …,
//!   wie 7-Zip sie erzeugt) werden als ein zusammenhängender Strom gelesen.
//! - **Schreiben**: [`OutputFile`] verteilt die Bytes auf Teile fester Größe
//!   und kann dabei zurückspringen (ZIP und 7z schreiben Header nachträglich).

use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::error::{Result, ZippError};

/// Kleinste erlaubte Teilgröße.
pub const MIN_VOLUME_SIZE: u64 = 64 * 1024;

// MARK: - Teile finden

/// Endet der Name auf `.<Ziffern>` (mindestens 3), z. B. `.001`?
/// Liefert (Name ohne Nummer, Nummer, Stellen).
fn split_number(name: &str) -> Option<(&str, u32, usize)> {
    let (stem, digits) = name.rsplit_once('.')?;
    if digits.len() < 3 || !digits.bytes().all(|b| b.is_ascii_digit()) || stem.is_empty() {
        return None;
    }
    Some((stem, digits.parse().ok()?, digits.len()))
}

/// `name.partN.rar` → (Präfix bis „part“, Nummer, Stellen).
fn rar_part_number(name: &str) -> Option<(&str, u32, usize)> {
    let lower = name.to_ascii_lowercase();
    if !lower.ends_with(".rar") {
        return None;
    }
    let without = &name[..name.len() - 4];
    let idx = without.to_ascii_lowercase().rfind(".part")?;
    let digits = &without[idx + 5..];
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some((&without[..idx + 5], digits.parse().ok()?, digits.len()))
}

/// Alter RAR-Stil: `name.r00`, `name.r01` … (der erste Teil heißt `name.rar`).
fn old_rar_volume(name: &str) -> Option<(&str, u32)> {
    let (stem, ext) = name.rsplit_once('.')?;
    let bytes = ext.as_bytes();
    if bytes.len() == 3
        && (bytes[0] == b'r' || bytes[0] == b'R')
        && ext[1..].bytes().all(|b| b.is_ascii_digit())
    {
        return Some((stem, ext[1..].parse().ok()?));
    }
    None
}

fn file_name(path: &Path) -> Option<String> {
    path.file_name().map(|n| n.to_string_lossy().into_owned())
}

/// Der erste Teil eines mehrteiligen Archivs. Bei normalen Archiven `path` selbst.
pub fn first_volume(path: &Path) -> PathBuf {
    let Some(name) = file_name(path) else {
        return path.to_path_buf();
    };
    let dir = path.parent().unwrap_or_else(|| Path::new(""));
    let candidate = if let Some((prefix, n, width)) = rar_part_number(&name) {
        (n != 1).then(|| dir.join(format!("{prefix}{:0width$}.rar", 1)))
    } else if let Some((stem, _)) = old_rar_volume(&name) {
        Some(dir.join(format!("{stem}.rar")))
    } else if let Some((stem, n, width)) = split_number(&name) {
        (n != 1).then(|| dir.join(format!("{stem}.{:0width$}", 1)))
    } else {
        None
    };
    match candidate {
        Some(first) if first.is_file() => first,
        _ => path.to_path_buf(),
    }
}

/// Alle vorhandenen Teile in Reihenfolge, beginnend mit dem ersten.
/// Bei normalen Archiven nur `path`.
pub fn all_volumes(path: &Path) -> Vec<PathBuf> {
    let first = first_volume(path);
    let Some(name) = file_name(&first) else {
        return vec![first];
    };
    let dir = first.parent().unwrap_or_else(|| Path::new("")).to_path_buf();
    let mut parts = vec![first.clone()];
    let mut push_while = |make: &dyn Fn(u32) -> PathBuf, start: u32| {
        for n in start.. {
            let p = make(n);
            if !p.is_file() {
                break;
            }
            parts.push(p);
        }
    };
    if let Some((prefix, 1, width)) = rar_part_number(&name) {
        push_while(&|n| dir.join(format!("{prefix}{n:0width$}.rar")), 2);
    } else if let Some((stem, 1, width)) = split_number(&name) {
        push_while(&|n| dir.join(format!("{stem}.{n:0width$}")), 2);
    } else if name.to_ascii_lowercase().ends_with(".rar") {
        let stem = &name[..name.len() - 4];
        push_while(&|n| dir.join(format!("{stem}.r{n:02}")), 0);
    }
    parts
}

/// Archivname ohne Teilnummer, für Ordnernamen und die Endungserkennung:
/// `Fotos.7z.001` → `Fotos.7z`, `Fotos.part1.rar` → `Fotos.rar`.
pub fn logical_name(path: &Path) -> String {
    let name = file_name(path).unwrap_or_default();
    if let Some((prefix, _, _)) = rar_part_number(&name) {
        return format!("{}.rar", &prefix[..prefix.len() - 5]);
    }
    if let Some((stem, _, _)) = split_number(&name) {
        return stem.to_string();
    }
    name
}

/// Gesamtgröße aller Teile.
pub(crate) fn total_size(path: &Path) -> Result<u64> {
    let mut sum = 0;
    for p in all_volumes(path) {
        sum += fs::metadata(&p)?.len();
    }
    Ok(sum)
}

// MARK: - Lesen

/// Liest mehrere Dateien als einen Strom (Read + Seek). Für normale Archive
/// ist es einfach die eine Datei.
pub(crate) struct Source {
    parts: Vec<(File, u64)>,
    /// Startposition jedes Teils im Gesamtstrom.
    starts: Vec<u64>,
    len: u64,
    pos: u64,
}

impl Source {
    /// Öffnet ein Archiv; byteweise aufgeteilte Teile werden zusammengesetzt.
    pub(crate) fn open(path: &Path) -> Result<Self> {
        let first = first_volume(path);
        let paths = match file_name(&first).as_deref().and_then(split_number) {
            Some(_) => all_volumes(&first),
            None => vec![first],
        };
        let mut parts = Vec::with_capacity(paths.len());
        let mut starts = Vec::with_capacity(paths.len());
        let mut len = 0;
        for p in &paths {
            let file = File::open(p).map_err(|e| ZippError::Io(format!("{}: {e}", p.display())))?;
            let size = file.metadata()?.len();
            starts.push(len);
            len += size;
            parts.push((file, size));
        }
        Ok(Self {
            parts,
            starts,
            len,
            pos: 0,
        })
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> u64 {
        self.len
    }

    fn locate(&self, pos: u64) -> Option<(usize, u64)> {
        let idx = match self.starts.binary_search(&pos) {
            Ok(i) => i,
            Err(i) => i.checked_sub(1)?,
        };
        let offset = pos - self.starts[idx];
        // Leere Teile überspringen
        let mut i = idx;
        let mut off = offset;
        while i < self.parts.len() && off >= self.parts[i].1 {
            off -= self.parts[i].1;
            i += 1;
        }
        (i < self.parts.len()).then_some((i, off))
    }
}

impl Read for Source {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || self.pos >= self.len {
            return Ok(0);
        }
        let Some((idx, offset)) = self.locate(self.pos) else {
            return Ok(0);
        };
        let (file, size) = &mut self.parts[idx];
        let max = usize::try_from((*size - offset).min(buf.len() as u64)).unwrap_or(buf.len());
        file.seek(SeekFrom::Start(offset))?;
        let n = file.read(&mut buf[..max])?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for Source {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let target = match to {
            SeekFrom::Start(p) => Some(p),
            SeekFrom::End(d) => self.len.checked_add_signed(d),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
        }
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "ungültige Position"))?;
        self.pos = target;
        Ok(target)
    }
}

// MARK: - Schreiben

/// Zieldatei, die erst bei [`commit`](Self::commit) sichtbar wird und bei
/// Bedarf in Teile fester Größe aufgeteilt wird (`.001`, `.002` …).
///
/// Ergibt sich nur ein Teil, bekommt er den normalen Namen ohne Nummer.
pub(crate) struct OutputFile {
    dest: PathBuf,
    volume_size: u64,
    parts: Vec<(PathBuf, File)>,
    pos: u64,
    len: u64,
    committed: bool,
}

impl OutputFile {
    pub(crate) fn new(dest: &Path, volume_size: Option<u64>) -> Result<Self> {
        let volume_size = match volume_size {
            Some(v) if v > 0 => {
                if v < MIN_VOLUME_SIZE {
                    return Err(ZippError::Unsupported(format!(
                        "Teile müssen mindestens {} KB groß sein",
                        MIN_VOLUME_SIZE / 1024
                    )));
                }
                v
            }
            _ => u64::MAX,
        };
        let mut out = Self {
            dest: dest.to_path_buf(),
            volume_size,
            parts: Vec::new(),
            pos: 0,
            len: 0,
            committed: false,
        };
        out.ensure_part(0)?;
        Ok(out)
    }

    fn temp_path(&self, index: usize) -> PathBuf {
        let dir = self.dest.parent().unwrap_or_else(|| Path::new("."));
        let name = file_name(&self.dest).unwrap_or_default();
        dir.join(format!(
            ".{name}.zipp-{}-{:03}.tmp",
            std::process::id(),
            index + 1
        ))
    }

    fn ensure_part(&mut self, index: usize) -> io::Result<()> {
        while self.parts.len() <= index {
            let path = self.temp_path(self.parts.len());
            let file = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(true)
                .open(&path)?;
            self.parts.push((path, file));
        }
        Ok(())
    }

    /// Endgültige Namen der Teile.
    fn final_paths(&self) -> Vec<PathBuf> {
        if self.parts.len() == 1 {
            return vec![self.dest.clone()];
        }
        let width = self.parts.len().to_string().len().max(3);
        let name = file_name(&self.dest).unwrap_or_default();
        let dir = self.dest.parent().unwrap_or_else(|| Path::new(""));
        (1..=self.parts.len())
            .map(|n| dir.join(format!("{name}.{n:0width$}")))
            .collect()
    }

    /// Schreibt alles auf die Platte und gibt den Teilen ihre endgültigen Namen.
    pub(crate) fn commit(mut self) -> Result<Vec<PathBuf>> {
        for (_, f) in &self.parts {
            f.sync_all()?;
        }
        let finals = self.final_paths();
        for ((temp, _), dest) in self.parts.iter().zip(&finals) {
            fs::rename(temp, dest)?;
        }
        self.committed = true;
        Ok(finals)
    }

    pub(crate) fn len(&self) -> u64 {
        self.len
    }

    /// Bereits angelegte Teile. Die Quellensammlung überspringt sie, sonst
    /// landet das Archiv in sich selbst.
    pub(crate) fn temp_paths(&self) -> Vec<PathBuf> {
        self.parts.iter().map(|(p, _)| p.clone()).collect()
    }
}

impl Write for OutputFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let idx =
            usize::try_from(self.pos / self.volume_size).map_err(|_| io::Error::other("Archiv zu groß"))?;
        let offset = self.pos % self.volume_size;
        self.ensure_part(idx)?;
        let room = self.volume_size - offset;
        let n = usize::try_from(room.min(buf.len() as u64)).unwrap_or(buf.len());
        let file = &mut self.parts[idx].1;
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(&buf[..n])?;
        self.pos += n as u64;
        self.len = self.len.max(self.pos);
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        for (_, f) in &mut self.parts {
            f.flush()?;
        }
        Ok(())
    }
}

impl Seek for OutputFile {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let target = match to {
            SeekFrom::Start(p) => Some(p),
            SeekFrom::End(d) => self.len.checked_add_signed(d),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
        }
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "ungültige Position"))?;
        self.pos = target;
        Ok(target)
    }
}

impl Drop for OutputFile {
    fn drop(&mut self) {
        if !self.committed {
            for (p, _) in &self.parts {
                let _ = fs::remove_file(p);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(split_number("a.7z.001"), Some(("a.7z", 1, 3)));
        assert_eq!(split_number("a.7z.12"), None);
        assert_eq!(split_number("a.txt"), None);
        assert_eq!(rar_part_number("Film.part03.rar"), Some(("Film.part", 3, 2)));
        assert_eq!(rar_part_number("Film.rar"), None);
        assert_eq!(old_rar_volume("Film.r07"), Some(("Film", 7)));
        assert_eq!(old_rar_volume("Film.rar"), None);
        assert_eq!(logical_name(Path::new("/x/Fotos.7z.002")), "Fotos.7z");
        assert_eq!(logical_name(Path::new("/x/Fotos.part2.rar")), "Fotos.rar");
        assert_eq!(logical_name(Path::new("/x/Fotos.zip")), "Fotos.zip");
    }

    #[test]
    fn finds_parts() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        for n in ["Film.part01.rar", "Film.part02.rar", "Film.part03.rar"] {
            fs::write(d.join(n), b"x").unwrap();
        }
        assert_eq!(
            first_volume(&d.join("Film.part03.rar")),
            d.join("Film.part01.rar")
        );
        assert_eq!(all_volumes(&d.join("Film.part02.rar")).len(), 3);

        for n in ["Alt.rar", "Alt.r00", "Alt.r01"] {
            fs::write(d.join(n), b"x").unwrap();
        }
        assert_eq!(first_volume(&d.join("Alt.r01")), d.join("Alt.rar"));
        assert_eq!(all_volumes(&d.join("Alt.rar")).len(), 3);

        for n in ["Daten.7z.001", "Daten.7z.002"] {
            fs::write(d.join(n), b"x").unwrap();
        }
        assert_eq!(first_volume(&d.join("Daten.7z.002")), d.join("Daten.7z.001"));
        assert_eq!(all_volumes(&d.join("Daten.7z.002")).len(), 2);

        // Ohne ersten Teil bleibt der Pfad, wie er ist
        fs::write(d.join("Einzel.7z.005"), b"x").unwrap();
        assert_eq!(first_volume(&d.join("Einzel.7z.005")), d.join("Einzel.7z.005"));
    }

    #[test]
    fn split_write_and_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("x.bin");
        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let mut out = OutputFile::new(&dest, Some(MIN_VOLUME_SIZE)).unwrap();
        out.write_all(&data).unwrap();
        // Zurückspringen und über eine Teilgrenze hinweg überschreiben
        out.seek(SeekFrom::Start(MIN_VOLUME_SIZE - 2)).unwrap();
        out.write_all(b"ABCD").unwrap();
        let paths = out.commit().unwrap();
        assert_eq!(paths.len(), 5);
        assert_eq!(paths[0], dir.path().join("x.bin.001"));

        let mut expected = data.clone();
        let at = usize::try_from(MIN_VOLUME_SIZE - 2).unwrap();
        expected[at..at + 4].copy_from_slice(b"ABCD");
        let mut src = Source::open(&paths[3]).unwrap();
        assert_eq!(src.len(), expected.len() as u64);
        let mut back = Vec::new();
        src.read_to_end(&mut back).unwrap();
        assert_eq!(back, expected);
        src.seek(SeekFrom::End(-3)).unwrap();
        let mut tail = [0u8; 3];
        src.read_exact(&mut tail).unwrap();
        assert_eq!(&tail, &expected[expected.len() - 3..]);
        // Keine Reste
        let leftovers = fs::read_dir(dir.path())
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            })
            .count();
        assert_eq!(leftovers, 0);
    }

    #[test]
    fn single_part_keeps_plain_name() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("klein.zip");
        let mut out = OutputFile::new(&dest, Some(MIN_VOLUME_SIZE)).unwrap();
        out.write_all(b"hallo").unwrap();
        assert_eq!(out.commit().unwrap(), vec![dest.clone()]);
        assert_eq!(fs::read(dest).unwrap(), b"hallo");
    }

    #[test]
    fn dropped_output_leaves_nothing() {
        let dir = tempfile::tempdir().unwrap();
        {
            let mut out = OutputFile::new(&dir.path().join("a.7z"), Some(MIN_VOLUME_SIZE)).unwrap();
            out.write_all(&vec![0u8; 200_000]).unwrap();
        }
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
    }
}
