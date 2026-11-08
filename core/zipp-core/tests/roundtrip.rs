//! Ende-zu-Ende-Tests: erstellen → auflisten → testen → entpacken → vergleichen.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use zipp_core::*;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Legt einen Beispielordner an:
/// projekt/
///   readme.txt, leer.txt, Ümlaut ä.txt, bild.png (zufällig), sub/tief/code.rs, link -> readme.txt
///   .DS_Store (soll ausgeschlossen werden)
fn sample_tree(root: &Path) -> PathBuf {
    let p = root.join("projekt");
    fs::create_dir_all(p.join("sub/tief")).unwrap();
    fs::write(p.join("readme.txt"), "Hallo ZIPP\n".repeat(200)).unwrap();
    fs::write(p.join("leer.txt"), "").unwrap();
    fs::write(p.join("Ümlaut ä.txt"), "Grüße").unwrap();
    let noise: Vec<u8> = (0..50_000u32)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
        .collect();
    fs::write(p.join("bild.png"), noise).unwrap();
    fs::write(p.join("sub/tief/code.rs"), "fn main() {}\n").unwrap();
    fs::write(p.join(".DS_Store"), "junk").unwrap();
    std::os::unix::fs::symlink("readme.txt", p.join("link")).unwrap();
    p
}

fn assert_same_tree(original: &Path, extracted: &Path) {
    for rel in [
        "readme.txt",
        "leer.txt",
        "Ümlaut ä.txt",
        "bild.png",
        "sub/tief/code.rs",
    ] {
        let a = fs::read(original.join(rel)).unwrap();
        let b = fs::read(extracted.join(rel)).unwrap_or_else(|_| panic!("fehlt: {rel}"));
        assert_eq!(a, b, "Inhalt verschieden: {rel}");
    }
    assert!(
        !extracted.join(".DS_Store").exists(),
        ".DS_Store hätte fehlen sollen"
    );
}

fn create(src: &Path, dest: &Path, format: CreateFormat, password: Option<&str>) -> CreateSummary {
    let options = CreateOptions {
        format,
        level: 6,
        password: password.map(str::to_string),
        encrypt_file_names: password.is_some(),
        exclude_mac_metadata: true,
        volume_size: None,
    };
    create_archive(&[src.to_path_buf()], dest, &options, &NoProgress).unwrap()
}

#[test]
fn roundtrip_all_formats() {
    for format in [
        CreateFormat::Zip,
        CreateFormat::SevenZip,
        CreateFormat::TarGz,
        CreateFormat::TarXz,
        CreateFormat::TarZst,
        CreateFormat::TarBz2,
    ] {
        let dir = tempfile::tempdir().unwrap();
        let src = sample_tree(dir.path());
        let archive = dir.path().join(format!("test.{}", format.extension()));
        let summary = create(&src, &archive, format, None);
        assert_eq!(summary.files, 6, "{format:?}: 5 Dateien + 1 Symlink");

        let listing = list_archive(&archive, None).unwrap();
        assert_eq!(
            listing.single_root_folder().as_deref(),
            Some("projekt"),
            "{format:?}"
        );
        assert!(
            listing
                .entries
                .iter()
                .any(|e| e.path == "projekt/sub/tief/code.rs"),
            "{format:?}"
        );
        assert!(listing.entries.iter().all(|e| !e.path.ends_with(".DS_Store")));
        let link = listing
            .entries
            .iter()
            .find(|e| e.path == "projekt/link")
            .expect("Symlink fehlt");
        assert!(link.is_symlink, "{format:?}: Symlink nicht erkannt");

        let tested = test_archive(&archive, None, &NoProgress).unwrap();
        assert_eq!(tested.files, 6, "{format:?}");

        let out = dir.path().join("out");
        let result = extract_archive(&archive, &out, &ExtractOptions::default(), &NoProgress).unwrap();
        assert_eq!(result.files, 5, "{format:?}");
        assert_eq!(result.symlinks, 1, "{format:?}");
        assert_same_tree(&src, &out.join("projekt"));
        assert_eq!(
            fs::read_link(out.join("projekt/link")).unwrap(),
            PathBuf::from("readme.txt")
        );
    }
}

