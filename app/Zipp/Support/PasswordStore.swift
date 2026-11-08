import Foundation
import Security

/// Archiv-Passwörter im macOS-Schlüsselbund (pro Archivpfad).
enum PasswordStore {
    private static let service = "ZIPP – Archiv-Passwörter"

    private static func query(for url: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url.standardizedFileURL.path,
        ]
    }

    static func save(_ password: String, for url: URL) {
        let data = Data(password.utf8)
        let base = query(for: url)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ZIPP: \(url.lastPathComponent)"
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func load(for url: URL) -> String? {
        var q = query(for: url)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(for url: URL) {
        SecItemDelete(query(for: url) as CFDictionary)
    }

    // MARK: - Passwort-Liste

    /// Passwörter, die ZIPP bei verschlüsselten Archiven automatisch ausprobiert
    /// (wie WinRARs „Passwörter verwalten“). Ein Eintrag im Schlüsselbund, als JSON.
    private static var listQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZIPP – Passwort-Liste",
            kSecAttrAccount as String: "liste",
        ]
    }

    static func savedList() -> [String] {
        var q = listQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    static func saveList(_ list: [String]) {
        var unique: [String] = []
        for pw in list where !pw.isEmpty && !unique.contains(pw) { unique.append(pw) }
        guard !unique.isEmpty, let data = try? JSONEncoder().encode(unique) else {
            SecItemDelete(listQuery as CFDictionary)
            return
        }
        let status = SecItemUpdate(listQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = listQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ZIPP: Passwort-Liste"
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
