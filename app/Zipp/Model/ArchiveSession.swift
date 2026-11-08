import AppKit
import Observation
import ZippCore

/// Optionen für einen Entpack-Vorgang.
struct ExtractRequest {
    /// Leer = ganzes Archiv
    var nodes: [ArchiveNode]
    var baseFolder: URL
    var folderMode: FolderMode
    var overwrite: OverwriteChoice
    var revealAfter: Bool
    var trashArchiveAfter: Bool
}

/// Ein geöffnetes Archiv in einem Fenster: Inhalt, Navigation, Auswahl und Aktionen.
@MainActor
@Observable
final class ArchiveSession {
    enum Phase: Equatable {
        case loading
        case locked(wrongPassword: Bool)
        case ready
        case failed(String)
    }

    let url: URL
    let ui: WindowState

    private(set) var phase: Phase = .loading
    private(set) var listing: ArchiveListing?
    private(set) var root: ArchiveNode?
    private(set) var currentFolder: ArchiveNode?
    private(set) var password: String?
    /// Erhöht sich, wenn die Tabelle neu geladen werden muss.
    private(set) var contentVersion = 0

    var selection: [ArchiveNode] = []
    var searchText = "" {
        didSet {
            if searchText != oldValue { selection = []; contentVersion += 1 }
        }
    }

    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var forwardStack: [String] = []
    @ObservationIgnored private var tempDirectories: [URL] = []
    /// Die gespeicherte Passwort-Liste wird pro Archiv nur einmal durchprobiert.
    @ObservationIgnored private var triedPasswordList = false
    private(set) var historyVersion = 0

    init(url: URL, ui: WindowState) {
        self.url = url
        self.ui = ui
    }

    /// Name ohne Teilnummer („Fotos.7z“ statt „Fotos.7z.001“).
    var displayName: String { ArchiveTypes.logicalName(of: url) }
    var isEditable: Bool { listing?.supportsEditing == true }
    var canGoBack: Bool { phase == .ready && !backStack.isEmpty }
    var canGoForward: Bool { phase == .ready && !forwardStack.isEmpty }
    var canGoUp: Bool { phase == .ready && searchText.isEmpty && currentFolder?.parent != nil }

    var visibleItems: [ArchiveNode] {
        guard let folder = currentFolder, let root else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? folder.children : root.descendants(matching: query, limit: 10_000)
    }

    // MARK: - Laden

    /// Liest das Inhaltsverzeichnis. Fragt bei Bedarf nach dem Passwort.
    func load() async {
        if root == nil { phase = .loading }
        var candidate = password ?? PasswordStore.load(for: url)
        var fromKeychain = password == nil && candidate != nil
        var wrong = false
        while true {
            do {
                let path = url.path
                let pw = candidate
                let name = url.lastPathComponent
                let (listing, tree) = try await Task.detached(priority: .userInitiated) {
                    let listing = try listArchive(path: path, password: pw)
                    return (listing, ArchiveNode.buildTree(from: listing.entries, rootName: name))
                }.value
                apply(listing: listing, root: tree, password: pw)
                return
            } catch ZippError.PasswordRequired, ZippError.WrongPassword {
                if fromKeychain {
                    // Gespeichertes Passwort passt nicht mehr
                    PasswordStore.remove(for: url)
                    fromKeychain = false
                }
                if let fromList = await passwordFromList() {
                    candidate = fromList
                    continue
                }
                wrong = candidate != nil || wrong
                guard let answer = await ui.passwordProvider?(displayName, wrong) else {
                    phase = .locked(wrongPassword: wrong)
                    return
                }
                candidate = answer.password
                if answer.remember { PasswordStore.save(answer.password, for: url) }
                wrong = true
            } catch {
                phase = .failed(ErrorText.describe(error))
                return
            }
        }
    }

    private func apply(listing: ArchiveListing, root: ArchiveNode, password: String?) {
        let previousFolder = currentFolder?.path
        let previousSelection = Set(selection.map(\.path))
        self.listing = listing
        self.root = root
        self.password = password
        currentFolder = previousFolder.flatMap { root.find(path: $0) } ?? root
        backStack = backStack.filter { root.find(path: $0) != nil }
        forwardStack = forwardStack.filter { root.find(path: $0) != nil }
        selection = (currentFolder?.children ?? []).filter { previousSelection.contains($0.path) }
        phase = .ready
        contentVersion += 1
        historyVersion += 1
    }