#[test]
fn detects_formats() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    for (format, expected) in [
        (CreateFormat::Zip, ArchiveFormat::Zip),
        (CreateFormat::SevenZip, ArchiveFormat::SevenZip),
        (CreateFormat::TarGz, ArchiveFormat::TarGz),
        (CreateFormat::TarXz, ArchiveFormat::TarXz),
        (CreateFormat::TarZst, ArchiveFormat::TarZst),
        (CreateFormat::TarBz2, ArchiveFormat::TarBz2),
    ] {
        // Absichtlich falsche Endung: Erkennung muss über den Inhalt laufen
        let archive = dir.path().join(format!("x-{}.bin", format.extension()));
        create(&src, &archive, format, None);
        assert_eq!(detect_format(&archive).unwrap(), expected);
    }
    assert_eq!(
        detect_format(&fixture("version.rar")).unwrap(),
        ArchiveFormat::Rar
    );
    let text = dir.path().join("kein-archiv.txt");
    fs::write(&text, "hallo").unwrap();
    assert_eq!(detect_format(&text), Err(ZippError::UnsupportedFormat));
}

#[test]
fn single_gzip_file() {
    let dir = tempfile::tempdir().unwrap();
    let gz = dir.path().join("log.txt.gz");
    let mut enc =
        flate2::write::GzEncoder::new(fs::File::create(&gz).unwrap(), flate2::Compression::default());
    enc.write_all(b"Zeile 1\nZeile 2\n").unwrap();
    enc.finish().unwrap();

    assert_eq!(detect_format(&gz).unwrap(), ArchiveFormat::Gzip);
    let listing = list_archive(&gz, None).unwrap();
    assert_eq!(listing.entries.len(), 1);
    assert_eq!(listing.entries[0].path, "log.txt");
    assert_eq!(listing.entries[0].size, 16);
    let out = dir.path().join("out");
    extract_archive(&gz, &out, &ExtractOptions::default(), &NoProgress).unwrap();
    assert_eq!(
        fs::read_to_string(out.join("log.txt")).unwrap(),
        "Zeile 1\nZeile 2\n"
    );
}

#[test]
fn zip_password() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("geheim.zip");
    create(&src, &archive, CreateFormat::Zip, Some("s3cret"));

    let listing = list_archive(&archive, None).unwrap();
    assert!(listing.has_encrypted_entries);
    let out = dir.path().join("out");
    assert_eq!(
        extract_archive(&archive, &out, &ExtractOptions::default(), &NoProgress),
        Err(ZippError::PasswordRequired)
    );
    let wrong = ExtractOptions {
        password: Some("falsch".into()),
        ..Default::default()
    };
    assert_eq!(
        extract_archive(&archive, &out, &wrong, &NoProgress),
        Err(ZippError::WrongPassword)
    );
    let right = ExtractOptions {
        password: Some("s3cret".into()),
        ..Default::default()
    };
    extract_archive(&archive, &out, &right, &NoProgress).unwrap();
    assert_same_tree(&src, &out.join("projekt"));
}

#[test]
fn sevenz_password_with_encrypted_names() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("geheim.7z");
    create(&src, &archive, CreateFormat::SevenZip, Some("s3cret"));

    // Dateinamen sind verschlüsselt: ohne Passwort nicht einmal auflistbar
    assert_eq!(
        list_archive(&archive, None).err(),
        Some(ZippError::PasswordRequired)
    );
    let listing = list_archive(&archive, Some("s3cret")).unwrap();
    assert!(listing.header_encrypted);
    assert!(listing.has_encrypted_entries);

    let out = dir.path().join("out");
    let right = ExtractOptions {
        password: Some("s3cret".into()),
        ..Default::default()
    };
    extract_archive(&archive, &out, &right, &NoProgress).unwrap();
    assert_same_tree(&src, &out.join("projekt"));

    let wrong = ExtractOptions {
        password: Some("falsch".into()),
        ..Default::default()
    };
    assert!(extract_archive(&archive, &dir.path().join("out2"), &wrong, &NoProgress).is_err());
}

