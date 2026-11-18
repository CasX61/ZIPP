import AppKit
import UniformTypeIdentifiers
import ZippCore

/// Drag aus dem Archiv in den Finder: Die Datei wird erst entpackt, wenn sie
/// losgelassen wird, und zwar direkt am Zielort (File Promise).
///
/// Alle Einträge eines Drags gehören zu einem `DragBatch`. Dauert das Entpacken
/// länger als einen Augenblick, erscheint ein kleines Fortschrittsfenster mit
/// gemeinsamem Balken für alle gezogenen Einträge und einem Abbrechen-Knopf.
@MainActor
final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    /// Alles, was zum Entpacken nötig ist (wird an den Hintergrund-Thread übergeben).
    struct Info: Sendable {
        let archivePath: String
        let entryPath: String
        let parentPath: String
        let name: String
        let password: String?
        let batch: DragBatch
        let index: Int
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let session: ArchiveSession
    /// Der Drag, zu dem gerade Einträge hinzukommen (bis `sealBatch()`).
    private var openBatch: DragBatch?

    init(session: ArchiveSession) {
        self.session = session
    }

    func makeProvider(for node: ArchiveNode, window: NSWindow?) -> NSFilePromiseProvider {
        // NSTableView fragt alle gezogenen Zeilen direkt hintereinander ab. Ein alter,
        // nie begonnener Drag (z. B. sofort abgebrochen) wird nicht weiterverwendet.
        if openBatch == nil || openBatch!.isStale {
            openBatch = DragBatch(ui: session.ui, window: window)
        }
        let batch = openBatch!
        let index = batch.register(name: node.name, size: node.isDirectory ? node.totalSize : node.size)

        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: node.fileExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = Info(
            archivePath: session.url.path,
            entryPath: node.path,
            parentPath: node.parentPath,
            name: node.name,
            password: session.password,
            batch: batch,
            index: index
        )
        return provider
    }

    /// Der Drag hat begonnen: weitere Einträge gehören zu einem neuen Drag.
    func sealBatch() {
        openBatch = nil
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
        let batch = info.batch
        batch.itemStarted()
        guard !batch.isCancelled else {
            batch.itemFinished(info.index, error: nil)
            completionHandler(CocoaError(.userCancelled))
            return
        }
        let fm = FileManager.default
        do {
            // Erst in einen Zwischenordner auf demselben Volume, dann verschieben.
            // So liegt am Ziel nie eine halb entpackte Datei.
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
                progress: DragItemProgress(batch: batch, index: info.index)
            )
            let produced = staging.appendingPathComponent(info.name)
            let target = FileNaming.uniqueURL(url)
            try fm.moveItem(at: produced, to: target)
            batch.itemFinished(info.index, error: nil)
            completionHandler(nil)
        } catch {
            if ErrorText.isCancellation(error) {
                batch.itemFinished(info.index, error: nil)
                completionHandler(CocoaError(.userCancelled))
            } else {
                batch.itemFinished(info.index, error: (info.name, ErrorText.describe(error)))
                completionHandler(error)
            }
        }
    }
}

// MARK: - Ein Drag (ein oder mehrere Einträge)

/// Fasst den Fortschritt aller Einträge eines Drags zusammen. Wird vom Main-Thread
/// angelegt und von den Hintergrund-Operationen fortgeschrieben, deshalb mit Lock.
final class DragBatch: @unchecked Sendable {
    /// Erst nach dieser Zeit erscheint das Fenster; kleine Dateien sind vorher fertig.
    private static let showDelay: Duration = .milliseconds(400)

    private let lock = NSLock()
    private var names: [String] = []
    private var planned: [UInt64] = []
    private var done: [UInt64] = []
    private var totals: [UInt64] = []
    private var running = 0
    private var finished = 0
    private var errors: [(name: String, message: String)] = []
    /// Bleibt gesetzt, auch wenn der Job schon weg ist (wartende Einträge brechen dann sofort ab).
    private var cancelled = false
    /// Jeder Start und jedes Ende zählt hoch; daran erkennt das Fenster, ob noch etwas nachkommt.
    private var generation = 0

    /// Fortschritt und Abbruch des angezeigten Jobs (threadsicher, unter `lock` gesetzt).
    private var relay: ProgressRelay?

    private let created = Date()
    private weak var ui: WindowState?
    private weak var window: NSWindow?
    // Nur auf dem Main-Thread benutzt
    private(set) var job: Job?
    private var panel: ProgressPanel?
    /// Ist das Fortschrittsfenster gerade zu sehen? (für Tests)
    @MainActor var isShowingWindow: Bool { panel != nil }

