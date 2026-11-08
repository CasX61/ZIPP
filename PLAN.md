# ZIPP: Archiv-Manager für macOS

> **Name: ZIPP.** Wer in Spotlight oder im Launchpad „zip“ tippt, findet die App sofort. Bildidee für das Icon: ein Reißverschluss (engl. *zipper*), der auf- und zugeht, so wie Entpacken und Packen.
>
> Ziel: die Bedienung von WinRAR (Archiv öffnen, wie einen Ordner durchsuchen, Dateien rein- und rausziehen), aber als echte, moderne macOS-App.
>
> **Kostenlos und Open Source auf GitHub.** Jeder Commit auf `main` erzeugt automatisch ein DMG, siehe [7. Open Source und CI/CD](#7-open-source-und-cicd).

Design-Mockup: [design.html](design.html) (im Browser öffnen, ist interaktiv)

---

## Stand der Umsetzung (8. November 2026)

**Alle Funktionen für Version 1.0 sind umgesetzt und getestet.** Offen sind nur noch Dinge, die ein
GitHub-Repository bzw. ein Apple-Developer-Konto brauchen (erster CI-Lauf, Notarisierung) und die Punkte unter „Später“.

| Bereich | Stand |
|---|---|
| Rust-Kern `core/zipp-core` | ZIP, 7z, RAR, TAR(.gz/.bz2/.xz/.zst), einzelne .gz/.bz2/.xz/.zst lesen · mehrteilige Archive (`.part1.rar`, `.r00`, `.7z.001`, `.zip.001`) · ZIP, 7z, TAR.* erstellen, auch aufgeteilt · Bearbeiten (hinzufügen, löschen, umbenennen, neuer Ordner) in ZIP, 7z, TAR.* · Konvertieren · Passwortprüfung · Zeichensatz-Erkennung für Windows-ZIPs · Zip-Slip-/Symlink-Schutz · Quarantäne · Abbruch · **43 Tests** |
| Swift-Brücke `core/zipp-ffi` | UniFFI 0.32, Fortschritt als Callback aus Swift, Fehler als Swift-`enum` |
| Kommandozeile `core/zipp-cli` | `zipp l/x/t/a/c` mit Passwort, Teilgröße und Stufe; als Release-Download |
| App `app/Zipp` | AppKit-Fenster + SwiftUI-Bausteine, Toolbar, Seitenleiste, Tabelle, Inspektor, Sheets (Entpacken, Komprimieren/Konvertieren, Umbenennen, neuer Ordner, Passwort), Quick Look, File Promises in beide Richtungen (auch zwischen Archivfenstern), Finder-Dienste, Passwort-Liste, Update-Hinweis · **9 Tests** (inkl. Rust-Brücke) |
| Prüfung | Fremdlesbarkeit mit The Unarchiver (`unar`) und macOS-`tar` geprüft, 5 Minuten Fuzzing ohne Befund, Abläufe in der App über `DebugSnapshots` durchgespielt |
| Build | `make bootstrap / run / test / lint / dmg / cli / fuzz`, Xcode-Projekt aus `app/project.yml` (XcodeGen) |
| CI/CD | `ci.yml`, `nightly.yml`, `release.yml` (gemeinsamer Baustein `build-dmg.yml`, DMG + CLI), `fuzz.yml` (wöchentlich), Dependabot, Homebrew-Cask-Vorlage. **Noch nicht auf GitHub gelaufen.** |
| Icon | `assets/AppIcon-source.png` → `make icon` erzeugt die abgerundete macOS-Form in allen Größen |

**Bewusste Abweichungen vom ursprünglichen Plan:**
- **Kein XPC-Dienst (vorerst).** Der Kern läuft im App-Prozess. Rust ist speichersicher, und Panics werden von UniFFI als Swift-Fehler gemeldet. Das Restrisiko ist der C/C++-Code (UnRAR, zstd, xz), den das wöchentliche Fuzzing mit abdeckt. Der XPC-Dienst steht unter „Später“.
- **Finder-Kontextmenü über macOS-Dienste** statt Finder-Sync-Erweiterung. Eine Finder-Sync-Erweiterung muss in der Sandbox laufen und wirkt nur in überwachten Ordnern; Dienste funktionieren überall, ohne Sandbox und ohne zusätzliches Target.
- **Update-Hinweis statt Sparkle.** ZIPP fragt einmal am Tag die GitHub-API nach dem neuesten Release und verlinkt das DMG. Sparkle bräuchte ein eigenes Schlüsselpaar und ein eingebettetes Framework, das mit Ad-hoc-Signatur an der Library Validation scheitert. Mit Developer-ID-Signatur lässt es sich später nachrüsten.
- **Bearbeiten von 7z/TAR durch Neuschreiben**: entpacken in einen temporären Ordner, ändern, mit gleichen Einstellungen (Passwort, verschlüsselte Namen) neu schreiben. Gehen dabei Einträge verloren (Hardlinks, Geräte, unsichere Pfade), bricht ZIPP ab, ohne etwas zu ändern. ZIP wird weiter direkt geändert (Rohkopie ohne Neukomprimierung).
- **Aufgeteilte ZIPs im WinZip-Format (`.z01`) werden nicht gelesen**, nur byteweise aufgeteilte (`.zip.001`, wie von 7-Zip und ZIPP). Das WinZip-Format braucht Unterstützung für mehrere Datenträger, die die zip-Crate nicht hat.
- **ZippCore wird statisch gelinkt** statt als eingebettetes Framework. Mit Hardened Runtime und Ad-hoc-Signatur würde macOS ein eingebettetes Framework ablehnen (Library Validation). Statisch gibt es dieses Problem nicht, und die App startet schneller.
- **Tabelle in AppKit, Rest in SwiftUI**, App-Lebenszyklus in AppKit (`main.swift`): volle Kontrolle über Fenster, Tabs, Menüs und „Öffnen mit“.
- **Nur ein Build-Baustein für Nightly und Release** (`build-dmg.yml`), damit der DMG-Weg nicht doppelt gepflegt wird.

---

## 1. Was an WinRAR gut ist (und was wir übernehmen)

| WinRAR-Prinzip | Umsetzung in ZIPP |
|---|---|
| Archiv öffnet sich **wie ein Ordner** | Archiv-Browser mit Tabelle, Pfadleiste, Zurück/Vor, Ordner-Doppelklick |
| Dateien **rein-/rausziehen** | Drag in das Fenster = hinzufügen, Drag in den Finder = nur diese Dateien entpacken |
| Große Toolbar mit den Hauptaktionen | Wenige klare Buttons: Hinzufügen, Entpacken, Testen, Löschen, Info |
| Kontextmenü im Explorer | Finder-Kontextmenü: „Hier entpacken“, „Entpacken nach …“, „Als ZIP komprimieren“ |
| Ein Dialog für alle Archiv-Optionen | Ein aufgeräumtes Sheet: Format, Stufe, Passwort, Aufteilen |
| Archiv testen / Info / Kommentar | Testen-Button, Inspektor-Leiste rechts, Kommentar-Feld |

**Was wir weglassen:** SFX-Archive (.exe, unter macOS sinnlos), Nag-Screen, Windows-Optik, die Menge an Optionen, die kaum jemand braucht.

**Was macOS-typisch dazukommt:** Quick Look (Leertaste) für Dateien *im* Archiv, Passwörter im Schlüsselbund, Kurzbefehle/Shortcuts, Dark Mode, Tabs, Spotlight-ähnliche Suche im Archiv.

---

## 2. Stack-Empfehlung

### Kurz: **SwiftUI/AppKit für die Oberfläche + Rust für den Archiv-Kern**

Rust für **alles** würde ich nicht nehmen. Die Rust-GUI-Frameworks (egui, iced, Slint, gpui) zeichnen ihre eigenen Steuerelemente. Das sieht nicht nach macOS aus und fühlt sich auch nicht so an. Tauri ist eine Web-View. Vor allem fehlt bei allen der Zugriff auf genau die Dinge, die eine WinRAR-Alternative ausmachen:

- **Drag aus dem Archiv in den Finder** (`NSFilePromiseProvider`: die Datei wird erst entpackt, wenn der Nutzer sie fallen lässt, und zwar direkt am Zielort)
- **Finder-Erweiterung** (Kontextmenü), **Quick-Look-Erweiterung**, Dateizuordnungen
- Native Tabellen für 100.000+ Einträge, Bedienungshilfen (VoiceOver), Tastatursteuerung, Tabs

Rust ist dagegen ideal für den Teil, der Archive liest und schreibt: schnell, speichersicher (wichtig, weil Archive aus dem Internet *nicht vertrauenswürdige Eingaben* sind), gut testbar und später auch für eine CLI oder eine Windows/Linux-Version nutzbar.

```
┌──────────────────────────────────────────────┐
│  ZIPP.app  (Swift 6, SwiftUI + AppKit)       │
│  Fenster, Tabelle, Drag & Drop, Sheets,      │
│  Einstellungen, Schlüsselbund, Quick Look    │
├──────────────────────────────────────────────┤
│  ZippCore.xcframework  (UniFFI-Bindings)     │
├──────────────────────────────────────────────┤
│  zipp-core  (Rust)                           │
│  Formate, Streaming, Fortschritt, Abbruch,   │
│  Verschlüsselung, Sicherheitsprüfungen       │
└──────────────────────────────────────────────┘
       ▲ läuft in einem XPC-Dienst (siehe 5.)
```

### Details

| Bereich | Wahl | Warum |
|---|---|---|
| UI | **SwiftUI** (Swift 6, `@Observable`) | Modernes macOS-Design (Liquid Glass ab macOS 26) direkt verfügbar |
| Große Listen | **AppKit `NSTableView`/`NSOutlineView`** über `NSViewRepresentable` | SwiftUI `Table` ist bei sehr vielen Zeilen und beim Drag-out-Verhalten noch zu eingeschränkt |
| Drag & Drop | `NSFilePromiseProvider` (raus), `NSDraggingDestination` / `.onDrop` (rein) | Echtes WinRAR-Verhalten |
| Rust ↔ Swift | **UniFFI** (Mozilla), erzeugt Swift-Code + xcframework | Stabil, async-fähig, Callbacks für Fortschritt |
| Build | Xcode-Projekt + Build-Phase, die `cargo build` für `aarch64-apple-darwin` und `x86_64-apple-darwin` ausführt und mit `lipo` zusammenführt | Ein Klick in Xcode baut alles |
| Updates | **Sparkle 2**, Appcast auf GitHub Pages, Downloads aus GitHub Releases | Standard für Apps außerhalb des App Stores, kostet nichts |
| Vertrieb | **GitHub Releases (DMG)**, signiert und notarisiert, später zusätzlich ein Homebrew Cask | Kostenlos und Open Source. Kein App Store, weil die Sandbox mehrteilige Archive und „Hier entpacken“ kompliziert macht (siehe 6.) |
| Mindest-OS | macOS 14 Sonoma (Liquid Glass ab 26 mit Fallback) | Guter Kompromiss zwischen Reichweite und modernen APIs |

### Rust-Crates für die Formate

| Format | Lesen | Schreiben | Crate / Bibliothek |
|---|---|---|---|
| ZIP (inkl. AES-256, ZIP64) | ✅ | ✅ | `zip` |
| 7z (LZMA2, AES-256, Dateinamen verschlüsselt) | ✅ | ✅ | `sevenz-rust2` |
| RAR 4/5 (inkl. verschlüsselt, mehrteilig) | ✅ | ❌ | `unrar` (Bindings an den offiziellen UnRAR-Quellcode) |
| TAR | ✅ | ✅ | `tar` |
| gzip / bzip2 / xz / zstd / lz4 | ✅ | ✅ | `flate2`, `bzip2`, `liblzma`, `zstd`, `lz4_flex` |
| ISO, CAB, LHA, ARJ, DMG (Exoten) | ✅ | ❌ | Fallback über **libarchive** (C, per `bindgen`) |

> ⚠️ **RAR erstellen geht nicht.** Die UnRAR-Lizenz erlaubt nur das Entpacken. Zum Erstellen braucht man eine kommerzielle Lizenz von RARLAB. Das macht auch The Unarchiver, Keka usw. so. Stattdessen bieten wir **7z** (komprimiert ähnlich gut) und **ZIP** (läuft überall) an. Ein Hinweis in der UI erklärt das kurz.

### Alternative, falls Rust zu viel Aufwand ist
Alles in Swift mit libarchive über C-Interop. Damit kommt man schneller zu einem MVP, aber Fehler beim Speicherzugriff auf fremden Archiven sind wahrscheinlicher, und eine Portierung auf andere Systeme wird schwieriger. **Meine Empfehlung bleibt die Kombination mit Rust.** Der Aufwand für die Bindings fällt einmalig an, danach ist der Kern sauber getrennt.

---

## 3. Funktionen

### MVP (Version 0.1): „besser als WinRA“
- [x] Archive öffnen: ZIP, RAR, 7z, TAR(.gz/.bz2/.xz/.zst)
- [x] **Archiv-Browser**: Tabelle (Name, Größe, gepackt, Verhältnis, geändert, Art), sortierbar, Ordnernavigation, Pfadleiste
- [x] **Drag raus**: einzelne Dateien/Ordner in den Finder ziehen = entpacken
- [x] **Drag rein**: Dateien aufs leere Fenster = neues Archiv, aufs offene Archiv = hinzufügen (Hinzufügen nur bei ZIP)
- [x] Alles/Auswahl entpacken, mit Fortschritt, Geschwindigkeit, Restzeit und Abbrechen
- [x] ZIP und 7z erstellen: Kompressionsstufe, Passwort (AES-256), dazu TAR.GZ/ZST/XZ
- [x] Passwort-Abfrage für verschlüsselte Archive
- [x] Archiv testen (CRC-Prüfung)
- [x] Quick Look (Leertaste) für Dateien im Archiv
- [x] Doppelklick auf eine Datei im Archiv öffnet sie mit der Standard-App (entpackt in einen temporären Ordner)
- [x] Dateizuordnung: ZIPP als Standard-App für Archive (in der Info.plist deklariert)

### Version 1.0
- [x] **Finder-Kontextmenü**: „Hier entpacken“, „Entpacken nach ‚Ordnername/‘“, „Als ZIP komprimieren“, „Als 7z komprimieren“ (als macOS-Dienste)
- [x] **Intelligentes Entpacken**: liegt im Archiv genau ein Ordner, wird kein zusätzlicher Ordner angelegt. Liegen viele lose Dateien darin, wird ein Ordner erstellt (das nervt bei WinRAR immer)
- [x] Dateien im Archiv löschen und umbenennen, neue Ordner anlegen (ZIP/7z/TAR, Archiv wird dafür intern neu geschrieben)
- [x] Mehrteilige Archive lesen (`.part1.rar`, `.r00`, `.7z.001`, `.zip.001`; nicht `.z01`) und erstellen (aufteilen in 100 MB, 700 MB, 4 GB/FAT32, eigene Größe)
- [x] **Zeichensatz-Erkennung** für ZIP-Dateinamen aus Windows (CP437, CP850, Shift-JIS, GBK, CP866). Kaputte Umlaute sind ein häufiges Problem
- [x] `.DS_Store`, `__MACOSX`, `._*` beim Komprimieren automatisch ausschließen (abschaltbar)
- [x] Passwörter im Schlüsselbund speichern, „Passwort-Liste“ zum automatischen Ausprobieren
- [x] Archive konvertieren (RAR → 7z/ZIP, ZIP → 7z …)
- [x] Inspektor: Methode, CRC, Verschlüsselung, Solid-Archiv, Kommentar (Kommentar nur lesen)
- [x] Suche/Filter im Archiv (auch rekursiv)
- [x] Tabs und mehrere Fenster, Archive nebeneinander, Dateien zwischen zwei Archiven ziehen
- [x] Einstellungen: Standardformat, Zielordner (gleicher Ordner / fragen / fest), Archiv nach dem Entpacken in den Papierkorb, Zielordner danach öffnen

### Später
- [ ] Quick-Look-Erweiterung: Leertaste auf ein Archiv im Finder zeigt den Inhalt
- [ ] App Intents / Kurzbefehle („Ordner als ZIP komprimieren“)
- [x] CLI `zipp x datei.rar` (nutzt denselben Rust-Kern)
- [ ] XPC-Dienst: Kern in einem eigenen Prozess, damit ein Absturz im C-Code (UnRAR, xz, zstd) die App nicht mitreißt
- [ ] Sparkle-Updates (sobald mit Developer ID signiert wird)
- [ ] Aufgeteilte ZIPs im WinZip-Format (`.z01`, `.z02` …)
- [ ] ZIP-Reparatur (Zentralverzeichnis aus lokalen Headern wiederherstellen)
- [ ] Benchmark, Prüfsummen (SHA-256) für Dateien im Archiv
- [ ] Lokalisierung (DE/EN zuerst)

---

## 4. UX- und Design-Konzept

Siehe [design.html](design.html). Kernpunkte:

1. **Ein Fenster pro Archiv**, wie ein Dokument. Ohne geöffnetes Archiv zeigt das Fenster eine große **Drop-Zone** mit zwei Hälften: links „Archiv öffnen“, rechts „Neues Archiv erstellen“.
2. **Toolbar** (Liquid Glass): Zurück/Vor · Archivname mit Format-Badge und Schloss-Symbol · *Hinzufügen*, **Entpacken** (Hauptaktion, hervorgehoben), *Testen*, *Löschen*, *Info* · Suche.
3. **Seitenleiste**: Ordnerbaum des Archivs, „Zuletzt geöffnet“, Schnellziele (Downloads, Schreibtisch).
4. **Tabelle** in der Mitte mit kleinem Balken für das Kompressionsverhältnis. Das sieht man sofort, ohne Zahlen lesen zu müssen.
5. **Inspektor** rechts (einklappbar): Vorschau, Größe, CRC, Methode, Datum.
6. **Statusleiste**: Auswahl, Größe, Format, Verschlüsselung, Gesamtverhältnis.
7. **Sheets** statt eigener Fenster für Komprimieren, Entpacken und Passwort. Die Standardwerte sind so gesetzt, dass man fast immer nur Enter drücken muss.
8. **Fortschritt** erscheint unten im Fenster, nicht als Modal. Man kann weiter im Archiv navigieren.

### Tastenkürzel
| Kürzel | Aktion |
|---|---|
| ⌘O | Archiv öffnen |
| ⌘N | Neues Archiv |
| ⌘E | Auswahl/alles entpacken (Standardziel) |
| ⌥⌘E | Entpacken nach … |
| ⌘⇧A | Dateien hinzufügen |
| Leertaste | Quick Look |
| ⌘↑ / ⌘↓ | Übergeordneter Ordner / Öffnen |
| ⌘⌫ | Aus Archiv löschen |
| ⌘T | Archiv testen |
| ⌘I | Inspektor ein/aus |
| ⌘F | Im Archiv suchen |

---

## 5. Architektur

```
zipp/
├── core/                        # Rust-Workspace
│   ├── zipp-core/               # Formate, Traits, Sicherheit
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── archive.rs       # trait ArchiveReader / ArchiveWriter
│   │   │   ├── entry.rs         # Entry { path, size, packed, crc, mtime, encrypted, … }
│   │   │   ├── formats/{zip,sevenz,rar,tar,compressed,libarchive}.rs
│   │   │   ├── extract.rs       # Ziel-Logik, Smart-Folder, Konflikte
│   │   │   ├── safety.rs        # Zip-Slip, Symlinks, Bomben-Erkennung
│   │   │   ├── progress.rs      # Callback-Trait + CancellationToken
│   │   │   └── encoding.rs      # Dateinamen-Zeichensatz
│   │   └── tests/fixtures/      # Test-Archive aller Formate
│   ├── zipp-ffi/                # UniFFI-Schnittstelle (dünne Schicht)
│   └── zipp-cli/                # später
├── app/
│   ├── Zipp.xcodeproj
│   ├── Zipp/                    # Haupt-App (SwiftUI)
│   │   ├── App/                 # ZippApp, Fenster, Menüs, Commands
│   │   ├── Browser/             # ArchiveBrowserView, NSTableView-Bridge, PathBar
│   │   ├── Sheets/              # Compress-, Extract-, Password-Sheet
│   │   ├── Inspector/
│   │   ├── DragDrop/            # FilePromiseProvider, DropDelegate
│   │   ├── Model/               # ArchiveDocument (@Observable), Job-Queue
│   │   └── Settings/
│   ├── ZippWorker/              # XPC-Dienst: führt den Rust-Kern aus
│   ├── ZippFinder/              # Finder-Erweiterung (Kontextmenü)
│   └── ZippQuickLook/           # Quick-Look-Erweiterung (später)
└── scripts/build-core.sh        # cargo → lipo → xcframework
```

**Warum ein XPC-Dienst?** Kaputte oder bösartige Archive dürfen die App nicht abstürzen lassen. Der Rust-Kern läuft in einem eigenen Prozess mit eigener Sandbox. Stürzt der ab, zeigt die App eine Fehlermeldung, und das Fenster bleibt offen.

**Datenfluss beim Öffnen:** App → XPC `list(url)` → Rust liest nur das Inhaltsverzeichnis (bei ZIP das Zentralverzeichnis, geht in Millisekunden) → `[Entry]` → in der App wird daraus ein Baum gebaut → Tabelle.

**Datenfluss beim Drag in den Finder:** Nutzer zieht → `NSFilePromiseProvider` → Finder liefert den Zielordner → XPC `extract(entries, to:)` → Fortschritt kommt über einen Callback in die Statusleiste.

---

## 6. Sicherheit und Fallstricke

- **Zip-Slip**: Pfade wie `../../etc/x` oder absolute Pfade ablehnen, Symlinks nicht aus dem Zielordner herauszeigen lassen
- **Zip-Bomben**: warnen, wenn das Verhältnis > 1:1000 ist oder die entpackte Größe über dem freien Speicher liegt
- **Quarantäne-Attribut** (`com.apple.quarantine`) vom Archiv auf entpackte Dateien übertragen, damit Gatekeeper weiter funktioniert. Das wird oft vergessen und ist ein echtes Sicherheitsproblem
- macOS-Metadaten erhalten: Rechte (`chmod +x`), erweiterte Attribute, Symlinks, Datum
- **Sandbox**: Für mehrteilige Archive braucht die App Zugriff auf Nachbardateien (`NSIsRelatedItemType` in der Info.plist). „Hier entpacken“ aus dem Finder schreibt in einen Ordner, für den die App keine Rechte hat. Deshalb starten wir mit Developer-ID-Vertrieb außerhalb des App Stores
- Dateinamen: Unicode-Normalisierung (NFD/NFC) zwischen Windows-ZIPs und APFS
- Fuzzing des Rust-Kerns mit `cargo fuzz`, bevor die App veröffentlicht wird

---

## 7. Open Source und CI/CD

### Lizenz und Repository
- **Lizenz: MIT oder Apache-2.0** (bei Rust-Projekten üblich: beide zur Wahl). Damit kann jeder den Code nutzen, auch in anderen Projekten.
- **UnRAR** ist ein Sonderfall: Der Code darf mitgeliefert werden, steht aber unter der eigenen UnRAR-Lizenz (Entpacken ja, RAR-Kompressor nachbauen nein). Er kommt in einen eigenen Ordner `third_party/unrar/` mit Lizenzdatei, und das README weist darauf hin. **GPL ist deshalb ungeeignet**, weil sich die UnRAR-Lizenz nicht mit der GPL verträgt.
- Dateien im Repository: `LICENSE`, `README.md` (Screenshots, Installation, Hinweis zu Gatekeeper), `CONTRIBUTING.md`, `SECURITY.md` (wie man Sicherheitslücken meldet, wichtig bei einem Archiv-Parser), Vorlagen für Issues und Pull Requests, `CHANGELOG.md`.
- Commit-Nachrichten im Format **Conventional Commits** (`feat:`, `fix:` …). Daraus wird der Changelog automatisch erzeugt.

### Pipelines (GitHub Actions, macOS-Runner)

| Workflow | Auslöser | Was passiert | Ergebnis |
|---|---|---|---|
| `ci.yml` | jeder Push und jeder Pull Request | `cargo fmt --check`, `cargo clippy`, `cargo test`, `xcodebuild test` | Grüner oder roter Haken |
| `nightly.yml` | jeder Commit auf `main` | Komplett bauen, signieren, notarisieren, DMG + CLI erstellen (über `build-dmg.yml`) | **Pre-Release „Nightly“** auf GitHub, wird bei jedem Commit überschrieben |
| `release.yml` | Tag `v*` (z. B. `v1.2.0`) | Wie Nightly, dazu Release Notes aus den Commits und die Werte für den Homebrew-Cask | **Stabiles Release** mit DMG und CLI; die App weist auf neue Versionen hin |
| `fuzz.yml` | wöchentlich | `cargo fuzz` auf allen Format-Parsern | Issue, falls ein Absturz gefunden wird |

Optional lässt sich die Versionierung mit **release-please** automatisieren. Das Tool sammelt die Commits in einem Release-Pull-Request, und sobald man ihn merged, wird der Tag gesetzt und `release.yml` läuft von allein.

### Ablauf des DMG-Builds

```
checkout
 → Rust-Toolchain + Targets aarch64/x86_64-apple-darwin (mit Cache)
 → scripts/build-app.sh        # build-core.sh (cargo ×2 → lipo → xcframework) → xcodebuild, universal
 → scripts/make-dmg.sh         # codesign (Developer ID, Hardened Runtime) → hdiutil → notarytool → stapler
 → scripts/build-cli.sh        # zipp-CLI universal, signiert/notarisiert → .tar.gz
 → gh release create / upload  # DMG + CLI, jeweils mit SHA-256-Prüfsumme
```

### Secrets in GitHub
| Secret | Wofür |
|---|---|
| `DEVELOPER_ID_CERT_P12` (Base64) + `DEVELOPER_ID_CERT_PASSWORD` | Signieren, wird im Runner in einen temporären Schlüsselbund importiert |
| `DEVELOPER_ID_NAME` | Name der Signatur-Identität, z. B. `Developer ID Application: Vorname Nachname (TEAMID)` |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8` | Notarisierung über `notarytool` (App-Store-Connect-API-Key, kein Passwort nötig) |

> ⚠️ **Signieren und Notarisieren kostet Geld:** Dafür braucht man eine Mitgliedschaft im Apple Developer Program (99 $/Jahr). Ohne sie funktioniert die Pipeline trotzdem, das DMG ist dann aber nur ad-hoc signiert. Nutzer müssen die App beim ersten Start über *Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen* freigeben. Viele Open-Source-Apps fangen so an. Der Workflow erkennt fehlende Secrets und überspringt dann die Schritte fürs Signieren und Notarisieren.

### Für Mitwirkende
- `make bootstrap` installiert die Rust-Targets und Tools, danach baut das Projekt mit einem Klick in Xcode
- Pull Requests von Forks laufen nur durch `ci.yml`, nie durch Jobs mit Secrets
- Dependabot oder Renovate halten die Crates, Swift Packages und Actions aktuell

---

## 8. Roadmap

| Phase | Inhalt | Ergebnis | Stand |
|---|---|---|---|
| **0: Setup** | Rust-Workspace, UniFFI, Xcode-Projekt, Build-Skript, GitHub-Repository mit Lizenz, `ci.yml` und `nightly.yml` (DMG bei jedem Commit) | „Hello World“ aus Rust in SwiftUI, erstes Nightly-DMG | ✅ (DMG lokal gebaut; GitHub-Lauf steht aus) |
| **1: Lesen** | ZIP/7z/RAR/TAR auflisten, Archiv-Browser, Navigation, Inspektor | Archive ansehen | ✅ |
| **2: Entpacken** | Alles/Auswahl, Drag in den Finder, Passwort, Fortschritt, Sicherheitsprüfungen, Quarantäne | **Nutzbar für den Alltag** | ✅ |
| **3: Erstellen** | Compress-Sheet, Drag ins Fenster, ZIP/7z, AES, Ausschlüsse | MVP komplett | ✅ |
| **4: Integration** | Finder-Kontextmenü, Dateizuordnung, Quick Look, Einstellungen, Smart-Folder, XPC-Dienst | Version 1.0-Beta | ✅ (XPC bewusst verschoben, siehe oben) |
| **5: Feinschliff** | Bearbeiten im Archiv, mehrteilige Archive, Zeichensätze, Konvertieren, `release.yml` mit Sparkle-Appcast, Homebrew Cask | **1.0 Release** | ✅ (Update-Hinweis statt Sparkle; Cask als Vorlage) |

---

## 9. Nächste Schritte

1. **GitHub-Repository `CasX61/zipp` anlegen** und pushen. Der Name steht in `core/Cargo.toml` und `app/Zipp/Support/Project.swift` (Projektseite und Update-Prüfung). Der erste Push auf `main` testet `ci.yml` und `nightly.yml`. Ob der Runner `macos-26` schon verfügbar ist, zeigt der erste Lauf; sonst in den Workflows auf `macos-15` stellen.
2. **Erstes Release**: `git tag v0.1.0 && git push origin v0.1.0`. Danach `version`/`sha256` in `packaging/homebrew/zipp.rb` eintragen (stehen in der Zusammenfassung des Release-Laufs) und die Datei in einen Tap `CasX61/homebrew-tap` kopieren.
3. **Bundle-ID festlegen** (derzeit `app.zipp.ZIPP` in `app/project.yml`) und optional ein Apple-Developer-Konto für Signatur und Notarisierung (Secrets siehe Abschnitt 7). Ohne Konto bleibt der Gatekeeper-Hinweis beim ersten Start.
4. Von Hand ausprobieren, was sich automatisch nicht testen ließ: Ziehen mit der Maus (in den Finder, zwischen zwei Fenstern, aus Mail), Quick Look, Finder-Kontextmenü, Passwortabfrage, sehr große Archive.
5. Danach die Punkte unter „Später“, zuerst der XPC-Dienst und die Lokalisierung (Englisch).
