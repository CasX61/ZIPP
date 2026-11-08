//! Beliebige Bytes als Archiv: erkennen, auflisten, testen, entpacken.
//!
//! Neben Abstürzen prüft das Ziel die wichtigste Sicherheitsregel: Beim
//! Entpacken darf nichts außerhalb des Zielordners entstehen.
#![no_main]

use libfuzzer_sys::fuzz_target;
use zipp_core::{ExtractOptions, NoProgress, extract_archive, list_archive, test_archive};

fuzz_target!(|data: &[u8]| {
    let dir = tempfile::tempdir().expect("Temp-Ordner");
    let probe = dir.path().join("probe");
    std::fs::write(&probe, data).expect("schreiben");

    if list_archive(&probe, None).is_err() {
        return;
    }
    let _ = test_archive(&probe, Some("passwort"), &NoProgress);
    let out = dir.path().join("out");
    let _ = extract_archive(&probe, &out, &ExtractOptions::default(), &NoProgress);

    // Außer der Eingabe und dem Zielordner darf nichts im Temp-Ordner liegen.
    for entry in std::fs::read_dir(dir.path()).expect("lesen") {
        let name = entry.expect("Eintrag").file_name();
        assert!(
            name == "probe" || name == "out",
            "Datei außerhalb des Ziels angelegt: {name:?}"
        );
    }
});
