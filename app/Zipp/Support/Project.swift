import Foundation

/// Feste Angaben zum Projekt.
enum Project {
    /// GitHub-Repository („Besitzer/Name“). Wird für die Projektseite und die Update-Prüfung genutzt.
    static let repository = "CasX61/zipp"

    static var homepage: URL { URL(string: "https://github.com/\(repository)")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }
}