#[test]
fn rar_fixtures() {
    let listing = list_archive(&fixture("version.rar"), None).unwrap();
    assert_eq!(listing.format, ArchiveFormat::Rar);
    assert!(!listing.entries.is_empty());
    let dir = tempfile::tempdir().unwrap();
    let res = extract_archive(
        &fixture("version.rar"),
        dir.path(),
        &ExtractOptions::default(),
        &NoProgress,
    )
    .unwrap();
    assert!(res.files >= 1);
    test_archive(&fixture("solid.rar"), None, &NoProgress).unwrap();

    // Verschlüsselter Inhalt, Namen lesbar
    let crypted = fixture("crypted.rar");
    let listing = list_archive(&crypted, None).unwrap();
    assert!(listing.has_encrypted_entries);
    assert_eq!(listing.entries[0].path, ".gitignore");
    let out = dir.path().join("crypted");
    assert_eq!(
        extract_archive(&crypted, &out, &ExtractOptions::default(), &NoProgress),
        Err(ZippError::PasswordRequired)
    );
    let opts = ExtractOptions {
        password: Some("unrar".into()),
        ..Default::default()
    };
    extract_archive(&crypted, &out, &opts, &NoProgress).unwrap();
    assert_eq!(
        fs::read_to_string(out.join(".gitignore")).unwrap(),
        "target\nCargo.lock\n"
    );

    // Verschlüsselte Namen
    let hpw = fixture("comment-hpw-password.rar");
    assert!(list_archive(&hpw, None).is_err());
    let listing = list_archive(&hpw, Some("password")).unwrap();
    assert!(listing.header_encrypted);
}

#[test]
fn selection_and_strip_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("a.zip");
    create(&src, &archive, CreateFormat::Zip, None);

    // Wie beim Herausziehen von „tief“ aus dem Ordner „projekt/sub“
    let out = dir.path().join("drag");
    let opts = ExtractOptions {
        selection: vec!["projekt/sub/tief".into()],
        strip_prefix: Some("projekt/sub".into()),
        ..Default::default()
    };
    let res = extract_archive(&archive, &out, &opts, &NoProgress).unwrap();
    assert_eq!(res.files, 1);
    assert_eq!(
        fs::read_to_string(out.join("tief/code.rs")).unwrap(),
        "fn main() {}\n"
    );
    assert!(!out.join("projekt").exists());
}

#[test]
fn overwrite_policies() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("a.zip");
    create(&src, &archive, CreateFormat::Zip, None);
    let out = dir.path().join("out");
    let only_readme = |overwrite| ExtractOptions {
        selection: vec!["projekt/readme.txt".into()],
        overwrite,
        ..Default::default()
    };
    extract_archive(
        &archive,
        &out,
        &only_readme(OverwritePolicy::Replace),
        &NoProgress,
    )
    .unwrap();
    fs::write(out.join("projekt/readme.txt"), "geändert").unwrap();

    let skip = extract_archive(&archive, &out, &only_readme(OverwritePolicy::Skip), &NoProgress).unwrap();
    assert_eq!(skip.skipped_existing, 1);
    assert_eq!(
        fs::read_to_string(out.join("projekt/readme.txt")).unwrap(),
        "geändert"
    );

    let both = extract_archive(
        &archive,
        &out,
        &only_readme(OverwritePolicy::KeepBoth),
        &NoProgress,
    )
    .unwrap();
    assert_eq!(both.renamed, 1);
    assert!(out.join("projekt/readme 2.txt").exists());

    extract_archive(
        &archive,
        &out,
        &only_readme(OverwritePolicy::Replace),
        &NoProgress,
    )
    .unwrap();
    assert_ne!(
        fs::read_to_string(out.join("projekt/readme.txt")).unwrap(),
        "geändert"
    );
}

/// Baut ein bösartiges ZIP von Hand.
fn evil_zip(path: &Path, build: impl FnOnce(&mut zip::ZipWriter<fs::File>)) {
    let mut w = zip::ZipWriter::new(fs::File::create(path).unwrap());
    build(&mut w);
    w.finish().unwrap();
}

