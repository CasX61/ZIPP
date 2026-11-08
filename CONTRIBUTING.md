# Mitmachen bei ZIPP

Danke, dass du helfen willst!

## Einrichten

```sh
make bootstrap
make run
```

## Bevor du einen Pull Request öffnest

```sh
make lint   # rustfmt + clippy (ohne Warnungen)
make test   # Rust- und Swift-Tests
```

Die CI führt genau das aus. Pull Requests aus Forks bekommen keinen Zugriff auf Signatur-Secrets.

## Commit-Nachrichten

Bitte [Conventional Commits](https://www.conventionalcommits.org/de/) verwenden, daraus entstehen die Release Notes:

```
feat: 7z-Archive aufteilen
fix: Umlaute in Windows-ZIPs korrekt anzeigen
docs: README ergänzt
```

## Wo was hingehört

- **Archiv-Logik** (Formate, Sicherheit, Entpacken/Erstellen) gehört nach `core/zipp-core` und braucht einen Test in `core/zipp-core/tests/`.
- **Kommandozeile** liegt in `core/zipp-cli` und nutzt nur die öffentliche API von `zipp-core`.
- **Parser-Änderungen** bitte zusätzlich mit `make fuzz` prüfen (Rust nightly + `cargo install cargo-fuzz`).
- **Neue Funktionen für die App** werden in `core/zipp-ffi/src/lib.rs` exportiert. Die Swift-Bindings erzeugt `scripts/build-core.sh` automatisch.
- **Oberfläche** liegt in `app/Zipp`: AppKit für Fenster, Tabelle und Drag & Drop, SwiftUI für Seitenleiste, Inspektor und Dialoge.
- **Xcode-Projekt**: Änderungen nur in `app/project.yml` (danach `make project`).

## Sicherheit

Archive aus dem Internet sind nicht vertrauenswürdig. Jeder Pfad aus einem Archiv muss durch
`safety::sanitize`, nie direkt auf die Platte. Lücken bitte gemäß [SECURITY.md](SECURITY.md) melden.
