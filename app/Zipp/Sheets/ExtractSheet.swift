import SwiftUI

struct ExtractSheetResult {
    var folder: URL
    var folderMode: FolderMode
    var overwrite: OverwriteChoice
    var revealAfter: Bool
    var trashArchive: Bool
}

/// „Entpacken nach …“
struct ExtractSheet: View {
    let summary: String
    let archiveURL: URL
    let preview: (URL, FolderMode) -> URL
    let onCancel: () -> Void
    let onConfirm: (ExtractSheetResult) -> Void

    @State private var folder: URL
    @State private var folderMode = Preferences.folderMode
    @State private var overwrite = Preferences.overwrite
    @State private var revealAfter = Preferences.revealAfterExtract
    @State private var trashArchive = Preferences.trashAfterExtract

    init(
        summary: String,
        archiveURL: URL,
        initialFolder: URL,
        preview: @escaping (URL, FolderMode) -> URL,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ExtractSheetResult) -> Void
    ) {
        self.summary = summary
        self.archiveURL = archiveURL
        self.preview = preview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _folder = State(initialValue: initialFolder)
    }

    private var shortcuts: [(String, URL)] {
        var list: [(String, URL)] = [("Neben dem Archiv", archiveURL.deletingLastPathComponent())]
        list += QuickDestination.all.prefix(2).map { ($0.title, $0.url) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Entpacken").font(.title3.weight(.semibold))
            Text(summary).foregroundStyle(.secondary).padding(.top, 2)

            Form {
                LabeledContent("Ziel") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(displayPath(folder))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                            Button("Wählen …") { chooseFolder() }
                        }
                        HStack(spacing: 6) {
                            ForEach(shortcuts, id: \.1) { title, url in
                                if url.standardizedFileURL.path == folder.standardizedFileURL.path {
                                    Button(title) { folder = url }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                } else {
                                    Button(title) { folder = url }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Picker("Ordner anlegen", selection: $folderMode) {
                    ForEach(FolderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Ergebnis") {
                    Text(displayPath(preview(folder, folderMode)) + (preview(folder, folderMode).hasDirectoryPath ? "/" : ""))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }

                Picker("Vorhandene Dateien", selection: $overwrite) {
                    ForEach(OverwriteChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Zielordner danach im Finder zeigen", isOn: $revealAfter)
                Toggle("Archiv danach in den Papierkorb legen", isOn: $trashArchive)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)

            Label {
                Text("Die Quarantäne-Markierung des Archivs wird übernommen. Pfade, die aus dem Ziel herausführen, werden blockiert.")
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Entpacken") {
                    onConfirm(ExtractSheetResult(
                        folder: folder, folderMode: folderMode, overwrite: overwrite,
                        revealAfter: revealAfter, trashArchive: trashArchive
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 520)
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}
