import AppKit
import SwiftUI
import ZippCore

private extension NSToolbarItem.Identifier {
    static let back = Self("zipp.back")
    static let forward = Self("zipp.forward")
    static let add = Self("zipp.add")
    static let extract = Self("zipp.extract")
    static let test = Self("zipp.test")
    static let delete = Self("zipp.delete")
    static let search = Self("zipp.search")
}

/// Hält das Sheet schwach, damit sich der Schließen-Callback darauf beziehen kann.
private final class SheetBox {
    weak var controller: NSViewController?
}

/// Ein Fenster: entweder Willkommen (kein Archiv) oder ein geöffnetes Archiv.
@MainActor
final class ArchiveWindowController: NSWindowController, NSWindowDelegate {
    let ui = WindowState()
    private(set) var session: ArchiveSession?
    var onClose: (() -> Void)?

    private weak var searchItem: NSSearchToolbarItem?
    private var pendingSheetCancel: (() -> Void)?

    var archiveURL: URL? { session?.url }
    var isBusy: Bool { ui.job != nil }

    private var splitController: MainSplitViewController? {
        window?.contentViewController as? MainSplitViewController
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 680, height: 420)
        window.tabbingIdentifier = "ZIPPArchiveWindow"
        window.title = "ZIPP"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureToolbar()
        configureCallbacks()
        showWelcome()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    // MARK: - Inhalt

    private func setContent(_ controller: NSViewController) {
        guard let window else { return }
        let frame = window.frame
        window.contentViewController = controller
        window.setFrame(frame, display: true)
    }

    func showWelcome() {
        session?.cleanup()
        session = nil
        let host = NSHostingController(rootView: WelcomeView(
            ui: ui,
            onOpen: { [weak self] in self?.chooseArchiveToOpen() },
            onCreate: { [weak self] in self?.chooseFilesToCompress() },
            onDrop: { [weak self] urls in self?.handleDrop(urls) },
            onCompress: { [weak self] urls in self?.presentCompress(sources: urls) },
            onOpenRecent: { url in AppDelegate.shared?.openArchive(url) }
        ))
        host.sizingOptions = []
        setContent(host)
        window?.title = "ZIPP"
        window?.subtitle = ""
        window?.representedURL = nil
        updateToolbarVisibility()
        window?.toolbar?.validateVisibleItems()
    }

    /// Ohne geöffnetes Archiv die Archiv-Knöpfe ausblenden statt nur ausgrauen.
    private func updateToolbarVisibility() {
        guard #available(macOS 15.0, *), let toolbar = window?.toolbar else { return }
        let archiveOnly: Set<NSToolbarItem.Identifier> = [
            .toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .add, .extract, .test, .delete, .search,
            .toggleInspector, .inspectorTrackingSeparator,
        ]
        for item in toolbar.items where archiveOnly.contains(item.itemIdentifier) {
            item.isHidden = session == nil
        }
    }

    func load(_ url: URL) {
        session?.cleanup()
        let session = ArchiveSession(url: url, ui: ui)
        self.session = session
        let split = MainSplitViewController(
            session: session,
            onOpenRecent: { url in AppDelegate.shared?.openArchive(url) },
            onQuickExtract: { [weak self] folder in self?.quickExtract(to: folder) }
        )
        setContent(split)
        window?.title = session.displayName
        window?.representedURL = url
        window?.subtitle = "Wird geladen …"
        RecentArchives.shared.add(url)
        updateToolbarVisibility()
        observeSession()
        Task { await session.load() }
    }

