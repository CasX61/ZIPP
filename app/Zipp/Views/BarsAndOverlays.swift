import SwiftUI

/// Pfadleiste: Archiv › Ordner › Unterordner (klickbar).
struct BreadcrumbBar: View {
    let session: ArchiveSession

    var body: some View {
        HStack(spacing: 2) {
            if !session.searchText.isEmpty {
                Label("Suchergebnisse für „\(session.searchText)“", systemImage: "magnifyingglass")
                    .font(.callout.weight(.medium))
                Text("· \(Fmt.count(session.visibleItems.count))")
                    .foregroundStyle(.secondary)
            } else if let folder = session.currentFolder {
                let chain = folder.ancestors
                ForEach(Array(chain.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                            .imageScale(.small)
                    }
                    Button {
                        session.navigate(to: node)
                    } label: {
                        HStack(spacing: 4) {
                            if node.isRoot { Image(systemName: "archivebox") }
                            Text(node.isRoot ? session.displayName : node.name)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(index == chain.count - 1 ? .medium : .regular)
                    .foregroundStyle(index == chain.count - 1 ? .primary : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Statusleiste unten.
struct StatusBar: View {
    let session: ArchiveSession

    var body: some View {
        HStack(spacing: 10) {
            Text(summary).lineLimit(1)
            Spacer()
            if let listing = session.listing {
                Pill(text: listing.formatLabel)
                if listing.hasEncryptedEntries {
                    Pill(text: listing.headerEncrypted ? "Namen verschlüsselt" : "Verschlüsselt", symbol: "lock.fill")
                }
                if listing.totalSize > 0, listing.archiveSize > 0 {
                    let saved = max(0, Int(((1 - Double(listing.archiveSize) / Double(listing.totalSize)) * 100).rounded()))
                    Pill(text: "Ersparnis \(saved) %")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        guard session.phase == .ready else { return "" }
        let items = session.visibleItems
        let selection = session.selection
        if selection.isEmpty {
            return "\(Fmt.objects(items.count)) · \(Fmt.size(items.reduce(0) { $0 &+ $1.totalSize }))"
        }
        return "\(Fmt.count(selection.count)) von \(Fmt.count(items.count)) ausgewählt · \(Fmt.size(selection.reduce(0) { $0 &+ $1.totalSize }))"
    }
}

private struct Pill: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

/// Fortschritt (unten) und Rückmeldungen (oben) über der Dateiliste.
struct OverlayLayer: View {
    let ui: WindowState

    var body: some View {
        VStack {
            if let toast = ui.toast {
                ToastView(toast: toast) { ui.toast = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
            if let job = ui.job {
                JobView(job: job)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.3), value: ui.toast?.id)
        .animation(.spring(duration: 0.3), value: ui.job?.id)
        .allowsHitTesting(ui.toast != nil || ui.job != nil)
    }
}

struct JobView: View {
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.14), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.isCancelling ? "Wird abgebrochen …" : job.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let fraction = job.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(job.current)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(metrics).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button {
                job.cancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Abbrechen")
            .disabled(job.isCancelling)
        }
        .padding(12)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var metrics: String {
        var parts: [String] = []
        if let fraction = job.fraction { parts.append("\(Int(fraction * 100)) %") }
        if job.bytesPerSecond > 0 { parts.append(Fmt.speed(job.bytesPerSecond)) }
        if let remaining = job.remaining { parts.append(Fmt.remaining(remaining)) }
        return parts.joined(separator: " · ")
    }
}

struct ToastView: View {
    let toast: Toast
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(toast.message).lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    onClose()
                }
                .buttonStyle(.link)
            }
            Button(action: onClose) { Image(systemName: "xmark").imageScale(.small) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private var icon: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch toast.style {
        case .success: .green
        case .info: .accentColor
        case .warning: .orange
        }
    }
}

/// Laden, verschlüsselt oder Fehler: ersetzt die Dateiliste.
struct SessionStateView: View {
    let session: ArchiveSession

    var body: some View {
        Group {
            switch session.phase {
            case .ready:
                Color.clear
            case .loading:
                ProgressView("Inhalt wird gelesen …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .locked(let wrong):
                ContentUnavailableView {
                    Label("Verschlüsseltes Archiv", systemImage: "lock.fill")
                } description: {
                    Text(wrong ? "Das Passwort war falsch." : "Auch die Dateinamen sind verschlüsselt. Gib das Passwort ein, um den Inhalt zu sehen.")
                } actions: {
                    Button("Passwort eingeben …") { Task { await session.load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Archiv kann nicht geöffnet werden", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Erneut versuchen") { Task { await session.load() } }
                }
            }
        }
        .allowsHitTesting(session.phase != .ready)
    }
}
