import XCTest
@testable import Budget_App

final class DemoStoreTests: XCTestCase {
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
}
