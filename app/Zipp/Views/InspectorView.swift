import SwiftUI
import ZippCore

/// Rechte Leiste: Details zur Auswahl oder zum ganzen Archiv.
struct InspectorView: View {
    let session: ArchiveSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch session.selection.count {
                case 0: archiveInfo
                case 1: nodeInfo(session.selection[0])
                default: multiInfo(session.selection)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }

    // MARK: Einzelner Eintrag

    @ViewBuilder
    private func nodeInfo(_ node: ArchiveNode) -> some View {
        header(icon: Image(nsImage: IconCache.icon(for: node.contentType)), title: node.name, subtitle: subtitle(for: node))
        Divider().padding(.vertical, 12)
        DetailGrid {
            DetailRow("Größe", Fmt.size(node.totalSize))
            DetailRow("Gepackt", node.totalPacked.map(Fmt.size) ?? "–")
            if let percent = node.savingsPercent {
                DetailRow("Ersparnis", "\(percent) %", color: .green)
            }
            if !node.isDirectory {
                if let method = node.method { DetailRow("Methode", method) }
                if let crc = node.crc32 { DetailRow("CRC32", String(format: "%08X", crc), monospaced: true) }
            }
            DetailRow("Geändert", Fmt.date(node.modified))
            DetailRow("Verschlüsselt", node.isEncrypted ? "Ja" : (node.containsEncrypted ? "Teilweise" : "Nein"),
                      color: node.containsEncrypted ? .orange : nil)
            if !node.parentPath.isEmpty { DetailRow("Ordner", node.parentPath) }
        }
        Divider().padding(.vertical, 12)
        HStack {
            if !node.isDirectory {
                Button("Vorschau", systemImage: "eye") { quickLook() }
            }
            Button("Entpacken", systemImage: "arrow.down.doc") { extract() }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }

    private func subtitle(for node: ArchiveNode) -> String {
        node.isDirectory ? "Ordner · \(Fmt.files(node.fileCount))" : node.kindName
    }

    // MARK: Mehrfachauswahl

    @ViewBuilder
    private func multiInfo(_ nodes: [ArchiveNode]) -> some View {
        let size = nodes.reduce(UInt64(0)) { $0 &+ $1.totalSize }
        let packed = nodes.allSatisfy { $0.totalPacked != nil }
            ? nodes.reduce(UInt64(0)) { $0 &+ ($1.totalPacked ?? 0) } : nil
        header(
            icon: Image(systemName: "square.stack.3d.up"),
            title: "\(Fmt.objects(nodes.count)) ausgewählt",
            subtitle: Fmt.files(nodes.reduce(0) { $0 + $1.fileCount })
        )
        Divider().padding(.vertical, 12)
        DetailGrid {
            DetailRow("Größe", Fmt.size(size))
            DetailRow("Gepackt", packed.map(Fmt.size) ?? "–")
            if let packed, size > 0 {
                DetailRow("Ersparnis", "\(max(0, Int(((1 - Double(packed) / Double(size)) * 100).rounded()))) %", color: .green)
            }
        }
        Divider().padding(.vertical, 12)
        Button("Auswahl entpacken", systemImage: "arrow.down.doc") { extract() }
            .buttonStyle(.borderedProminent)
    }

    // MARK: Archiv

    @ViewBuilder
    private var archiveInfo: some View {
        if let listing = session.listing, let root = session.root {
            header(
                icon: Image(nsImage: IconCache.archiveIcon(for: session.url)),
                title: session.displayName,
                subtitle: "\(listing.formatLabel)-Archiv"
            )
            Divider().padding(.vertical, 12)
            DetailGrid {
                DetailRow("Dateien", Fmt.count(root.fileCount))
                DetailRow("Entpackt", Fmt.size(listing.totalSize))
                DetailRow("Archivgröße", Fmt.size(listing.archiveSize))
                if listing.totalSize > 0 {
                    let saved = max(0, Int(((1 - Double(listing.archiveSize) / Double(listing.totalSize)) * 100).rounded()))
                    DetailRow("Ersparnis", "\(saved) %", color: .green)
                }
                DetailRow("Verschlüsselt", encryptionText(listing), color: listing.hasEncryptedEntries ? .orange : nil)
                DetailRow("Solid", listing.isSolid ? "Ja" : "Nein")
                if listing.volumeCount > 1 {
                    DetailRow("Teile", "\(listing.volumeCount)")
                }
                if let encoding = listing.nameEncoding {
                    DetailRow("Zeichensatz", encoding)
                }
                DetailRow("Bearbeitbar", editingText(listing))
            }
            if let comment = listing.comment {
                Text("Kommentar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                Text(comment)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .padding(.top, 4)
            }
        } else {
            Text("Keine Auswahl")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func editingText(_ listing: ArchiveListing) -> String {
        if !listing.supportsEditing { return "Nein (nur lesen)" }
        return listing.editRewritesAll ? "Ja (wird neu geschrieben)" : "Ja"
    }

    private func encryptionText(_ listing: ArchiveListing) -> String {
        if listing.headerEncrypted { return "Ja, inkl. Dateinamen" }
        return listing.hasEncryptedEntries ? "Ja" : "Nein"
    }

    // MARK: Bausteine

    private func header(icon: Image, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .textSelection(.enabled)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func quickLook() {
        NSApp.sendAction(#selector(ArchiveWindowController.toggleQuickLook(_:)), to: nil, from: nil)
    }

    private func extract() {
        NSApp.sendAction(#selector(ArchiveWindowController.extractTo(_:)), to: nil, from: nil)
    }
}

private struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            content
        }
        .font(.callout)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var color: Color?
    var monospaced = false

    init(_ label: String, _ value: String, color: Color? = nil, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.color = color
        self.monospaced = monospaced
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color ?? .primary)
                .font(monospaced ? .callout.monospaced() : .callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
