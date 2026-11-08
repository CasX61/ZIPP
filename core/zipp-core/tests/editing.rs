//! Tests für Bearbeiten (alle Formate), Aufteilen, Konvertieren,
//! Passwortprüfung und Zeichensatz-Erkennung.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use zipp_core::*;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// projekt/{a.txt, b.txt, ordner/c.txt, ordner/tief/d.bin}
fn tree(root: &Path) -> PathBuf {
    let p = root.join("projekt");
    fs::create_dir_all(p.join("ordner/tief")).unwrap();
    fs::write(p.join("a.txt"), "A".repeat(1000)).unwrap();
    fs::write(p.join("b.txt"), "B").unwrap();
    fs::write(p.join("ordner/c.txt"), "C").unwrap();
    let noise: Vec<u8> = (0..40_000u32)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 11) as u8)
        .collect();
    fs::write(p.join("ordner/tief/d.bin"), noise).unwrap();
    p
}

/// Nicht komprimierbare Pseudozufallsdaten (xorshift).
fn random_bytes(len: usize) -> Vec<u8> {
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 32) as u8
        })
        .collect()
}

fn options(format: CreateFormat, password: Option<&str>) -> CreateOptions {
    CreateOptions {
        format,
        level: 6,
        password: password.map(String::from),
        encrypt_file_names: password.is_some() && format == CreateFormat::SevenZip,
        exclude_mac_metadata: true,
        volume_size: None,
    }
}

fn make(src: &Path, dest: &Path, format: CreateFormat, password: Option<&str>) {
    create_archive(
        &[src.to_path_buf()],
        dest,
        &options(format, password),
        &NoProgress,
    )
    .unwrap();
}

/// Dateien (ohne Ordner) mit Inhalt, nach Pfad sortiert.
fn contents(archive: &Path, password: Option<&str>) -> BTreeMap<String, Vec<u8>> {
    let out = tempfile::tempdir().unwrap();
    let opts = ExtractOptions {
        password: password.map(String::from),
        ..Default::default()
    };
    extract_archive(archive, out.path(), &opts, &NoProgress).unwrap();
    let mut map = BTreeMap::new();
    for e in walkdir(out.path()) {
        let rel = e.strip_prefix(out.path()).unwrap().to_string_lossy().into_owned();
        map.insert(rel, fs::read(&e).unwrap());
    }
    map
}

fn walkdir(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                files.push(p);
            }
        }
    }
    files
}

fn names(archive: &Path, password: Option<&str>) -> Vec<String> {
    list_archive(archive, password)
        .unwrap()
        .entries
        .into_iter()
        .map(|e| e.path)
        .collect()
}