    /// Titelzeile und Toolbar aktuell halten.
    private func observeSession() {
        guard let session else { return }
        withObservationTracking {
            _ = session.phase
            _ = session.listing
            _ = session.selection
            _ = session.historyVersion
            _ = session.searchText
            _ = ui.job
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                self.updateChrome()
                self.observeSession()
            }
        }
        updateChrome()
    }

    private func updateChrome() {
        guard let session else { return }
        switch session.phase {
        case .ready:
            if let listing = session.listing {
                let files = listing.entries.filter { !$0.isDir }.count
                let parts = listing.volumeCount > 1 ? " · \(listing.volumeCount) Teile" : ""
                window?.subtitle = "\(listing.formatLabel)\(parts) · \(Fmt.files(files)) · \(Fmt.size(listing.totalSize))"
            }
        case .loading: window?.subtitle = "Wird geladen …"
        case .locked: window?.subtitle = "Verschlüsselt"
        case .failed: window?.subtitle = "Fehler"
        }
        if let field = searchItem?.searchField, field.stringValue != session.searchText {
            field.stringValue = session.searchText
        }
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Dialoge

    private func configureCallbacks() {
        ui.errorPresenter = { [weak self] title, message in
            self?.showAlert(title: title, message: message)
        }
        ui.confirmer = { [weak self] title, message, confirm in
            guard let self else { return false }
            return await self.askConfirmation(title: title, message: message, confirm: confirm)
        }
        ui.passwordProvider = { [weak self] name, wrong in
            guard let self else { return nil }
            return await self.askPassword(archiveName: name, wrong: wrong)
        }
        ui.closeWindow = { [weak self] in self?.close() }
    }

    private func showAlert(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window.attachedSheet ?? window)
    }

    private func askConfirmation(title: String, message: String, confirm: String) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Abbrechen")
        alert.alertStyle = .warning
        if confirm == "Löschen" { alert.buttons.first?.hasDestructiveAction = true }
        let response = await alert.beginSheetModal(for: window.attachedSheet ?? window)
        return response == .alertFirstButtonReturn
    }

    private func askPassword(archiveName: String, wrong: Bool) async -> (password: String, remember: Bool)? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ((password: String, remember: Bool)?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            let presented = presentSheet { dismiss in
                PasswordSheet(
                    archiveName: archiveName,
                    wrongPassword: wrong,
                    onCancel: { dismiss(); finish(nil) },
                    onSubmit: { password, remember in dismiss(); finish((password, remember)) }
                )
            }
            if presented {
                pendingSheetCancel = { finish(nil) }
            } else {
                finish(nil)
            }
        }
    }

    /// Zeigt eine SwiftUI-Ansicht als Sheet. Gibt `false` zurück, wenn schon eins offen ist.
    @discardableResult
    func presentSheet<Content: View>(_ build: (_ dismiss: @escaping () -> Void) -> Content) -> Bool {
        guard let presenter = window?.contentViewController, window?.attachedSheet == nil else {
            NSSound.beep()
            return false
        }
        let box = SheetBox()
        let content = build { [weak presenter, weak self] in
            self?.pendingSheetCancel = nil
            if let controller = box.controller { presenter?.dismiss(controller) }
        }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        box.controller = host
        presenter.presentAsSheet(host)
        return true
    }

    // MARK: - Öffnen & Erstellen

    func chooseArchiveToOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ArchiveTypes.openableTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.message = "Archiv zum Öffnen auswählen"
        panel.prompt = "Öffnen"
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in AppDelegate.shared?.open(urls) }
        }
    }

    func chooseFilesToCompress() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Dateien und Ordner für das neue Archiv auswählen"
        panel.prompt = "Auswählen"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.presentCompress(sources: urls) }
        }
    }

    /// Drop auf das Willkommen-Fenster: Archive öffnen, alles andere komprimieren.
    func handleDrop(_ urls: [URL]) {
        let archives = urls.filter { ArchiveTypes.isLikelyArchive($0) && !$0.hasDirectoryPath }
        if archives.count == urls.count {
            AppDelegate.shared?.open(archives)
        } else {
            presentCompress(sources: urls)
        }
    }

    func presentCompress(sources: [URL]) {
        guard !sources.isEmpty else { return }
        presentSheet { dismiss in
            CompressSheet(sources: sources, onCancel: dismiss) { [weak self] request in
                dismiss()
                Task { await self?.runCompress(request) }
            }
        }
    }

    private func runCompress(_ request: CompressRequest) async {
        let ext = createFormatExtension(format: request.format)
        let dest = FileNaming.uniqueArchiveURL(
            folder: request.folder, name: request.name, ext: ext, split: request.volumeSize != nil
        )
        let sources = request.sources.map(\.path)
        let options = request.options
        let destPath = dest.path
        do {
            let summary = try await ui.runJob(title: "Erstelle „\(dest.lastPathComponent)“ …", symbol: "archivebox") { relay in
                try createArchive(sources: sources, destination: destPath, options: options, progress: relay)
            }
            if request.trashOriginals {
                _ = try? await NSWorkspace.shared.recycle(request.sources)
            }
            ui.announceCreated(summary)
        } catch {
            ui.presentError(error, title: "Erstellen fehlgeschlagen")
        }
    }

    // MARK: - Bearbeiten & Konvertieren

    func presentConvert() {
        guard let session, session.phase == .ready else { return }
        presentSheet { dismiss in
            CompressSheet(sources: [], convertFrom: session.url, onCancel: dismiss) { request in
                dismiss()
                Task { await session.convert(request) }
            }
        }
    }

    func presentRename() {
        guard let session, session.phase == .ready, session.selection.count == 1 else { return }
        let node = session.selection[0]
        presentSheet { dismiss in
            NameSheet(
                title: "Umbenennen",
                message: "Neuer Name für „\(node.name)“:",
                initialName: node.name,
                confirmTitle: "Umbenennen",
                onCancel: dismiss
            ) { name in
                dismiss()
                Task { await session.rename(node, to: name) }
            }
        }
    }

    func presentNewFolder() {
        guard let session, session.phase == .ready else { return }
        let location = session.currentFolder?.parent == nil ? "oberster Ebene" : "„\(session.currentFolder?.name ?? "")“"
        presentSheet { dismiss in
            NameSheet(
                title: "Neuer Ordner",
                message: "Leeren Ordner in \(location) anlegen:",
                initialName: session.suggestedFolderName(),
                confirmTitle: "Anlegen",
                onCancel: dismiss
            ) { name in
                dismiss()
                Task { await session.createFolder(named: name) }
            }
        }
    }

    // MARK: - Entpacken

    private var selectedOrAll: [ArchiveNode] { session?.selection ?? [] }

    func quickExtract(to folder: URL? = nil) {
        guard let session, session.phase == .ready else { return }
        guard let base = folder ?? Preferences.extractDestination.folder(for: session.url) else {
            presentExtractSheet()
            return
        }
        let request = ExtractRequest(
            nodes: session.selection,
            baseFolder: base,
            folderMode: Preferences.folderMode,
            overwrite: Preferences.overwrite,
            revealAfter: Preferences.revealAfterExtract,
            trashArchiveAfter: false
        )
        Task { await session.extract(request) }
    }

    func presentExtractSheet() {
        guard let session, session.phase == .ready, let listing = session.listing else { return }
        let nodes = session.selection
        let summary: String
        if nodes.isEmpty {
            let files = listing.entries.filter { !$0.isDir }.count
            summary = "Gesamtes Archiv · \(Fmt.files(files)) · \(Fmt.size(listing.totalSize))"
        } else {
            let files = nodes.reduce(0) { $0 + $1.fileCount }
            summary = "\(Fmt.objects(nodes.count)) ausgewählt · \(Fmt.files(files)) · \(Fmt.size(nodes.reduce(0) { $0 &+ $1.totalSize }))"
        }
        let initial = Preferences.extractDestination.folder(for: session.url) ?? session.url.deletingLastPathComponent()
        presentSheet { dismiss in
            ExtractSheet(
                summary: summary,
                archiveURL: session.url,
                initialFolder: initial,
                preview: { base, mode in session.resultPreview(for: nodes, base: base, mode: mode) },
                onCancel: dismiss,
                onConfirm: { options in
                    dismiss()
                    let request = ExtractRequest(
                        nodes: nodes,
                        baseFolder: options.folder,
                        folderMode: options.folderMode,
                        overwrite: options.overwrite,
                        revealAfter: options.revealAfter,
                        trashArchiveAfter: options.trashArchive
                    )
                    Task { await session.extract(request) }
                }
            )
        }
    }

    // MARK: - Aktionen (Menü & Toolbar)

    @objc func goBack(_ sender: Any?) { session?.goBack() }
    @objc func goForward(_ sender: Any?) { session?.goForward() }
    @objc func goUp(_ sender: Any?) { session?.goUp() }

    @objc func openSelection(_ sender: Any?) {
        guard let session, let node = session.selection.first else { return }
        if session.selection.count == 1 {
            session.open(node)
        } else {
            let files = session.selection.filter { !$0.isDirectory }
            Task { await session.openWithDefaultApp(files) }
        }
    }

    @objc func extractDefault(_ sender: Any?) { quickExtract() }
    @objc func extractTo(_ sender: Any?) { presentExtractSheet() }

    @objc func addFiles(_ sender: Any?) {
        guard let session, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Dateien zu „\(session.displayName)“ hinzufügen"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await session.add(urls, into: nil) }
        }
    }

    @objc func testArchive(_ sender: Any?) {
        guard let session else { return }
        Task { await session.test() }
    }

    @objc func deleteSelection(_ sender: Any?) {
        guard let session else { return }
        Task { await session.delete(session.selection) }
    }

    @objc func renameSelection(_ sender: Any?) { presentRename() }
    @objc func newFolder(_ sender: Any?) { presentNewFolder() }
    @objc func convertArchive(_ sender: Any?) { presentConvert() }

    @objc func toggleQuickLook(_ sender: Any?) { splitController?.browser.toggleQuickLook() }

    @objc func revealArchive(_ sender: Any?) {
        guard let url = session?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func focusSearch(_ sender: Any?) { searchItem?.beginSearchInteraction() }

    @objc func newArchive(_ sender: Any?) { chooseFilesToCompress() }

    @objc private func searchChanged(_ sender: NSSearchField) {
        session?.searchText = sender.stringValue
    }

    @objc func unlockArchive(_ sender: Any?) {
        guard let session else { return }
        Task { await session.load() }
    }

    // MARK: - Fenster

    /// Schließt offene Dialoge (z. B. beim Beenden, das sonst an einem offenen Sheet scheitert).
    func dismissSheets() {
        pendingSheetCancel?()
        pendingSheetCancel = nil
        if let content = window?.contentViewController {
            content.presentedViewControllers?.forEach { content.dismiss($0) }
        }
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
    }

    func windowWillClose(_ notification: Notification) {
        pendingSheetCancel?()
        pendingSheetCancel = nil
        ui.job?.cancel()
        session?.cleanup()
        onClose?()
    }
}

