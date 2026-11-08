import AppKit
import ZippCore

/// Finder-Kontextmenü über macOS-Dienste (Rechtsklick → „Dienste“ bzw. „Schnellaktionen“).
///
/// Die Einträge stehen in der Info.plist (`NSServices`, siehe `project.yml`).
/// macOS ruft die Methoden über die Selektoren `name:userData:error:` auf.
@MainActor
final class ServiceProvider: NSObject {
    private var jobs: [ServiceJobController] = []

    /// Läuft gerade ein Auftrag? (Dann kein Willkommen-Fenster beim Start.)
    var isBusy: Bool { !jobs.isEmpty }

    // MARK: - Einstiegspunkte

    @objc(extractHere:userData:error:)
    func extractHere(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        extract(files(from: pboard), mode: Preferences.folderMode)
    }

    @objc(extractToFolder:userData:error:)
    func extractToFolder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        extract(files(from: pboard), mode: .always)
    }

    @objc(compressZip:userData:error:)
    func compressZip(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        compress(files(from: pboard), format: .zip)
    }

    @objc(compress7z:userData:error:)
    func compress7z(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        compress(files(from: pboard), format: .sevenZip)
    }

    @objc(compressDialog:userData:error:)
    func compressDialog(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = files(from: pboard)
        guard !urls.isEmpty else { return }
        NSApp.activate()
        AppDelegate.shared?.presentCompress(for: urls)
    }

    private func files(from pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: - Entpacken

    /// Entpackt jedes Archiv neben sich selbst (mehrteilige Archive nur einmal).
    func extract(_ urls: [URL], mode: FolderMode) {
        var archives: [URL] = []
        for url in urls where ArchiveTypes.isLikelyArchive(url) && !url.hasDirectoryPath {
            let first = ArchiveTypes.firstVolume(of: url)
            if !archives.contains(first) { archives.append(first) }
        }
        guard !archives.isEmpty else {
            NSSound.beep()
            return
        }
        let title = archives.count == 1 ? "„\(ArchiveTypes.logicalName(of: archives[0]))“ entpacken" : "\(archives.count) Archive entpacken"
        let controller = start(title: title)
        Task {
            for url in archives {
                guard !controller.ui.isCancelledByUser else { break }
                let session = ArchiveSession(url: url, ui: controller.ui)
                await session.load()
                switch session.phase {
                case .ready:
                    let request = ExtractRequest(
                        nodes: [],
                        baseFolder: url.deletingLastPathComponent(),
                        folderMode: mode,
                        overwrite: Preferences.overwrite,
                        revealAfter: false,
                        trashArchiveAfter: Preferences.trashAfterExtract
                    )
                    await session.extract(request)
                case .failed(let message):
                    controller.ui.presentMessage("„\(session.displayName)“ kann nicht geöffnet werden", message)
                case .loading, .locked:
                    break // Passwortabfrage abgebrochen
                }
                session.cleanup()
            }
            finish(controller)
        }
    }

    // MARK: - Komprimieren

    /// Erstellt ein Archiv neben den Dateien, mit den Standardeinstellungen.
    func compress(_ urls: [URL], format: CreateFormat) {
        guard let first = urls.first else { return }
        let name = CompressSheet.defaultName(for: urls, convertFrom: nil)
        let dest = FileNaming.uniqueArchiveURL(
            folder: first.deletingLastPathComponent(), name: name,
            ext: createFormatExtension(format: format), split: false
        )
        let controller = start(title: "„\(dest.lastPathComponent)“ erstellen")
        let sources = urls.map(\.path)
        let destPath = dest.path
        let options = CreateOptions(
            format: format,
            level: CompressionLevel.value(forIndex: Preferences.compressionLevelIndex),
            password: nil,
            encryptFileNames: false,
            excludeMacMetadata: Preferences.excludeMacFiles,
            volumeSize: nil
        )
        Task {
            do {
                _ = try await controller.ui.runJob(title: "Erstelle „\(dest.lastPathComponent)“ …", symbol: "archivebox") { relay in
                    try createArchive(sources: sources, destination: destPath, options: options, progress: relay)
                }
            } catch {
                controller.ui.presentError(error, title: "Erstellen fehlgeschlagen")
            }
            finish(controller)
        }
    }

    // MARK: - Fenster

    /// Beim Beenden: offene Dialoge schließen, laufende Aufträge abbrechen.
    func cancelAll() {
        for job in jobs {
            if let window = job.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            job.close()
        }
    }

    private func start(title: String) -> ServiceJobController {
        let controller = ServiceJobController(title: title)
        controller.onClose = { [weak self, weak controller] in
            self?.jobs.removeAll { $0 === controller }
        }
        jobs.append(controller)
        controller.present()
        return controller
    }

    private func finish(_ controller: ServiceJobController) {
        // Fehlermeldungen hängen als Sheet am Fenster: erst schließen, wenn sie weg sind.
        if let window = controller.window, window.attachedSheet != nil {
            Task {
                while window.attachedSheet != nil, window.isVisible {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                controller.finish()
            }
        } else {
            controller.finish()
        }
    }
}