    /// Ruft eine Operation auf und fragt bei Bedarf (erneut) nach dem Passwort.
    func withPassword<T>(_ operation: (String?) async throws -> T) async throws -> T {
        var wrong = false
        while true {
            do {
                return try await operation(password)
            } catch let error as ZippError where error == .PasswordRequired || error == .WrongPassword {
                if let fromList = await passwordFromList() {
                    password = fromList
                    continue
                }
                wrong = wrong || error == .WrongPassword || password != nil
                guard let answer = await ui.passwordProvider?(displayName, wrong) else {
                    throw ZippError.Cancelled
                }
                password = answer.password
                if answer.remember { PasswordStore.save(answer.password, for: url) }
                wrong = true
            }
        }
    }

    /// Fragt nach dem Passwort, z. B. bevor verschlüsselte Dateien herausgezogen werden.
    @discardableResult
    func requestPassword() async -> Bool {
        if let fromList = await passwordFromList() {
            password = fromList
            return true
        }
        guard let answer = await ui.passwordProvider?(displayName, false) else { return false }
        password = answer.password
        if answer.remember { PasswordStore.save(answer.password, for: url) }
        return true
    }

    /// Probiert die gespeicherte Passwort-Liste (einmal pro Archiv).
    private func passwordFromList() async -> String? {
        guard !triedPasswordList else { return nil }
        triedPasswordList = true
        let list = PasswordStore.savedList()
        guard !list.isEmpty else { return nil }
        let path = url.path
        return await Task.detached(priority: .userInitiated) {
            list.first { (try? checkPassword(path: path, password: $0)) == true }
        }.value
    }

    // MARK: - Navigation

    func navigate(to node: ArchiveNode, recordHistory: Bool = true) {
        guard node.isDirectory, node !== currentFolder || !searchText.isEmpty else { return }
        if recordHistory, let current = currentFolder {
            backStack.append(current.path)
            forwardStack.removeAll()
        }
        currentFolder = node
        selection = []
        if !searchText.isEmpty { searchText = "" }
        contentVersion += 1
        historyVersion += 1
    }

    func goBack() {
        guard let path = backStack.popLast(), let node = root?.find(path: path) else { return }
        if let current = currentFolder { forwardStack.append(current.path) }
        navigate(to: node, recordHistory: false)
    }

    func goForward() {
        guard let path = forwardStack.popLast(), let node = root?.find(path: path) else { return }
        if let current = currentFolder { backStack.append(current.path) }
        navigate(to: node, recordHistory: false)
    }

    func goUp() {
        guard let parent = currentFolder?.parent else { return }
        let child = currentFolder
        navigate(to: parent)
        if let child { selection = [child] }
    }

    /// Doppelklick: Ordner öffnen, Datei mit der Standard-App öffnen.
    func open(_ node: ArchiveNode) {
        if node.isDirectory {
            navigate(to: node)
        } else {
            Task { await openWithDefaultApp([node]) }
        }
    }

    // MARK: - Entpacken

    /// Gemeinsamer Elternpfad (für das Herausziehen einzelner Einträge).
    private func commonParentPath(of nodes: [ArchiveNode]) -> String? {
        let parents = Set(nodes.map(\.parentPath))
        guard parents.count == 1, let parent = parents.first, !parent.isEmpty else { return nil }
        return parent
    }

    /// Braucht es einen eigenen Ordner?
    func needsOwnFolder(for nodes: [ArchiveNode], mode: FolderMode) -> Bool {
        switch mode {
        case .always: return true
        case .never: return false
        case .automatic:
            guard nodes.isEmpty, let listing else { return false }
            return listing.singleRootFolder == nil && listing.topLevelCount > 1
        }
    }

    /// Wohin genau entpackt wird (für die Vorschau im Dialog).
    func destination(for nodes: [ArchiveNode], base: URL, mode: FolderMode) -> URL {
        if needsOwnFolder(for: nodes, mode: mode) {
            return FileNaming.uniqueURL(base.appendingPathComponent(ArchiveTypes.baseName(of: url), isDirectory: true))
        }
        return base
    }

