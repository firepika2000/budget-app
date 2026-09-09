import SwiftUI

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

    init() {
        _session = StateObject(wrappedValue: AppSession.production)
        #if DEBUG
        RuntimeBuildIdentity.logStartup()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}
