import AppKit
import UniformTypeIdentifiers

/// Formatierung für die Anzeige (nur auf dem Main-Thread benutzen).
@MainActor
enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func size(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "–" }
        return dateFormatter.string(from: date)
    }

    static func count(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func files(_ n: Int) -> String {
        n == 1 ? "1 Datei" : "\(count(n)) Dateien"
    }

    static func objects(_ n: Int) -> String {
        n == 1 ? "1 Objekt" : "\(count(n)) Objekte"
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "noch \(max(1, Int(seconds.rounded()))) s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "noch \(minutes) min" : "noch \(minutes / 60) h \(minutes % 60) min"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        size(UInt64(max(0, bytesPerSecond))) + "/s"
    }
}

/// Icons aus dem System (wie im Finder), zwischengespeichert pro Typ.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for type: UTType) -> NSImage {
        if let cached = cache[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }

    static func archiveIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    static func kindName(for type: UTType) -> String {
        type.localizedDescription ?? type.preferredFilenameExtension?.uppercased() ?? "Dokument"
    }
}
