import Foundation
import UniformTypeIdentifiers
import ZippCore

/// Dateiendungen und Namenslogik für Archive.
enum ArchiveTypes {
    /// Mehrteilige Endungen zuerst prüfen.
    static let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"]

    static let extensions = [
        "zip", "zipx", "7z", "rar", "tar", "gz", "gzip", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "zst", "zstd", "tzst",
    ]

    /// Typen für den Öffnen-Dialog.
    static var openableTypes: [UTType] {
        var types: [UTType] = [.archive, .zip]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    /// Sieht der Name nach einem Archiv aus? (Die echte Erkennung macht der Rust-Kern.)
    /// Auch Teile mehrteiliger Archive: `.7z.001`, `.part2.rar`, `.r00`.
    static func isLikelyArchive(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        if compoundExtensions.contains(where: { lower.hasSuffix($0) }) {
            return true
        }
        if lower.range(of: #"\.(\d{3,}|r\d{2})$"#, options: .regularExpression) != nil {
            return true
        }
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// Name ohne Teilnummer: „Fotos.7z.002“ → „Fotos.7z“, „Film.part2.rar“ → „Film.rar“.
    static func logicalName(of url: URL) -> String {
        archiveLogicalName(path: url.path)
    }

    /// Erster Teil eines mehrteiligen Archivs (sonst die URL selbst).
    static func firstVolume(of url: URL) -> URL {
        URL(fileURLWithPath: ZippCore.firstVolume(path: url.path)).standardizedFileURL
    }

    /// „Projekt.tar.gz“ → „Projekt“, „Setup.part1.rar“ → „Setup“, „Fotos.7z.001“ → „Fotos“.
    static func baseName(of url: URL) -> String {
        let logical = url.deletingLastPathComponent().appendingPathComponent(logicalName(of: url))
        var name = logical.lastPathComponent
        let lower = name.lowercased()
        if let compound = compoundExtensions.first(where: { lower.hasSuffix($0) }) {
            name.removeLast(compound.count)
        } else if extensions.contains(logical.pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        if let range = name.range(of: #"\.part0*1$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.isEmpty ? "Archiv" : name
    }
}

enum FileNaming {
    /// Freier Name für ein neues Archiv. Bei aufgeteilten Archiven darf auch
    /// „Name.ext.001“ noch nicht existieren.
    static func uniqueArchiveURL(folder: URL, name: String, ext: String, split: Bool) -> URL {
        let fm = FileManager.default
        func isFree(_ url: URL) -> Bool {
            !fm.fileExists(atPath: url.path) && !(split && fm.fileExists(atPath: url.path + ".001"))
        }
        var candidate = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while !isFree(candidate) {
            candidate = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Erster freier Name: „Name.zip“, „Name 2.zip“, „Name 3.zip“ …
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let lower = name.lowercased()
        var stem = name
        var ext = ""
        if let compound = ArchiveTypes.compoundExtensions.first(where: { lower.hasSuffix($0) }) {
            stem = String(name.dropLast(compound.count))
            ext = String(name.suffix(compound.count))
        } else if !url.pathExtension.isEmpty, !url.hasDirectoryPath {
            stem = (name as NSString).deletingPathExtension
            ext = "." + url.pathExtension
        }
        var n = 2
        while true {
            let candidate = parent.appendingPathComponent("\(stem) \(n)\(ext)", isDirectory: url.hasDirectoryPath)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
}
