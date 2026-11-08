//! `zipp`: der ZIPP-Kern auf der Kommandozeile.
//!
//! ```text
//! zipp l  archiv            Inhalt auflisten
//! zipp x  archiv [ziel]     entpacken (Standard: neben dem Archiv, intelligenter Ordner)
//! zipp t  archiv            testen
//! zipp a  ziel.zip dateien… erstellen (Format aus der Endung)
//! zipp c  archiv ziel.7z    konvertieren
//! Optionen: -p PASSWORT, -v GRÖSSE (z. B. 100m, 4g: aufteilen), -0 … -9 (Stufe)
//! ```

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};

use zipp_core::{
    CreateFormat, CreateOptions, ExtractOptions, Progress, ZippError, all_volumes, convert_archive,
    create_archive, extract_archive, first_volume, list_archive, logical_name, test_archive,
};

struct Options {
    password: Option<String>,
    volume_size: Option<u64>,
    level: u8,
    args: Vec<String>,
}

fn parse(mut raw: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut o = Options {
        password: None,
        volume_size: None,
        level: 6,
        args: Vec::new(),
    };
    while let Some(arg) = raw.next() {
        match arg.as_str() {
            "-p" => o.password = Some(raw.next().ok_or("-p braucht ein Passwort")?),
            "-v" => o.volume_size = Some(parse_size(&raw.next().ok_or("-v braucht eine Größe")?)?),
            s if s.len() == 2 && s.starts_with('-') && s.as_bytes()[1].is_ascii_digit() => {
                o.level = s.as_bytes()[1] - b'0';
            }
            _ => o.args.push(arg),
        }
    }
    Ok(o)
}

fn parse_size(s: &str) -> Result<u64, String> {
    let lower = s.to_ascii_lowercase();
    let (num, factor) = match lower.chars().last() {
        Some('k') => (&lower[..lower.len() - 1], 1_000),
        Some('m') => (&lower[..lower.len() - 1], 1_000_000),
        Some('g') => (&lower[..lower.len() - 1], 1_000_000_000),
        _ => (lower.as_str(), 1),
    };
    let n: f64 = num.parse().map_err(|_| format!("Ungültige Größe „{s}“"))?;
    Ok((n * f64::from(factor)) as u64)
}

fn format_for(dest: &Path) -> Result<CreateFormat, String> {
    let name = dest.to_string_lossy().to_lowercase();
    Ok(match () {
        () if name.ends_with(".zip") => CreateFormat::Zip,
        () if name.ends_with(".7z") => CreateFormat::SevenZip,
        () if name.ends_with(".tar.gz") || name.ends_with(".tgz") => CreateFormat::TarGz,
        () if name.ends_with(".tar.xz") || name.ends_with(".txz") => CreateFormat::TarXz,
        () if name.ends_with(".tar.zst") || name.ends_with(".tzst") => CreateFormat::TarZst,
        () if name.ends_with(".tar.bz2") || name.ends_with(".tbz2") => CreateFormat::TarBz2,
        () if name.ends_with(".tar") => CreateFormat::Tar,
        () => return Err(format!("Unbekannte Endung: {}", dest.display())),
    })
}

/// Fortschritt als Prozentzahl auf stderr (nur im Terminal).
struct Bar(AtomicU64);

impl Progress for Bar {
    fn update(&self, done: u64, total: u64, _current: &str) {
        if total == 0 || !std::io::stderr().is_terminal() {
            return;
        }
        let pct = done.saturating_mul(100) / total;
        if self.0.swap(pct, Ordering::Relaxed) != pct {
            eprint!("\r{pct:3} %");
        }
    }

    fn is_cancelled(&self) -> bool {
        false
    }
}

fn size(bytes: u64) -> String {
    match bytes {
        b if b >= 1_000_000_000 => format!("{:.1} GB", b as f64 / 1e9),
        b if b >= 1_000_000 => format!("{:.1} MB", b as f64 / 1e6),
        b if b >= 1_000 => format!("{:.1} KB", b as f64 / 1e3),
        b => format!("{b} B"),
    }
}

