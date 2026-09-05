import XCTest
import SwiftUI
import UIKit
import BudgetAPI
@testable import Budget_App

final class DemoStoreTests: XCTestCase {
    @MainActor
    func testTargetMetadataCreateDisableAndDeleteNeverChangesMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let category = try XCTUnwrap(store.categories.first)
        let before = (store.summary?.readyToAssignMinor, store.accounts.map { store.balance(for: $0) }, store.transactions.count)

        for type in ["monthly_funding", "savings_balance", "target_by_date", "recurring_expense"] {
            try await store.saveTarget(categoryID: category.id, value: APICategoryTargetUpsert(targetType: type, targetAmountMinor: 12_345, targetDate: type == "target_by_date" || type == "recurring_expense" ? "2027-09-05" : nil, recurrenceMonths: type == "recurring_expense" ? 12 : nil, isActive: type != "savings_balance"))
            XCTAssertEqual(store.targets[category.id]?.targetAmountMinor, type == "savings_balance" ? nil : 12_345)
        }
        try await store.deleteTarget(categoryID: category.id)
        XCTAssertNil(store.targets[category.id])
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
    func testAccountRegisterScopesOrdersAndDescribesProductionTransactions() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let account = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let destination = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        try await store.createTransfer(APITransferCreate(sourceAccountID: account.id, destinationAccountID: destination.id, amountMinor: 500, occurredOn: "2026-09-05", memo: "Register transfer", isCleared: true))
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
        let value = APITransactionCreate(accountID: checking.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-05", payeeName: "Register regression", memo: "", isCleared: false)

        try await store.createTransaction(value)
        let created = try XCTUnwrap(store.transactions.first(where: { $0.payeeName == "Register regression" }))
        XCTAssertEqual(store.transactions(for: checking).count, originalCount + 1)

        let moved = APITransactionCreate(accountID: savings.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-05", payeeName: "Register regression", memo: "moved", isCleared: true)
        try await store.updateTransaction(id: created.id, value: moved)
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

    func testCurrencyTextAcceptsNaturalDecimalZeroAndSignedInput() {
        XCTAssertEqual(CurrencyText.parseMinorUnits("12.34", currencyCode: "USD"), 1_234)
        XCTAssertEqual(CurrencyText.parseMinorUnits("0", currencyCode: "USD"), 0)
        XCTAssertEqual(CurrencyText.parseMinorUnits("-12.34", currencyCode: "USD"), -1_234)
        XCTAssertNil(CurrencyText.parseMinorUnits("12.345", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("not money", currencyCode: "USD"))
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
    }
}