#[test]
fn blocks_zip_slip() {
    let dir = tempfile::tempdir().unwrap();
    let archive = dir.path().join("evil.zip");
    evil_zip(&archive, |w| {
        let o = zip::write::SimpleFileOptions::default();
        w.start_file("../ausbruch.txt", o).unwrap();
        w.write_all(b"boese").unwrap();
        w.start_file("ok.txt", o).unwrap();
        w.write_all(b"gut").unwrap();
    });
    let out = dir.path().join("out");
    let res = extract_archive(&archive, &out, &ExtractOptions::default(), &NoProgress).unwrap();
    assert_eq!(res.skipped_unsafe, vec!["../ausbruch.txt".to_string()]);
    assert!(!dir.path().join("ausbruch.txt").exists());
    assert_eq!(fs::read_to_string(out.join("ok.txt")).unwrap(), "gut");
}

#[test]
fn blocks_symlink_escape() {
    let dir = tempfile::tempdir().unwrap();
    let archive = dir.path().join("evil.zip");
    evil_zip(&archive, |w| {
        let o = zip::write::SimpleFileOptions::default();
        // Link zeigt nach außen und wird übersprungen …
        w.add_symlink("raus", "../../", o).unwrap();
        // … deshalb landet diese Datei harmlos in einem echten Ordner „raus“
        w.start_file("raus/datei.txt", o).unwrap();
        w.write_all(b"x").unwrap();
    });
    let out = dir.path().join("out");
    let res = extract_archive(&archive, &out, &ExtractOptions::default(), &NoProgress).unwrap();
    assert_eq!(res.skipped_unsafe, vec!["raus".to_string()]);
    assert!(out.join("raus").is_dir());
    assert!(
        !fs::symlink_metadata(out.join("raus"))
            .unwrap()
            .file_type()
            .is_symlink()
    );

    // Vorhandener Symlink im Ziel darf nicht durchschrieben werden
    let out2 = dir.path().join("out2");
    let outside = dir.path().join("aussen");
    fs::create_dir_all(&out2).unwrap();
    fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, out2.join("raus")).unwrap();
    let err = extract_archive(&archive, &out2, &ExtractOptions::default(), &NoProgress);
    assert!(matches!(err, Err(ZippError::Io(_))), "{err:?}");
    assert!(!outside.join("datei.txt").exists());
}

struct CancelAfter {
    calls: AtomicU64,
    after: u64,
    cancelled: AtomicBool,
}

impl Progress for CancelAfter {
    fn update(&self, _: u64, _: u64, _: &str) {
        if self.calls.fetch_add(1, Ordering::SeqCst) + 1 >= self.after {
            self.cancelled.store(true, Ordering::SeqCst);
        }
    }
    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

#[test]
fn cancel_leaves_no_temp_file() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("abbruch.zip");
    let progress = CancelAfter {
        calls: AtomicU64::new(0),
        after: 2,
        cancelled: AtomicBool::new(false),
    };
    let res = create_archive(&[src], &archive, &CreateOptions::default(), &progress);
    assert_eq!(res.err(), Some(ZippError::Cancelled));
    assert!(!archive.exists());
    let leftovers: Vec<_> = fs::read_dir(dir.path())
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().contains("zipp-"))
        .collect();
    assert!(leftovers.is_empty(), "temporäre Datei übrig: {leftovers:?}");
}

#[test]
fn quarantine_is_propagated() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("q.zip");
    create(&src, &archive, CreateFormat::Zip, None);
    let value = b"0081;672e0000;Safari;";
    if xattr::set(&archive, "com.apple.quarantine", value).is_err() {
        eprintln!("Dateisystem ohne xattr – Test übersprungen");
        return;
    }
    let out = dir.path().join("out");
    let opts = ExtractOptions {
        apply_quarantine: true,
        ..Default::default()
    };
    extract_archive(&archive, &out, &opts, &NoProgress).unwrap();
    for p in ["projekt/readme.txt", "projekt/sub/tief/code.rs", "projekt/sub"] {
        assert_eq!(
            xattr::get(out.join(p), "com.apple.quarantine")
                .unwrap()
                .as_deref(),
            Some(&value[..]),
            "{p}"
        );
    }
}

