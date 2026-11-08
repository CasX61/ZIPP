import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Pfadleiste, Dateiliste und Statusleiste eines Archivs.
@MainActor
final class BrowserViewController: NSViewController {
    let session: ArchiveSession
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private lazy var promiseDelegate = FilePromiseDelegate(session: session)
    private var previewURLs: [URL] = []

    private enum Row {
        case parent
        case node(ArchiveNode)
    }

    private var rows: [Row] = []

    private enum Column: String, CaseIterable {
        case name, size, packed, ratio, modified, kind

        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Größe"
            case .packed: "Gepackt"
            case .ratio: "Ersparnis"
            case .modified: "Geändert"
            case .kind: "Art"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 240
            case .size, .packed: 76
            case .ratio: 100
            case .modified: 128
            case .kind: 120
            }
        }

        var isNumeric: Bool { self == .size || self == .packed }
        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    init(session: ArchiveSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    // MARK: - Aufbau

    override func loadView() {
        let root = NSView()
        configureTable()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let pathBar = NSHostingView(rootView: BreadcrumbBar(session: session))
        let status = NSHostingView(rootView: StatusBar(session: session))
        let state = NSHostingView(rootView: SessionStateView(session: session))
        let overlay = NSHostingView(rootView: OverlayLayer(ui: session.ui))
        for view in [pathBar, status, state, overlay] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(pathBar)
        root.addSubview(scrollView)
        root.addSubview(status)
        root.addSubview(state)
        root.addSubview(overlay)

        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),

            state.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            state.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            state.bottomAnchor.constraint(equalTo: status.topAnchor),

            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            overlay.bottomAnchor.constraint(equalTo: status.topAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeSession()
        reload()
    }

    private func configureTable() {
        for column in Column.allCases {
            let tc = NSTableColumn(identifier: column.identifier)
            tc.title = column.title
            tc.width = column.width
            tc.minWidth = column == .name ? 160 : 60
            tc.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .name)
            tc.headerCell.alignment = column.isNumeric ? .right : .left
            tableView.addTableColumn(tc)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 10, height: 0)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.autosaveName = "ZIPPBrowserTable"
        tableView.autosaveTableColumns = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        // „Lokal“ heißt: innerhalb von ZIPP, also auch in ein anderes Archivfenster
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.registerForDraggedTypes(
            [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        )
        tableView.draggingDestinationFeedbackStyle = .regular

        tableView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        tableView.onOpen = { [weak self] in self?.openSelected() }
        tableView.onGoUp = { [weak self] in self?.session.goUp() }
        tableView.onDelete = { [weak self] in
            guard let self else { return }
            Task { await self.session.delete(self.session.selection) }
        }
        tableView.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
    }

    // MARK: - Daten

    private func observeSession() {
        withObservationTracking {
            _ = session.contentVersion
            _ = session.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.observeSession()
            }
        }
    }

    func reload() {
        let selectedPaths = Set(session.selection.map(\.path))
        var newRows: [Row] = []
        if session.searchText.isEmpty, session.currentFolder?.parent != nil {
            newRows.append(.parent)
        }
        newRows += sorted(session.visibleItems).map(Row.node)
        rows = newRows
        tableView.reloadData()

        var indexes = IndexSet()
        for (i, row) in rows.enumerated() {
            if case .node(let node) = row, selectedPaths.contains(node.path) { indexes.insert(i) }
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
        scrollView.isHidden = session.phase != .ready
    }

    private func sorted(_ items: [ArchiveNode]) -> [ArchiveNode] {
        let descriptor = tableView.sortDescriptors.first
        let key = Column(rawValue: descriptor?.key ?? "") ?? .name
        let ascending = descriptor?.ascending ?? true
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: ComparisonResult = switch key {
            case .name: a.name.localizedStandardCompare(b.name)
            case .size: compare(a.totalSize, b.totalSize)
            case .packed: compare(a.totalPacked ?? 0, b.totalPacked ?? 0)
            case .ratio: compare(a.savingsPercent ?? -1, b.savingsPercent ?? -1)
            case .modified: compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .kind: a.kindName.localizedStandardCompare(b.kindName)
            }
            if result == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func node(at row: Int) -> ArchiveNode? {
        guard row >= 0, row < rows.count, case .node(let node) = rows[row] else { return nil }
        return node
    }

    private var selectedNodes: [ArchiveNode] {
        tableView.selectedRowIndexes.compactMap { node(at: $0) }
    }

    // MARK: - Aktionen

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .parent: session.goUp()
        case .node(let node): session.open(node)
        }
    }

    private func openSelected() {
        if tableView.selectedRowIndexes.count == 1, let row = tableView.selectedRowIndexes.first,
           row < rows.count, case .parent = rows[row]
        {
            session.goUp()
            return
        }
        let nodes = selectedNodes
        if nodes.count == 1 {
            session.open(nodes[0])
        } else if !nodes.isEmpty {
            Task { await session.openWithDefaultApp(nodes.filter { !$0.isDirectory }) }
        }
    }

    // MARK: - Kontextmenü

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard session.phase == .ready else { return nil }
        let menu = NSMenu()
        let nodes = selectedNodes
        // `target: nil` = über die Responder-Kette an den Fenster-Controller
        func add(_ title: String, _ symbol: String, _ action: Selector, target: AnyObject?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = target
            menu.addItem(item)
        }
        if !nodes.isEmpty {
            add("Öffnen", "arrow.up.forward.app", #selector(menuOpen(_:)), target: self)
            if nodes.contains(where: { !$0.isDirectory }) {
                add("Quick Look", "eye", #selector(menuQuickLook(_:)), target: self)
            }
            menu.addItem(.separator())
            add("Entpacken nach …", "arrow.down.doc", #selector(ArchiveWindowController.extractTo(_:)), target: nil)
            add("Entpacken (Standardziel)", "arrow.down.to.line",
                #selector(ArchiveWindowController.extractDefault(_:)), target: nil)
            menu.addItem(.separator())
            add("Pfad im Archiv kopieren", "doc.on.doc", #selector(copyPaths(_:)), target: self)
            if session.isEditable {
                menu.addItem(.separator())
                if nodes.count == 1 {
                    add("Umbenennen …", "pencil", #selector(ArchiveWindowController.renameSelection(_:)), target: nil)
                }
                add("Aus Archiv löschen", "trash", #selector(ArchiveWindowController.deleteSelection(_:)), target: nil)
            }
        } else {
            add("Alles entpacken nach …", "arrow.down.doc", #selector(ArchiveWindowController.extractTo(_:)), target: nil)
            if session.isEditable {
                menu.addItem(.separator())
                add("Dateien hinzufügen …", "plus", #selector(ArchiveWindowController.addFiles(_:)), target: nil)
                add("Neuer Ordner …", "folder.badge.plus", #selector(ArchiveWindowController.newFolder(_:)), target: nil)
            }
        }
        return menu
    }

    @objc private func menuOpen(_ sender: Any?) { openSelected() }
    @objc private func menuQuickLook(_ sender: Any?) { toggleQuickLook() }

    @objc private func copyPaths(_ sender: Any?) {
        let text = selectedNodes.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let nodes = selectedNodes.filter { !$0.isDirectory }
        guard !nodes.isEmpty else { return }
        Task {
            do {
                previewURLs = try await session.extractToTemporary(nodes)
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            } catch {
                session.ui.presentError(error, title: "Vorschau nicht möglich")
            }
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // Quick Look ruft diese Methoden immer auf dem Main-Thread auf.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

// MARK: - Quick Look Datenquelle

extension BrowserViewController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }
}

// MARK: - Tabelle: Daten & Drag and Drop

extension BrowserViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reload()
    }

    /// Drag in den Finder
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let node = node(at: row) else { return nil }
        if node.containsEncrypted, session.password == nil {
            // Ohne Passwort kann nicht entpackt werden: erst danach fragen, dann erneut ziehen
            Task { await session.requestPassword() }
            return nil
        }
        return promiseDelegate.makeProvider(for: node)
    }

    /// Drop von Dateien zum Hinzufügen
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if (info.draggingSource as AnyObject?) === tableView { return [] }
        let pasteboard = info.draggingPasteboard
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        // File Promises: aus einem anderen ZIPP-Fenster, aus Mail, Fotos …
        let hasPromises = pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        guard session.phase == .ready, hasFiles || hasPromises else { return [] }
        if dropOperation == .on, let target = node(at: row), target.isDirectory {
            return .copy
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        var target: ArchiveNode?
        if dropOperation == .on, let node = node(at: row), node.isDirectory { target = node }
        let pasteboard = info.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty
        {
            Task { await session.add(urls, into: target) }
            return true
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !receivers.isEmpty
        {
            receivePromises(receivers, into: target?.path)
            return true
        }
        return false
    }

    /// Lässt die versprochenen Dateien in einen temporären Ordner schreiben und fügt sie dann hinzu.
    private func receivePromises(_ receivers: [NSFilePromiseReceiver], into targetPath: String?) {
        guard let dir = try? TempStore.makeDirectory() else { return }
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let collector = PromiseCollector(expected: expected) { [weak self] urls, failed in
            Task { @MainActor in
                defer { TempStore.remove(dir) }
                guard let self else { return }
                if urls.isEmpty {
                    if failed {
                        self.session.ui.presentMessage("Hinzufügen fehlgeschlagen", "Die gezogenen Dateien konnten nicht übernommen werden.")
                    }
                    return
                }
                let target = targetPath.flatMap { self.session.root?.find(path: $0) }
                await self.session.add(urls, into: target)
            }
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in
                collector.received(url, failed: error != nil)
            }
        }
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()
}

/// Sammelt die Ergebnisse mehrerer File Promises (Rückrufe kommen auf einem Hintergrund-Thread).
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private var failed = false
    private let done: @Sendable ([URL], Bool) -> Void

    init(expected: Int, done: @escaping @Sendable ([URL], Bool) -> Void) {
        remaining = expected
        self.done = done
    }

    func received(_ url: URL, failed didFail: Bool) {
        let result: ([URL], Bool)? = lock.withLock {
            if didFail { failed = true } else { urls.append(url) }
            remaining -= 1
            return remaining == 0 ? (urls, failed) : nil
        }
        if let result { done(result.0, result.1) }
    }
}

// MARK: - Tabelle: Darstellung

extension BrowserViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let entry = rows[row]

        if column == .ratio {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? RatioCellView ?? {
                let c = RatioCellView()
                c.identifier = id
                return c
            }()
            if case .node(let node) = entry, let percent = node.savingsPercent {
                cell.bar.isHidden = false
                cell.bar.fraction = Double(percent) / 100
                cell.label.stringValue = "\(percent) %"
            } else {
                cell.bar.isHidden = true
                cell.label.stringValue = ""
            }
            return cell
        }

        let cell = textCell(for: column, in: tableView)
        switch entry {
        case .parent:
            if column == .name {
                cell.textField?.stringValue = ".."
                cell.imageView?.image = IconCache.icon(for: .folder)
                cell.imageView?.alphaValue = 0.5
            } else {
                cell.textField?.stringValue = ""
            }
        case .node(let node):
            cell.imageView?.alphaValue = 1
            switch column {
            case .name:
                cell.imageView?.image = IconCache.icon(for: node.contentType)
                cell.textField?.attributedStringValue = nameString(for: node)
            case .size:
                cell.textField?.stringValue = Fmt.size(node.totalSize)
            case .packed:
                cell.textField?.stringValue = node.totalPacked.map(Fmt.size) ?? "–"
            case .modified:
                cell.textField?.stringValue = Fmt.date(node.modified)
            case .kind:
                cell.textField?.stringValue = node.kindName
            case .ratio:
                break
            }
        }
        return cell
    }

    private func nameString(for node: ArchiveNode) -> NSAttributedString {
        let result = NSMutableAttributedString(string: node.name)
        if node.isEncrypted || (node.isDirectory && node.containsEncrypted && node.fileCount == 0) {
            if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "verschlüsselt") {
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                    .applying(.init(paletteColors: [.systemOrange]))
                let attachment = NSTextAttachment()
                attachment.image = lock.withSymbolConfiguration(config)
                result.append(NSAttributedString(string: "  "))
                result.append(NSAttributedString(attachment: attachment))
            }
        }
        if !session.searchText.isEmpty, !node.parentPath.isEmpty {
            result.append(NSAttributedString(
                string: "   in \(node.parentPath)",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        return result
    }

    private func textCell(for column: Column, in tableView: NSTableView) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = column.identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.truncatesLastVisibleLine = true
        cell.addSubview(text)
        cell.textField = text
        if column == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            text.textColor = .secondaryLabelColor
        }
        if column.isNumeric {
            text.alignment = .right
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let nodes = selectedNodes
        if nodes.map(\.path) != session.selection.map(\.path) {
            session.selection = nodes
        }
        // Offene Vorschau folgt der Auswahl (wie im Finder)
        let files = nodes.filter { !$0.isDirectory }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, !files.isEmpty {
            Task {
                guard let urls = try? await session.extractToTemporary(files) else { return }
                previewURLs = urls
                panel.reloadData()
            }
        }
    }
}
