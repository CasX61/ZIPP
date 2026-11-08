# Changelog

Alle wichtigen Änderungen an ZIPP. Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## [Unveröffentlicht]

### Neu
- Rust-Kern `zipp-core`: ZIP, 7z, RAR, TAR (+ gz/bz2/xz/zst) und einzeln komprimierte Dateien lesen;
  ZIP, 7z und TAR.* erstellen; ZIP bearbeiten (hinzufügen/löschen ohne Neukomprimieren)
- Schutz vor Zip-Slip und Symlink-Angriffen, Übernahme der Quarantäne-Markierung
- macOS-App: Archiv-Browser, Seitenleiste, Inspektor, Suche, Quick Look
- Drag & Drop: Dateien direkt in den Finder entpacken (File Promises), Dateien ins Archiv ziehen
- Dialoge für Entpacken (intelligenter Ordner), Komprimieren (AES-256) und Passwort (Schlüsselbund)
- CI, Nightly-DMG bei jedem Commit auf `main`, Releases per Git-Tag
- Finder-Kontextmenü (macOS-Dienste): hier entpacken, in eigenen Ordner entpacken, als ZIP/7z komprimieren
- Bearbeiten auch bei 7z und TAR.*; Umbenennen (F2) und neue Ordner in allen bearbeitbaren Formaten
- Archive konvertieren (z. B. RAR → ZIP, ZIP → 7z), Quarantäne-Markierung bleibt erhalten
- Mehrteilige Archive lesen (`.part1.rar`, `.r00`, `.7z.001`, `.zip.001`) und Archive aufgeteilt erstellen
- Zeichensatz-Erkennung für ZIP-Dateinamen aus Windows (CP437/850/866, Shift-JIS, GBK, Big5, EUC-KR …)
- Passwort-Liste im Schlüsselbund, die bei verschlüsselten Archiven automatisch ausprobiert wird
- Dateien zwischen zwei Archivfenstern (und aus Mail, Fotos …) ziehen
- Update-Hinweis über GitHub Releases (abschaltbar)
- Erscheinungsbild wählbar (Automatisch, Hell, Dunkel) im neuen Einstellungs-Tab „Allgemein“ und im Menü „Darstellung“
- Willkommen-Fenster ohne ausgegraute Archiv-Knöpfe (ab macOS 15)
- Kommandozeilen-Tool `zipp` (auch als Release-Download), Homebrew-Cask-Vorlage, wöchentliches Fuzzing