    @MainActor
    init(ui: WindowState, window: NSWindow?) {
        self.ui = ui
        self.window = window
    }

    /// Ein Drag, dessen Zeilen schon vor einer Weile abgefragt wurden, hat nie begonnen.
    @MainActor var isStale: Bool { Date().timeIntervalSince(created) > 1 }

    @MainActor
    func register(name: String, size: UInt64) -> Int {
        lock.withLock {
            names.append(name)
            planned.append(size)
            done.append(0)
            totals.append(size)
            return names.count - 1
        }
    }

    /// Abgebrochen über den Knopf im Fortschrittsfenster.
    var isCancelled: Bool {
        lock.withLock { cancelledLocked() }
    }

    // MARK: Aus dem Hintergrund

    func itemStarted() {
        let first = lock.withLock { () -> Bool in
            running += 1
            generation += 1
            return running == 1 && finished == 0
        }
        if first {
            Task { @MainActor in await self.scheduleWindow() }
        }
    }

    func update(_ index: Int, done itemDone: UInt64, total itemTotal: UInt64, current: String) {
        let (sumDone, sumTotal) = lock.withLock { () -> (UInt64, UInt64) in
            done[index] = itemDone
            totals[index] = max(planned[index], itemTotal)
            return (done.reduce(0, +), totals.reduce(0, +))
        }
        currentRelay()?.onProgress(done: sumDone, total: sumTotal, current: current)
    }

    func itemFinished(_ index: Int, error: (String, String)?) {
        let (sumDone, sumTotal) = lock.withLock { () -> (UInt64, UInt64) in
            running -= 1
            finished += 1
            generation += 1
            done[index] = totals[index]
            if let error { errors.append((error.0, error.1)) }
            return (done.reduce(0, +), totals.reduce(0, +))
        }
        currentRelay()?.onProgress(done: sumDone, total: sumTotal, current: "")
        Task { @MainActor in await self.finishIfIdle() }
    }

    /// Nur unter `lock` aufrufen.
    private func cancelledLocked() -> Bool {
        if relay?.isCancelled() == true { cancelled = true }
        return cancelled
    }

    private func currentRelay() -> ProgressRelay? {
        lock.withLock { relay }
    }

    // MARK: Fenster (Main-Thread)

    @MainActor
    private func scheduleWindow() async {
        let names = lock.withLock { self.names }
        let title = names.count == 1 ? "Entpacke „\(names[0])“ …" : "Entpacke \(Fmt.objects(names.count)) …"
        let job = Job(title: title, symbol: "arrow.down.doc")
        self.job = job
        lock.withLock { relay = job.relay }

        try? await Task.sleep(for: Self.showDelay)
        guard self.job === job, lock.withLock({ running > 0 }) else { return }
        let panel = ProgressPanel(job: job)
        panel.show(near: window)
        self.panel = panel
    }

    /// Alle gestarteten Einträge sind fertig. Kurz warten, ob noch einer startet
    /// (die Warteschlange arbeitet höchstens zwei gleichzeitig ab).
    @MainActor
    private func finishIfIdle() async {
        let generationAtEnd = lock.withLock { () -> Int? in
            running == 0 ? generation : nil
        }
        guard let generationAtEnd else { return }
        let allDone = lock.withLock { finished >= names.count }
        if !allDone {
            try? await Task.sleep(for: .milliseconds(300))
            guard lock.withLock({ running == 0 && generation == generationAtEnd }) else { return }
        }
        panel?.close()
        panel = nil
        job = nil
        // Fehler nur einmal melden, bei Abbruch gar nicht
        let (errors, cancelled) = lock.withLock { () -> ([(name: String, message: String)], Bool) in
            let result = (self.errors, cancelledLocked())
            self.errors = []
            relay = nil
            return result
        }
        guard !errors.isEmpty, !cancelled else { return }
        let title = errors.count == 1
            ? "„\(errors[0].name)“ konnte nicht entpackt werden"
            : "\(Fmt.objects(errors.count)) konnten nicht entpackt werden"
        ui?.presentMessage(title, errors[0].message)
    }
}

/// Fortschritt eines einzelnen Eintrags, weitergereicht an seinen Drag.
private final class DragItemProgress: ProgressListener, @unchecked Sendable {
    private let batch: DragBatch
    private let index: Int

    init(batch: DragBatch, index: Int) {
        self.batch = batch
        self.index = index
    }

    func onProgress(done: UInt64, total: UInt64, current: String) {
        batch.update(index, done: done, total: total, current: current)
    }

    func isCancelled() -> Bool {
        batch.isCancelled
    }
}
