import SwiftUI
import AppIntents

struct QuickEntryDraft: Codable, Equatable {
    var payee: String?
    var amount: String?
    var memo: String?
    var occurredOn: Date?
    var isInflow: Bool
    var createdAt: Date?

    init(
        payee: String? = nil,
        amount: String? = nil,
        memo: String? = nil,
        occurredOn: Date? = nil,
        isInflow: Bool = false,
        createdAt: Date? = Date(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.payee = payee?.quickEntryValue(maxLength: 150)
        self.amount = amount?.quickEntryValue(maxLength: 64)
        self.memo = memo?.quickEntryValue(maxLength: 500)
        self.occurredOn = Self.acceptedOccurredOn(occurredOn, now: now, calendar: calendar)
        self.isInflow = isInflow
        self.createdAt = createdAt
    }

    static func acceptedOccurredOn(_ value: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let value else { return nil }
        let normalized = calendar.startOfDay(for: value)
        return normalized <= calendar.startOfDay(for: now) ? normalized : nil
    }

    func isFresh(at date: Date = Date()) -> Bool {
        guard let createdAt else { return true }
        return date.timeIntervalSince(createdAt) <= 300 && createdAt.timeIntervalSince(date) <= 30
    }
}

private extension String {
    func quickEntryValue(maxLength: Int) -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}

enum QuickEntryRequest {
    static let defaultsKey = "clearpocket.pendingQuickEntry"
    static let notification = Notification.Name("ClearPocketQuickEntryRequest")
    static func request(_ draft: QuickEntryDraft = QuickEntryDraft()) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: notification, object: nil)
    }
    static func consume() -> QuickEntryDraft? {
        // Preserve one-shot compatibility with builds that stored a Boolean marker.
        if UserDefaults.standard.bool(forKey: defaultsKey) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return QuickEntryDraft()
        }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        guard let draft = try? JSONDecoder().decode(QuickEntryDraft.self, from: data),
              draft.isFresh() else { return nil }
        return draft
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "clearpocket",
              url.host?.lowercased() == "quick-entry",
              url.path.isEmpty,
              url.query == nil,
              url.fragment == nil else { return false }
        request()
        return true
    }
}

enum QuickEntryKind: String, AppEnum, CaseIterable {
    case expense, income

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Transaction Type")
    static let caseDisplayRepresentations: [QuickEntryKind: DisplayRepresentation] = [
        .expense: "Expense",
        .income: "Income"
    ]
}

private enum QuickEntryIntentError: LocalizedError {
    case futureDate

    var errorDescription: String? {
        switch self {
        case .futureDate:
            "Choose today or an earlier date. Use Schedule Transaction in ClearPocket for future activity."
        }
    }
}

enum WorkspaceShortcutDestination: String, AppEnum, CaseIterable {
    case home, plan, activity, accounts, insights, household

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "ClearPocket Screen")
    static let caseDisplayRepresentations: [WorkspaceShortcutDestination: DisplayRepresentation] = [
        .home: "Home",
        .plan: "Plan",
        .activity: "Activity",
        .accounts: "Accounts",
        .insights: "Insights",
        .household: "Household"
    ]
}

enum WorkspaceShortcutRequest {
    static let defaultsKey = "clearpocket.pendingWorkspaceDestination"
    static let notification = Notification.Name("ClearPocketWorkspaceShortcutRequest")
    static func request(_ destination: WorkspaceShortcutDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: notification, object: nil)
    }
    static func consume() -> WorkspaceShortcutDestination? {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return WorkspaceShortcutDestination(rawValue: rawValue)
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "clearpocket", url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawValue = components.queryItems?.first(where: { $0.name == "destination" })?.value,
              let destination = WorkspaceShortcutDestination(rawValue: rawValue) else { return false }
        request(destination)
        return true
    }
}

