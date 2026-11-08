import SwiftUI
import ZippCore

struct CompressRequest {
    var sources: [URL]
    var name: String
    var folder: URL
    var format: CreateFormat
    var level: UInt8
    var password: String?
    var encryptFileNames: Bool
    var excludeMacFiles: Bool
    var trashOriginals: Bool
    /// In Teile dieser Größe aufteilen (Bytes)
    var volumeSize: UInt64?

    var options: CreateOptions {
        CreateOptions(
            format: format,
            level: level,
            password: password,
            encryptFileNames: encryptFileNames,
            excludeMacMetadata: excludeMacFiles,
            volumeSize: volumeSize
        )
    }
}

extension CreateFormat: @retroactive Identifiable {
    public var id: String { createFormatExtension(format: self) }

    static let ordered: [CreateFormat] = [.zip, .sevenZip, .tarGz, .tarZst, .tarXz]

    var title: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7z"
        case .tarGz: "TAR.GZ"
        case .tarXz: "TAR.XZ"
        case .tarZst: "TAR.ZST"
        case .tarBz2: "TAR.BZ2"
        case .tar: "TAR"
        }
    }

    var hint: String {
        switch self {
        case .zip: "Öffnet sich überall, auch unter Windows ohne Zusatzprogramm."
        case .sevenZip: "Beste Kompression, auch die Dateinamen lassen sich verschlüsseln."
        case .tarGz: "Standard unter Linux und macOS, Dateirechte bleiben erhalten."
        case .tarXz: "Sehr starke Kompression, dafür langsamer."
        case .tarZst: "Sehr schnell bei guter Kompression (Zstandard)."
        case .tarBz2: "Älteres Format, für Kompatibilität."
        case .tar: "Ohne Kompression, nur zusammengefasst."
        }
    }

    var supportsPassword: Bool { self == .zip || self == .sevenZip }

    static func from(id: String) -> CreateFormat {
        ordered.first { $0.id == id } ?? .zip
    }
}

/// „Neues Archiv“ – und mit `convertFrom` auch „Archiv konvertieren“.
struct CompressSheet: View {
    let sources: [URL]
    /// Gesetzt beim Konvertieren: das Quellarchiv (dann gibt es keine Ausschluss-Option).
    let convertFrom: URL?
    let onCancel: () -> Void
    let onConfirm: (CompressRequest) -> Void

    @State private var name: String
    @State private var folder: URL
    @State private var format = CreateFormat.from(id: Preferences.createFormatID)
    @State private var levelIndex = Double(Preferences.compressionLevelIndex)
    @State private var usePassword = false
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var encryptNames = true
    @State private var excludeMac = Preferences.excludeMacFiles
    @State private var trashOriginals = false
    @State private var totalSize: UInt64?
    @State private var volumes = VolumeChoice.none
    @State private var customVolumeMB = 1000.0

    init(
        sources: [URL],
        convertFrom: URL? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (CompressRequest) -> Void
    ) {
        self.sources = sources
        self.convertFrom = convertFrom
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let first = convertFrom ?? sources.first
        _name = State(initialValue: Self.defaultName(for: sources, convertFrom: convertFrom))
        _folder = State(initialValue: first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser)
        if let convertFrom {
            // Beim Konvertieren ein anderes Format vorschlagen als das der Quelle
            let source = ArchiveTypes.logicalName(of: convertFrom).lowercased()
            let preferred = CreateFormat.from(id: Preferences.createFormatID)
            if source.hasSuffix("." + preferred.id) {
                _format = State(initialValue: preferred == .zip ? .sevenZip : .zip)
            }
            _excludeMac = State(initialValue: false)
        }
    }

    /// Ordnername bzw. Dateiname ohne Endung; bei mehreren Objekten der Name des Elternordners.
    static func defaultName(for sources: [URL], convertFrom: URL?) -> String {
        if let convertFrom { return ArchiveTypes.baseName(of: convertFrom) }
        let first = sources.first
        let name: String
        if sources.count == 1, let first {
            name = first.hasDirectoryPath ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        } else {
            name = first?.deletingLastPathComponent().lastPathComponent ?? "Archiv"
        }
        return name.isEmpty ? "Archiv" : name
    }

    private var isConverting: Bool { convertFrom != nil }

    private var volumeSize: UInt64? { volumes.bytes(customMB: customVolumeMB) }

    private var passwordProblem: String? {
        guard usePassword, format.supportsPassword else { return nil }
        if password.isEmpty { return "Bitte ein Passwort eingeben." }
        if password != repeatPassword { return "Die Passwörter stimmen nicht überein." }
        return nil
    }