// MARK: - Validierung

extension ArchiveWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    private func isEnabled(_ action: Selector?) -> Bool {
        guard let action else { return false }
        let ready = session?.phase == .ready
        let idle = ui.job == nil
        let tableFocused = window?.firstResponder is FileTableView
        switch action {
        case #selector(goBack(_:)): return session?.canGoBack ?? false
        case #selector(goForward(_:)): return session?.canGoForward ?? false
        case #selector(goUp(_:)): return session?.canGoUp ?? false
        case #selector(openSelection(_:)): return ready && !(session?.selection.isEmpty ?? true)
        case #selector(extractDefault(_:)), #selector(extractTo(_:)), #selector(testArchive(_:)):
            return ready && idle
        case #selector(addFiles(_:)): return ready && idle && (session?.isEditable ?? false)
        case #selector(deleteSelection(_:)):
            return ready && idle && (session?.isEditable ?? false) && !(session?.selection.isEmpty ?? true)
                && (tableFocused || !(window?.firstResponder is NSText))
        case #selector(renameSelection(_:)):
            return ready && idle && (session?.isEditable ?? false) && session?.selection.count == 1
        case #selector(newFolder(_:)):
            return ready && idle && (session?.isEditable ?? false) && (session?.searchText.isEmpty ?? false)
        case #selector(convertArchive(_:)): return ready && idle
        case #selector(toggleQuickLook(_:)):
            return ready && (session?.selection.contains { !$0.isDirectory } ?? false)
        case #selector(revealArchive(_:)): return session != nil
        case #selector(focusSearch(_:)): return ready
        case #selector(unlockArchive(_:)): return session != nil
        default: return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled(menuItem.action) }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { isEnabled(item.action) }
}

