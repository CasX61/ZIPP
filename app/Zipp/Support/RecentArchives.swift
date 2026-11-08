import AppKit
import Observation

/// „Zuletzt geöffnet“ – für Seitenleiste, Willkommen-Fenster und Menü.
@MainActor
@Observable
final class RecentArchives {
    static let shared = RecentArchives()

    private static let key = "recentArchives"
    private static let limit = 12

    private(set) var urls: [URL]

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        let url = url.standardizedFileURL
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > Self.limit { urls.removeLast(urls.count - Self.limit) }
        save()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Nur Einträge, die es noch gibt.
    var existing: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clear() {
        urls = []
        save()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.key)
    }
}