    /// Wo der Inhalt landet (für die Anzeige „Ergebnis“): bei einem einzelnen
    /// Wurzelordner dessen Pfad, sonst der Zielordner.
    func resultPreview(for nodes: [ArchiveNode], base: URL, mode: FolderMode) -> URL {
        let target = destination(for: nodes, base: base, mode: mode)
        if target == base, nodes.isEmpty, let root = listing?.singleRootFolder {
            return base.appendingPathComponent(root, isDirectory: true)
        }
        if target == base, nodes.count == 1 {
            return base.appendingPathComponent(nodes[0].name, isDirectory: nodes[0].isDirectory)
        }
        return target
    }

    @discardableResult
    func extract(_ request: ExtractRequest) async -> URL? {
        guard let listing else { return nil }
        let nodes = request.nodes
        let whole = nodes.isEmpty
        let destination = destination(for: nodes, base: request.baseFolder, mode: request.folderMode)
        let required = whole ? listing.totalSize : nodes.reduce(0) { $0 &+ $1.totalSize }

        // Genug Platz?
        if let free = try? request.baseFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
            free > 0, required > UInt64(free)
        {
            ui.presentMessage(
                "Nicht genug Speicherplatz",
                "Zum Entpacken werden \(Fmt.size(required)) benötigt, frei sind nur \(Fmt.size(UInt64(free)))."
            )
            return nil
        }
        // Verdacht auf Zip-Bombe?
        if listing.archiveSize > 0, required > 1_000_000_000, required / max(listing.archiveSize, 1) > 1000 {
            let ok = await ui.confirm(
                "Ungewöhnlich hohe Kompression",
                "Das Archiv ist \(Fmt.size(listing.archiveSize)) groß, entpackt aber \(Fmt.size(required)). Das kann eine „Zip-Bombe“ sein. Trotzdem entpacken?",
                confirm: "Trotzdem entpacken"
            )
            guard ok else { return nil }
        }

        let path = url.path
        let dest = destination.path
        let selection = nodes.map(\.path)
        let strip = whole ? nil : commonParentPath(of: nodes)
        let overwrite: OverwritePolicy = switch request.overwrite {
        case .replace: .replace
        case .skip: .skip
        case .keepBoth: .keepBoth
        }
        let fileCount = whole ? Int(listing.entries.filter { !$0.isDir }.count) : nodes.reduce(0) { $0 + $1.fileCount }

        do {
            let summary = try await withPassword { pw in
                try await ui.runJob(title: "Entpacke \(Fmt.files(fileCount)) …", symbol: "arrow.down.doc") { relay in
                    try extractArchive(
                        path: path,
                        destination: dest,
                        options: ExtractOptions(
                            password: pw, selection: selection, stripPrefix: strip,
                            overwrite: overwrite, applyQuarantine: true
                        ),
                        progress: relay
                    )
                }
            }
            let revealTargets = revealTargets(nodes: nodes, base: request.baseFolder, destination: destination)
            var toast = Toast(message: "Entpackt nach „\(destination.lastPathComponent)“")
            if !summary.skippedUnsafe.isEmpty {
                toast = Toast(
                    message: "Entpackt. \(summary.skippedUnsafe.count) unsichere Einträge wurden übersprungen.",
                    style: .warning
                )
            }
            toast.actionTitle = "Im Finder zeigen"
            toast.action = { NSWorkspace.shared.activateFileViewerSelecting(revealTargets) }
            ui.show(toast)
            if request.revealAfter {
                NSWorkspace.shared.activateFileViewerSelecting(revealTargets)
            }
            if request.trashArchiveAfter {
                // Bei mehrteiligen Archiven alle Teile
                let volumes = archiveVolumes(path: url.path).map { URL(fileURLWithPath: $0) }
                NSWorkspace.shared.recycle(volumes) { [ui] _, error in
                    Task { @MainActor in
                        if let error { ui.presentError(error) } else { ui.closeWindow?() }
                    }
                }
            }
            return destination
        } catch {
            ui.presentError(error, title: "Entpacken fehlgeschlagen")
            return nil
        }
    }

