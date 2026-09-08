import SwiftUI

@main
struct BudgetApp: App {
    // SwiftUI may reconstruct the App value while scenes are being connected. Keep the production
    // composition root explicit so every reconstructed root receives the same process session.
    @StateObject private var session: AppSession

    init() {
        _session = StateObject(wrappedValue: AppSession.production)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}
