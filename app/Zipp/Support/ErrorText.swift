import Foundation
import ZippCore

/// Verständliche Fehlermeldungen für die Oberfläche.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        if let e = error as? ZippError {
            switch e {
            case .PasswordRequired:
                return "Für dieses Archiv wird ein Passwort benötigt."
            case .WrongPassword:
                return "Das Passwort ist falsch."
            case .UnsupportedFormat:
                return "Diese Datei ist kein unterstütztes Archiv."
            case .Corrupt(let message):
                return "Das Archiv ist beschädigt oder unvollständig.\n\(message)"
            case .ChecksumMismatch(let path):
                return "Die Prüfsumme von „\(path)“ stimmt nicht. Die Datei ist beschädigt."
            case .Cancelled:
                return "Der Vorgang wurde abgebrochen."
            case .Unsupported(let message):
                return message
            case .Io(let message):
                return message
            }
        }
        return error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        (error as? ZippError) == .Cancelled
    }
}
