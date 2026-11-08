import SwiftUI

/// Ordnerbaum des Archivs, zuletzt geöffnete Archive, Schnellziele.
struct SidebarView: View {
    let session: ArchiveSession
    let onOpenRecent: (URL) -> Void
    let onQuickExtract: (URL) -> Void
    private let recents = RecentArchives.shared

    private var folderSelection: Binding<ArchiveNode?> {
        Binding(
            get: { session.searchText.isEmpty ? session.currentFolder : nil },
            set: { node in if let node { session.navigate(to: node) } }
        )
    }

    var body: some View {
        List(selection: folderSelection) {
            if let root = session.root {
                Section("Archiv") {
                    OutlineGroup([root], children: \.outlineChildren) { node in
                        Label {
                            Text(node.isRoot ? session.displayName : node.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: node.isRoot ? "archivebox" : "folder")
                        }
                        .tag(node)
                    }
                }
            }

            let others = recents.existing.filter { $0 != session.url.standardizedFileURL }.prefix(6)
            if !others.isEmpty {
                Section("Zuletzt geöffnet") {
                    ForEach(Array(others), id: \.self) { url in
                        Button { onOpenRecent(url) } label: {
                            Label(url.lastPathComponent, systemImage: "doc.zipper")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                }
            }

            Section("Schnell entpacken nach") {
                ForEach(QuickDestination.all) { destination in
                    Button { onQuickExtract(destination.url) } label: {
                        Label(destination.title, systemImage: destination.symbol)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.phase != .ready)
                    .help("Auswahl (oder alles) nach „\(destination.title)“ entpacken")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct QuickDestination: Identifiable {
    let title: String
    let symbol: String
    let url: URL
    var id: String { url.path }

    static var all: [QuickDestination] {
        let fm = FileManager.default
        var result: [QuickDestination] = []
        if let url = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            result.append(.init(title: "Downloads", symbol: "arrow.down.circle", url: url))
        }
        if let url = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            result.append(.init(title: "Schreibtisch", symbol: "menubar.dock.rectangle", url: url))
        }
        if let url = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            result.append(.init(title: "Dokumente", symbol: "doc", url: url))
        }
        return result
    }
}
