import Foundation

/// Temporäre Ordner für Quick Look und „Öffnen mit“.
enum TempStore {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZIPP-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func makeDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Reste früherer Programmläufe (z. B. nach Absturz) entfernen.
    static func cleanupStale() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        else { return }
        for item in items where item.lastPathComponent.hasPrefix("ZIPP-") && item != root {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