    private func revealTargets(nodes: [ArchiveNode], base: URL, destination: URL) -> [URL] {
        if destination != base { return [destination] }
        if nodes.isEmpty {
            if let root = listing?.singleRootFolder { return [base.appendingPathComponent(root)] }
            return [base]
        }
        let targets = nodes.map { base.appendingPathComponent($0.name) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return targets.isEmpty ? [base] : targets
    }

    /// Entpackt in einen temporären Ordner (für Quick Look und „Öffnen“).
    func extractToTemporary(_ nodes: [ArchiveNode]) async throws -> [URL] {
        let dir = try TempStore.makeDirectory()
        tempDirectories.append(dir)
        let path = url.path
        let selection = nodes.map(\.path)
        let strip = commonParentPath(of: nodes)
        let big = nodes.reduce(0) { $0 &+ $1.totalSize } > 20_000_000
        _ = try await withPassword { pw in
            try await ui.runJob(title: "Bereite Vorschau vor …", symbol: "eye", showsProgress: big) { relay in
                try extractArchive(
                    path: path,
                    destination: dir.path,
                    options: ExtractOptions(
                        password: pw, selection: selection, stripPrefix: strip,
                        overwrite: .replace, applyQuarantine: true
                    ),
                    progress: relay
                )
            }
        }
        return nodes.map { dir.appendingPathComponent(strip == nil ? $0.path : $0.name) }
    }

    func openWithDefaultApp(_ nodes: [ArchiveNode]) async {
        do {
            let urls = try await extractToTemporary(nodes)
            for url in urls { NSWorkspace.shared.open(url) }
        } catch {
            ui.presentError(error, title: "Öffnen fehlgeschlagen")
        }
    }

    // MARK: - Testen

    func test() async {
        let path = url.path
        do {
            let summary = try await withPassword { pw in
                try await ui.runJob(title: "Teste \(displayName) …", symbol: "checkmark.shield") { relay in
                    try testArchive(path: path, password: pw, progress: relay)
                }
            }
            ui.show(Toast(message: "Keine Fehler gefunden · \(Fmt.files(Int(summary.files))) geprüft"))
        } catch {
            ui.presentError(error, title: "Das Archiv ist fehlerhaft")
        }
    }

    // MARK: - Bearbeiten

    /// ZIP wird direkt geändert, 7z und TAR.* werden neu geschrieben; RAR und
    /// mehrteilige Archive sind nur lesbar.
    private func ensureEditable(_ action: String) -> Bool {
        guard let listing else { return false }
        if listing.supportsEditing { return true }
        var reason: String
        if listing.volumeCount > 1 {
            reason = "Mehrteilige Archive kann ZIPP nur lesen und entpacken."
        } else {
            reason = "\(listing.formatLabel)-Archive kann ZIPP nur lesen und entpacken."
        }
        if listing.format == .rar {
            reason += " RAR-Archive zu verändern ist aus Lizenzgründen nicht möglich."
        }
        reason += " Tipp: Mit „Konvertieren …“ (Menü „Archiv“) wird daraus ein ZIP oder 7z, das sich bearbeiten lässt."
        ui.presentMessage("\(action) nicht möglich", reason)
        return false
    }

    /// Bei 7z und TAR.* wird das ganze Archiv neu geschrieben, das soll man sehen.
    private func editTitle(_ base: String) -> String {
        listing?.editRewritesAll == true ? "\(base) (Archiv wird neu geschrieben) …" : "\(base) …"
    }

    /// Nach einer Bearbeitung neu laden und `path` auswählen.
    private func reload(selecting path: String?) async {
        await load()
        guard let path, let node = root?.find(path: path) else { return }
        if let parent = node.parent, parent !== currentFolder, searchText.isEmpty {
            navigate(to: parent)
        }
        selection = [node]
        contentVersion += 1
    }

    func add(_ urls: [URL], into folder: ArchiveNode?) async {
        guard let listing, ensureEditable("Hinzufügen") else { return }
        let path = url.path
        let inner = (folder ?? currentFolder)?.path ?? ""
        let sources = urls.map(\.path)
        let level = CompressionLevel.value(forIndex: Preferences.compressionLevelIndex)
        let exclude = Preferences.excludeMacFiles
        // ZIP: Ist das Archiv verschlüsselt und das Passwort bekannt, werden neue Dateien ebenso geschützt.
        // 7z: Das Passwort wird zum Neuschreiben gebraucht (ohne fragt der Kern danach).
        let encrypted = listing.hasEncryptedEntries
        let title = editTitle("Füge \(Fmt.objects(urls.count)) hinzu")
        do {
            _ = try await withPassword { pw in
                let addPassword = encrypted ? pw : nil
                return try await ui.runJob(title: title, symbol: "plus") { relay in
                    try addToArchive(
                        path: path, sources: sources, innerDir: inner,
                        options: AddOptions(level: level, password: addPassword, excludeMacMetadata: exclude),
                        progress: relay
                    )
                }
            }
            let firstName = urls.count == 1 ? urls[0].lastPathComponent : nil
            await reload(selecting: firstName.map { inner.isEmpty ? $0 : "\(inner)/\($0)" })
            ui.show(Toast(message: "\(Fmt.objects(urls.count)) hinzugefügt"))
        } catch {
            ui.presentError(error, title: "Hinzufügen fehlgeschlagen")
        }
    }

    func delete(_ nodes: [ArchiveNode]) async {
        guard !nodes.isEmpty, ensureEditable("Löschen") else { return }
        let title = nodes.count == 1 ? "„\(nodes[0].name)“ aus dem Archiv löschen?" : "\(Fmt.objects(nodes.count)) aus dem Archiv löschen?"
        guard await ui.confirm(title, "Das lässt sich nicht widerrufen.", confirm: "Löschen") else { return }
        let path = url.path
        let paths = nodes.map(\.path)
        let jobTitle = editTitle("Lösche")
        do {
            _ = try await withPassword { pw in
                try await ui.runJob(title: jobTitle, symbol: "trash") { relay in
                    try deleteFromArchive(path: path, paths: paths, password: pw, progress: relay)
                }
            }
            selection = []
            await load()
            ui.show(Toast(message: "\(Fmt.objects(nodes.count)) gelöscht"))
        } catch {
            ui.presentError(error, title: "Löschen fehlgeschlagen")
        }
    }

    func rename(_ node: ArchiveNode, to newName: String) async {
        guard newName != node.name, ensureEditable("Umbenennen") else { return }
        let path = url.path
        let entry = node.path
        let title = editTitle("Benenne „\(node.name)“ um")
        do {
            let newPath = try await withPassword { pw in
                try await ui.runJob(title: title, symbol: "pencil") { relay in
                    try renameInArchive(path: path, entry: entry, newName: newName, password: pw, progress: relay)
                }
            }
            await reload(selecting: newPath)
        } catch {
            ui.presentError(error, title: "Umbenennen fehlgeschlagen")
        }
    }

    /// „Neuer Ordner“, „Neuer Ordner 2“ … (erster freier Name im aktuellen Ordner).
    func suggestedFolderName() -> String {
        let taken = Set((currentFolder?.children ?? []).map { $0.name.lowercased() })
        var name = "Neuer Ordner"
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "Neuer Ordner \(n)"
            n += 1
        }
        return name
    }

