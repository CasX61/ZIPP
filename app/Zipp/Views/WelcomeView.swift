import SwiftUI
import UniformTypeIdentifiers

/// Fenster ohne Archiv: zwei große Drop-Zonen und die zuletzt geöffneten Archive.
struct WelcomeView: View {
    let ui: WindowState
    let onOpen: () -> Void
    let onCreate: () -> Void
    /// Drop auf „Archiv öffnen“: Archive öffnen, andere Dateien komprimieren
    let onDrop: ([URL]) -> Void
    /// Drop auf „Neues Archiv“: immer komprimieren
    let onCompress: ([URL]) -> Void
    let onOpenRecent: (URL) -> Void

    private let recents = RecentArchives.shared

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                DropZone(
                    title: "Archiv öffnen",
                    message: "Archiv hierher ziehen oder klicken, um es wie einen Ordner zu durchsuchen",
                    symbol: "archivebox",
                    shortcut: "⌘O",
                    action: onOpen,
                    onDrop: onDrop
                )
                DropZone(
                    title: "Neues Archiv erstellen",
                    message: "Dateien oder Ordner hierher ziehen. Format und Passwort wählst du im nächsten Schritt.",
                    symbol: "plus",
                    shortcut: "⌘N",
                    action: onCreate,
                    onDrop: onCompress
                )
            }
            .frame(maxWidth: 680)

            Text("ZIP · 7z · RAR · TAR · GZ · BZ2 · XZ · ZST")
                .font(.caption)
                .foregroundStyle(.tertiary)

            let recent = Array(recents.existing.prefix(5))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zuletzt geöffnet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recent, id: \.self) { url in
                        Button { onOpenRecent(url) } label: {
                            HStack {
                                Image(nsImage: IconCache.archiveIcon(for: url))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 680)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { OverlayLayer(ui: ui) }
    }
}

private struct DropZone: View {
    let title: String
    let message: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(.tint.opacity(0.13), in: .rect(cornerRadius: 15))
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Gleiche Höhe in beiden Karten, damit die Symbole auf einer Linie stehen
                    .frame(maxWidth: 250, minHeight: 58, alignment: .top)
                Text(shortcut).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isTargeted || isHovered ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 5])
                    )
            )
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onDrop(files)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
