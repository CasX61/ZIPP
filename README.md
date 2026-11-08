<p align="center">
  <img src="assets/AppIcon-source.png" width="128" alt="ZIPP-Icon">
</p>

<h1 align="center">ZIPP</h1>

<p align="center">
  <strong>Der Archiv-Manager für macOS – so einfach wie WinRAR, so nativ wie der Finder.</strong><br>
  Kostenlos und Open Source.
</p>

---

ZIPP öffnet Archive wie einen Ordner: durchsuchen, einzelne Dateien in den Finder ziehen,
neue Dateien hineinziehen, fertig. Unter der Oberfläche arbeitet ein Kern in Rust, der
fremde Archive als nicht vertrauenswürdig behandelt.

## Funktionen

- **Archive wie Ordner durchsuchen**: Tabelle mit Größe, gepackter Größe, Ersparnis, Datum und Art, sortierbar, mit Pfadleiste, Zurück/Vor und `..`-Zeile
- **Drag & Drop in beide Richtungen**: Dateien in den Finder ziehen entpackt genau diese Dateien, und zwar erst beim Loslassen direkt am Ziel. Dateien ins Fenster ziehen fügt sie hinzu, auch von einem Archivfenster ins andere oder aus Mail.
- **Finder-Kontextmenü**: Rechtsklick → „Mit ZIPP hier entpacken“, „… in eigenen Ordner entpacken“, „… als ZIP / als 7z komprimieren“
- **Intelligentes Entpacken**: Liegt alles in einem Ordner, entsteht kein doppelter Ordner. Lose Dateien bekommen automatisch einen eigenen.
- **Erstellen**: ZIP, 7z, TAR.GZ, TAR.ZST und TAR.XZ, mit Kompressionsstufe und Passwort (AES-256, bei 7z auch für die Dateinamen), auf Wunsch aufgeteilt (100 MB, 700 MB, 4 GB für FAT32 oder eigene Größe)
- **Bearbeiten**: Dateien hinzufügen, löschen, umbenennen (F2) und neue Ordner anlegen, in ZIP, 7z und TAR.*
- **Konvertieren**: z. B. RAR → ZIP oder ZIP → 7z, in einem Schritt
- **Mehrteilige Archive**: `.part1.rar`, `.r00`, `.7z.001`, `.zip.001`. Es reicht, irgendeinen Teil zu öffnen.
- **Windows-Dateinamen**: Umlaute und japanische, chinesische oder kyrillische Namen aus älteren Windows-ZIPs werden richtig erkannt (CP437/850/866, Shift-JIS, GBK, Big5 …)
- **Passwörter**: Abfrage bei Bedarf, optional im macOS-Schlüsselbund, dazu eine Passwort-Liste, die automatisch durchprobiert wird
- **Testen**: Prüft alle Prüfsummen, ohne zu entpacken
- **Quick Look** (Leertaste) und Öffnen per Doppelklick, direkt aus dem Archiv
- **Sicher**: Schutz vor Zip-Slip und Symlink-Tricks, Warnung bei Zip-Bomben, Quarantäne-Markierung wird übernommen
- **Erscheinungsbild**: Automatisch (wie macOS), Hell oder Dunkel, in den Einstellungen oder unter *Darstellung → Erscheinungsbild*
- Seitenleiste, Inspektor, Suche im ganzen Archiv, Tabs, Tastaturbedienung, Update-Hinweis
- **Kommandozeile**: `zipp x archiv.rar`, `zipp a backup.7z Ordner -v 4g` (gleicher Kern)

| Format | Lesen | Erstellen | Bearbeiten |
|---|:-:|:-:|:-:|
| ZIP (inkl. AES, ZIP64) | ✅ | ✅ | ✅ |
| 7z (inkl. AES, verschlüsselte Namen) | ✅ | ✅ | ✅ ² |
| RAR 4/5, auch mehrteilig | ✅ | – ¹ | – ¹ |
| TAR, TAR.GZ/BZ2/XZ/ZST | ✅ | ✅ | ✅ ² |
| GZ, BZ2, XZ, ZST (einzelne Datei) | ✅ | – | – |
| Aufgeteilt (`.001`, `.002` …) | ✅ | ✅ | – |

¹ Die UnRAR-Lizenz erlaubt nur das Entpacken. Mit „Konvertieren“ wird daraus ein ZIP oder 7z.
² Das Archiv wird dafür neu geschrieben (ZIP wird direkt geändert, ohne neu zu komprimieren).

### Tastenkürzel

