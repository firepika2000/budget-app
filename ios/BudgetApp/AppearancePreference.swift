import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

@MainActor
final class AppearancePreference: ObservableObject {
    static let storageKey = "budget.appearance"
    @Published var selection: AppAppearance {
        didSet { defaults.set(selection.rawValue, forKey: Self.storageKey) }
    }
    private let defaults: UserDefaults

    static var productionDefaults: UserDefaults {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-appearance-suite=") }),
              let name = argument.split(separator: "=", maxSplits: 1).last.map(String.init),
              let suite = UserDefaults(suiteName: name) else { return .standard }
        return suite
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.storageKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
