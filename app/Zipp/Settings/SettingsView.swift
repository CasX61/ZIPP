import SwiftUI
import ZippCore

/// Einstellungen (⌘,)
struct SettingsView: View {
    @AppStorage(Preferences.Key.extractDestination) private var destination = ExtractDestination.besideArchive.rawValue
    @AppStorage(Preferences.Key.folderMode) private var folderMode = FolderMode.automatic.rawValue
    @AppStorage(Preferences.Key.overwrite) private var overwrite = OverwriteChoice.keepBoth.rawValue
    @AppStorage(Preferences.Key.revealAfterExtract) private var revealAfterExtract = true
    @AppStorage(Preferences.Key.trashAfterExtract) private var trashAfterExtract = false
    @AppStorage(Preferences.Key.createFormat) private var createFormat = "zip"
    @AppStorage(Preferences.Key.compressionLevel) private var compressionLevel = 2
    @AppStorage(Preferences.Key.excludeMacFiles) private var excludeMacFiles = true
    @AppStorage(Preferences.Key.revealAfterCreate) private var revealAfterCreate = true
    @AppStorage(Preferences.Key.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Preferences.Key.appearance) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        TabView {
            Form {
                Section("Erscheinungsbild") {
                    AppearancePicker(selection: $appearance)
                }
                Section("Updates") {
                    Toggle("Einmal am Tag nach Updates suchen", isOn: $checkForUpdates)
                    Button("Jetzt nach Updates suchen") {
                        Task { await UpdateChecker.check(userInitiated: true) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            Form {
                Picker("„Entpacken“ (⌘E) entpackt nach", selection: $destination) {
                    ForEach(ExtractDestination.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Eigenen Ordner anlegen", selection: $folderMode) {
                    ForEach(FolderMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("„Automatisch“ legt nur dann einen Ordner an, wenn das Archiv mehrere Objekte auf oberster Ebene enthält.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Vorhandene Dateien", selection: $overwrite) {
                    ForEach(OverwriteChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Ergebnis im Finder zeigen", isOn: $revealAfterExtract)
                Toggle("Archiv danach in den Papierkorb legen", isOn: $trashAfterExtract)
            }
            .formStyle(.grouped)
            .tabItem { Label("Entpacken", systemImage: "arrow.down.doc") }

            Form {
                Picker("Standardformat", selection: $createFormat) {
                    ForEach(CreateFormat.ordered) { Text($0.title).tag($0.id) }
                }
                Picker("Kompression", selection: $compressionLevel) {
                    ForEach(Array(CompressionLevel.titles.enumerated()), id: \.offset) { index, title in
                        Text(title).tag(index)
                    }
                }
                Toggle("macOS-Dateien weglassen (.DS_Store, __MACOSX, ._*)", isOn: $excludeMacFiles)
                Toggle("Neues Archiv im Finder zeigen", isOn: $revealAfterCreate)
            }
            .formStyle(.grouped)
            .tabItem { Label("Erstellen", systemImage: "archivebox") }

            PasswordListView()
                .tabItem { Label("Passwörter", systemImage: "key") }

            Form {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Archiv-Kern", value: coreVersion())
                LabeledContent("Lesen", value: "ZIP, 7z, RAR, TAR, GZ, BZ2, XZ, ZST, mehrteilig")
                LabeledContent("Erstellen", value: "ZIP, 7z, TAR.GZ, TAR.XZ, TAR.ZST, auch aufgeteilt")
                LabeledContent("Bearbeiten", value: "ZIP, 7z, TAR.*")
                Text("RAR-Archive werden mit dem offiziellen UnRAR-Code gelesen. Erstellen und Ändern ist aus Lizenzgründen nicht möglich.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("ZIPP auf GitHub") { NSWorkspace.shared.open(Project.homepage) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
        .onChange(of: appearance) { _, raw in
            (AppAppearance(rawValue: raw) ?? .system).apply()
        }
    }
}

// MARK: - Erscheinungsbild

/// Drei Karten wie in den macOS-Systemeinstellungen: Automatisch, Hell, Dunkel.
private struct AppearancePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 18) {
            ForEach(AppAppearance.allCases) { option in
                let selected = selection == option.rawValue
                Button {
                    selection = option.rawValue
                } label: {
                    VStack(spacing: 7) {
                        AppearancePreview(option: option)
                            .frame(width: 112, height: 72)
                            .clipShape(.rect(cornerRadius: 9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(.separator, lineWidth: 1)
                            }
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
                            }
                        Text(option.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Erscheinungsbild \(option.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

/// Kleines ZIPP-Fenster in fester Hell- bzw. Dunkel-Farbgebung.
private struct AppearancePreview: View {
    let option: AppAppearance

    var body: some View {
        switch option {
        case .light: MiniWindow(palette: .light)
        case .dark: MiniWindow(palette: .dark)
        case .system:
            ZStack {
                MiniWindow(palette: .light)
                MiniWindow(palette: .dark)
                    .mask {
                        GeometryReader { geo in
                            Path { p in
                                p.move(to: CGPoint(x: geo.size.width * 0.62, y: 0))
                                p.addLine(to: CGPoint(x: geo.size.width, y: 0))
                                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                                p.addLine(to: CGPoint(x: geo.size.width * 0.38, y: geo.size.height))
                                p.closeSubpath()
                            }
                        }
                    }
            }
        }
    }
}

private struct MiniWindow: View {
    struct Palette {
        let desktop: Color
        let window: Color
        let sidebar: Color
        let line: Color
        let row: Color
        static let light = Palette(
            desktop: Color(red: 0.56, green: 0.71, blue: 0.93),
            window: .white,
            sidebar: Color(white: 0.93),
            line: Color(white: 0.80),
            row: Color(white: 0.965)
        )
        static let dark = Palette(
            desktop: Color(red: 0.13, green: 0.17, blue: 0.33),
            window: Color(white: 0.16),
            sidebar: Color(white: 0.22),
            line: Color(white: 0.38),
            row: Color(white: 0.19)
        )
    }

    let palette: Palette

    var body: some View {
        ZStack(alignment: .topLeading) {
            palette.desktop
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2.5) {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                    }
                    .frame(height: 5)
                    .padding(.bottom, 3)
                    Capsule().fill(Color.accentColor).frame(width: 20, height: 4)
                    Capsule().fill(palette.line).frame(width: 16, height: 3)
                    Capsule().fill(palette.line).frame(width: 18, height: 3)
                }
                .padding(6)
                .frame(width: 34, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(palette.sidebar)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<5) { i in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(i == 0 ? Color.accentColor.opacity(0.85) : palette.line)
                                .frame(width: 6, height: 5)
                            Capsule().fill(palette.line).frame(width: CGFloat([34, 26, 30, 22, 28][i]), height: 3)
                            Spacer(minLength: 0)
                            Capsule().fill(Color.green.opacity(0.8)).frame(width: CGFloat([10, 6, 12, 4, 8][i]), height: 2.5)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 9)
                        .background(i % 2 == 1 ? palette.row : palette.window)
                    }
                }
                .padding(.top, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(palette.window)
            }
            .clipShape(.rect(cornerRadius: 5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 0))
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Passwörter, die ZIPP bei verschlüsselten Archiven automatisch ausprobiert.
private struct PasswordListView: View {
    @State private var passwords = PasswordStore.savedList()
    @State private var newPassword = ""
    @State private var reveal = false
    @State private var selection: Set<Int> = []

    var body: some View {
        Form {
            Section {
                Text("ZIPP probiert diese Passwörter bei verschlüsselten Archiven automatisch aus, bevor es nachfragt. Sie liegen im macOS-Schlüsselbund.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(selection: $selection) {
                    ForEach(passwords.indices, id: \.self) { index in
                        Text(reveal ? passwords[index] : String(repeating: "•", count: min(12, passwords[index].count)))
                            .font(.body.monospaced())
                            .tag(index)
                    }
                }
                .frame(height: 130)
                .overlay {
                    if passwords.isEmpty {
                        Text("Noch keine Passwörter").foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    SecureField("Neues Passwort", text: $newPassword)
                        .onSubmit(add)
                    Button("Hinzufügen", action: add)
                        .disabled(newPassword.isEmpty)
                }
                HStack {
                    Toggle("Passwörter anzeigen", isOn: $reveal)
                    Spacer()
                    Button("Entfernen", role: .destructive, action: removeSelected)
                        .disabled(selection.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        guard !newPassword.isEmpty, !passwords.contains(newPassword) else {
            newPassword = ""
            return
        }
        passwords.append(newPassword)
        newPassword = ""
        PasswordStore.saveList(passwords)
    }

    private func removeSelected() {
        passwords = passwords.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        selection = []
        PasswordStore.saveList(passwords)
    }
}
