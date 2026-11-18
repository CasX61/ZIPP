import Foundation

/// Beobachtet genau eine Datei (über ihren Dateideskriptor, nicht über den Pfad)
/// und meldet das erste Ereignis. Danach ist der Beobachter verbraucht; wer weiter
/// beobachten will, legt einen neuen an (die Datei kann inzwischen eine andere sein).
@MainActor
final class FileWatcher {
    enum Event: Equatable {
        /// Umbenannt oder verschoben (auch in den Papierkorb). `to` ist der neue Pfad, falls bekannt.
        case moved(to: URL?)
        /// Gelöscht, ersetzt oder das Volume wurde ausgeworfen.
        case deleted
        /// Inhalt verändert
        case modified
    }

    private var source: DispatchSourceFileSystemObject?

    /// `nil`, wenn die Datei nicht geöffnet werden kann (z. B. existiert nicht mehr).
    init?(url: URL, onEvent: @escaping @MainActor (Event) -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename, .revoke, .write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                let mask = source.data
                let event: Event
                if mask.contains(.rename) {
                    event = .moved(to: Self.currentPath(of: fd))
                } else if mask.contains(.delete) || mask.contains(.revoke) {
                    event = .deleted
                } else {
                    event = .modified
                }
                self.cancel()
                onEvent(event)
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    /// Wo die Datei jetzt liegt (funktioniert auch nach dem Verschieben).
    nonisolated private static func currentPath(of fd: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path)
    }

    /// Liegt die Datei in einem Papierkorb (Benutzer oder externes Volume)?
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }
}
