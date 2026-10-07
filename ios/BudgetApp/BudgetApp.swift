import SwiftUI
import AppIntents

enum QuickEntryRequest {
    static let defaultsKey = "clearpocket.pendingQuickEntry"
    static func request() { UserDefaults.standard.set(true, forKey: defaultsKey) }
    static func consume() -> Bool {
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return false }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return true
    }
}

struct OpenClearPocketTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add ClearPocket Transaction"
    static let description = IntentDescription("Open the active ClearPocket budget directly to a new transaction.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickEntryRequest.request()
        return .result()
    }
}

struct ClearPocketShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenClearPocketTransactionIntent(),
                    phrases: ["Add a transaction in \(.applicationName)", "Record spending in \(.applicationName)"],
                    shortTitle: "Add Transaction", systemImageName: "plus.circle.fill")
    }
}

#if DEBUG
enum RuntimeBuildIdentity {
    static let repositoryMarker = "budgetapp-product-spec-stage0-v1"
    private static let injectedValues: [String: String] = {
        guard let url = Bundle.main.url(forResource: "BudgetAppRuntimeIdentity", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return Dictionary(uniqueKeysWithValues: contents.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
    }()
    static let commit = injectedValues["commit"] ?? "unknown"
    static let configuration = injectedValues["configuration"] ?? "Debug"
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

    static var visibleText: String {
        "DEBUG \(commit) • \(configuration)\n\(bundleIdentifier) • v\(version) (\(build))\n\(repositoryMarker)"
    }

    static func logStartup() {
        print("BUDGETAPP_RUNTIME commit=\(commit) configuration=\(configuration) bundle=\(bundleIdentifier) version=\(version) build=\(build) marker=\(repositoryMarker)")
    }
}
#endif

@main
struct BudgetApp: App {
    // SwiftUI may reconstruct the App value while scenes are being connected. Keep the production
    // composition root explicit so every reconstructed root receives the same process session.
    @StateObject private var session: AppSession
    @StateObject private var appearance: AppearancePreference

    init() {
        _session = StateObject(wrappedValue: AppSession.production)
        _appearance = StateObject(wrappedValue: AppearancePreference(defaults: AppearancePreference.productionDefaults))
        #if DEBUG
        RuntimeBuildIdentity.logStartup()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.selection.colorScheme)
        }
    }
}
