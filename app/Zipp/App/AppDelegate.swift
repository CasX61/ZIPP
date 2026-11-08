import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    private var controllers: [ArchiveWindowController] = []
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false
    private var settingsWindow: NSWindow?
    let services = ServiceProvider()

    // MARK: - Lebenszyklus

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        AppAppearance.current.apply()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
        NSApp.mainMenu = MainMenu.build(recentMenuDelegate: self)
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        // Finder-Kontextmenü (Dienste)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        TempStore.cleanupStale()
        // Wurde ZIPP nur für einen Dienst gestartet („Hier entpacken“), kein leeres Fenster zeigen.
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !pendingURLs.isEmpty {
            open(pendingURLs)
            pendingURLs = []
        } else if controllers.isEmpty, defaultLaunch {
            newWelcomeWindow()
        } else if controllers.isEmpty {
            // Sicherheitsnetz: Kam doch kein Auftrag, nach kurzer Zeit das normale Fenster zeigen.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if self.controllers.isEmpty, !self.services.isBusy { self.newWelcomeWindow() }
            }
        }
        UpdateChecker.checkAutomaticallyIfDue()
        #if DEBUG
        DebugSnapshots.runIfRequested()
        #endif
    }

    /// Doppelklick im Finder, „Öffnen mit“, Drop aufs Dock-Symbol.
    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            open(urls)
        } else {
            pendingURLs += urls
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWelcomeWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Beenden

    /// AppKit bricht `terminate` ab, solange ein Sheet offen ist (z. B. die
    /// Passwortabfrage). Deshalb vorher alle Dialoge schließen und laufende
    /// Vorgänge abbrechen. Gilt für ⌘Q, „Beenden“ im Dock, Abmelden und Neustart.
    @objc func quit(_ sender: Any?) {
        prepareForTermination()
        NSApp.terminate(sender)
    }

    private func prepareForTermination() {
        for controller in controllers {
            controller.dismissSheets()
            controller.ui.job?.cancel()
        }
        services.cancelAll()
    }

    /// Quit-Apple-Event (Dock, Abmelden, `osascript … to quit`).
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        quit(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempStore.cleanupAll()
    }

    // MARK: - Fenster

    /// Archive öffnen; Ordner und andere Dateien (z. B. per Drop aufs Dock-Symbol) komprimieren.
    func open(_ urls: [URL]) {
        func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        let archives = urls.filter { !isDirectory($0) && ArchiveTypes.isLikelyArchive($0) }
        let others = urls.filter { url in !archives.contains(url) }
        for url in archives { openArchive(url) }
        if !others.isEmpty { presentCompress(for: others) }
    }

    /// „Neues Archiv“-Dialog für diese Dateien (in einem freien Fenster).
    func presentCompress(for urls: [URL]) {
        let controller = controllers.first { $0.archiveURL == nil && !$0.isBusy && $0.window?.attachedSheet == nil }
            ?? newWelcomeWindow()
        controller.showWindow(nil)
        controller.presentCompress(sources: urls)
    }

    func openArchive(_ url: URL) {
        // Bei mehrteiligen Archiven immer den ersten Teil öffnen (auch wenn „.part3.rar“ angeklickt wurde)
        let url = ArchiveTypes.firstVolume(of: url)
        if let existing = controllers.first(where: { $0.archiveURL?.standardizedFileURL == url }) {
            existing.showWindow(nil)
            return
        }
        let controller = controllers.first { $0.archiveURL == nil && !$0.isBusy && $0.window?.attachedSheet == nil }
            ?? makeController()
        controller.load(url)
        controller.showWindow(nil)
    }

    @discardableResult
    func newWelcomeWindow() -> ArchiveWindowController {
        let controller = makeController()
        controller.showWindow(nil)
        return controller
    }

    private func makeController() -> ArchiveWindowController {
        let controller = ArchiveWindowController()
        if let last = controllers.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        return controller
    }

    private var frontController: ArchiveWindowController? {
        NSApp.keyWindow?.windowController as? ArchiveWindowController
            ?? NSApp.mainWindow?.windowController as? ArchiveWindowController
    }

    // MARK: - Menü-Aktionen

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ArchiveTypes.openableTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Öffnen"
        panel.message = "Archiv zum Öffnen auswählen"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    @objc func newDocument(_ sender: Any?) {
        let controller = frontController ?? newWelcomeWindow()
        controller.showWindow(nil)
        controller.chooseFilesToCompress()
    }

    @objc func newWindow(_ sender: Any?) {
        newWelcomeWindow()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Einstellungen"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Kostenloser Open-Source-Archiv-Manager für macOS.\nRAR-Unterstützung: UnRAR © Alexander Roshal.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "ZIPP"])
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openArchive(url)
    }

    @objc func clearRecents(_ sender: Any?) {
        RecentArchives.shared.clear()
    }

    @objc func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(Project.homepage)
    }

    /// Menü „Darstellung → Erscheinungsbild“ (`representedObject` = Rohwert)
    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let appearance = AppAppearance(rawValue: raw) else { return }
        AppAppearance.set(appearance)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Task { await UpdateChecker.check(userInitiated: true) }
    }

    @objc func openServicesHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "ZIPP im Finder-Kontextmenü"
        alert.informativeText = """
        Rechtsklick auf ein Archiv oder auf Dateien im Finder → „Dienste“ (bzw. „Schnellaktionen“):
        • Mit ZIPP hier entpacken
        • Mit ZIPP in eigenen Ordner entpacken
        • Mit ZIPP als ZIP / als 7z komprimieren
        • Mit ZIPP komprimieren …

        Fehlen die Einträge, lassen sie sich in den Systemeinstellungen einschalten: Tastatur → Tastaturkurzbefehle → Dienste → „Dateien und Ordner“.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Tastatur-Einstellungen öffnen")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - „Zuletzt geöffnet“

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentArchives.shared.existing
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            let icon = IconCache.archiveIcon(for: url)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = url.path
            menu.addItem(item)
        }
        if urls.isEmpty {
            let empty = NSMenuItem(title: "Keine Einträge", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Liste löschen", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseAppearance(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == AppAppearance.current.rawValue ? .on : .off
        }
        return true
    }
}