#[test]
fn zip_add_and_delete() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("edit.zip");
    create(&src, &archive, CreateFormat::Zip, Some("pw"));

    let extra = dir.path().join("neu.txt");
    fs::write(&extra, "neu").unwrap();
    add_to_archive(
        &archive,
        std::slice::from_ref(&extra),
        "projekt/sub",
        &AddOptions::default(),
        &NoProgress,
    )
    .unwrap();
    let names: Vec<String> = list_archive(&archive, None)
        .unwrap()
        .entries
        .into_iter()
        .map(|e| e.path)
        .collect();
    assert!(names.contains(&"projekt/sub/neu.txt".to_string()), "{names:?}");
    assert!(names.contains(&"projekt/readme.txt".to_string()));

    // Ersetzen: gleicher Name wird nicht doppelt angelegt
    fs::write(&extra, "neuer").unwrap();
    add_to_archive(
        &archive,
        &[extra],
        "projekt/sub",
        &AddOptions::default(),
        &NoProgress,
    )
    .unwrap();
    let count = list_archive(&archive, None)
        .unwrap()
        .entries
        .iter()
        .filter(|e| e.path == "projekt/sub/neu.txt")
        .count();
    assert_eq!(count, 1);

    let removed = delete_from_archive(&archive, &["projekt/sub".into()], None, &NoProgress).unwrap();
    assert!(removed >= 3, "entfernt: {removed}");
    let listing = list_archive(&archive, None).unwrap();
    assert!(listing.entries.iter().all(|e| !e.path.starts_with("projekt/sub")));

    // Verschlüsselte Altdaten sind nach dem Kopieren weiter lesbar
    let out = dir.path().join("out");
    let opts = ExtractOptions {
        password: Some("pw".into()),
        ..Default::default()
    };
    extract_archive(&archive, &out, &opts, &NoProgress).unwrap();
    assert_eq!(
        fs::read(out.join("projekt/bild.png")).unwrap(),
        fs::read(src.join("bild.png")).unwrap()
    );

    // RAR: klare Fehlermeldung statt kaputtem Archiv
    let rar = dir.path().join("x.rar");
    fs::copy(fixture("version.rar"), &rar).unwrap();
    assert!(matches!(
        delete_from_archive(&rar, &["VERSION".into()], None, &NoProgress),
        Err(ZippError::Unsupported(_))
    ));
}

#[test]
fn detects_corruption() {
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("kaputt.zip");
    // Nur speichern, damit die Bytes 1:1 im Archiv stehen
    let opts = CreateOptions {
        level: 0,
        ..Default::default()
    };
    create_archive(&[src], &archive, &opts, &NoProgress).unwrap();
    let mut bytes = fs::read(&archive).unwrap();
    let needle = b"Hallo ZIPP";
    let pos = bytes.windows(needle.len()).position(|w| w == needle).unwrap();
    bytes[pos] ^= 0xFF;
    fs::write(&archive, bytes).unwrap();
    let err = test_archive(&archive, None, &NoProgress).unwrap_err();
    assert!(matches!(err, ZippError::ChecksumMismatch(_)), "{err:?}");
}

#[test]
fn progress_reaches_total() {
    struct Last(AtomicU64, AtomicU64);
    impl Progress for Last {
        fn update(&self, done: u64, total: u64, _: &str) {
            self.0.store(done, Ordering::SeqCst);
            self.1.store(total, Ordering::SeqCst);
        }
        fn is_cancelled(&self) -> bool {
            false
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let src = sample_tree(dir.path());
    let archive = dir.path().join("p.7z");
    create(&src, &archive, CreateFormat::SevenZip, None);
    let p = Last(AtomicU64::new(0), AtomicU64::new(0));
    extract_archive(&archive, &dir.path().join("o"), &ExtractOptions::default(), &p).unwrap();
    assert!(p.1.load(Ordering::SeqCst) > 0);
    assert_eq!(p.0.load(Ordering::SeqCst), p.1.load(Ordering::SeqCst));
}