struct OpenClearPocketTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add ClearPocket Transaction"
    static let description = IntentDescription("Open the active ClearPocket budget directly to a new transaction.")
    static let openAppWhenRun = true

    @Parameter(title: "Payee") var payee: String?
    @Parameter(title: "Amount", description: "Enter the amount as currency text, such as 12.34.") var amount: String?
    @Parameter(title: "Memo") var memo: String?
    @Parameter(title: "Date", description: "The date the transaction happened. Future transactions should be scheduled in ClearPocket.") var occurredOn: Date?
    @Parameter(title: "Type") var kind: QuickEntryKind?

    @MainActor
    func perform() async throws -> some IntentResult {
        if occurredOn != nil, QuickEntryDraft.acceptedOccurredOn(occurredOn) == nil {
            throw QuickEntryIntentError.futureDate
        }
        QuickEntryRequest.request(QuickEntryDraft(
            payee: payee,
            amount: amount,
            memo: memo,
            occurredOn: occurredOn,
            isInflow: kind == .income
        ))
        return .result()
    }
}

struct OpenClearPocketPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ClearPocket Plan"
    static let description = IntentDescription("Open the active ClearPocket budget directly to Plan.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WorkspaceShortcutRequest.request(.plan)
        return .result()
    }
}

struct OpenClearPocketAccountsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ClearPocket Accounts"
    static let description = IntentDescription("Open the active ClearPocket budget directly to Accounts.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WorkspaceShortcutRequest.request(.accounts)
        return .result()
    }
}

struct OpenClearPocketInsightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ClearPocket Insights"
    static let description = IntentDescription("Open the active ClearPocket budget directly to Insights.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WorkspaceShortcutRequest.request(.insights)
        return .result()
    }
}

struct OpenClearPocketActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ClearPocket Activity"
    static let description = IntentDescription("Open the active ClearPocket budget directly to Activity.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WorkspaceShortcutRequest.request(.activity)
        return .result()
    }
}

struct OpenClearPocketHouseholdIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ClearPocket Household"
    static let description = IntentDescription("Open the active ClearPocket budget directly to Household.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WorkspaceShortcutRequest.request(.household)
        return .result()
    }
}

struct OpenClearPocketScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ClearPocket Screen"
    static let description = IntentDescription("Choose a screen to open in the active ClearPocket budget.")
    static let openAppWhenRun = true

    @Parameter(title: "Screen") var destination: WorkspaceShortcutDestination

    init() {}
    init(destination: WorkspaceShortcutDestination) { self.destination = destination }

    @MainActor func perform() async throws -> some IntentResult {
        WorkspaceShortcutRequest.request(destination)
        return .result()
    }
}

struct ClearPocketShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenClearPocketTransactionIntent(),
                    phrases: ["Add a transaction in \(.applicationName)", "Record spending in \(.applicationName)"],
                    shortTitle: "Add Transaction", systemImageName: "plus.circle.fill")
        AppShortcut(intent: OpenClearPocketPlanIntent(),
                    phrases: ["Open my plan in \(.applicationName)", "Plan my money in \(.applicationName)"],
                    shortTitle: "Open Plan", systemImageName: "list.bullet.rectangle")
        AppShortcut(intent: OpenClearPocketAccountsIntent(),
                    phrases: ["Open my accounts in \(.applicationName)", "Show my accounts in \(.applicationName)"],
                    shortTitle: "Open Accounts", systemImageName: "building.columns")
        AppShortcut(intent: OpenClearPocketInsightsIntent(),
                    phrases: ["Open insights in \(.applicationName)", "Show my spending insights in \(.applicationName)"],
                    shortTitle: "Open Insights", systemImageName: "chart.pie.fill")
        AppShortcut(intent: OpenClearPocketActivityIntent(),
                    phrases: ["Open my activity in \(.applicationName)", "Show my transactions in \(.applicationName)"],
                    shortTitle: "Open Activity", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: OpenClearPocketHouseholdIntent(),
                    phrases: ["Open my household in \(.applicationName)", "Show my household in \(.applicationName)"],
                    shortTitle: "Open Household", systemImageName: "person.2.fill")
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
                .onOpenURL { url in
                    if !QuickEntryRequest.handle(url) { _ = WorkspaceShortcutRequest.handle(url) }
                }
        }
    }
}
