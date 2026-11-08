import SwiftUI

/// Passwort-Abfrage für verschlüsselte Archive.
struct PasswordSheet: View {
    let archiveName: String
    let wrongPassword: Bool
    let onCancel: () -> Void
    let onSubmit: (String, Bool) -> Void

    @State private var password = ""
    @State private var remember = true
    @State private var shake = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 48, height: 48)
                    .background(.orange.opacity(0.15), in: .rect(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("„\(archiveName)“ ist geschützt")
                        .font(.headline)
                        .lineLimit(2)
                    Text(wrongPassword ? "Das Passwort war falsch. Bitte erneut versuchen." : "Gib das Passwort ein, um fortzufahren.")
                        .font(.callout)
                        .foregroundStyle(wrongPassword ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            SecureField("Passwort", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .offset(x: shake ? -6 : 0)
            Toggle("Im Schlüsselbund sichern", isOn: $remember)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Öffnen", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else {
            withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) { shake.toggle() }
            shake = false
            return
        }
        onSubmit(password, remember)
    }
}