// MARK: - Toolbar

extension ArchiveWindowController: NSToolbarDelegate {
    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "ZIPPToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace,
         .add, .extract, .test, .delete, .flexibleSpace, .search, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .add, .extract, .test, .delete,
         .search, .toggleInspector, .inspectorTrackingSeparator, .flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case .back:
            return button(id, "Zurück", "chevron.backward", #selector(goBack(_:)), "Zurück (⌘[)")
        case .forward:
            return button(id, "Vor", "chevron.forward", #selector(goForward(_:)), "Vor (⌘])")
        case .add:
            return button(id, "Hinzufügen", "plus", #selector(addFiles(_:)), "Dateien zum Archiv hinzufügen (⇧⌘A)")
        case .extract:
            let item = button(id, "Entpacken", "arrow.down.doc", #selector(extractTo(_:)), "Entpacken nach … (⌥⌘E)")
            if #available(macOS 26.0, *) { item.style = .prominent }
            return item
        case .test:
            return button(id, "Testen", "checkmark.shield", #selector(testArchive(_:)), "Archiv auf Fehler prüfen (⌘T)")
        case .delete:
            return button(id, "Löschen", "trash", #selector(deleteSelection(_:)), "Aus dem Archiv löschen (⌘⌫)")
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Suchen"
            item.searchField.placeholderString = "Im Archiv suchen"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func button(
        _ id: NSToolbarItem.Identifier,
        _ label: String,
        _ symbol: String,
        _ action: Selector,
        _ tooltip: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}