| Kürzel | Aktion |
|---|---|
| ⌘O / ⌘N | Archiv öffnen / Neues Archiv |
| ⌘E / ⌥⌘E | Entpacken (Standardziel) / Entpacken nach … |
| ⇧⌘A / ⇧⌘N | Dateien hinzufügen / Neuer Ordner |
| F2 | Umbenennen |
| Leertaste | Quick Look |
| ↩ oder ⌘↓ / ⌫ oder ⌘↑ | Öffnen / Übergeordneter Ordner |
| ⌘⌫ | Aus Archiv löschen |
| ⌘T | Archiv testen |
| ⌘F | Im Archiv suchen |
| ⌘I | Inspektor ein/aus |

## Installation

1. Das neueste DMG unter [Releases](../../releases) laden (`ZIPP-x.y.z.dmg`; jeder Commit erzeugt außerdem ein `nightly`-Build).
2. ZIPP in den Ordner „Programme“ ziehen.
3. Solange die Builds noch nicht notarisiert sind, beim ersten Start: Rechtsklick auf ZIPP → **Öffnen**, oder *Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen*.

Voraussetzung: macOS 14 Sonoma oder neuer, Apple Silicon oder Intel.

### Finder-Kontextmenü

Nach dem ersten Start stehen die ZIPP-Einträge im Rechtsklick-Menü des Finders unter **Dienste**
(bzw. „Schnellaktionen“). Fehlen sie: *Systemeinstellungen → Tastatur → Tastaturkurzbefehle → Dienste →
Dateien und Ordner* und die ZIPP-Einträge einschalten.

### Kommandozeile

Unter Releases liegt zusätzlich `zipp-cli-x.y.z-macos.tar.gz`:

```sh
tar -xzf zipp-cli-*-macos.tar.gz && sudo mv zipp /usr/local/bin/
zipp l archiv.7z                   # auflisten
zipp x film.part1.rar              # entpacken (intelligenter Ordner)
zipp a backup.7z Fotos -p geheim   # erstellen, mit Passwort
zipp a gross.zip Ordner -v 4g      # in 4-GB-Teile aufteilen
zipp c alt.rar neu.zip             # konvertieren
```

## Selbst bauen

Voraussetzungen: Xcode 26 oder neuer, [Rust](https://rustup.rs), [Homebrew](https://brew.sh).

```sh
make bootstrap   # Rust-Targets + XcodeGen installieren, Kern bauen, Xcode-Projekt erzeugen
make run         # Debug-Build bauen und starten
make test        # alle Tests (Rust + Swift)
make dmg         # Release-Build (universal) als build/ZIPP.dmg
make cli         # Kommandozeilen-Tool als build/zipp-cli-macos.tar.gz
make fuzz        # Format-Parser fuzzen (Rust nightly + cargo-fuzz)
```

Danach lässt sich `app/Zipp.xcodeproj` auch ganz normal in Xcode öffnen (`make open`). Das Projekt wird
aus `app/project.yml` erzeugt. Bitte dort ändern, nicht im `.xcodeproj`.

## Aufbau

```
core/                 Rust-Workspace
  zipp-core/          Archiv-Engine: Formate, Entpacken, Erstellen, Sicherheit (+ Tests)
  zipp-ffi/           Swift-Schnittstelle (UniFFI)
  zipp-cli/           Kommandozeilen-Tool `zipp`
  uniffi-bindgen/     Generator für die Swift-Bindings
  fuzz/               Fuzzing der Format-Parser (cargo-fuzz)
app/
  project.yml         Xcode-Projekt (XcodeGen)
  Zipp/               macOS-App: AppKit + SwiftUI
  ZippTests/          Swift-Tests
scripts/              build-core.sh, build-app.sh, build-cli.sh, make-dmg.sh, make-icon.swift
packaging/homebrew/   Homebrew-Cask
.github/workflows/    CI, Nightly-DMG, Releases, wöchentliches Fuzzing
```

Die Oberfläche ist bewusst nativ (AppKit-Tabelle, File Promises für Drag & Drop, Quick Look).
Der Rust-Kern ist speichersicher und unabhängig testbar. Mehr dazu und die Roadmap stehen in [PLAN.md](PLAN.md).

## Mitmachen

Beiträge sind willkommen! Siehe [CONTRIBUTING.md](CONTRIBUTING.md). Sicherheitslücken bitte nicht öffentlich
melden, sondern wie in [SECURITY.md](SECURITY.md) beschrieben.

## Lizenz

ZIPP steht wahlweise unter der [MIT-Lizenz](LICENSE-MIT) oder der [Apache-Lizenz 2.0](LICENSE-APACHE).

RAR-Unterstützung: UnRAR © Alexander Roshal, unter der [UnRAR-Lizenz](third_party/unrar/license.txt).
Dieser Code darf nicht verwendet werden, um den RAR-Kompressor nachzubauen.
