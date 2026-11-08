import AppKit

/// Erscheinungsbild der App: wie das System, immer hell oder immer dunkel.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Automatisch"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `nil` = dem System folgen
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.appearance) ?? "") ?? .system
    }

    /// Speichern und sofort auf alle Fenster anwenden.
    @MainActor
    static func set(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: Preferences.Key.appearance)
        appearance.apply()
    }

    /// Nur anwenden (beim Start und wenn die Einstellung sich ändert).
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}