fn run() -> Result<(), String> {
    let mut raw = std::env::args().skip(1);
    let command = raw.next().unwrap_or_default();
    let o = parse(raw)?;
    let pw = o.password.as_deref();
    let bar = Bar(AtomicU64::new(u64::MAX));
    let err = |e: ZippError| e.to_string();
    let arg = |i: usize| o.args.get(i).map(PathBuf::from);

    match command.as_str() {
        "l" | "list" => {
            let archive = arg(0).ok_or("Archiv fehlt")?;
            let listing = list_archive(&archive, pw).map_err(err)?;
            for e in &listing.entries {
                let kind = if e.is_dir {
                    "/"
                } else if e.is_symlink {
                    "@"
                } else {
                    ""
                };
                let lock = if e.encrypted { " 🔒" } else { "" };
                println!(
                    "{:>10}  {}{kind}{lock}",
                    if e.is_dir { String::new() } else { size(e.size) },
                    e.path
                );
            }
            println!(
                "\n{} · {} Einträge · {} entpackt · {} Archiv{}{}",
                listing.format.label(),
                listing.entries.len(),
                size(listing.total_size()),
                size(listing.archive_size),
                if all_volumes(&archive).len() > 1 {
                    format!(" · {} Teile", all_volumes(&archive).len())
                } else {
                    String::new()
                },
                listing
                    .name_encoding
                    .map(|e| format!(" · Namen in {e}"))
                    .unwrap_or_default()
            );
        }
        "x" | "extract" => {
            let archive = first_volume(&arg(0).ok_or("Archiv fehlt")?);
            let dest = match arg(1) {
                Some(d) => d,
                None => {
                    let listing = list_archive(&archive, pw).map_err(err)?;
                    let parent = archive.parent().unwrap_or(Path::new(".")).to_path_buf();
                    if listing.single_root_folder().is_some() || listing.top_level_names().len() <= 1 {
                        parent
                    } else {
                        let name = logical_name(&archive);
                        let stem = name.split('.').next().unwrap_or("Archiv").to_string();
                        parent.join(stem)
                    }
                }
            };
            let options = ExtractOptions {
                password: o.password.clone(),
                apply_quarantine: true,
                ..Default::default()
            };
            let s = extract_archive(&archive, &dest, &options, &bar).map_err(err)?;
            eprintln!(
                "\r{} Dateien ({}) nach {}",
                s.files,
                size(s.bytes),
                dest.display()
            );
            if !s.skipped_unsafe.is_empty() {
                eprintln!("Übersprungen (unsicher): {}", s.skipped_unsafe.join(", "));
            }
        }
        "t" | "test" => {
            let archive = arg(0).ok_or("Archiv fehlt")?;
            let s = test_archive(&archive, pw, &bar).map_err(err)?;
            eprintln!("\rKeine Fehler · {} Dateien · {}", s.files, size(s.bytes));
        }
        "a" | "add" | "create" => {
            let dest = arg(0).ok_or("Ziel fehlt")?;
            let sources: Vec<PathBuf> = o.args[1..].iter().map(PathBuf::from).collect();
            let options = CreateOptions {
                format: format_for(&dest)?,
                level: o.level,
                password: o.password.clone(),
                encrypt_file_names: o.password.is_some(),
                exclude_mac_metadata: true,
                volume_size: o.volume_size,
            };
            let s = create_archive(&sources, &dest, &options, &bar).map_err(err)?;
            eprintln!(
                "\r{} Dateien · {} → {}",
                s.files,
                size(s.bytes_in),
                size(s.bytes_out)
            );
            for out in &s.outputs {
                println!("{}", out.display());
            }
        }
        "c" | "convert" => {
            let archive = arg(0).ok_or("Archiv fehlt")?;
            let dest = arg(1).ok_or("Ziel fehlt")?;
            let options = CreateOptions {
                format: format_for(&dest)?,
                level: o.level,
                password: None,
                encrypt_file_names: false,
                exclude_mac_metadata: false,
                volume_size: o.volume_size,
            };
            let s = convert_archive(&archive, pw, &dest, &options, &bar).map_err(err)?;
            eprintln!("\r{} Dateien → {}", s.files, size(s.bytes_out));
        }
        _ => {
            eprintln!(
                "ZIPP {} – Archive auf der Kommandozeile\n\n\
                 zipp l archiv              Inhalt auflisten\n\
                 zipp x archiv [ziel]       entpacken\n\
                 zipp t archiv              testen\n\
                 zipp a ziel.zip dateien…   erstellen (zip, 7z, tar, tar.gz, tar.xz, tar.zst, tar.bz2)\n\
                 zipp c archiv ziel.7z      konvertieren\n\n\
                 -p PASSWORT   Passwort (beim Erstellen: AES-256)\n\
                 -v GRÖSSE     in Teile aufteilen, z. B. -v 100m, -v 4g\n\
                 -0 … -9       Kompressionsstufe (Standard 6)",
                env!("CARGO_PKG_VERSION")
            );
            return Err(String::new());
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            if !e.is_empty() {
                eprintln!("\rFehler: {e}");
            }
            ExitCode::FAILURE
        }
    }
}
