import Foundation
import UniformTypeIdentifiers
import ZippCore

/// Ein Knoten im Archivbaum (Ordner oder Datei).
///
/// Wird einmal im Hintergrund aus der flachen Liste des Kerns gebaut und danach
/// nur noch gelesen. Deshalb `@unchecked Sendable`. Nach Änderungen am Archiv
/// wird ein neuer Baum gebaut.
final class ArchiveNode: Identifiable, Hashable, @unchecked Sendable {
    let name: String
    /// Vollständiger Pfad im Archiv ("" = Wurzel)
    let path: String
    let isDirectory: Bool

    private(set) var isSymlink = false
    private(set) var size: UInt64 = 0
    private(set) var packedSize: UInt64?
    private(set) var crc32: UInt32?
    private(set) var modified: Date?
    private(set) var isEncrypted = false
    private(set) var method: String?
    private(set) var children: [ArchiveNode] = []
    /// Nur die Unterordner, sortiert (für die Seitenleiste)
    private(set) var folders: [ArchiveNode] = []
    private(set) weak var parent: ArchiveNode?

    // Summen, bei Ordnern rekursiv
    private(set) var totalSize: UInt64 = 0
    private(set) var totalPacked: UInt64?
    private(set) var fileCount = 0
    private(set) var containsEncrypted = false

    /// Nur auf dem Main-Thread benutzen (Zwischenspeicher für Sortierung/Anzeige).
    private var cachedKindName: String?

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    static func == (lhs: ArchiveNode, rhs: ArchiveNode) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var isRoot: Bool { parent == nil }

    /// Pfad des übergeordneten Ordners ("" auf oberster Ebene)
    var parentPath: String { parent?.path ?? "" }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var contentType: UTType {
        if isDirectory { return .folder }
        if isSymlink { return .symbolicLink }
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    /// Für Ordner: Unterordner oder `nil` (für `OutlineGroup`)
    var outlineChildren: [ArchiveNode]? { folders.isEmpty ? nil : folders }

    /// Ersparnis in Prozent (gepackt im Verhältnis zu entpackt)
    var savingsPercent: Int? {
        guard totalSize > 0, let packed = totalPacked else { return nil }
        return max(0, Int(((1 - Double(packed) / Double(totalSize)) * 100).rounded()))
    }

    /// Wurzel … self
    var ancestors: [ArchiveNode] {
        var chain: [ArchiveNode] = []
        var node: ArchiveNode? = self
        while let n = node {
            chain.insert(n, at: 0)
            node = n.parent
        }
        return chain
    }

    @MainActor
    var kindName: String {
        if let cachedKindName { return cachedKindName }
        let name = isDirectory ? "Ordner" : IconCache.kindName(for: contentType)
        cachedKindName = name
        return name
    }

    func find(path: String) -> ArchiveNode? {
        if path.isEmpty { return self }
        var node = self
        for part in path.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// Rekursive Suche nach Namen (für das Suchfeld).
    func descendants(matching query: String, limit: Int) -> [ArchiveNode] {
        var result: [ArchiveNode] = []
        var stack = children.reversed() as [ArchiveNode]
        while let node = stack.popLast(), result.count < limit {
            if node.name.localizedStandardContains(query) {
                result.append(node)
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    // MARK: - Aufbau

    /// Baut den Baum aus der flachen Liste. Fehlende Ordner werden ergänzt.
    static func buildTree(from entries: [ArchiveEntry], rootName: String) -> ArchiveNode {
        let root = ArchiveNode(name: rootName, path: "", isDirectory: true)
        var directories: [String: ArchiveNode] = ["": root]

        func directory(for path: String) -> ArchiveNode {
            if let existing = directories[path] { return existing }
            let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
            let parent = directory(for: parentPath)
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let node = ArchiveNode(name: name, path: path, isDirectory: true)
            node.parent = parent
            parent.children.append(node)
            directories[path] = node
            return node
        }

        for entry in entries {
            let node: ArchiveNode
            if entry.isDir {
                node = directory(for: entry.path)
            } else {
                let parentPath = entry.path.split(separator: "/").dropLast().joined(separator: "/")
                let parent = directory(for: parentPath)
                let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
                node = ArchiveNode(name: name, path: entry.path, isDirectory: false)
                node.parent = parent
                parent.children.append(node)
                node.size = entry.size
                node.packedSize = entry.packedSize
                node.crc32 = entry.crc32
                node.isSymlink = entry.isSymlink
                node.method = entry.method
            }
            node.isEncrypted = entry.encrypted
            if let modified = entry.modified {
                node.modified = Date(timeIntervalSince1970: TimeInterval(modified))
            }
        }
        root.finish()
        return root
    }

    /// Summen berechnen und sortieren (rekursiv, ohne tiefe Rekursion des Aufrufstapels).
    private func finish() {
        // Post-Order über einen expliziten Stapel
        var order: [ArchiveNode] = []
        var stack: [ArchiveNode] = [self]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.children.filter(\.isDirectory))
        }
        for node in order.reversed() {
            node.children.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            node.folders = node.children.filter(\.isDirectory)
            var total: UInt64 = 0
            var packed: UInt64? = 0
            var files = 0
            var encrypted = false
            var latest: Date?
            for child in node.children {
                if child.isDirectory {
                    total &+= child.totalSize
                    files += child.fileCount
                    encrypted = encrypted || child.containsEncrypted
                    if let p = packed, let cp = child.totalPacked { packed = p &+ cp } else { packed = nil }
                } else {
                    total &+= child.size
                    files += 1
                    encrypted = encrypted || child.isEncrypted
                    if let p = packed, let cp = child.packedSize { packed = p &+ cp } else { packed = nil }
                    child.totalSize = child.size
                    child.totalPacked = child.packedSize
                    child.fileCount = 1
                    child.containsEncrypted = child.isEncrypted
                }
                if let m = child.modified, m > (latest ?? .distantPast) { latest = m }
            }
            node.totalSize = total
            node.totalPacked = packed
            node.fileCount = files
            node.containsEncrypted = encrypted || node.isEncrypted
            if node.modified == nil { node.modified = latest }
        }
    }
}