#[test]
fn edit_every_writable_format() {
    let cases = [
        (CreateFormat::Zip, "x.zip", None),
        (CreateFormat::Zip, "y.zip", Some("geheim")),
        (CreateFormat::SevenZip, "x.7z", None),
        (CreateFormat::SevenZip, "y.7z", Some("geheim")),
        (CreateFormat::Tar, "x.tar", None),
        (CreateFormat::TarGz, "x.tar.gz", None),
        (CreateFormat::TarXz, "x.tar.xz", None),
        (CreateFormat::TarZst, "x.tar.zst", None),
        (CreateFormat::TarBz2, "x.tar.bz2", None),
    ];
    for (format, file, pw) in cases {
        let dir = tempfile::tempdir().unwrap();
        let src = tree(dir.path());
        let archive = dir.path().join(file);
        make(&src, &archive, format, pw);
        let label = format!("{file} {pw:?}");

        // Hinzufügen in einen Unterordner
        let extra = dir.path().join("neu.txt");
        fs::write(&extra, "neu").unwrap();
        let add = AddOptions {
            password: pw.map(String::from),
            ..Default::default()
        };
        add_to_archive(
            &archive,
            std::slice::from_ref(&extra),
            "projekt/ordner",
            &add,
            &NoProgress,
        )
        .unwrap();

        // Umbenennen: Datei und Ordner
        let to = rename_in_archive(&archive, "projekt/a.txt", "alpha.txt", pw, &NoProgress).unwrap();
        assert_eq!(to, "projekt/alpha.txt");
        rename_in_archive(&archive, "projekt/ordner", "Ordner Neu", pw, &NoProgress).unwrap();

        // Konflikt: Ziel gibt es schon
        assert!(
            rename_in_archive(&archive, "projekt/b.txt", "alpha.txt", pw, &NoProgress).is_err(),
            "{label}: Konflikt nicht erkannt"
        );
        // Ungültiger Name
        assert!(rename_in_archive(&archive, "projekt/b.txt", "a/b", pw, &NoProgress).is_err());

        // Neuer leerer Ordner
        let made = create_folder_in_archive(&archive, "projekt", "Leer", pw, &NoProgress).unwrap();
        assert_eq!(made, "projekt/Leer");
        assert!(create_folder_in_archive(&archive, "projekt", "Leer", pw, &NoProgress).is_err());

        // Löschen
        let removed = delete_from_archive(&archive, &["projekt/b.txt".into()], pw, &NoProgress).unwrap();
        assert_eq!(removed, 1, "{label}");

        let listed = names(&archive, pw);
        assert!(
            listed.contains(&"projekt/Leer".to_string()),
            "{label}: {listed:?}"
        );
        // Zeitstempel des neuen Ordners: jetzt (Ortszeit richtig umgerechnet, nicht UTC)
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let leer = list_archive(&archive, pw)
            .unwrap()
            .entries
            .into_iter()
            .find(|e| e.path == "projekt/Leer")
            .unwrap();
        if let Some(t) = leer.modified {
            assert!(
                (now - t).abs() < 120,
                "{label}: Ordnerzeit weicht {} s ab",
                now - t
            );
        }
        let files = contents(&archive, pw);
        let expected: Vec<&str> = vec![
            "projekt/Ordner Neu/c.txt",
            "projekt/Ordner Neu/neu.txt",
            "projekt/Ordner Neu/tief/d.bin",
            "projekt/alpha.txt",
        ];
        assert_eq!(
            files.keys().map(String::as_str).collect::<Vec<_>>(),
            expected,
            "{label}"
        );
        assert_eq!(files["projekt/alpha.txt"], fs::read(src.join("a.txt")).unwrap());
        assert_eq!(
            files["projekt/Ordner Neu/tief/d.bin"],
            fs::read(src.join("ordner/tief/d.bin")).unwrap()
        );
        assert_eq!(files["projekt/Ordner Neu/neu.txt"], b"neu");

        // Verschlüsselung bleibt erhalten
        if let Some(pw) = pw {
            let listing = list_archive(&archive, Some(pw)).unwrap();
            assert!(listing.has_encrypted_entries, "{label}");
            if format == CreateFormat::SevenZip {
                assert!(
                    listing.header_encrypted,
                    "{label}: Namen nicht mehr verschlüsselt"
                );
                assert!(list_archive(&archive, None).is_err());
            }
        }
        // Keine Reste neben dem Archiv
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains(".zipp-"))
            .collect();
        assert!(leftovers.is_empty(), "{label}: {leftovers:?}");
    }
}

#[test]
fn rebuild_needs_password() {
    let dir = tempfile::tempdir().unwrap();
    let src = tree(dir.path());
    let archive = dir.path().join("p.7z");
    make(&src, &archive, CreateFormat::SevenZip, Some("pw"));
    let before = fs::read(&archive).unwrap();
    assert!(delete_from_archive(&archive, &["projekt/b.txt".into()], None, &NoProgress).is_err());
    assert!(delete_from_archive(&archive, &["projekt/b.txt".into()], Some("falsch"), &NoProgress).is_err());
    assert_eq!(
        fs::read(&archive).unwrap(),
        before,
        "Archiv darf nicht verändert sein"
    );
}

