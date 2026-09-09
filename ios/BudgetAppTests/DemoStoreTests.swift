import XCTest
import SwiftUI
import UIKit
import BudgetAPI
@testable import Budget_App

final class DemoStoreTests: XCTestCase {
    override func tearDown() {
        ConnectionURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testFreshBudgetStartingBalanceAndActivationSurfacesUseProductionPaths() throws {
        let demo = DemoStore()
        demo.accounts = []
        demo.transactions = []
        demo.categories = []
        demo.groupOrder = []
        demo.setUnassigned(0)

        demo.createAccount(name: "Everyday Checking", type: "checking", isOnBudget: true, startingBalance: 72_000)
        XCTAssertEqual(demo.accounts.first?.balance, 72_000)
        XCTAssertEqual(demo.readyToAssign, 72_000)
        XCTAssertEqual(demo.transactions.first?.payee, "Starting Balance")
        XCTAssertTrue(demo.transactions.first?.cleared == true)
        XCTAssertEqual(demo.transactions.first?.categoryIDs, [])

        let testFile = URL(fileURLWithPath: #filePath)
        let appDirectory = testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp")
        let workspace = try String(contentsOf: appDirectory.appendingPathComponent("BudgetWorkspaceView.swift"))
        let root = try String(contentsOf: appDirectory.appendingPathComponent("RootView.swift"))
        let editor = try String(contentsOf: appDirectory.appendingPathComponent("EditingViews.swift"))
        XCTAssertTrue(root.contains("ActiveBudgetShell(context: context)"), "resolved routing must enter the persistent active-budget shell")
        XCTAssertTrue(root.contains("private struct AuthenticationFlowView"), "authentication drafts must be owned below the application route boundary")
        XCTAssertFalse(root.contains("@StateObject private var authenticationForm"), "RootView must not observe keystrokes and invalidate the routed hierarchy")
        XCTAssertFalse(root.contains(".fullScreenCover(item: $selectedBudget)"), "the active workspace must not be a temporary child of a Budgets browser")
        XCTAssertEqual(root.components(separatedBy: "ActiveBudgetShell(context: context)").count - 1, 1, "all resolved sources must enter the one product shell route")
        XCTAssertFalse(root.contains("case .deterministicWorkspace"), "deterministic and Live must not have separate workspace routes")
        let shell = root.components(separatedBy: "struct ActiveBudgetShell").last?.components(separatedBy: "private struct WorkspaceCompositionRoot").first ?? ""
        XCTAssertFalse(shell.contains("BudgetSelectionView"), "the active shell must never fall back to the legacy Budgets browser")
        XCTAssertTrue(workspace.contains("WorkspaceCommandRepository"))
        XCTAssertFalse(workspace.contains("dataSource as? DemoWorkspaceDataSource"), "workspace commands must use the common repository contract")
        XCTAssertTrue(workspace.contains("Add your first account"))
        XCTAssertEqual(workspace.components(separatedBy: ".workspaceProfileToolbar").count - 1, 5, "Profile & Settings must be global workspace chrome on every tab")
        XCTAssertTrue(workspace.contains(".id(activeTab)"), "the iOS 27 production shell must materialize the selected tab instead of rendering a blank lazy stack")
        XCTAssertTrue(workspace.contains("intentional identity replacement at the shell boundary"), "the exceptional shell identity boundary must remain documented")
        XCTAssertFalse(workspace.contains("workspaceDismissToolbar"), "the active budget must not navigate back to a Budgets parent")
        XCTAssertTrue(workspace.contains("Create Category Group"))
        XCTAssertTrue(workspace.contains("Add your first category"))
        XCTAssertTrue(workspace.contains("Money you currently have that has not been given a purpose yet."))
        XCTAssertTrue(editor.contains("openingBalanceMinor: balance"))
        XCTAssertFalse(editor.contains("APITransactionCreate("), "production editors must emit canonical application operations")
        XCTAssertFalse(editor.contains("let serverURL"), "editors must submit through the shared workspace store, not own transport configuration")
        XCTAssertFalse(editor.contains("let token"), "credentials must not leak into local editing state")
    }

    func testFreshBudgetActivationIsAuthoritativeCapabilityDrivenAndHasNoLatch() {
        let freshOwner = FreshBudgetActivationState(accountCount: 0, groupCount: 0, categoryCount: 0, canManageStructure: true)
        XCTAssertTrue(freshOwner.needsAccount)
        XCTAssertTrue(freshOwner.showsAddAccount)
        XCTAssertTrue(freshOwner.showsCreateGroup)
        XCTAssertFalse(freshOwner.showsAddCategory)
        XCTAssertFalse(freshOwner.showsNormalPlan)

        let afterGroup = FreshBudgetActivationState(accountCount: 1, groupCount: 1, categoryCount: 0, canManageStructure: true)
        XCTAssertFalse(afterGroup.needsAccount)
        XCTAssertTrue(afterGroup.showsAddAccount, "adding another account remains discoverable")
        XCTAssertFalse(afterGroup.showsCreateGroup)
        XCTAssertTrue(afterGroup.showsAddCategory)

        let populated = FreshBudgetActivationState(accountCount: 1, groupCount: 1, categoryCount: 1, canManageStructure: true)
        XCTAssertTrue(populated.showsNormalPlan)
        XCTAssertTrue(populated.showsAddAccount)

        let restricted = FreshBudgetActivationState(accountCount: 0, groupCount: 0, categoryCount: 0, canManageStructure: false)
        XCTAssertFalse(restricted.showsAddAccount)
        XCTAssertFalse(restricted.showsCreateGroup)
        XCTAssertFalse(restricted.showsAddCategory)
    }

    @MainActor
    func testProductionWorkspaceRendersFreshAccountsAndPlanTabsWithLivePresentationChrome() async {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppSession(
            defaults: defaults,
            keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"),
            initialMode: .deterministic
        )
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")

        let accounts = WorkspaceSelectionHarness(store: store, session: session, destination: 3)
        XCTAssertGreaterThan(renderedContentSignal(accounts), 1_000, "switching Home → Accounts rendered blank")
        let plan = WorkspaceSelectionHarness(store: store, session: session, destination: 1)
        XCTAssertGreaterThan(renderedContentSignal(plan), 1_000, "switching Home → Plan rendered blank")
    }

    @MainActor
    func testScheduledRepositoryCRUDRecurrencesAndFutureIncomeStayNonSpendable() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        XCTAssertEqual(store.scheduledTransactions.count, 5)
        XCTAssertEqual(store.scheduledTransactions.filter(\.isActive).count, 4)
        XCTAssertTrue(store.scheduledTransactions.contains { $0.id == "schedule-inactive" && !$0.isActive })
        XCTAssertEqual(Set(store.scheduledTransactions.map(\.recurrenceUnit)), ["weeks", "months"])
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let before = (store.summary?.readyToAssignMinor, store.balance(for: account), store.transactions.count)
        for unit in ["once", "days", "weeks", "months", "years"] {
            try await store.createSchedule(.init(accountID: account.id, name: "Future \(unit)", amountMinor: 50_000, nextDate: "2026-12-01", recurrenceUnit: unit, intervalCount: unit == "weeks" ? 2 : 1))
            XCTAssertTrue(store.scheduledTransactions.contains { $0.name == "Future \(unit)" && $0.recurrenceUnit == unit })
        }
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.0)
        XCTAssertEqual(store.balance(for: account), before.1)
        XCTAssertEqual(store.transactions.count, before.2)
        XCTAssertTrue(store.forecast?.occurrences.contains { $0.name == "Future years" && $0.amountMinor == 50_000 } == true)

        let edited = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Future months" })
        try await store.updateSchedule(id: edited.id, operation: .init(accountID: account.id, name: "Edited monthly", amountMinor: -1_234, nextDate: "2026-12-02", recurrenceUnit: "months", intervalCount: 3))
        XCTAssertTrue(store.scheduledTransactions.contains { $0.name == "Edited monthly" && $0.intervalCount == 3 })
        try await store.updateSchedule(id: edited.id, operation: .init(accountID: account.id, name: "Edited monthly", amountMinor: -1_234, nextDate: "2026-12-02", recurrenceUnit: "months", intervalCount: 3, isActive: false))
        XCTAssertTrue(store.scheduledTransactions.contains { $0.id == edited.id && !$0.isActive }, "paused schedules remain manageable after reload")
        try await store.updateSchedule(id: edited.id, operation: .init(accountID: account.id, name: "Edited monthly", amountMinor: -1_234, nextDate: "2026-12-02", recurrenceUnit: "months", intervalCount: 3, isActive: true))
        XCTAssertTrue(store.scheduledTransactions.contains { $0.id == edited.id && $0.isActive })
        let deletable = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Future days" })
        try await store.updateSchedule(id: deletable.id, operation: .init(accountID: account.id, name: deletable.name, amountMinor: deletable.amountMinor, nextDate: deletable.nextDate, recurrenceUnit: deletable.recurrenceUnit, intervalCount: deletable.intervalCount, isActive: false))
        try await store.deleteSchedule(id: deletable.id)
        XCTAssertFalse(store.scheduledTransactions.contains { $0.id == deletable.id })
    }

