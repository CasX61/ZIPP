import Foundation

/// Wohin „Entpacken“ (⌘E) ohne Nachfrage entpackt.
enum ExtractDestination: String, CaseIterable, Identifiable {
    case besideArchive, downloads, desktop, ask
    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideArchive: "Neben dem Archiv"
        case .downloads: "Downloads"
        case .desktop: "Schreibtisch"
        case .ask: "Jedes Mal fragen"
        }
    }

    func folder(for archive: URL) -> URL? {
        let fm = FileManager.default
        switch self {
        case .besideArchive: return archive.deletingLastPathComponent()
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .ask: return nil
        }
    }
}

/// Soll beim Entpacken ein eigener Ordner angelegt werden?
enum FolderMode: String, CaseIterable, Identifiable {
    /// Nur wenn das Archiv mehrere Objekte auf oberster Ebene hat
    case automatic
    case always
    case never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatisch"
        case .always: "Immer"
        case .never: "Nie"
        }
    }
}

/// Verhalten bei vorhandenen Dateien (App-Seite, wird auf den Kern abgebildet).
enum OverwriteChoice: String, CaseIterable, Identifiable {
    case keepBoth, replace, skip
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: "Beide behalten"
        case .replace: "Ersetzen"
        case .skip: "Überspringen"
        }
    }
}

/// Persistente Einstellungen (UserDefaults). Die Schlüssel nutzt auch `SettingsView` per `@AppStorage`.
enum Preferences {
    enum Key {
        static let extractDestination = "extractDestination"
        static let folderMode = "folderMode"
        static let overwrite = "overwrite"
        static let revealAfterExtract = "revealAfterExtract"
        static let trashAfterExtract = "trashAfterExtract"
        static let createFormat = "createFormat"
        static let compressionLevel = "compressionLevel"
        static let excludeMacFiles = "excludeMacFiles"
        static let revealAfterCreate = "revealAfterCreate"
        static let checkForUpdates = "checkForUpdates"
        static let appearance = "appearance"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.extractDestination: ExtractDestination.besideArchive.rawValue,
            Key.folderMode: FolderMode.automatic.rawValue,
            Key.overwrite: OverwriteChoice.keepBoth.rawValue,
            Key.revealAfterExtract: true,
            Key.trashAfterExtract: false,
            Key.createFormat: "zip",
            Key.compressionLevel: 2,
            Key.excludeMacFiles: true,
            Key.revealAfterCreate: true,
            Key.checkForUpdates: true,
            Key.appearance: AppAppearance.system.rawValue,
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var extractDestination: ExtractDestination {
        ExtractDestination(rawValue: defaults.string(forKey: Key.extractDestination) ?? "") ?? .besideArchive
    }

    static var folderMode: FolderMode {
        FolderMode(rawValue: defaults.string(forKey: Key.folderMode) ?? "") ?? .automatic
    }

    static var overwrite: OverwriteChoice {
        OverwriteChoice(rawValue: defaults.string(forKey: Key.overwrite) ?? "") ?? .keepBoth
    }

    static var revealAfterExtract: Bool { defaults.bool(forKey: Key.revealAfterExtract) }
    static var trashAfterExtract: Bool { defaults.bool(forKey: Key.trashAfterExtract) }
    static var createFormatID: String { defaults.string(forKey: Key.createFormat) ?? "zip" }
    /// Index 0…4 (Speichern, Schnell, Normal, Gut, Maximal)
    static var compressionLevelIndex: Int { min(4, max(0, defaults.integer(forKey: Key.compressionLevel))) }
    static var excludeMacFiles: Bool { defaults.bool(forKey: Key.excludeMacFiles) }
    static var revealAfterCreate: Bool { defaults.bool(forKey: Key.revealAfterCreate) }
    static var checkForUpdates: Bool { defaults.bool(forKey: Key.checkForUpdates) }
}

/// Aufteilen in Teile beim Erstellen.
enum VolumeChoice: String, CaseIterable, Identifiable {
    case none, mb100, mb700, gb4, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nicht aufteilen"
        case .mb100: "100 MB"
        case .mb700: "700 MB (CD)"
        case .gb4: "4 GB (FAT32-USB-Stick)"
        case .custom: "Eigene Größe"
        }
    }

    /// Größe in Bytes; bei `.custom` aus der Eingabe in MB.
    func bytes(customMB: Double) -> UInt64? {
        switch self {
        case .none: nil
        case .mb100: 100_000_000
        case .mb700: 700_000_000
        // FAT32 erlaubt höchstens 4 GiB − 1 Byte pro Datei
        case .gb4: 4_294_967_295
        case .custom: customMB > 0 ? UInt64(customMB * 1_000_000) : nil
        }
    }
}

/// Kompressionsstufen der Oberfläche → Stufe 0…9 im Kern.
enum CompressionLevel {
    static let titles = ["Speichern", "Schnell", "Normal", "Gut", "Maximal"]
    static let values: [UInt8] = [0, 1, 6, 8, 9]

    static func value(forIndex index: Int) -> UInt8 {
        values[min(values.count - 1, max(0, index))]
    }
}