    private var volumeProblem: String? {
        guard volumes == .custom else { return nil }
        let min = Double(minVolumeSize()) / 1_000_000
        return customVolumeMB < min ? "Teile müssen mindestens \(String(format: "%.2f", min)) MB groß sein." : nil
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && passwordProblem == nil && volumeProblem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isConverting ? "Archiv konvertieren" : "Neues Archiv").font(.title3.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).padding(.top, 2)

            Form {
                LabeledContent("Name") {
                    HStack(spacing: 4) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .labelsHidden()
                        Text(".\(format.id)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Speicherort") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Ändern …") { chooseFolder() }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Format", selection: $format) {
                        ForEach(CreateFormat.ordered) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(format.hint + " RAR kann aus Lizenzgründen nicht erstellt werden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $levelIndex, in: 0...4, step: 1) {
                        Text("Kompression")
                    }
                    HStack {
                        ForEach(Array(CompressionLevel.titles.enumerated()), id: \.offset) { index, title in
                            Text(title)
                                .font(.caption2)
                                .fontWeight(Int(levelIndex) == index ? .semibold : .regular)
                                .foregroundStyle(Int(levelIndex) == index ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            if index < CompressionLevel.titles.count - 1 { Spacer() }
                        }
                    }
                    .padding(.leading, 90)
                }

                Toggle("Mit Passwort schützen (AES-256)", isOn: $usePassword)
                    .disabled(!format.supportsPassword)
                if usePassword && format.supportsPassword {
                    SecureField("Passwort", text: $password)
                    SecureField("Wiederholen", text: $repeatPassword)
                    if format == .sevenZip {
                        Toggle("Auch die Dateinamen verschlüsseln", isOn: $encryptNames)
                    }
                    if let problem = passwordProblem, !password.isEmpty || !repeatPassword.isEmpty {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }

                Picker("Aufteilen", selection: $volumes) {
                    ForEach(VolumeChoice.allCases) { Text($0.title).tag($0) }
                }
                if volumes == .custom {
                    LabeledContent("Teilgröße") {
                        HStack(spacing: 4) {
                            TextField("MB", value: $customVolumeMB, format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .labelsHidden()
                            Text("MB").foregroundStyle(.secondary)
                        }
                    }
                }
                if volumes != .none {
                    Text(volumeProblem ?? "Ergibt „\(name).\(format.id).001“, „.002“ … Zum Entpacken werden alle Teile im selben Ordner gebraucht.")
                        .font(.caption)
                        .foregroundStyle(volumeProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !isConverting {
                    Toggle("macOS-Dateien weglassen (.DS_Store, __MACOSX, ._*)", isOn: $excludeMac)
                }
                Toggle(isConverting ? "Original danach in den Papierkorb legen" : "Originale danach in den Papierkorb legen",
                       isOn: $trashOriginals)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .animation(.default, value: usePassword)
            .animation(.default, value: format)
            .animation(.default, value: volumes)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isConverting ? "Konvertieren" : "Erstellen") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
            .padding(.top, 12)
        }
        .padding(22)
        .frame(width: 540)
        .task { await computeSize() }
    }

    private var subtitle: String {
        if let convertFrom {
            return "„\(ArchiveTypes.logicalName(of: convertFrom))“ in ein anderes Format umwandeln"
        }
        let objects = sources.count == 1 ? "„\(sources[0].lastPathComponent)“" : "\(sources.count) Objekte"
        if let totalSize { return "\(objects) · \(Fmt.size(totalSize))" }
        return objects
    }

    private func confirm() {
        guard canCreate else { return }
        let safeName = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        onConfirm(CompressRequest(
            sources: sources,
            name: safeName,
            folder: folder,
            format: format,
            level: CompressionLevel.value(forIndex: Int(levelIndex)),
            password: usePassword && format.supportsPassword ? password : nil,
            encryptFileNames: format == .sevenZip && encryptNames,
            excludeMacFiles: excludeMac,
            trashOriginals: trashOriginals,
            volumeSize: volumeSize
        ))
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

    private func computeSize() async {
        guard !isConverting else { return }
        let sources = sources
        totalSize = await Task.detached(priority: .utility) { Self.totalSize(of: sources) }.value
    }

    /// Summe aller Dateigrößen (rekursiv). Synchron, läuft im Hintergrund.
    private nonisolated static func totalSize(of sources: [URL]) -> UInt64 {
        var total: UInt64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        for url in sources {
            if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
                total &+= UInt64(values.fileSize ?? 0)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            else { continue }
            while let file = enumerator.nextObject() as? URL {
                if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                    total &+= UInt64(values.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