    func createFolder(named name: String) async {
        guard ensureEditable("Neuer Ordner") else { return }
        let path = url.path
        let inner = currentFolder?.path ?? ""
        let title = editTitle("Lege „\(name)“ an")
        do {
            let newPath = try await withPassword { pw in
                try await ui.runJob(title: title, symbol: "folder.badge.plus") { relay in
                    try createFolderInArchive(path: path, innerDir: inner, name: name, password: pw, progress: relay)
                }
            }
            await reload(selecting: newPath)
        } catch {
            ui.presentError(error, title: "Ordner anlegen fehlgeschlagen")
        }
    }

    // MARK: - Konvertieren

    func convert(_ request: CompressRequest) async {
        let ext = createFormatExtension(format: request.format)
        let dest = FileNaming.uniqueArchiveURL(
            folder: request.folder, name: request.name, ext: ext, split: request.volumeSize != nil
        )
        let path = url.path
        let destPath = dest.path
        let options = request.options
        do {
            let summary = try await withPassword { pw in
                try await ui.runJob(title: "Konvertiere in \(request.format.title) …", symbol: "arrow.triangle.2.circlepath") { relay in
                    try convertArchive(path: path, password: pw, destination: destPath, options: options, progress: relay)
                }
            }
            ui.announceCreated(summary)
            if request.trashOriginals {
                let volumes = archiveVolumes(path: url.path).map { URL(fileURLWithPath: $0) }
                NSWorkspace.shared.recycle(volumes) { [ui] _, error in
                    Task { @MainActor in
                        if let error { ui.presentError(error) } else { ui.closeWindow?() }
                    }
                }
            }
        } catch {
            ui.presentError(error, title: "Konvertieren fehlgeschlagen")
        }
    }

    // MARK: - Aufräumen

    func cleanup() {
        for dir in tempDirectories { TempStore.remove(dir) }
        tempDirectories.removeAll()
    }
}
