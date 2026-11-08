import SwiftUI

/// Kleiner Dialog für einen Namen: „Umbenennen“ und „Neuer Ordner“.
struct NameSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(
        title: String,
        message: String,
        initialName: String,
        confirmTitle: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if trimmed.isEmpty { return "" }
        if trimmed.contains("/") { return "Der Name darf keinen Schrägstrich (/) enthalten." }
        if trimmed == "." || trimmed == ".." { return "Dieser Name ist nicht erlaubt." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { confirm() }
            if let problem, !problem.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func confirm() {
        guard problem == nil else { return }
        onConfirm(trimmed)
    }
}
