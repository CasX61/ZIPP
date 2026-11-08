import AppKit
import UniformTypeIdentifiers
import ZippCore

/// Drag aus dem Archiv in den Finder: Die Datei wird erst entpackt, wenn sie
/// losgelassen wird, und zwar direkt am Zielort (File Promise).
@MainActor
final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    /// Alles, was zum Entpacken nötig ist (wird an den Hintergrund-Thread übergeben).
    struct Info: Sendable {
        let archivePath: String
        let entryPath: String
        let parentPath: String
        let name: String
        let password: String?
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let session: ArchiveSession
    nonisolated private let ui: WindowState

    init(session: ArchiveSession) {
        self.session = session
        self.ui = session.ui
    }

    func makeProvider(for node: ArchiveNode) -> NSFilePromiseProvider {
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: node.fileExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = Info(
            archivePath: session.url.path,
            entryPath: node.path,
            parentPath: node.parentPath,
            name: node.name,
            password: session.password
        )
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? Info)?.name ?? "Datei"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    /// Läuft auf `queue` (Hintergrund).
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let info = filePromiseProvider.userInfo as? Info else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let fm = FileManager.default
        do {
            // Erst in einen Zwischenordner auf demselben Volume, dann verschieben.
            let staging: URL
            if let replacement = try? fm.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: url.deletingLastPathComponent(), create: true
            ) {
                staging = replacement
            } else {
                staging = try TempStore.makeDirectory()
            }
            defer { try? fm.removeItem(at: staging) }

            _ = try extractArchive(
                path: info.archivePath,
                destination: staging.path,
                options: ExtractOptions(
                    password: info.password,
                    selection: [info.entryPath],
                    stripPrefix: info.parentPath.isEmpty ? nil : info.parentPath,
                    overwrite: .replace,
                    applyQuarantine: true
                ),
                progress: ProgressRelay()
            )
            let produced = staging.appendingPathComponent(info.name)
            let target = FileNaming.uniqueURL(url)
            try fm.moveItem(at: produced, to: target)
            completionHandler(nil)
        } catch {
            let ui = self.ui
            let message = ErrorText.describe(error)
            Task { @MainActor in
                ui.presentMessage("„\(info.name)“ konnte nicht entpackt werden", message)
            }
            completionHandler(error)
        }
    }
}
