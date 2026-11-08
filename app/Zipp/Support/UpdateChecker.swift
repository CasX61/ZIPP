import AppKit

/// Prüft über die GitHub-API, ob es ein neueres Release gibt.
///
/// Bewusst ohne automatische Installation: ZIPP zeigt nur einen Hinweis mit
/// Link zum DMG. So braucht es kein Update-Framework und keine eigenen Schlüssel.
@MainActor
enum UpdateChecker {
    struct Release: Decodable, Sendable {
        let tagName: String
        let name: String?
        let htmlUrl: URL
        let body: String?
        let prerelease: Bool
        let draft: Bool

        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
    }

    private static let interval: TimeInterval = 24 * 60 * 60

    /// Beim Start: höchstens einmal am Tag, nur wenn eingeschaltet, ohne Fehlermeldungen.
    static func checkAutomaticallyIfDue() {
        guard Preferences.checkForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: Preferences.Key.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > interval else { return }
        Task { await check(userInitiated: false) }
    }

    /// „Nach Updates suchen …“
    static func check(userInitiated: Bool) async {
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Preferences.Key.lastUpdateCheck)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if isNewer(release.version, than: current) {
                showUpdate(release, current: current)
            } else if userInitiated {
                let alert = NSAlert()
                alert.messageText = "ZIPP ist aktuell"
                alert.informativeText = "Version \(current) ist die neueste Version."
                alert.runModal()
            }
        } catch {
            guard userInitiated else { return }
            let alert = NSAlert()
            alert.messageText = "Update-Prüfung fehlgeschlagen"
            alert.informativeText = "GitHub ist gerade nicht erreichbar (\(error.localizedDescription)). Neue Versionen gibt es auch unter \(Project.releasesPage.absoluteString)."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Releases öffnen")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(Project.releasesPage)
            }
        }
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: Project.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ZIPP-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    /// Vergleicht „1.2.10“ mit „1.2.9“ numerisch. Zusätze wie „-beta“ werden ignoriert.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func showUpdate(_ release: Release, current: String) {
        let alert = NSAlert()
        alert.messageText = "ZIPP \(release.version) ist verfügbar"
        var text = "Du verwendest Version \(current)."
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\n\n" + String(notes.prefix(600)) + (notes.count > 600 ? " …" : "")
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Herunterladen")
        alert.addButton(withTitle: "Später")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlUrl)
        }
    }
}