#[test]
fn rar_and_split_archives_are_read_only() {
    let dir = tempfile::tempdir().unwrap();
    let rar = dir.path().join("v.rar");
    fs::copy(fixture("version.rar"), &rar).unwrap();
    assert!(matches!(
        rename_in_archive(&rar, "VERSION", "x", None, &NoProgress),
        Err(ZippError::Unsupported(_))
    ));

    let src = tree(dir.path());
    fs::write(src.join("gross.bin"), random_bytes(200_000)).unwrap();
    let dest = dir.path().join("teile.7z");
    let mut opts = options(CreateFormat::SevenZip, None);
    opts.level = 0;
    opts.volume_size = Some(MIN_VOLUME_SIZE);
    let summary = create_archive(&[src], &dest, &opts, &NoProgress).unwrap();
    assert!(summary.outputs.len() > 1);
    assert!(matches!(
        delete_from_archive(&summary.outputs[0], &["projekt/b.txt".into()], None, &NoProgress),
        Err(ZippError::Unsupported(_))
    ));
}

#[test]
fn split_volumes_roundtrip() {
    for (format, file) in [
        (CreateFormat::SevenZip, "teile.7z"),
        (CreateFormat::Zip, "teile.zip"),
        (CreateFormat::TarGz, "teile.tar.gz"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let src = tree(dir.path());
        // Nicht komprimierbare Daten, damit es sicher mehrere Teile werden
        let big = random_bytes(300_000);
        fs::write(src.join("gross.bin"), &big).unwrap();
        let dest = dir.path().join(file);
        let mut opts = options(format, None);
        opts.volume_size = Some(MIN_VOLUME_SIZE);
        let summary = create_archive(std::slice::from_ref(&src), &dest, &opts, &NoProgress).unwrap();
        assert!(summary.outputs.len() >= 5, "{file}: {:?}", summary.outputs);
        assert_eq!(summary.outputs[0], dir.path().join(format!("{file}.001")));
        for p in &summary.outputs[..summary.outputs.len() - 1] {
            assert_eq!(fs::metadata(p).unwrap().len(), MIN_VOLUME_SIZE, "{}", p.display());
        }

        // Öffnen über einen beliebigen Teil
        let middle = &summary.outputs[2];
        assert_eq!(first_volume(middle), summary.outputs[0]);
        assert_eq!(all_volumes(middle).len(), summary.outputs.len());
        assert_eq!(logical_name(middle), file);
        let listing = list_archive(middle, None).unwrap();
        let total: u64 = summary
            .outputs
            .iter()
            .map(|p| fs::metadata(p).unwrap().len())
            .sum();
        assert_eq!(listing.archive_size, total);
        test_archive(middle, None, &NoProgress).unwrap();
        let files = contents(middle, None);
        assert_eq!(files["projekt/gross.bin"], big, "{file}");
        assert_eq!(files["projekt/ordner/c.txt"], b"C");
    }
}

#[test]
fn convert_between_formats() {
    let dir = tempfile::tempdir().unwrap();
    let src = tree(dir.path());
    let zip = dir.path().join("q.zip");
    make(&src, &zip, CreateFormat::Zip, Some("pw"));
    let original = contents(&zip, Some("pw"));

    let sz = dir.path().join("q.7z");
    let summary = convert_archive(
        &zip,
        Some("pw"),
        &sz,
        &options(CreateFormat::SevenZip, None),
        &NoProgress,
    )
    .unwrap();
    assert_eq!(summary.outputs, vec![sz.clone()]);
    assert_eq!(contents(&sz, None), original);

    let tgz = dir.path().join("q.tar.zst");
    convert_archive(&sz, None, &tgz, &options(CreateFormat::TarZst, None), &NoProgress).unwrap();
    assert_eq!(contents(&tgz, None), original);

    // RAR → ZIP
    let rar_zip = dir.path().join("crypted.zip");
    convert_archive(
        &fixture("crypted.rar"),
        Some("unrar"),
        &rar_zip,
        &options(CreateFormat::Zip, None),
        &NoProgress,
    )
    .unwrap();
    assert_eq!(contents(&rar_zip, None)[".gitignore"], b"target\nCargo.lock\n");

    // Ziel = Quelle wird abgelehnt
    assert!(
        convert_archive(
            &zip,
            Some("pw"),
            &zip,
            &options(CreateFormat::Zip, None),
            &NoProgress
        )
        .is_err()
    );
}

#[test]
fn quarantine_survives_conversion() {
    let dir = tempfile::tempdir().unwrap();
    let src = tree(dir.path());
    let zip = dir.path().join("q.zip");
    make(&src, &zip, CreateFormat::Zip, None);
    let value = b"0081;00000000;Safari;".to_vec();
    if xattr::set(&zip, "com.apple.quarantine", &value).is_err() {
        return; // Dateisystem ohne xattr
    }
    let out = dir.path().join("q.7z");
    convert_archive(
        &zip,
        None,
        &out,
        &options(CreateFormat::SevenZip, None),
        &NoProgress,
    )
    .unwrap();
    assert_eq!(xattr::get(&out, "com.apple.quarantine").unwrap(), Some(value));
}

#[test]
fn password_check() {
    let dir = tempfile::tempdir().unwrap();
    let src = tree(dir.path());
    for (format, file) in [(CreateFormat::Zip, "c.zip"), (CreateFormat::SevenZip, "c.7z")] {
        let archive = dir.path().join(file);
        make(&src, &archive, format, Some("richtig"));
        assert!(check_password(&archive, "richtig").unwrap(), "{file}");
        assert!(!check_password(&archive, "falsch").unwrap(), "{file}");
    }
    // 7z mit verschlüsseltem Inhalt, aber lesbaren Namen
    let archive = dir.path().join("inhalt.7z");
    let mut opts = options(CreateFormat::SevenZip, Some("richtig"));
    opts.encrypt_file_names = false;
    create_archive(std::slice::from_ref(&src), &archive, &opts, &NoProgress).unwrap();
    assert!(check_password(&archive, "richtig").unwrap());
    assert!(!check_password(&archive, "falsch").unwrap());

    assert!(check_password(&fixture("crypted.rar"), "unrar").unwrap());
    assert!(!check_password(&fixture("crypted.rar"), "falsch").unwrap());
    assert!(check_password(&fixture("comment-hpw-password.rar"), "password").unwrap());
    assert!(!check_password(&fixture("comment-hpw-password.rar"), "falsch").unwrap());
    // Unverschlüsselt: jedes Passwort „passt“
    let plain = dir.path().join("plain.zip");
    make(&src, &plain, CreateFormat::Zip, None);
    assert!(check_password(&plain, "egal").unwrap());
}

// MARK: - Zeichensätze

fn crc32(data: &[u8]) -> u32 {
    let mut crc = flate2::Crc::new();
    crc.update(data);
    crc.sum()
}

/// Schreibt ein ZIP mit rohen Namen ohne UTF-8-Flag, wie es ältere
/// Windows-Programme tun.
fn legacy_zip(path: &Path, entries: &[(Vec<u8>, &[u8])]) {
    let mut out = Vec::new();
    let mut central = Vec::new();
    for (name, data) in entries {
        let offset = u32::try_from(out.len()).unwrap();
        let crc = crc32(data);
        let size = u32::try_from(data.len()).unwrap();
        let name_len = u16::try_from(name.len()).unwrap();
        // Lokaler Header
        out.extend(0x0403_4b50u32.to_le_bytes());
        out.extend(20u16.to_le_bytes()); // benötigte Version
        out.extend(0u16.to_le_bytes()); // Flags: kein UTF-8
        out.extend(0u16.to_le_bytes()); // gespeichert
        out.extend(0u16.to_le_bytes()); // Zeit
        out.extend(0x21u16.to_le_bytes()); // Datum 1.1.1980
        out.extend(crc.to_le_bytes());
        out.extend(size.to_le_bytes());
        out.extend(size.to_le_bytes());
        out.extend(name_len.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(name);
        out.extend(*data);
        // Zentralverzeichnis
        central.extend(0x0201_4b50u32.to_le_bytes());
        central.extend(20u16.to_le_bytes()); // erstellt von: MS-DOS
        central.extend(20u16.to_le_bytes());
        central.extend(0u16.to_le_bytes());
        central.extend(0u16.to_le_bytes());
        central.extend(0u16.to_le_bytes());
        central.extend(0x21u16.to_le_bytes());
        central.extend(crc.to_le_bytes());
        central.extend(size.to_le_bytes());
        central.extend(size.to_le_bytes());
        central.extend(name_len.to_le_bytes());
        central.extend(0u16.to_le_bytes()); // Extra
        central.extend(0u16.to_le_bytes()); // Kommentar
        central.extend(0u16.to_le_bytes()); // Disk
        central.extend(0u16.to_le_bytes()); // interne Attribute
        central.extend(0u32.to_le_bytes()); // externe Attribute
        central.extend(offset.to_le_bytes());
        central.extend(name);
    }
    let cd_offset = u32::try_from(out.len()).unwrap();
    let cd_size = u32::try_from(central.len()).unwrap();
    let count = u16::try_from(entries.len()).unwrap();
    out.extend(&central);
    out.extend(0x0605_4b50u32.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    out.extend(count.to_le_bytes());
    out.extend(count.to_le_bytes());
    out.extend(cd_size.to_le_bytes());
    out.extend(cd_offset.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    fs::write(path, out).unwrap();
}

/// CP850-Kodierung für die Zeichen, die im Test vorkommen.
fn cp850(s: &str) -> Vec<u8> {
    s.chars()
        .map(|c| match c {
            'ä' => 0x84,
            'ö' => 0x94,
            'ü' => 0x81,
            'Ä' => 0x8E,
            'Ö' => 0x99,
            'Ü' => 0x9A,
            'ß' => 0xE1,
            c if c.is_ascii() => c as u8,
            c => panic!("nicht im Test vorgesehen: {c}"),
        })
        .collect()
}

#[test]
fn windows_zip_names_are_decoded() {
    let dir = tempfile::tempdir().unwrap();
    let german = dir.path().join("windows.zip");
    legacy_zip(
        &german,
        &[
            (cp850("Bücher/Übersicht.txt"), b"eins"),
            (cp850("Größe ändern.doc"), b"zwei"),
            (cp850("Straße.txt"), b"drei"),
        ],
    );
    let listing = list_archive(&german, None).unwrap();
    let listed: Vec<&str> = listing.entries.iter().map(|e| e.path.as_str()).collect();
    assert_eq!(listed, ["Bücher/Übersicht.txt", "Größe ändern.doc", "Straße.txt"]);
    assert!(
        listing.name_encoding.as_deref().unwrap().contains("850"),
        "{:?}",
        listing.name_encoding
    );
    let files = contents(&german, None);
    assert_eq!(files["Bücher/Übersicht.txt"], b"eins");

    // Bearbeiten behält die Namen (roh kopiert) und erkennt sie danach wieder
    delete_from_archive(&german, &["Straße.txt".into()], None, &NoProgress).unwrap();
    assert_eq!(names(&german, None), ["Bücher/Übersicht.txt", "Größe ändern.doc"]);
    rename_in_archive(&german, "Größe ändern.doc", "Maße.doc", None, &NoProgress).unwrap();
    assert_eq!(names(&german, None), ["Bücher/Übersicht.txt", "Maße.doc"]);

    let japanese = dir.path().join("japan.zip");
    let sjis = |s: &str| encoding_rs::SHIFT_JIS.encode(s).0.into_owned();
    legacy_zip(
        &japanese,
        &[(sjis("写真/夏休み.jpg"), b"x"), (sjis("請求書.pdf"), b"y")],
    );
    let listing = list_archive(&japanese, None).unwrap();
    let listed: Vec<&str> = listing.entries.iter().map(|e| e.path.as_str()).collect();
    assert_eq!(listed, ["写真/夏休み.jpg", "請求書.pdf"]);
    assert_eq!(contents(&japanese, None)["写真/夏休み.jpg"], b"x");

    // Normale UTF-8-ZIPs bleiben unberührt
    let src = tree(dir.path());
    let modern = dir.path().join("modern.zip");
    make(&src, &modern, CreateFormat::Zip, None);
    assert_eq!(list_archive(&modern, None).unwrap().name_encoding, None);
}
