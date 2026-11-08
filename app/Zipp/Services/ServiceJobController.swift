import AppKit
import SwiftUI

/// Kleines Fortschrittsfenster für Aufträge aus dem Finder-Kontextmenü
/// („Hier entpacken“, „Als ZIP komprimieren“). Fragt bei Bedarf nach dem
/// Passwort und zeigt Fehler, ohne ein ganzes Archivfenster zu öffnen.
@MainActor
final class ServiceJobController: NSWindowController, NSWindowDelegate {
    let ui = WindowState()
    var onClose: (() -> Void)?
    private var pendingSheetCancel: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 110),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.delegate = self
        let host = NSHostingController(rootView: ServiceJobView(ui: ui, title: title) { [weak self] in
            self?.close()
        })
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.center()
        configureCallbacks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    func present() {
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Schließt das Fenster, außer es gibt noch etwas zu lesen (Warnung).
    func finish() {
        if ui.toast?.style == .warning {
            ui.isFinished = true
        } else {
            close()
        }
    }

    private func configureCallbacks() {
        ui.errorPresenter = { [weak self] title, message in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            if let window = self?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
        ui.confirmer = { [weak self] title, message, confirm in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: "Abbrechen")
            alert.alertStyle = .warning
            guard let window = self?.window else { return alert.runModal() == .alertFirstButtonReturn }
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        ui.passwordProvider = { [weak self] name, wrong in
            await self?.askPassword(archiveName: name, wrong: wrong)
        }
    }

    private func askPassword(archiveName: String, wrong: Bool) async -> (password: String, remember: Bool)? {
        guard let window, window.attachedSheet == nil else { return nil }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ((password: String, remember: Bool)?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            var sheetWindow: NSWindow?
            let dismiss = { [weak self] in
                self?.pendingSheetCancel = nil
                if let sheetWindow { window.endSheet(sheetWindow) }
            }
            let host = NSHostingController(rootView: PasswordSheet(
                archiveName: archiveName,
                wrongPassword: wrong,
                onCancel: { dismiss(); finish(nil) },
                onSubmit: { password, remember in dismiss(); finish((password, remember)) }
            ))
            let sheet = NSWindow(contentViewController: host)
            sheetWindow = sheet
            pendingSheetCancel = { finish(nil) }
            window.beginSheet(sheet)
        }
    }

    func windowWillClose(_ notification: Notification) {
        pendingSheetCancel?()
        pendingSheetCancel = nil
        ui.job?.cancel()
        ui.isCancelledByUser = true
        onClose?()
    }
}

private struct ServiceJobView: View {
    let ui: WindowState
    let title: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let job = ui.job {
                JobView(job: job)
            } else if ui.isFinished, let toast = ui.toast {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(toast.message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("OK", action: onDone).keyboardShortcut(.defaultAction)
                }
                .padding(12)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(title) …").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(width: 460)
    }
}
