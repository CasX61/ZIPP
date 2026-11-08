import AppKit
import Observation
import ZippCore

/// Empfängt den Fortschritt aus dem Rust-Kern (auf einem Hintergrund-Thread)
/// und leitet ihn an den Main-Thread weiter. Abbruch wird hier gemerkt.
final class ProgressRelay: ProgressListener, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable (UInt64, UInt64, String) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (UInt64, UInt64, String) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func onProgress(done: UInt64, total: UInt64, current: String) {
        let handler = lock.withLock { self.handler }
        handler?(done, total, current)
    }

    func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Ein laufender Vorgang (Entpacken, Komprimieren, Testen …).
@MainActor
@Observable
final class Job: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    private(set) var done: UInt64 = 0
    private(set) var total: UInt64 = 0
    private(set) var current = ""
    private(set) var isCancelling = false
    @ObservationIgnored let relay = ProgressRelay()
    @ObservationIgnored private let started = Date()

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        relay.setHandler { [weak self] done, total, current in
            Task { @MainActor in self?.update(done: done, total: total, current: current) }
        }
    }

    private func update(done: UInt64, total: UInt64, current: String) {
        self.done = done
        self.total = total
        if !current.isEmpty { self.current = current }
    }

    var fraction: Double? {
        total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    var bytesPerSecond: Double {
        let elapsed = Date().timeIntervalSince(started)
        return elapsed > 0.5 ? Double(done) / elapsed : 0
    }

    var remaining: TimeInterval? {
        let rate = bytesPerSecond
        guard rate > 0, total > done else { return nil }
        return Double(total - done) / rate
    }

    func cancel() {
        isCancelling = true
        relay.cancel()
    }
}

/// Kurze Rückmeldung oben im Fenster.
struct Toast: Identifiable {
    enum Style { case success, info, warning }
    let id = UUID()
    var message: String
    var style: Style = .success
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
}

/// Zustand eines Fensters, der unabhängig vom Archiv ist (auch im Willkommen-Fenster).
@MainActor
@Observable
final class WindowState {
    var job: Job?
    var toast: Toast?
    /// Nur im Dienste-Fenster: alle Aufträge sind erledigt (es bleibt eine Warnung zu lesen).
    var isFinished = false
    /// Nur im Dienste-Fenster: der Nutzer hat das Fenster geschlossen, weitere Aufträge entfallen.
    @ObservationIgnored var isCancelledByUser = false

    // Vom Fenster-Controller gesetzt
    @ObservationIgnored var passwordProvider: ((_ archiveName: String, _ wrong: Bool) async -> (password: String, remember: Bool)?)?
    @ObservationIgnored var errorPresenter: ((_ title: String, _ message: String) -> Void)?
    @ObservationIgnored var confirmer: ((_ title: String, _ message: String, _ confirm: String) async -> Bool)?
    @ObservationIgnored var closeWindow: (() -> Void)?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Führt Arbeit im Hintergrund aus und zeigt dabei den Fortschritt.
    func runJob<T: Sendable>(
        title: String,
        symbol: String,
        showsProgress: Bool = true,
        _ work: @escaping @Sendable (ProgressRelay) throws -> T
    ) async throws -> T {
        let job = Job(title: title, symbol: symbol)
        if showsProgress { self.job = job }
        defer { if self.job === job { self.job = nil } }
        let relay = job.relay
        return try await Task.detached(priority: .userInitiated) { try work(relay) }.value
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.actionTitle == nil ? 3.5 : 6))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            self?.toast = nil
        }
    }

    func presentError(_ error: Error, title: String = "Das hat nicht geklappt") {
        if ErrorText.isCancellation(error) {
            show(Toast(message: "Abgebrochen", style: .info))
            return
        }
        errorPresenter?(title, ErrorText.describe(error))
    }

    func presentMessage(_ title: String, _ message: String) {
        errorPresenter?(title, message)
    }

    func confirm(_ title: String, _ message: String, confirm: String) async -> Bool {
        await confirmer?(title, message, confirm) ?? false
    }
}

extension WindowState {
    /// Meldung nach dem Erstellen oder Konvertieren eines Archivs (auch aufgeteilt).
    func announceCreated(_ summary: CreateSummary) {
        let urls = summary.outputs.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { return }
        let name = urls.count > 1 ? ArchiveTypes.logicalName(of: first) : first.lastPathComponent
        let parts = urls.count > 1 ? " · \(urls.count) Teile" : ""
        var toast = Toast(message: "„\(name)“ erstellt · \(Fmt.size(summary.bytesOut))\(parts)")
        toast.actionTitle = "Öffnen"
        toast.action = { AppDelegate.shared?.openArchive(first) }
        show(toast)
        if Preferences.revealAfterCreate {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}