    @MainActor
    func testScheduledProductionSurfacesShareWorkspaceStateAndForecastContract() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let forecast = try XCTUnwrap(store.forecast)
        XCTAssertFalse(forecast.occurrences.isEmpty)
        XCTAssertTrue(forecast.occurrences.contains { $0.destinationAccountID != nil })
        XCTAssertTrue(forecast.occurrences.contains { $0.amountMinor > 0 })
        XCTAssertTrue(forecast.occurrences.contains { $0.accountID == "visa" })
        XCTAssertFalse(forecast.occurrences.contains { $0.scheduledTransactionID == "schedule-inactive" })

        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let contents = try String(contentsOf: source)
        XCTAssertTrue(contents.contains("LiveScheduledTransactionsView"))
        XCTAssertTrue(contents.contains("Upcoming scheduled"))
        XCTAssertTrue(contents.contains("View all scheduled transactions"))
        XCTAssertTrue(contents.contains("Paused · no forecast or realization"))
        XCTAssertTrue(contents.contains("Projected values include schedules but are not spendable"))
    }

    @MainActor
    func testScheduledRealizationAdvancesAndOnceDeactivatesWithWorkspaceRefresh() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let due = BudgetWorkspaceStore.dateString(Date())
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let category = try XCTUnwrap(store.categories.first { $0.id == "electric" })
        try await store.createSchedule(.init(accountID: account.id, categoryID: category.id, name: "Due weekly", amountMinor: -2_500, nextDate: due, recurrenceUnit: "weeks"))
        let recurring = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Due weekly" })
        let activityBefore = store.summary?.categories.first { $0.categoryID == category.id }?.activityMinor
        let transactionCount = store.transactions.count
        let result = try await store.realizeSchedule(id: recurring.id)
        XCTAssertEqual(result.transactionIDs.count, 1)
        XCTAssertEqual(store.transactions.count, transactionCount + 1)
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == category.id }?.activityMinor, (activityBefore ?? 0) - 2_500)
        XCTAssertGreaterThan(try XCTUnwrap(store.scheduledTransactions.first { $0.id == recurring.id }?.nextDate), due)

        try await store.createSchedule(.init(accountID: account.id, categoryID: category.id, name: "One time", amountMinor: -500, nextDate: due, recurrenceUnit: "once"))
        let once = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "One time" })
        let onceResult = try await store.realizeSchedule(id: once.id)
        XCTAssertFalse(onceResult.isActive)
        XCTAssertEqual(store.scheduledTransactions.first { $0.id == once.id }?.isActive, false)
    }

    @MainActor
    func testScheduledTransferAndCardRealizationUseExistingDemoAccountingPaths() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let due = BudgetWorkspaceStore.dateString(Date())
        let checking = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let savings = try XCTUnwrap(store.accounts.first { $0.id == "savings" })
        let checkingBefore = store.balance(for: checking), savingsBefore = store.balance(for: savings)
        try await store.createSchedule(.init(accountID: checking.id, destinationAccountID: savings.id, name: "Due transfer", amountMinor: 1_000, nextDate: due, recurrenceUnit: "months"))
        let transfer = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Due transfer" })
        let transferResult = try await store.realizeSchedule(id: transfer.id)
        XCTAssertEqual(transferResult.transactionIDs.count, 2)
        XCTAssertEqual(store.balance(for: checking), checkingBefore - 1_000)
        XCTAssertEqual(store.balance(for: savings), savingsBefore + 1_000)

        let card = try XCTUnwrap(store.accounts.first { $0.id == "visa" })
        let groceries = try XCTUnwrap(store.categories.first { $0.id == "groceries" })
        let cardBefore = store.balance(for: card)
        let activityBefore = store.summary?.categories.first { $0.categoryID == groceries.id }?.activityMinor ?? 0
        try await store.createSchedule(.init(accountID: card.id, categoryID: groceries.id, name: "Due card purchase", amountMinor: -1_500, nextDate: due, recurrenceUnit: "months"))
        let purchase = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Due card purchase" })
        _ = try await store.realizeSchedule(id: purchase.id)
        XCTAssertEqual(store.balance(for: card), cardBefore - 1_500)
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == groceries.id }?.activityMinor, activityBefore - 1_500)
    }

    @MainActor
    func testTargetMetadataCreateDisableAndDeleteNeverChangesMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let category = try XCTUnwrap(store.categories.first { store.targets[$0.id] == nil })
        let before = (store.summary?.readyToAssignMinor, store.accounts.map { store.balance(for: $0) }, store.transactions.count)
        let initialPlanCost = store.summary?.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) }

        for type in ["monthly_funding", "savings_balance", "target_by_date", "recurring_expense"] {
            let active = type != "savings_balance"
            try await store.saveTarget(categoryID: category.id, value: APICategoryTargetUpsert(targetType: type, targetAmountMinor: 12_345, targetDate: type == "target_by_date" || type == "recurring_expense" ? "2027-09-05" : nil, recurrenceMonths: type == "recurring_expense" ? 12 : nil, minimumContributionMinor: 500, priority: 72, isActive: active))
            let saved = try XCTUnwrap(store.targets[category.id])
            XCTAssertEqual(saved.targetAmountMinor, 12_345)
            XCTAssertEqual(saved.targetType, type)
            XCTAssertEqual(saved.minimumContributionMinor, 500)
            XCTAssertEqual(saved.priority, 72)
            XCTAssertEqual(saved.isActive, active)
            let row = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == category.id })
            XCTAssertEqual(row.targetType, type)
            if active { XCTAssertGreaterThan(row.recommendedContributionMinor ?? 0, 0) }
            else { XCTAssertEqual(row.recommendedContributionMinor, 0) }
        }
        let editedPlanCost = store.summary?.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) }
        XCTAssertNotEqual(editedPlanCost, initialPlanCost, "Monthly Plan Cost must refresh after target edits")
        try await store.deleteTarget(categoryID: category.id)
        XCTAssertNil(store.targets[category.id])
        XCTAssertNil(store.summary?.categories.first { $0.categoryID == category.id }?.targetType)
        XCTAssertEqual(store.summary?.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) }, initialPlanCost)
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.0)
        XCTAssertEqual(store.accounts.map { store.balance(for: $0) }, before.1)
        XCTAssertEqual(store.transactions.count, before.2)
    }

    func testSpendingBreakdownBuildsRankedCategoryAndGroupSlicesFromReportContract() throws {
        let report = try JSONDecoder().decode(APISpendingReport.self, from: Data(#"{"start_date":"2026-08-01","end_date":"2026-08-31","currency_code":"USD","total_spending_minor":10000,"categories":[{"category_id":"food","category_name":"Food","category_group":"Everyday","spending_minor":7001,"transaction_ids":["purchase","refund","split"]},{"category_id":"fuel","category_name":"Fuel","category_group":"Everyday","spending_minor":2999,"transaction_ids":["split"]}]}"#.utf8))

        let categories = SpendingBreakdownSlice.make(from: report, mode: .category)
        XCTAssertEqual(categories.map(\.id), ["food", "fuel"])
        XCTAssertEqual(categories.map(\.spendingMinor), [7_001, 2_999])
        XCTAssertEqual(categories[0].percentage(of: report.totalSpendingMinor), 0.7001, accuracy: 0.000_001)

        let groups = SpendingBreakdownSlice.make(from: report, mode: .group)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].spendingMinor, report.totalSpendingMinor)
        XCTAssertEqual(Set(groups[0].transactionIDs), ["purchase", "refund", "split"])
    }

    func testProductionSpendingBreakdownRetainsSectorMarkPath() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let contents = try String(contentsOf: source)
        XCTAssertTrue(contents.contains("SectorMark(angle:"))
        XCTAssertTrue(contents.contains("spending-breakdown-sector-chart"))
    }

    @MainActor
    func testDemoAllocationHistoryMatchesLiveContractShape() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        // The same production category-detail view reads store.allocationOperations for demo and live.
        XCTAssertFalse(store.allocationOperations.isEmpty, "demo must emit allocation history like live")
        // Every operation balances to zero, exactly like the server allocation ledger.
        for operation in store.allocationOperations {
            XCTAssertEqual(operation.postings.reduce(Int64(0)) { $0 + $1.amountMinor }, 0)
        }
        // History includes an assignment and a category-to-category move (money in / money out).
        XCTAssertTrue(store.allocationOperations.contains { $0.kind == "assignment" })
        XCTAssertTrue(store.allocationOperations.contains { $0.kind == "category_transfer" })
        // At least one posting attributes to a real demo category, so category detail can filter it.
        let categoryIDs = Set(store.categories.map(\.id))
        XCTAssertTrue(store.allocationOperations.contains { operation in
            operation.postings.contains { $0.categoryID.map(categoryIDs.contains) == true }
        })
    }

    @MainActor
    func testAccountRegisterScopesOrdersAndDescribesProductionTransactions() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let account = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let destination = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        try await store.createTransfer(TransferMoneyOperation(sourceAccountID: account.id, destinationAccountID: destination.id, amountMinor: 500, occurredOn: "2026-09-05", memo: "Register transfer", isCleared: true))
        let rows = store.transactions(for: account)

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.accountID == account.id })
        XCTAssertEqual(rows.map(\.occurredOn), rows.map(\.occurredOn).sorted(by: >))
        XCTAssertTrue(rows.contains { $0.transferID != nil })
        XCTAssertTrue(store.transactions(for: destination).contains { $0.transferID != nil })
        XCTAssertTrue(rows.contains { !$0.splits.isEmpty })
        XCTAssertEqual(store.balance(for: account), store.clearedBalance(for: account) + store.unclearedBalance(for: account))
    }

    @MainActor
    func testAccountRegisterReflectsCreateEditAndDeleteRefreshes() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let checking = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let savings = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        let category = try XCTUnwrap(store.categories.first(where: { !$0.isArchived }))
        let originalCount = store.transactions(for: checking).count
        let value = RecordTransactionOperation(accountID: checking.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-05", payeeName: "Register regression", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [])

        try await store.createTransaction(value)
        let created = try XCTUnwrap(store.transactions.first(where: { $0.payeeName == "Register regression" }))
        XCTAssertEqual(store.transactions(for: checking).count, originalCount + 1)

        let moved = RecordTransactionOperation(accountID: savings.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-05", payeeName: "Register regression", memo: "moved", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await store.updateTransaction(id: created.id, operation: moved)
        XCTAssertFalse(store.transactions(for: checking).contains { $0.id == created.id })
        XCTAssertTrue(store.transactions(for: savings).contains { $0.id == created.id && $0.isCleared })

        try await store.deleteTransaction(id: created.id)
        XCTAssertFalse(store.transactions.contains { $0.id == created.id })
    }

    @MainActor
    func testHouseholdProfileHierarchyResolvesSharedDependenciesWhenRendered() throws {
        let session = AppSession()
        let store = BudgetWorkspaceStore.demo()
        let member = try JSONDecoder().decode(
            APIHouseholdMember.self,
            from: Data(#"{"user_id":"member-1","email":"member@example.com","display_name":"Member","role":"member","is_active":true}"#.utf8)
        )

        let household = LiveHouseholdView(session: session, store: store)
        let delegated = LiveDelegatedPolicyView(session: session, store: store, member: member)
        XCTAssertTrue(household.session === session)
        XCTAssertTrue(household.store === store)
        XCTAssertTrue(delegated.session === session)
        XCTAssertTrue(delegated.store === store)

        // Rendering both roots forces SwiftUI to resolve every dynamic property.
        // A missing EnvironmentObject traps here instead of escaping to manual QA.
        render(household.environmentObject(session).environmentObject(store))
        render(delegated.environmentObject(session).environmentObject(store))
    }

    @MainActor
    func testDataSourceModeAndServerURLPersistAcrossSessionRelaunch() async throws {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = "BudgetAppTests.\(UUID().uuidString)"
        let factory = connectionClientFactory { request in
            switch request.url?.path {
            case "/api/v1/health":
                return Self.response(request, body: #"{"status":"ok"}"#)
            case "/api/v1/bootstrap/status":
                return Self.response(request, body: #"{"initialized":true,"authentication_required":true,"api_version":"0.4.0"}"#)
            default:
                XCTFail("Unexpected connection request: \(request.url?.path ?? "nil")")
                return Self.response(request, body: "{}")
            }
        }
        let first = AppSession(defaults: defaults, keychain: KeychainStore(service: service), clientFactory: factory, initialMode: .deterministic)
        await first.configureServer("http://127.0.0.1:8000")
        XCTAssertEqual(first.composition, .liveServer)
        XCTAssertEqual(first.connectionStatus, .authenticationRequired)

        let relaunched = AppSession(defaults: defaults, keychain: KeychainStore(service: service), clientFactory: factory)
        XCTAssertEqual(relaunched.sourceMode, .liveServer)
        XCTAssertEqual(relaunched.serverURL?.absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(relaunched.composition, .liveServer)
        relaunched.selectDeterministic()
        let demoRelaunch = AppSession(defaults: defaults, keychain: KeychainStore(service: service), clientFactory: factory)
        XCTAssertEqual(demoRelaunch.composition, .deterministic)
    }

    @MainActor
    func testUnreachableAndInvalidLiveServerNeverFallBackToDemo() async {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let unreachable = AppSession(
            defaults: defaults,
            keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"),
            clientFactory: connectionClientFactory { _ in throw URLError(.cannotConnectToHost) },
            initialMode: .deterministic
        )
        await unreachable.configureServer("http://127.0.0.1:65530")
        XCTAssertEqual(unreachable.composition, .liveServer)
        guard case .unreachable = unreachable.connectionStatus else { return XCTFail("Expected unreachable live state") }

        let invalid = AppSession(defaults: defaults, keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"), initialMode: .deterministic)
        await invalid.configureServer("not a server URL")
        XCTAssertEqual(invalid.composition, .liveServer)
        guard case .invalidConfiguration = invalid.connectionStatus else { return XCTFail("Expected invalid live configuration") }
    }

    @MainActor
    func testChangingCompositionDoesNotMutateDeterministicFinancialState() async {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let before = (store.transactions.count, store.summary?.readyToAssignMinor, store.summary?.categories.map(\.availableMinor))
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppSession(
            defaults: defaults,
            keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"),
            clientFactory: connectionClientFactory { request in Self.response(request, body: #"{"status":"ok"}"#) },
            initialMode: .deterministic
        )
        await session.configureServer("http://127.0.0.1:8000")
        XCTAssertEqual(session.composition, .liveServer)
        XCTAssertEqual(store.transactions.count, before.0)
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.1)
        XCTAssertEqual(store.summary?.categories.map(\.availableMinor), before.2)
    }

    func testCurrencyTextAcceptsNaturalDecimalZeroAndSignedInput() {
        XCTAssertEqual(CurrencyText.parseMinorUnits("12.34", currencyCode: "USD"), 1_234)
        XCTAssertEqual(CurrencyText.parseMinorUnits("0", currencyCode: "USD"), 0)
        XCTAssertEqual(CurrencyText.parseMinorUnits("-12.34", currencyCode: "USD"), -1_234)
        XCTAssertNil(CurrencyText.parseMinorUnits("12.345", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("not money", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits(".", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("-", currencyCode: "USD"))
        XCTAssertEqual(CurrencyText.parseMinorUnits("820.00", currencyCode: "USD"), 82_000)
    }

    @MainActor
    func testEditingAssignmentTotalPreservesActivityAndAppliesOnlyExactDelta() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let groceries = try XCTUnwrap(store.summary?.categories.first(where: { $0.name == "Groceries" }))
        XCTAssertEqual(groceries.assignedMinor, 72_000)
        XCTAssertEqual(groceries.activityMinor, -48_264)
        XCTAssertEqual(store.summary?.readyToAssignMinor, 320_000)

        try await store.updateAssignment(categoryID: groceries.categoryID, month: "2026-09-01", assignedMinor: 82_000, expectedVersion: store.summary!.allocationVersion)

        let updated = try XCTUnwrap(store.summary?.categories.first(where: { $0.categoryID == groceries.categoryID }))
        XCTAssertEqual(updated.assignedMinor, 82_000)
        XCTAssertEqual(updated.activityMinor, -48_264)
        XCTAssertEqual(updated.availableMinor, 33_736)
        XCTAssertEqual(store.summary?.readyToAssignMinor, 310_000)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let domain = "BudgetAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    private func connectionClientFactory(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> (URL) throws -> APIClient {
        ConnectionURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return { try APIClient(baseURL: $0, session: session) }
    }

    private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    func testCurrencyTextEditableRoundTripsWithoutDoublePrecision() {
        for value: Int64 in [0, 1, -1, 12_345, -98_765, 9_007_199_254_740_991] {
            let text = CurrencyText.editable(value, currencyCode: "USD")
            XCTAssertEqual(CurrencyText.parseMinorUnits(text, currencyCode: "USD"), value)
        }
    }

    @MainActor
    func testSeedIsDeterministicAndHasTwelveMonthsOfActivity() {
        let first = DemoStore()
        let second = DemoStore()
        XCTAssertEqual(first.accounts, second.accounts)
        XCTAssertEqual(first.categories, second.categories)
        XCTAssertEqual(first.transactions, second.transactions)
        XCTAssertGreaterThanOrEqual(first.transactions.count, 70)
    }

    @MainActor
    func testChildVisibilityExcludesHouseholdAccountsAndOtherCategories() {
        let store = DemoStore()
        store.persona = .alex
        XCTAssertTrue(store.visibleAccounts.isEmpty)
        XCTAssertEqual(Set(store.visibleCategories.map(\.id)), ["alexallow", "alexsave", "alexgive"])
        XCTAssertTrue(store.visibleTransactions.allSatisfy { $0.member == .alex })
    }

    @MainActor
    func testMoveMoneyPreservesTotalAvailable() {
        let store = DemoStore()
        let before = store.categories.reduce(Int64(0)) { $0 + $1.available }
        store.move(amount: 5_000, from: "emergency", to: "fuel")
        XCTAssertEqual(store.categories.reduce(Int64(0)) { $0 + $1.available }, before)
    }

    @MainActor
    func testPartialApprovalFundsOnlyApprovedAmount() {
        let store = DemoStore()
        let before = store.categories.first { $0.id == "alexallow" }!.available
        let sourceBefore = store.categories.first { $0.id == "buffer" }!.available
        store.approve("request-game", amount: 2_000)
        XCTAssertEqual(store.requests.first { $0.id == "request-game" }?.status, "Partially approved")
        XCTAssertEqual(store.categories.first { $0.id == "alexallow" }?.available, before + 2_000)
        XCTAssertEqual(store.categories.first { $0.id == "buffer" }?.available, sourceBefore - 2_000)
    }

    @MainActor
    func testHideAmountsMasksCurrency() {
        let store = DemoStore()
        store.hideAmounts = true
        XCTAssertEqual(store.money(123_45), "••••")
    }

    @MainActor
    func testSmartAssignmentConsumesReadyToAssignWithoutCreatingMoney() {
        let store = DemoStore()
        let before = store.readyToAssign + store.categories.reduce(0) { $0 + $1.available }
        store.assign(amount: 12_345, to: "fuel")
        XCTAssertEqual(store.readyToAssign + store.categories.reduce(0) { $0 + $1.available }, before)
    }

    @MainActor
    func testSplitTransactionPreservesEveryMinorUnit() {
        let store = DemoStore()
        let before = store.categories.filter { ["groceries", "dining", "fuel"].contains($0.id) }.reduce(0) { $0 + $1.available }
        store.addTransaction(payee: "Split", amount: 101, accountID: "checking", categoryIDs: ["groceries", "dining", "fuel"], memo: "", attachment: false)
        let after = store.categories.filter { ["groceries", "dining", "fuel"].contains($0.id) }.reduce(0) { $0 + $1.available }
        XCTAssertEqual(before - after, 101)
    }

    @MainActor
    func testSharedEditorPreservesExactSplitsAndChangedDate() {
        let store = DemoStore()
        let changedDate = Date.demo(monthsAgo: 2, day: 14)
        XCTAssertTrue(store.updateTransactionSigned(
            id: "t4", payee: "Corrected split", signedAmount: -12_640,
            date: changedDate, accountID: "checking",
            categoryAmounts: ["repair": -10_001, "maintenance": -2_639],
            memo: "Exact correction", cleared: true, flag: "Reviewed",
            tags: ["home"], attachmentName: "invoice.pdf"
        ))
        let transaction = store.transactions.first { $0.id == "t4" }!
        XCTAssertEqual(transaction.date, changedDate)
        XCTAssertEqual(transaction.categoryAmounts, ["repair": -10_001, "maintenance": -2_639])
        XCTAssertEqual(transaction.tags, ["home"])
        XCTAssertEqual(transaction.attachmentName, "invoice.pdf")
    }

    @MainActor
    func testEditingCategoryPropagatesToInsightsAndBalances() {
        let store = DemoStore()
        let diningBefore = store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "dining" }!.1
        let groceriesBefore = store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "groceries" }!.1
        let balanceBefore = store.accounts.first { $0.id == "visa" }!.balance
        XCTAssertTrue(store.updateTransaction(id: "t1", payee: "Fresh Market", amount: 12_500, accountID: "visa", categoryIDs: ["dining"], memo: "Corrected", cleared: true, flag: nil))
        XCTAssertEqual(store.accounts.first { $0.id == "visa" }!.balance, balanceBefore)
        XCTAssertEqual(store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "dining" }!.1, diningBefore + 12_500)
        XCTAssertNil(store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "groceries" && $0.1 == groceriesBefore })
    }

    @MainActor
    func testReconcileCreatesExplicitAdjustmentAndUpdatesBalance() {
        let store = DemoStore()
        let accountBefore = store.accounts.first { $0.id == "checking" }!
        let statement = accountBefore.cleared + 1_000
        XCTAssertTrue(store.reconcile(accountID: "checking", statementBalance: statement))
        let accountAfter = store.accounts.first { $0.id == "checking" }!
        XCTAssertEqual(accountAfter.cleared, statement)
        XCTAssertEqual(accountAfter.balance, accountBefore.balance + 1_000)
        XCTAssertEqual(store.transactions.first?.payee, "Reconciliation adjustment")
        XCTAssertTrue(store.transactions.first?.reconciled == true)
    }

    @MainActor
    func testDelegatedCategoryCreationCannotExceedAuthority() {
        let store = DemoStore()
        store.persona = .alex
        let available = store.delegatedReadyToAssign
        XCTAssertFalse(store.createCategory(name: "Too Much", initialAssignment: available + 1))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.createCategory(name: "Concert", initialAssignment: available))
        XCTAssertEqual(store.delegatedReadyToAssign, 0)
        XCTAssertEqual(store.visibleCategories.last?.name, "Concert")
    }

    @MainActor
    func testDelegatedMoveCannotTouchParentCategory() {
        let store = DemoStore()
        store.persona = .alex
        XCTAssertFalse(store.move(amount: 100, from: "alexallow", to: "groceries"))
        XCTAssertEqual(store.errorMessage, DemoMutationError.restrictedCategory.localizedDescription)
    }

    @MainActor
    private func render<Content: View>(_ view: Content) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private func renderedContentSignal<Content: View>(_ view: Content) -> Int {
        let controller = UIHostingController(rootView: view)
        let frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let window = UIWindow(frame: frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func contentSignal() -> Int {
          let image = UIGraphicsImageRenderer(size: frame.size).image { _ in
              controller.view.drawHierarchy(in: frame, afterScreenUpdates: true)
          }
          guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
          let width = cgImage.width, height = cgImage.height, bytesPerRow = cgImage.bytesPerRow
          var signal = 0
          // Exclude tab/navigation chrome: those controls must not make a blank tab pass.
          for y in stride(from: height / 5, to: height * 3 / 4, by: 3) {
            for x in stride(from: width / 12, to: width * 11 / 12, by: 3) {
              let offset = y * bytesPerRow + x * 4
              let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
              if max(r, g, b) - min(r, g, b) > 28 || max(r, g, b) < 175 { signal += 1 }
            }
          }
          return signal
        }
        let signal = contentSignal()
        window.isHidden = true
        window.rootViewController = nil
        return signal
    }
}

private struct WorkspaceSelectionHarness: View {
    let store: BudgetWorkspaceStore
    let session: AppSession
    let destination: Int
    @State private var selection = 0
    var body: some View {
        BudgetWorkspaceView(testStore: store, selection: $selection)
            .environmentObject(session)
            .onAppear { DispatchQueue.main.async { selection = destination } }
    }
}

private final class ConnectionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
