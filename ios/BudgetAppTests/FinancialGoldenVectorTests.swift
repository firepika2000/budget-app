import XCTest
import BudgetAPI
@testable import Budget_App

final class FinancialGoldenVectorTests: XCTestCase {
    @MainActor
    func testDemoReconciliationUsesCurrentCapabilityAndAccountScopeWithoutPartialLocks() async throws {
        let source = DemoWorkspaceDataSource()
        let checking = try XCTUnwrap(source.demo.accounts.first { $0.id == "checking" })
        let operation = ReconcileAccountOperation(accountID: checking.id, statementBalanceMinor: checking.cleared, throughDate: "2099-12-31", createAdjustment: false, reason: "", expectedClearedBalanceMinor: checking.cleared)
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_accounts"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        do { try await source.reconcileAccount(operation); XCTFail("Revoked reconciliation capability") }
        catch APIClientError.server(let status, _) { XCTAssertEqual(status, 403) }
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["reconcile_account"], restrictAccounts: true, accountIDs: ["savings"], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        do { try await source.reconcileAccount(operation); XCTFail("Hidden account reconciliation") }
        catch APIClientError.server(let status, _) { XCTAssertEqual(status, 404) }
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["reconcile_account"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: 2))
        source.demo.persona = .partner
        try await source.reconcileAccount(operation)
        XCTAssertEqual(source.demo.accounts.map(\.balance), accounts.map(\.balance))
        XCTAssertEqual(source.demo.accounts.first { $0.id == checking.id }?.reconciledBalance, checking.cleared)
        XCTAssertTrue(source.demo.transactions.filter { $0.accountID == checking.id && $0.cleared }.allSatisfy(\.reconciled))
        XCTAssertEqual(source.demo.transactions.filter { $0.accountID != checking.id }, transactions.filter { $0.accountID != checking.id })
    }

    @MainActor
    func testDemoTransferAuthorityCoversBothLegsAndRefusesInvalidDatesAtomically() async throws {
        let source = DemoWorkspaceDataSource(now: { BudgetWorkspaceStore.parseDate("2026-09-15") })
        func operation(destination: String = "savings", date: String = "2026-09-01") -> TransferMoneyOperation {
            .init(sourceAccountID: "checking", destinationAccountID: destination, amountMinor: 100, occurredOn: date, memo: "Scope proof", isCleared: false)
        }
        let opening = source.demo.accounts
        try await source.transferMoney(operation())
        let id = try XCTUnwrap(source.demo.transactions.first?.transferID)
        func refused(_ status: Int, action: () async throws -> Void) async throws {
            let accounts = source.demo.accounts, transactions = source.demo.transactions
            do { try await action(); XCTFail("Unauthorized transfer mutation") }
            catch APIClientError.server(let actual, _) { XCTAssertEqual(actual, status) }
            XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        }
        for date in ["invalid", "2026-02-30", "2026-09-16"] {
            try await refused(422) { try await source.transferMoney(operation(date: date)) }
            try await refused(422) { try await source.updateTransfer(id: id, operation: operation(date: date)) }
        }
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        try await refused(403) { try await source.transferMoney(operation()) }
        try await refused(403) { try await source.updateTransfer(id: id, operation: operation()) }
        try await refused(403) { try await source.deleteTransfer(id: id) }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["create_transaction", "edit_transaction", "delete_transaction", "manage_budget_structure"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        try await refused(422) { try await source.transferMoney(operation()) }
        try await refused(404) { try await source.updateTransfer(id: id, operation: operation()) }
        try await refused(404) { try await source.deleteTransfer(id: id) }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["edit_transaction", "delete_transaction"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 2))
        source.demo.persona = .partner
        try await refused(403) { try await source.updateTransfer(id: id, operation: operation()) }
        try await refused(403) { try await source.deleteTransfer(id: id) }
        source.demo.persona = .rey
        let index = try XCTUnwrap(source.demo.transactions.firstIndex { $0.transferID == id })
        source.demo.transactions[index].reconciled = true
        try await refused(409) { try await source.deleteTransfer(id: id) }
        source.demo.transactions[index].reconciled = false
        try await source.deleteTransfer(id: id)
        XCTAssertEqual(source.demo.accounts, opening)
        XCTAssertFalse(source.demo.transactions.contains { $0.transferID == id })
    }

    @MainActor
    func testDemoScheduleShapeValidationIsAtomicForCreateUpdateAndStoredRealization() async throws {
        let source = DemoWorkspaceDataSource(now: { BudgetWorkspaceStore.parseDate("2026-09-15") })
        func value(account: String = "checking", destination: String? = nil, category: String? = nil,
                   payee: String? = nil, name: String = "Validation", amount: Int64 = -100,
                   date: String = "2026-09-01", unit: String = "once", interval: Int = 1,
                   memo: String = "", classification: String? = nil) -> ScheduleOperation {
            .init(accountID: account, destinationAccountID: destination, categoryID: category, payeeID: payee,
                  name: name, amountMinor: amount, nextDate: date, recurrenceUnit: unit, intervalCount: interval,
                  memo: memo, financialClassification: classification)
        }
        try await source.createSchedule(value())
        let id = try XCTUnwrap(source.demo.schedules.last?.id)
        let accounts = source.demo.accounts, transactions = source.demo.transactions, schedules = source.demo.schedules
        let invalid = [value(amount: 0), value(date: "not-a-date"), value(date: "2026-02-30"),
                       value(date: "2026-9-1"), value(date: "0000-01-01"), value(unit: "month"),
                       value(unit: "weeks", interval: .max), value(interval: 0), value(interval: -1), value(interval: 366),
                       value(name: ""), value(name: String(repeating: "n", count: 151)), value(memo: String(repeating: "m", count: 501)),
                       value(destination: "checking", amount: 100), value(destination: "savings", amount: -100),
                       value(destination: "savings", category: "groceries", amount: 100), value(destination: "savings", payee: "payee", amount: 100),
                       value(classification: "interest_charge"), value(classification: "unknown"),
                       value(account: "visa", amount: 100, classification: "interest_charge"), value(account: "auto", category: "groceries")]
        for operation in invalid {
            do { try await source.createSchedule(operation); XCTFail("Invalid creation: \(operation)") }
            catch APIClientError.server(let status, _) { XCTAssertEqual(status, 422) }
            do { try await source.updateSchedule(id: id, operation: operation); XCTFail("Invalid update") }
            catch APIClientError.server(let status, _) { XCTAssertEqual(status, 422) }
            XCTAssertEqual(source.demo.schedules, schedules)
            XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        }
        let index = try XCTUnwrap(source.demo.schedules.firstIndex { $0.id == id })
        source.demo.schedules[index].recurrenceUnit = "weeks"
        source.demo.schedules[index].intervalCount = .max
        let malformed = source.demo.schedules
        do { _ = try await source.realizeSchedule(id: id); XCTFail("Malformed stored recurrence must not post") }
        catch APIClientError.server(let status, _) { XCTAssertEqual(status, 422) }
        let month = BudgetWorkspaceStore.parseDate("2026-09-01")
        let query = WorkspaceReportQuery(start: month, end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        do { _ = try await source.snapshot(planMonth: month, report: query); XCTFail("Malformed recurrence must not enter forecast expansion") }
        catch APIClientError.server(let status, _) { XCTAssertEqual(status, 422) }
        XCTAssertEqual(source.demo.schedules, malformed)
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        source.demo.schedules = schedules
        for unit in ["once", "days", "weeks", "months", "years"] {
            try await source.createSchedule(value(date: "2028-02-29", unit: unit, interval: 365))
        }
        do { try await source.createScheduleFromTransaction(id: "t1", operation: .init(recurrenceUnit: "once", intervalCount: 1, nextDate: "2027-01-01")); XCTFail("Make Recurring must recur") }
        catch APIClientError.server(let status, _) { XCTAssertEqual(status, 422) }
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
    }

    @MainActor
    func testDemoSchedulesRecheckCurrentCapabilitiesAndBothResourceScopesBeforeRealization() async throws {
        let source = DemoWorkspaceDataSource(now: { BudgetWorkspaceStore.parseDate("2026-09-15") })
        let expense = ScheduleOperation(accountID: "checking", categoryID: "groceries", name: "Scope guard", amountMinor: -100, nextDate: "2026-09-01", recurrenceUnit: "once")
        let transfer = ScheduleOperation(accountID: "checking", destinationAccountID: "savings", name: "Private transfer", amountMinor: 100, nextDate: "2026-09-01", recurrenceUnit: "once")
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        try await source.createSchedule(expense)
        let id = try XCTUnwrap(source.demo.schedules.last?.id)
        try await source.createSchedule(transfer)
        let transferID = try XCTUnwrap(source.demo.schedules.last?.id)
        func refused(_ status: Int, action: () async throws -> Void) async throws {
            let schedules = source.demo.schedules
            do { try await action(); XCTFail("Unauthorized schedule operation") }
            catch APIClientError.server(let actual, _) { XCTAssertEqual(actual, status) }
            XCTAssertEqual(source.demo.schedules, schedules)
            XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        }
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        try await refused(403) { try await source.createSchedule(expense) }
        try await refused(403) { try await source.updateSchedule(id: id, operation: expense) }
        try await refused(403) { try await source.deleteSchedule(id: id) }
        try await refused(403) { _ = try await source.realizeSchedule(id: id) }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["manage_planning", "create_transaction"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: true, categoryIDs: ["dining"], expectedVersion: 1))
        source.demo.persona = .partner
        try await refused(404) { _ = try await source.realizeSchedule(id: id) }
        try await refused(404) { try await source.updateSchedule(id: id, operation: expense) }
        try await refused(404) { try await source.deleteSchedule(id: transferID) }
        try await refused(422) { try await source.createSchedule(expense) }
        try await refused(422) { try await source.createSchedule(transfer) }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["create_transaction"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: true, categoryIDs: ["groceries"], expectedVersion: 2))
        source.demo.persona = .partner
        let result = try await source.realizeSchedule(id: id)
        XCTAssertFalse(result.isActive); XCTAssertEqual(result.transactionIDs.count, 1)
        XCTAssertEqual(source.demo.transactions.count, transactions.count + 1)
        XCTAssertEqual(source.demo.accounts.first { $0.id == "checking" }?.balance, accounts.first { $0.id == "checking" }!.balance - 100)
        XCTAssertEqual(source.demo.schedules.first { $0.id == transferID }?.isActive, true)
    }

    @MainActor
    func testDemoLifecycleCommandsRecheckAuthorityAndRefuseReversalOverflowAtomically() async throws {
        let source = DemoWorkspaceDataSource(now: { BudgetWorkspaceStore.parseDate("2026-09-15") })
        let recurrence = MakeRecurringOperation(recurrenceUnit: "months", intervalCount: 1, nextDate: "2027-01-01")
        let actions: [() async throws -> Void] = [
            { try await source.duplicateTransaction(id: "t1", occurredOn: "2026-09-15") },
            { try await source.voidTransaction(id: "t1", reason: "Denied") },
            { try await source.createScheduleFromTransaction(id: "t1", operation: recurrence) }
        ]
        let original = source.demo.transactions, accounts = source.demo.accounts, schedules = source.demo.schedules
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        for action in actions {
            do { try await action(); XCTFail("Missing command capability") }
            catch APIClientError.server(let status, _) { XCTAssertEqual(status, 403) }
        }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["create_transaction", "delete_transaction", "manage_planning", "manage_budget_structure"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        for action in actions {
            do { try await action(); XCTFail("Hidden source") }
            catch APIClientError.server(let status, _) { XCTAssertEqual(status, 404) }
        }
        XCTAssertEqual(source.demo.transactions, original); XCTAssertEqual(source.demo.accounts, accounts)
        XCTAssertEqual(source.demo.schedules, schedules)
        source.demo.persona = .rey
        let index = try XCTUnwrap(source.demo.transactions.firstIndex { $0.id == "t1" })
        source.demo.transactions[index].amount = .min
        let before = source.demo.transactions
        do { try await source.voidTransaction(id: "t1", reason: "Overflow"); XCTFail("Unrepresentable reversal") } catch {}
        XCTAssertEqual(source.demo.transactions, before); XCTAssertEqual(source.demo.accounts, accounts)
        source.demo.transactions = original
        try await source.voidTransaction(id: "t1", reason: "Authorized correction")
        let reversal = try XCTUnwrap(source.demo.transactions.first { $0.reversalOfTransactionID == "t1" })
        XCTAssertEqual(BudgetWorkspaceStore.dateString(reversal.date), "2026-09-15")
        XCTAssertEqual(reversal.amount, 12500)
        let after = source.demo.transactions
        do { try await source.duplicateTransaction(id: "t1", occurredOn: "2026-09-15"); XCTFail("Voided duplication") } catch {}
        XCTAssertEqual(source.demo.transactions, after)
    }

    @MainActor
    func testDemoTransactionCommandsEnforceCurrentAuthorityAndPreserveOriginalCreator() async throws {
        let source = DemoWorkspaceDataSource()
        func operation(account: String = "checking", category: String = "groceries", amount: Int64 = -100) -> RecordTransactionOperation {
            .init(accountID: account, categoryID: category, amountMinor: amount, occurredOn: "2026-09-01", payeeName: "Command authority", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [])
        }
        source.demo.persona = .partner
        try await source.recordTransaction(operation())
        let id = try XCTUnwrap(source.demo.transactions.first?.id)
        source.demo.persona = .rey
        try await source.updateTransaction(id: id, operation: operation(amount: -120))
        XCTAssertEqual(source.demo.transactions.first { $0.id == id }?.member, .partner)
        let observation = try await source.browseTransactions(query: .init(search: "Command authority"))
        XCTAssertEqual(observation.items.first?.createdByUserID, "jordan")
        func refused(_ status: Int, action: () async throws -> Void) async throws {
            let before = source.demo.transactions, accounts = source.demo.accounts
            do { try await action(); XCTFail("Unauthorized transaction mutation") }
            catch APIClientError.server(let actual, _) { XCTAssertEqual(actual, status) }
            XCTAssertEqual(source.demo.transactions, before); XCTAssertEqual(source.demo.accounts, accounts)
        }
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        try await refused(403) { try await source.recordTransaction(operation()) }
        try await refused(403) { try await source.updateTransaction(id: id, operation: operation()) }
        try await refused(403) { try await source.deleteTransaction(id: id) }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["create_transaction", "edit_transaction", "delete_transaction"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: true, categoryIDs: ["groceries"], expectedVersion: 1))
        source.demo.persona = .partner
        try await refused(422) { try await source.recordTransaction(operation(account: "visa")) }
        try await refused(422) { try await source.recordTransaction(operation(category: "dining")) }
        try await refused(422) { try await source.updateTransaction(id: id, operation: operation(category: "dining")) }
        try await refused(404) { try await source.deleteTransaction(id: "t1") }
        try await source.updateTransaction(id: id, operation: operation(amount: -130))
        XCTAssertEqual(source.demo.transactions.first { $0.id == id }?.member, .partner)
        try await source.deleteTransaction(id: id)
        XCTAssertFalse(source.demo.transactions.contains { $0.id == id })
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["edit_transaction", "delete_transaction"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 2))
        source.demo.persona = .partner
        try await refused(403) { try await source.updateTransaction(id: "t1", operation: operation()) }
        try await refused(403) { try await source.deleteTransaction(id: "t1") }
        source.demo.persona = .rey
        try await refused(409) { try await source.deleteTransaction(id: "t1") }
    }

    @MainActor
    func testDemoBulkMutationRechecksCapabilityScopeOwnershipAndLifecycleAtomically() async throws {
        let source = DemoWorkspaceDataSource()
        let original = source.demo.transactions, accounts = source.demo.accounts
        func refused(_ ids: [String], status: Int) async throws {
            let before = source.demo.transactions
            do { try await source.bulkUpdateTransactions(.init(transactionIDs: ids, action: "set_cleared", cleared: true)); XCTFail("Unauthorized bulk mutation") }
            catch APIClientError.server(let actual, _) { XCTAssertEqual(actual, status) }
            XCTAssertEqual(source.demo.transactions, before)
            XCTAssertEqual(source.demo.accounts, accounts)
        }
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        try await refused(["t1"], status: 403)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["edit_transaction", "manage_budget_structure"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        try await refused(["t1"], status: 404)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["edit_transaction"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 2))
        source.demo.persona = .partner
        try await refused(["t1"], status: 403)
        source.demo.persona = .rey
        try await refused(["t1", "missing"], status: 404)
        try await refused(["t1", "t1"], status: 422)
        try await refused([], status: 422)
        try await refused((0..<201).map { "id-\($0)" }, status: 422)
        let index = try XCTUnwrap(source.demo.transactions.firstIndex { $0.id == "t1" })
        for status in ["voided", "reversal"] {
            source.demo.transactions[index].status = status
            try await refused(["t1"], status: 409)
        }
        source.demo.transactions[index].status = "posted"
        XCTAssertEqual(source.demo.transactions, original)
        try await source.bulkUpdateTransactions(.init(transactionIDs: ["t1"], action: "set_cleared", cleared: true))
        XCTAssertTrue(source.demo.transactions[index].cleared)
        XCTAssertEqual(source.demo.accounts.map(\.balance), accounts.map(\.balance))
        let clearedAccounts = source.demo.accounts
        try await source.bulkUpdateTransactions(.init(transactionIDs: ["t1"], action: "set_cleared", cleared: true))
        XCTAssertEqual(source.demo.accounts, clearedAccounts)
    }

    @MainActor
    func testDemoTransactionScopePrecedesRowsCountsAndSplitSerialization() async throws {
        let source = DemoWorkspaceDataSource()
        source.demo.transactions.append(.init(id: "mixed-scope", date: BudgetWorkspaceStore.parseDate("2026-09-15"), payee: "Private split", memo: "", accountID: "checking", categoryIDs: ["groceries", "dining"], categoryAmounts: ["groceries": -100, "dining": -200], amount: -300, member: .rey, cleared: false))
        let original = source.demo.transactions
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: true, categoryIDs: ["groceries"], expectedVersion: 0))
        source.demo.persona = .partner
        let page = try await source.browseTransactions(query: .init(limit: 200))
        let expected = original.filter { $0.accountID == "checking" && !$0.categoryIDs.isEmpty && Set($0.categoryIDs).isSubset(of: ["groceries"]) }
        XCTAssertEqual(Set(page.items.map(\.id)), Set(expected.map(\.id)))
        XCTAssertEqual(page.totalCount, expected.count)
        let hidden = try await source.browseTransactions(query: .init(search: "Private split", limit: 1))
        XCTAssertEqual(hidden.totalCount, 0); XCTAssertTrue(hidden.items.isEmpty); XCTAssertNil(hidden.nextCursor)
        for limit in [0, -1, 201, Int.max] {
            do { _ = try await source.browseTransactions(query: .init(limit: limit)); XCTFail("Invalid page limit") }
            catch APIClientError.server(let status, _) { XCTAssertEqual(status, 422) }
        }
        source.demo.persona = .rey
        let owner = try await source.browseTransactions(query: .init(search: "Private split"))
        XCTAssertEqual(owner.items.count, 1)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: owner.items[0].splits.map { ($0.categoryID, $0.amountMinor) }), ["groceries": -100, "dining": -200])
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: [], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        do { _ = try await source.browseTransactions(query: .init()); XCTFail("Revoked transaction read") }
        catch APIClientError.server(let status, _) { XCTAssertEqual(status, 403) }
        XCTAssertEqual(source.demo.transactions, original)
    }

    @MainActor
    func testDemoPayeeScopePrecedesSearchAggregationAndPagination() async throws {
        let source = DemoWorkspaceDataSource()
        let index = try XCTUnwrap(source.demo.payees.firstIndex { $0.name == "Fresh Market" })
        let payeeID = source.demo.payees[index].id
        source.demo.payees[index].aliases = ["Private merchant alias"]
        source.demo.payees[index].defaultCategoryID = "dining"
        source.demo.payees.append(contentsOf: (0..<5000).map { .init(id: "scale-\($0)", name: "Scale Merchant \($0)") })
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let first = try await source.searchPayees(query: "Scale", includeArchived: false, limit: 20, cursor: nil)
        XCTAssertEqual(first.items.count, 20)
        let second = try await source.searchPayees(query: "Scale", includeArchived: false, limit: 20, cursor: first.nextCursor)
        XCTAssertEqual(second.items.count, 20)
        XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        let repeated = try await source.searchPayees(query: "Scale", includeArchived: false, limit: 20, cursor: nil)
        XCTAssertEqual(first.items, repeated.items)
        for cursor in ["-1", "invalid", String(Int.max)] {
            if cursor == String(Int.max) {
                let beyond = try await source.searchPayees(query: "", includeArchived: false, limit: 20, cursor: cursor)
                XCTAssertTrue(beyond.items.isEmpty)
            } else {
                do { _ = try await source.searchPayees(query: "", includeArchived: false, limit: 20, cursor: cursor); XCTFail("Invalid cursor") } catch {}
            }
        }
        for limit in [0, -1, 51, Int.max] {
            do { _ = try await source.searchPayees(query: "", includeArchived: false, limit: limit, cursor: nil); XCTFail("Invalid page limit") } catch {}
        }
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: true, categoryIDs: ["groceries"], expectedVersion: 0))
        source.demo.persona = .partner
        let scoped = try await source.searchPayees(query: "Fresh", includeArchived: true, limit: 20, cursor: nil)
        let merchant = try XCTUnwrap(scoped.items.first { $0.id == payeeID })
        let allowed = transactions.filter { $0.payee == "Fresh Market" && !$0.categoryIDs.isEmpty && Set($0.categoryIDs).isSubset(of: ["groceries"]) }
        XCTAssertEqual(merchant.transactionCount, allowed.count)
        XCTAssertEqual(merchant.netAmountMinor, allowed.reduce(0) { $0 + $1.amount })
        XCTAssertNil(merchant.defaultCategoryID)
        XCTAssertTrue(merchant.aliases.isEmpty)
        for query in ["Private merchant alias", "Scale", "Payroll"] {
            let hidden = try await source.searchPayees(query: query, includeArchived: true, limit: 20, cursor: nil)
            XCTAssertTrue(hidden.items.isEmpty); XCTAssertNil(hidden.nextCursor)
        }
        let month = BudgetWorkspaceStore.parseDate("2026-09-01")
        let query = WorkspaceReportQuery(start: month, end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        let snapshot = try await source.snapshot(planMonth: month, report: query)
        XCTAssertFalse(snapshot.payees.contains { $0.displayName.hasPrefix("Scale") })
        XCTAssertTrue(snapshot.payees.allSatisfy { $0.aliases.isEmpty })
        XCTAssertNil(snapshot.payees.first { $0.id == payeeID }?.defaultCategoryID)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: [], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        do { _ = try await source.searchPayees(query: "", includeArchived: false, limit: 20, cursor: nil); XCTFail("Revoked read capability") } catch {}
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
    }

    @MainActor
    func testDemoTransactionCreatorAndMemberFilterDoNotChangeWithViewer() async throws {
        let source = DemoWorkspaceDataSource()
        let original = source.demo.transactions
        for viewer in [DemoPersona.rey, .partner] {
            source.demo.persona = viewer
            let page = try await source.browseTransactions(query: .init(limit: 200))
            XCTAssertEqual(page.items.count, original.count)
            for row in page.items {
                let creator = try XCTUnwrap(original.first(where: { $0.id == row.id })).member
                XCTAssertEqual(row.createdByUserID, creator == .rey ? "demo-owner" : creator.rawValue.lowercased())
            }
            for creator in DemoPersona.allCases {
                let id = creator == .rey ? "demo-owner" : creator.rawValue.lowercased()
                let filtered = try await source.browseTransactions(query: .init(actorUserIDs: [id], limit: 200))
                XCTAssertEqual(Set(filtered.items.map(\.id)), Set(original.filter { $0.member == creator }.map(\.id)))
                XCTAssertEqual(filtered.totalCount, filtered.items.count)
            }
        }
        source.demo.persona = .alex
        let hiddenOwner = try await source.browseTransactions(query: .init(actorUserIDs: ["demo-owner"], limit: 200))
        XCTAssertTrue(hiddenOwner.items.isEmpty)
        XCTAssertEqual(hiddenOwner.totalCount, 0)
        XCTAssertEqual(source.demo.transactions, original)
    }

    @MainActor
    func testDemoAttachmentAuthorizationAndIdentityAreCheckedBeforeDataAccess() async throws {
        let source = DemoWorkspaceDataSource()
        let original = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1")
        let transactions = source.demo.transactions, accounts = source.demo.accounts
        for persona in [DemoPersona.alex, .mia] {
            source.demo.persona = persona
            do { _ = try await source.transactionAttachments(id: "t1"); XCTFail("Hidden attachment list") } catch {}
            do { _ = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1"); XCTFail("Hidden bytes") } catch {}
            do { try await source.uploadTransactionAttachment(id: "t1", filename: "overwrite.png", contentType: "image/png", data: original); XCTFail("Hidden upload") } catch {}
            do { try await source.detachTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1"); XCTFail("Hidden detach") } catch {}
        }
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0))
        source.demo.persona = .partner
        let readable = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1")
        XCTAssertEqual(readable, original)
        do { try await source.detachTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1"); XCTFail("View-only detach") } catch {}
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions", "edit_transaction"], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: 1))
        source.demo.persona = .partner
        do { _ = try await source.transactionAttachments(id: "t1"); XCTFail("Custom hidden account") } catch {}
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_transactions", "edit_transaction"], restrictAccounts: false, accountIDs: [], restrictCategories: true, categoryIDs: ["dining"], expectedVersion: 2))
        source.demo.persona = .partner
        do { _ = try await source.transactionAttachments(id: "t1"); XCTFail("Custom hidden category") } catch {}
        source.demo.persona = .rey
        for id in ["foreign", "demo-attachment-t2"] {
            do { _ = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: id); XCTFail("Foreign attachment download") } catch {}
            do { try await source.detachTransactionAttachment(transactionID: "t1", attachmentID: id); XCTFail("Foreign attachment detach") } catch {}
        }
        XCTAssertEqual(source.demo.transactions, transactions)
        XCTAssertEqual(source.demo.accounts, accounts)
        let preserved = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1")
        XCTAssertEqual(preserved, original)
        try await source.detachTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1")
        let empty = try await source.transactionAttachments(id: "t1")
        XCTAssertTrue(empty.isEmpty)
        do { _ = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: "demo-attachment-t1"); XCTFail("Detached bytes") } catch {}
    }

    @MainActor
    func testDemoAccessProfileValidatesScopeAndRecordsRealOwnerTimeAndGrant() async throws {
        let timestamp = BudgetWorkspaceStore.parseDate("2026-09-18")
        let source = DemoWorkspaceDataSource(now: { timestamp })
        let before = try await source.accessProfile(userID: "jordan")
        XCTAssertEqual(before.grantPermission, "manage")
        XCTAssertEqual(Set(before.capabilities), APIBudgetPermission.manage.legacyCapabilities)
        let child = try await source.accessProfile(userID: "alex")
        XCTAssertEqual(child.grantPermission, "contribute")
        XCTAssertTrue(child.restrictAccounts); XCTAssertTrue(child.restrictCategories)
        XCTAssertFalse(child.categoryIDs.contains("miaallow"))
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let version = source.demo.allocationVersion
        let invalid: [APIAccessProfileUpsert] = [
            .init(capabilities: ["unknown"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0),
            .init(capabilities: ["view_budget", "view_budget"], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: 0),
            .init(capabilities: [], restrictAccounts: true, accountIDs: ["foreign"], restrictCategories: false, categoryIDs: [], expectedVersion: 0),
            .init(capabilities: [], restrictAccounts: false, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: 0),
            .init(capabilities: [], restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: ["groceries"], expectedVersion: 0),
            .init(capabilities: [], restrictAccounts: false, accountIDs: [], restrictCategories: true, categoryIDs: ["groceries", "groceries"], expectedVersion: 0),
            .init(capabilities: [], restrictAccounts: true, accountIDs: ["checking"], restrictCategories: true, categoryIDs: ["foreign"], expectedVersion: 0)
        ]
        for value in invalid {
            do { _ = try await source.updateAccessProfile(userID: "jordan", value: value); XCTFail("Invalid access must refuse atomically") } catch {}
            let unchanged = try await source.accessProfile(userID: "jordan")
            let events = try await source.householdAccessEvents()
            XCTAssertEqual(unchanged, before); XCTAssertTrue(events.isEmpty)
        }
        let input = APIAccessProfileUpsert(capabilities: ["view_transactions", "view_budget"], restrictAccounts: true,
            accountIDs: ["checking"], restrictCategories: true, categoryIDs: ["groceries", "dining"], expectedVersion: 0)
        let updated = try await source.updateAccessProfile(userID: "jordan", value: input)
        XCTAssertEqual(updated.grantPermission, "manage"); XCTAssertTrue(updated.isCustom)
        XCTAssertEqual(updated.capabilities, ["view_budget", "view_transactions"])
        XCTAssertEqual(updated.categoryIDs, ["dining", "groceries"])
        XCTAssertEqual(updated.updatedByDisplayName, "Rey Rivera")
        XCTAssertEqual(updated.updatedAt, ISO8601DateFormatter().string(from: timestamp))
        XCTAssertEqual(updated.version, 1)
        do { _ = try await source.updateAccessProfile(userID: "jordan", value: input); XCTFail("Stale version") } catch {}
        let reloaded = try await source.accessProfile(userID: "jordan")
        let events = try await source.householdAccessEvents()
        XCTAssertEqual(reloaded, updated); XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, "access_profile_updated")
        XCTAssertEqual(events[0].actorDisplayName, "Rey Rivera")
        XCTAssertEqual(events[0].subjectDisplayName, "Jordan Rivera")
        XCTAssertEqual(events[0].createdAt, updated.updatedAt)
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        XCTAssertEqual(source.demo.allocationVersion, version)
    }

    @MainActor
    func testRemovedDemoMemberCannotReadOrMutateAndCannotReceiveAllowance() async throws {
        let source = DemoWorkspaceDataSource()
        let month = BudgetWorkspaceStore.parseDate("2026-09-01")
        let query = WorkspaceReportQuery(start: month, end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        let before = try await source.snapshot(planMonth: month, report: query)
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let events = source.demo.allocationEvents.map(\.id), version = source.demo.allocationVersion
        source.demo.persona = .partner
        do { try await source.removeHouseholdMember(userID: "alex"); XCTFail("Owner-only removal") } catch {}
        do { _ = try await source.accessProfile(userID: "alex"); XCTFail("Owner-only access administration") } catch {}
        source.demo.persona = .rey
        for id in ["demo-owner", "rey", "unknown"] {
            do { try await source.removeHouseholdMember(userID: id); XCTFail("Cannot remove owner or unknown member") } catch {}
        }
        try await source.removeHouseholdMember(userID: "alex")
        do { try await source.removeHouseholdMember(userID: "alex"); XCTFail("Repeated removal must not duplicate audit") } catch {}
        let after = try await source.snapshot(planMonth: month, report: query)
        XCTAssertEqual(after.members.first { $0.userID == "alex" }?.isActive, false)
        XCTAssertEqual(after.members.first { $0.userID == "alex" }?.authorizationVersion, 2)
        XCTAssertEqual(after.requests, before.requests)
        let audit = try await source.householdAccessEvents()
        XCTAssertEqual(audit.count, 1); XCTAssertEqual(audit[0].eventType, "member_removed")
        XCTAssertEqual(audit[0].subjectDisplayName, "Alex Rivera")
        let allowance = try XCTUnwrap(source.demo.allowances.first { $0.member == .alex })
        do { try await source.issueAllowance(id: allowance.id, issueDate: allowance.nextDate, expectedVersion: version); XCTFail("Removed recipient cannot receive funds") } catch {}
        do { _ = try await source.accessProfile(userID: "alex"); XCTFail("Removed profile unavailable") } catch {}
        do { try await source.createCategory(groupID: "", groupName: "Alex", newGroupName: "", name: "Revoked recipient", delegatedUserID: "alex"); XCTFail("Removed member cannot receive new categories") } catch {}
        XCTAssertFalse(source.demo.categories.contains { $0.name == "Revoked recipient" })
        _ = try await source.createHouseholdInvitation(.init(email: "alex@example.test", role: "child"))
        source.demo.persona = .alex
        do { _ = try await source.snapshot(planMonth: month, report: query); XCTFail("Revoked snapshot") } catch {}
        do { _ = try await source.searchPayees(query: "", includeArchived: true, limit: 20, cursor: nil); XCTFail("Revoked search") } catch {}
        do { _ = try await source.downloadTransactionAttachment(transactionID: "t1", attachmentID: "attachment"); XCTFail("Revoked attachment") } catch {}
        do { try await source.deleteTransaction(id: transactions[0].id); XCTFail("Revoked mutation") } catch {}
        do { try await source.createRequest(.init(destinationCategoryID: "alexallow", requestedAmountMinor: 1, reason: "Revoked")); XCTFail("Revoked request") } catch {}
        do { try await source.createGroup(name: "Unauthorized"); XCTFail("Revoked structure") } catch {}
        do { _ = try await source.allowanceIssuances(id: allowance.id); XCTFail("Revoked history") } catch {}
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        XCTAssertEqual(source.demo.allocationVersion, version); XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
        XCTAssertFalse(source.demo.groupOrder.contains("Unauthorized"))
        source.demo.persona = .rey
        let reload = try await source.snapshot(planMonth: month, report: query)
        XCTAssertEqual(reload.members, after.members, "Invitation alone never reactivates membership")
    }

    func testEveryDemoRepositoryEntryChecksCurrentMembership() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let text = try String(contentsOf: path)
        let start = try XCTUnwrap(text.range(of: "final class DemoWorkspaceDataSource:"))
        let end = try XCTUnwrap(text.range(of: "private func workspaceRepositoryError"))
        let lines = text[start.lowerBound..<end.lowerBound].components(separatedBy: "\n")
        let entries = lines.filter { $0.hasPrefix("    func ") && $0.contains("async throws") }
        XCTAssertGreaterThan(entries.count, 50)
        for entry in entries { XCTAssertTrue(entry.contains("{ try requireActiveMembership();"), "Unguarded provider entry: \(entry)") }
    }

    @MainActor
    func testDemoInvitationsPersistRotateExpireAndEnforceOwnerWithoutMoneyMutation() async throws {
        var clock = BudgetWorkspaceStore.parseDate("2026-09-18")
        let source = DemoWorkspaceDataSource(now: { clock })
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let version = source.demo.allocationVersion
        let first = try await source.createHouseholdInvitation(.init(email: " New@Example.Test ", role: "child"))
        XCTAssertEqual(first.email, "new@example.test")
        var rows = try await source.householdInvitations()
        let originalID = try XCTUnwrap(rows.first?.id)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].status, "pending")
        XCTAssertEqual(rows[0].role, "child")
        let reread = try await source.householdInvitations()
        XCTAssertEqual(reread, rows)
        clock = clock.addingTimeInterval(7 * 24 * 60 * 60)
        rows = try await source.householdInvitations()
        XCTAssertEqual(rows[0].status, "expired")
        let replacement = try await source.resendHouseholdInvitation(id: originalID)
        XCTAssertNotEqual(replacement.invitationToken, first.invitationToken)
        XCTAssertEqual(replacement.email, first.email); XCTAssertEqual(replacement.role, first.role)
        rows = try await source.householdInvitations()
        XCTAssertEqual(rows.first { $0.id == originalID }?.status, "canceled")
        let replacementID = try XCTUnwrap(rows.first { $0.status == "pending" }?.id)
        clock = clock.addingTimeInterval(1)
        try await source.cancelHouseholdInvitation(id: replacementID)
        try await source.cancelHouseholdInvitation(id: replacementID)
        let events = try await source.householdAccessEvents()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first?.eventType, "invitation_canceled")
        XCTAssertEqual(Set(events.map(\.eventType)), ["invitation_created", "invitation_resent", "invitation_canceled"])
        XCTAssertFalse(events.description.contains(first.invitationToken))
        for persona in [DemoPersona.partner, .alex] {
            source.demo.persona = persona
            do { _ = try await source.householdInvitations(); XCTFail("Owner-only invitations") } catch {}
            do { _ = try await source.householdAccessEvents(); XCTFail("Owner-only history") } catch {}
            do { _ = try await source.createHouseholdInvitation(.init(email: "hidden@example.test", role: "adult")); XCTFail("Owner-only create") } catch {}
            do { _ = try await source.resendHouseholdInvitation(id: originalID); XCTFail("Owner-only resend") } catch {}
            do { try await source.cancelHouseholdInvitation(id: originalID); XCTFail("Owner-only cancel") } catch {}
        }
        source.demo.persona = .rey
        for value in [APIInvitationCreate(email: "invalid", role: "adult"), .init(email: "new@example.test", role: "owner"), .init(email: "alex@example.test", role: "child")] {
            do { _ = try await source.createHouseholdInvitation(value); XCTFail("Invalid invite") } catch {}
        }
        let unchanged = try await source.householdAccessEvents()
        XCTAssertEqual(unchanged, events)
        for index in 0..<205 {
            clock = clock.addingTimeInterval(1)
            _ = try await source.createHouseholdInvitation(.init(email: "scale-\(index)@example.test", role: "adult"))
        }
        let bounded = try await source.householdAccessEvents()
        XCTAssertEqual(bounded.count, 200)
        XCTAssertEqual(bounded.first?.detail, "scale-204@example.test")
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
        XCTAssertEqual(source.demo.allocationVersion, version)
    }

    @MainActor
    func testDemoRequestRevisionCancellationExpiryAndApprovalUseActualVersions() async throws {
        var now = BudgetWorkspaceStore.parseDate("2026-09-18")
        let source = DemoWorkspaceDataSource(now: { now })
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        func rows() async throws -> [APIFinancialRequest] { try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query).requests }
        func row(_ id: String) async throws -> APIFinancialRequest { let values = try await rows(); return try XCTUnwrap(values.first { $0.id == id }) }
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let original = try source.demo.planningSnapshot(month: "2026-09-01")
        let allocationVersion = source.demo.allocationVersion
        source.demo.persona = .alex
        try await source.createRequest(.init(destinationCategoryID: "alexallow", requestedAmountMinor: 2_500, reason: "Original"))
        let id = try XCTUnwrap(source.demo.requests.first?.id)
        var request = try await row(id)
        XCTAssertEqual(request.version, 0); XCTAssertEqual(request.actions.map(\.action), ["submitted"])
        XCTAssertNotNil(request.expiresAt)
        source.demo.persona = .rey
        do { try await source.cancelRequest(id: id, version: 0, note: "Not mine"); XCTFail("Owner cannot impersonate requester") } catch {}
        try await source.decideRequest(id: id, decision: "changes_requested", version: 0, amount: nil, sourceCategoryID: nil, note: "Explain the purchase")
        source.demo.persona = .alex
        let revision = APIFinancialRequestCreate(requestType: "purchase_approval", destinationCategoryID: "alexallow", requestedAmountMinor: 2_000, reason: "School supplies")
        do { try await source.reviseRequest(id: id, version: 0, value: revision); XCTFail("Stale revision") } catch {}
        do { try await source.reviseRequest(id: id, version: 1, value: .init(destinationCategoryID: "miaallow", requestedAmountMinor: 2_000, reason: "Hidden")); XCTFail("Sibling category") } catch {}
        try await source.reviseRequest(id: id, version: 1, value: revision)
        request = try await row(id)
        XCTAssertEqual(request.version, 2); XCTAssertEqual(request.requestType, "purchase_approval")
        XCTAssertEqual(request.actions.map(\.action), ["submitted", "changes_requested", "revised"])
        XCTAssertEqual(source.demo.allocationVersion, allocationVersion)
        source.demo.persona = .rey
        try await source.decideRequest(id: id, decision: "approve", version: 2, amount: 1_000, sourceCategoryID: "buffer", note: "Partial")
        request = try await row(id)
        XCTAssertEqual(request.version, 3); XCTAssertEqual(request.status, "partially_approved")
        XCTAssertEqual(request.sourceCategoryID, "buffer"); XCTAssertNotNil(request.allocationOperationID)
        XCTAssertEqual(request.actions.last?.amountMinor, 1_000)
        do { try await source.decideRequest(id: id, decision: "approve", version: 3, amount: 1_000, sourceCategoryID: "buffer", note: "Duplicate"); XCTFail("Terminal request") } catch {}
        let funded = try source.demo.planningSnapshot(month: "2026-09-01")
        XCTAssertEqual(funded.readyToAssignMinor, original.readyToAssignMinor)
        XCTAssertEqual(funded.categories["buffer"]?.availableMinor, (original.categories["buffer"]?.availableMinor ?? 0) - 1_000)
        XCTAssertEqual(funded.categories["alexallow"]?.availableMinor, (original.categories["alexallow"]?.availableMinor ?? 0) + 1_000)
        source.demo.persona = .alex
        request = try await row(id)
        XCTAssertNil(request.sourceCategoryID)
        try await source.createRequest(.init(destinationCategoryID: "alexsave", requestedAmountMinor: 100, reason: "Cancel"))
        let cancelID = try XCTUnwrap(source.demo.requests.first?.id)
        try await source.cancelRequest(id: cancelID, version: 0, note: "Changed my mind")
        do { try await source.cancelRequest(id: cancelID, version: 1, note: "Again"); XCTFail("Duplicate cancellation") } catch {}
        XCTAssertEqual(source.demo.requests.first?.actions.map(\.action), ["submitted", "cancelled"])
        var expiredIDs: [String] = []
        for _ in 0..<3 {
            try await source.createRequest(.init(destinationCategoryID: "alexallow", requestedAmountMinor: 100, reason: "Expires"))
            expiredIDs.append(try XCTUnwrap(source.demo.requests.first?.id))
        }
        now = now.addingTimeInterval(31 * 24 * 60 * 60)
        let expired = try await rows().filter { expiredIDs.contains($0.id) }
        XCTAssertEqual(expired.count, 3)
        XCTAssertTrue(expired.allSatisfy { $0.status == "expired" && $0.version == 1 && $0.actions.count == 2 && $0.actions.last?.actorUserID == nil })
        let repeated = try await rows().filter { expiredIDs.contains($0.id) }
        XCTAssertEqual(repeated, expired)
        source.demo.persona = .mia
        let siblingRows = try await rows()
        XCTAssertFalse(siblingRows.contains { $0.id == id || $0.id == cancelID || expiredIDs.contains($0.id) })
        source.demo.persona = .rey
        do { try await source.decideRequest(id: expiredIDs[0], decision: "approve", version: 1, amount: 100, sourceCategoryID: "buffer", note: "Expired"); XCTFail("Expired approval") } catch {}
        XCTAssertEqual(source.demo.allocationVersion, allocationVersion + 1)
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
    }

    @MainActor
    func testProductionDemoAllowanceIssuanceIsAtomicVersionedAndMatchesServerRollover() async throws {
        for policy in ["rollover", "use_it_or_lose_it"] {
            let source = DemoWorkspaceDataSource(fresh: true)
            let services = BudgetApplicationServices(repository: source)
            try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
            let account = try XCTUnwrap(source.demo.accounts.first?.id)
            try await services.transactions.record(.init(accountID: account, categoryID: nil, amountMinor: 10_000, occurredOn: "2026-08-01", payeeName: "Income", memo: "", isCleared: true, splits: [], flag: "", tags: [], attachmentMetadata: []))
            for (name, member) in [("Pool", nil), ("Spend", "alex"), ("Save", "alex")] as [(String, String?)] {
                try await source.createCategory(groupID: "", groupName: "Allowance", newGroupName: "", name: name, delegatedUserID: member)
            }
            let pool = source.demo.categories[0].id, spend = source.demo.categories[1].id, save = source.demo.categories[2].id
            try await source.assignMoney(.init(categoryID: pool, month: "2026-08-01", assignedMinor: 10_000, expectedVersion: 0))
            let beforeAccounts = source.demo.accounts, beforeTransactions = source.demo.transactions
            let body = APIAllowancePlanCreate(delegatedUserID: "alex", sourceCategoryID: pool, name: "Weekly", amountMinor: 2_000,
                nextIssueDate: "2026-08-28", recurrenceUnit: "week", intervalCount: 1, rolloverPolicy: policy,
                splits: [.init(destinationCategoryID: spend, amountMinor: 1_500), .init(destinationCategoryID: save, amountMinor: 500)])
            try await source.createAllowance(body)
            let id = try XCTUnwrap(source.demo.allowances.first?.id)
            XCTAssertEqual(source.demo.allocationVersion, 1)
            do { try await source.createAllowance(body); XCTFail("Active destination conflict") } catch {}
            try await source.setAllowanceActive(id: id, active: false)
            do { try await source.issueAllowance(id: id, issueDate: "2026-08-28", expectedVersion: 1); XCTFail("Paused issuance") } catch {}
            try await source.setAllowanceActive(id: id, active: true)
            XCTAssertEqual(source.demo.allocationVersion, 1)
            try await source.issueAllowance(id: id, issueDate: "2026-08-28", expectedVersion: 1)
            XCTAssertEqual(source.demo.allowances[0].nextDate, "2026-09-04")
            XCTAssertEqual(source.demo.allocationVersion, 2)
            do { try await source.issueAllowance(id: id, issueDate: "2026-08-28", expectedVersion: 2); XCTFail("Duplicate date") } catch {}
            do { try await source.issueAllowance(id: id, issueDate: "2026-09-04", expectedVersion: 1); XCTFail("Stale allocation token") } catch {}
            try await source.issueAllowance(id: id, issueDate: "2026-09-04", expectedVersion: 2)
            let plan = try source.demo.planningSnapshot(month: "2026-09-01")
            XCTAssertEqual(plan.categories[pool]?.availableMinor, policy == "rollover" ? 6_000 : 8_000)
            XCTAssertEqual(plan.categories[spend]?.availableMinor, policy == "rollover" ? 3_000 : 1_500)
            XCTAssertEqual(plan.categories[save]?.availableMinor, policy == "rollover" ? 1_000 : 500)
            XCTAssertEqual(plan.readyToAssignMinor, 0)
            XCTAssertEqual(source.demo.accounts, beforeAccounts); XCTAssertEqual(source.demo.transactions, beforeTransactions)
            XCTAssertEqual(source.demo.allocationVersion, 3)
            let history = try await source.allowanceIssuances(id: id)
            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(history.first?.reclaimedMinor, policy == "rollover" ? 0 : 2_000)
            let reread = try await source.allowanceIssuances(id: id)
            XCTAssertEqual(reread, history)
            let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-08-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
            let snapshot = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
            let operations = snapshot.allocationOperations.filter { $0.kind == "allowance_issuance" }
            XCTAssertEqual(operations.count, 2)
            XCTAssertTrue(operations.allSatisfy { $0.postings.reduce(Int64(0)) { $0 + $1.amountMinor } == 0 })
            XCTAssertEqual(operations.map { $0.postings.count }.max(), policy == "rollover" ? 4 : 8)
            source.demo.persona = .alex
            let child = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
            XCTAssertEqual(child.allowances.count, 1); XCTAssertNil(child.allowances.first?.sourceCategoryID)
            XCTAssertTrue(child.allocationOperations.isEmpty)
            do { try await source.issueAllowance(id: id, issueDate: "2026-09-11", expectedVersion: 3); XCTFail("Child cannot issue") } catch {}
            source.demo.persona = .mia
            do { _ = try await source.allowanceIssuances(id: id); XCTFail("Sibling history leak") } catch {}
            source.demo.persona = .rey
            source.demo.categories[1].delegatedTo = .mia
            do { try await source.issueAllowance(id: id, issueDate: "2026-09-11", expectedVersion: 3); XCTFail("Revoked delegation") } catch {}
            XCTAssertEqual(source.demo.allocationVersion, 3)
            XCTAssertEqual(source.demo.allowanceHistory.count, 2)
        }
    }

    @MainActor
    func testDemoAllowanceFailuresAndCalendarAdvancePreserveFinancialState() async throws {
        let source = DemoWorkspaceDataSource()
        for plan in source.demo.allowances { try await source.setAllowanceActive(id: plan.id, active: false) }
        try await source.assignMoney(.init(categoryID: "buffer", month: "2026-08-01", assignedMinor: 35_000, expectedVersion: source.demo.allocationVersion))
        func body(_ amount: Int64, name: String) -> APIAllowancePlanCreate {
            .init(delegatedUserID: "alex", sourceCategoryID: "buffer", name: name, amountMinor: amount,
                nextIssueDate: "2026-08-31", recurrenceUnit: "month", intervalCount: 1, rolloverPolicy: "rollover",
                splits: [.init(destinationCategoryID: "alexallow", amountMinor: amount)])
        }
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let version = source.demo.allocationVersion, events = source.demo.allocationEvents.map(\.id)
        try await source.createAllowance(body(50_000, name: "Too much"))
        let largeID = try XCTUnwrap(source.demo.allowances.last?.id)
        do { try await source.issueAllowance(id: largeID, issueDate: "2026-08-31", expectedVersion: version); XCTFail("Insufficient source") } catch {}
        XCTAssertEqual(source.demo.allowanceHistory.count, 0)
        XCTAssertEqual(source.demo.allocationVersion, version)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
        XCTAssertEqual(source.demo.allowances.last?.nextDate, "2026-08-31")
        try await source.setAllowanceActive(id: largeID, active: false)
        try await source.createAllowance(body(2_000, name: "Monthly"))
        let id = try XCTUnwrap(source.demo.allowances.last?.id)
        do { try await source.setAllowanceActive(id: largeID, active: true); XCTFail("Conflicting active destination") } catch {}
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(capabilities: ["view_budget", "manage_allowances"], restrictAccounts: false, accountIDs: [], restrictCategories: true, categoryIDs: ["alexallow"], expectedVersion: 0))
        source.demo.persona = .partner
        do { try await source.issueAllowance(id: id, issueDate: "2026-08-31", expectedVersion: version); XCTFail("Hidden source") } catch {}
        do { _ = try await source.allowanceIssuances(id: id); XCTFail("Hidden source history") } catch {}
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "alex", value: .init(capabilities: ["view_budget"], restrictAccounts: false, accountIDs: [], restrictCategories: true, categoryIDs: ["alexsave"], expectedVersion: 0))
        do { try await source.issueAllowance(id: id, issueDate: "2026-08-31", expectedVersion: version); XCTFail("Recipient visibility revoked") } catch {}
        _ = try await source.updateAccessProfile(userID: "alex", value: .init(capabilities: ["view_budget"], restrictAccounts: false, accountIDs: [], restrictCategories: true, categoryIDs: ["alexallow", "alexsave"], expectedVersion: 1))
        try await source.issueAllowance(id: id, issueDate: "2026-08-31", expectedVersion: version)
        XCTAssertEqual(source.demo.allowances.last?.nextDate, "2026-09-30")
        XCTAssertEqual(source.demo.allowanceHistory.count, 1)
        XCTAssertEqual(source.demo.allocationVersion, version + 1)
        XCTAssertEqual(source.demo.accounts, accounts); XCTAssertEqual(source.demo.transactions, transactions)
    }


    @MainActor
    func testProductionPolicyServiceIsProspectiveVersionedAuditedAndOwnerOnly() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 10_000))
        let cash = try XCTUnwrap(source.demo.accounts.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
        let category = try XCTUnwrap(source.demo.categories.last?.id)
        let today = BudgetWorkspaceStore.dateString(Date())
        try await services.transactions.record(.init(accountID: cash, categoryID: category, amountMinor: -2_000,
            occurredOn: today, payeeName: "Policy proof", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let month = source.demo.currentPlanningMonth
        let next = BudgetWorkspaceStore.dateString(Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: BudgetWorkspaceStore.parseDate(month))!)
        let initial = try await services.planning.cashRolloverPolicy()
        let accounts = source.demo.accounts, transactions = source.demo.transactions
        let events = source.demo.allocationEvents.map(\.id)
        let selection = APICashRolloverPolicySelection(policy: .absorbNextMonth, effectiveMonth: next,
            expectedPolicyVersion: initial.policyVersion, expectedAllocationVersion: initial.allocationVersion)
        let changed = try await services.planning.selectCashRolloverPolicy(selection)
        XCTAssertEqual(changed.currentPolicy, .carryCategoryDeficit)
        XCTAssertEqual(changed.policyVersion, 1)
        XCTAssertEqual(changed.allocationVersion, initial.allocationVersion + 1)
        XCTAssertEqual(try source.demo.planningSnapshot(month: month).readyToAssignMinor, 10_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: next).readyToAssignMinor, 8_000)
        do { _ = try await services.planning.selectCashRolloverPolicy(selection); XCTFail("Stale selection must refuse") } catch {}
        do { try await services.planning.assign(.init(categoryID: category, month: next, assignedMinor: 1_000, expectedVersion: initial.allocationVersion)); XCTFail("Policy invalidates stale assignment previews") } catch {}
        let noOp = try await services.planning.selectCashRolloverPolicy(.init(policy: .absorbNextMonth, effectiveMonth: next, expectedPolicyVersion: 1, expectedAllocationVersion: changed.allocationVersion))
        XCTAssertEqual(noOp, changed)
        let audit = try await services.planning.cashRolloverPolicyHistory()
        XCTAssertEqual(audit.items.map(\.version), [1, 0])
        XCTAssertEqual(audit.items.first?.source, "user_selection")
        XCTAssertNil(audit.items.last?.actorUserID)
        let reloaded = try await services.planning.cashRolloverPolicyHistory()
        XCTAssertEqual(reloaded, audit, "Refresh preserves audit identity and timestamp")
        for persona in [DemoPersona.partner, .alex, .mia] {
            source.demo.persona = persona
            do { _ = try await services.planning.cashRolloverPolicy(); XCTFail("Only the owner can read settings") } catch {}
            do { _ = try await services.planning.selectCashRolloverPolicy(.init(policy: .carryCategoryDeficit, effectiveMonth: next, expectedPolicyVersion: 1, expectedAllocationVersion: changed.allocationVersion)); XCTFail("Nonowner mutation must refuse") } catch {}
        }
        source.demo.persona = .rey
        do { _ = try await services.planning.selectCashRolloverPolicy(.init(policy: .carryCategoryDeficit, effectiveMonth: month, expectedPolicyVersion: 1, expectedAllocationVersion: changed.allocationVersion)); XCTFail("Current month is immutable") } catch {}
        let revised = try await services.planning.selectCashRolloverPolicy(.init(policy: .carryCategoryDeficit, effectiveMonth: next, expectedPolicyVersion: 1, expectedAllocationVersion: changed.allocationVersion))
        XCTAssertEqual(revised.policyVersion, 2)
        XCTAssertEqual(try source.demo.planningSnapshot(month: next).readyToAssignMinor, 10_000)
        XCTAssertEqual(source.demo.accounts, accounts)
        XCTAssertEqual(source.demo.transactions, transactions)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
    }

    @MainActor
    func testProductionPlanReportMatchesServerHistoryPartialPeriodsRefundsAndScope() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let cash = try XCTUnwrap(source.demo.accounts.last?.id)
        try await services.accounts.create(.init(name: "Card", kind: "credit", isOnBudget: true, openingBalanceMinor: 0))
        let card = try XCTUnwrap(source.demo.accounts.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Groceries", group: "Needs"))
        let groceries = try XCTUnwrap(source.demo.categories.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Dining", group: "Needs"))
        let dining = try XCTUnwrap(source.demo.categories.last?.id)
        func record(_ amount: Int64, account: String, category: String?, day: String, splits: [TransactionSplitOperation] = []) async throws {
            try await services.transactions.record(.init(accountID: account, categoryID: category, amountMinor: amount,
                occurredOn: day, payeeName: "Report proof", memo: "", isCleared: false, splits: splits, flag: nil, tags: [], attachmentMetadata: []))
        }
        try await record(100_000, account: cash, category: nil, day: "2026-06-30")
        for (category, amount) in [(groceries, Int64(30_000)), (dining, 10_000)] {
            try await services.planning.assign(.init(categoryID: category, month: "2026-07-01", assignedMinor: amount, expectedVersion: source.demo.allocationVersion))
        }
        try await record(-12_000, account: cash, category: nil, day: "2026-07-15", splits: [
            .init(categoryID: groceries, amountMinor: -8_000, memo: ""), .init(categoryID: dining, amountMinor: -4_000, memo: "")])
        try await services.planning.move(.init(sourceCategoryID: groceries, destinationCategoryID: dining, amountMinor: 5_000, occurredOn: "2026-08-01", note: "Move", expectedVersion: source.demo.allocationVersion))
        try await record(-4_000, account: card, category: dining, day: "2026-08-02")
        try await record(2_000, account: cash, category: groceries, day: "2026-08-03")
        func report(_ start: String, _ end: String) async throws -> APIPlanPerformanceReport {
            let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate(start), end: BudgetWorkspaceStore.parseDate(end), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
            let value = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
            return try XCTUnwrap(value.planPerformance)
        }
        let before = source.demo.financialObservation(accountReferences: ["cash": cash, "card": card], categoryReferences: ["groceries": groceries, "dining": dining])
        let full = try await report("2026-07-01", "2026-08-31")
        XCTAssertEqual(full.points.map(\.periodStart), ["2026-07-01", "2026-08-01"])
        XCTAssertEqual(full.points.map(\.periodEnd), ["2026-07-31", "2026-08-31"])
        // Exact matching scenario is tested through FastAPI in test_analytics.py.
        XCTAssertEqual(full.points.map(\.assignedMinor), [40_000, 0])
        XCTAssertEqual(full.points.map(\.activityMinor), [-12_000, 2_000])
        XCTAssertEqual(full.points.map(\.spendingMinor), [12_000, 2_000])
        XCTAssertEqual(full.points.map(\.carriedAvailableMinor), [0, 28_000])
        XCTAssertEqual(full.points.map(\.availableMinor), [28_000, 30_000])
        XCTAssertEqual(full.points.map(\.readyToAssignMinor), [60_000, 60_000])
        let partial = try await report("2026-07-16", "2026-08-02")
        XCTAssertEqual(partial.points.map(\.periodStart), ["2026-07-16", "2026-08-01"])
        XCTAssertEqual(partial.points.map(\.periodEnd), ["2026-07-31", "2026-08-02"])
        XCTAssertEqual(partial.points.map(\.activityMinor), [0, 0])
        XCTAssertEqual(partial.points.map(\.spendingMinor), [0, 4_000])
        XCTAssertEqual(partial.points.map(\.carriedAvailableMinor), [28_000, 28_000])
        XCTAssertEqual(partial.points.map(\.availableMinor), [28_000, 28_000])
        let refund = try await report("2026-08-03", "2026-08-03")
        XCTAssertEqual(refund.points.first?.spendingMinor, -2_000)
        XCTAssertEqual(refund.points.first?.carriedAvailableMinor, 28_000)
        let index = try XCTUnwrap(source.demo.categories.firstIndex { $0.id == groceries })
        source.demo.categories[index].isHidden = true
        let archived = try await report("2026-07-01", "2026-08-31")
        XCTAssertEqual(archived, full, "Archival cannot erase report history")
        source.demo.categories[index].isHidden = false
        XCTAssertEqual(source.demo.financialObservation(accountReferences: ["cash": cash, "card": card], categoryReferences: ["groceries": groceries, "dining": dining]), before)
        source.demo.categories[index].delegatedTo = .alex
        source.demo.persona = .alex
        let restricted = try await report("2026-07-01", "2026-08-31")
        XCTAssertEqual(restricted.points.map(\.readyToAssignMinor), [0, 0])
        XCTAssertEqual(restricted.points.map(\.availableMinor), [30_000, 25_000], "Hidden account activity must not leak")
        XCTAssertEqual(restricted.points.map(\.spendingMinor), [0, 0])
        let cashIndex = try XCTUnwrap(source.demo.accounts.firstIndex { $0.id == cash })
        source.demo.accounts[cashIndex].restrictedFromChildren = false
        let shared = try await report("2026-07-01", "2026-08-31")
        XCTAssertEqual(shared.points.map(\.readyToAssignMinor), [0, 0])
        XCTAssertEqual(shared.points.map(\.availableMinor), [22_000, 19_000])
        XCTAssertEqual(shared.points.map(\.spendingMinor), [8_000, -2_000])
    }

    @MainActor
    func testProductionDemoRolloverUsesActualCommandsAndPreservesHistory() async throws {
        let source = DemoWorkspaceDataSource(fresh: true, cashRolloverPolicies: [try .init(effectiveMonth: "2026-09-01", policy: .absorb, version: 1)])
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let cash = try XCTUnwrap(source.demo.accounts.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
        let category = try XCTUnwrap(source.demo.categories.last?.id)
        func record(_ amount: Int64, categoryID: String?, day: String) async throws {
            try await services.transactions.record(.init(accountID: cash, categoryID: categoryID, amountMinor: amount,
                occurredOn: day, payeeName: "Rollover proof", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        }
        try await record(50_000, categoryID: nil, day: "2026-08-01")
        try await services.planning.assign(.init(categoryID: category, month: "2026-08-01", assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))
        try await record(-15_000, categoryID: category, day: "2026-08-02")
        let before = source.demo.financialObservation(accountReferences: ["cash": cash], categoryReferences: ["needs": category])
        let events = source.demo.allocationEvents.map(\.id)
        for _ in 0..<2 {
            let august = try source.demo.planningSnapshot(month: "2026-08-01")
            let september = try source.demo.planningSnapshot(month: "2026-09-01")
            XCTAssertEqual(august.readyToAssignMinor, 40_000)
            XCTAssertEqual(august.allDateUnassignedMinor, 35_000)
            XCTAssertEqual(august.categories[category]?.availableMinor, -5_000)
            XCTAssertEqual(september.readyToAssignMinor, 35_000)
            XCTAssertEqual(september.categories[category]?.carriedAvailableMinor, 0)
            XCTAssertEqual(september.categories[category]?.activityMinor, 0)
            XCTAssertEqual(september.categories[category]?.assignedMinor, 0)
            let report = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
            let snapshot = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: report)
            XCTAssertEqual(snapshot.summary?.readyToAssignMinor, 35_000)
            XCTAssertEqual(snapshot.summary?.categories.first?.availableMinor, 0)
            XCTAssertEqual(snapshot.planPerformance?.points.first?.readyToAssignMinor, 35_000)
            let ranged = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-08-15"), end: BudgetWorkspaceStore.parseDate("2026-09-15"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
            let history = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-10-01"), report: ranged)
            XCTAssertEqual(history.planPerformance?.points.map(\.carriedAvailableMinor), [-5_000, 0])
            XCTAssertEqual(history.planPerformance?.points.map(\.activityMinor), [0, 0])
            XCTAssertEqual(history.planPerformance?.points.map(\.readyToAssignMinor), [40_000, 35_000])
        }
        do {
            try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 35_001, expectedVersion: source.demo.allocationVersion))
            XCTFail("Absorbed cash is not assignable a second time")
        } catch {}
        XCTAssertEqual(source.demo.financialObservation(accountReferences: ["cash": cash], categoryReferences: ["needs": category]), before)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
        try await record(2_000, categoryID: category, day: "2026-08-03")
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").readyToAssignMinor, 37_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").categories[category]?.availableMinor, 0)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
    }

    @MainActor
    func testProductionDemoRolloverSeparatesUnfundedCreditAndFundsLaterPurchases() async throws {
        let source = DemoWorkspaceDataSource(fresh: true, cashRolloverPolicies: [try .init(effectiveMonth: "2026-09-01", policy: .absorb, version: 1)])
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let cash = try XCTUnwrap(source.demo.accounts.last?.id)
        try await services.accounts.create(.init(name: "Card", kind: "credit", isOnBudget: true, openingBalanceMinor: 0))
        let card = try XCTUnwrap(source.demo.accounts.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
        let category = try XCTUnwrap(source.demo.categories.last?.id)
        func record(_ amount: Int64, accountID: String, categoryID: String?, day: String) async throws {
            try await services.transactions.record(.init(accountID: accountID, categoryID: categoryID, amountMinor: amount,
                occurredOn: day, payeeName: "Credit rollover proof", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        }
        try await record(50_000, accountID: cash, categoryID: nil, day: "2026-08-01")
        try await services.planning.assign(.init(categoryID: category, month: "2026-08-01", assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))
        try await record(-15_000, accountID: cash, categoryID: category, day: "2026-08-02")
        try await record(-3_000, accountID: card, categoryID: category, day: "2026-08-03")
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").categories[category]?.availableMinor, -3_000)
        XCTAssertEqual(source.demo.readyToAssign, 35_000)
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 0)
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 13_000, expectedVersion: source.demo.allocationVersion))
        try await record(-8_000, accountID: card, categoryID: category, day: "2026-09-02")
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 8_000)
        XCTAssertEqual(source.demo.accounts.last?.balance, -11_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").categories[category]?.availableMinor, 2_000)
        XCTAssertEqual(source.demo.readyToAssign, 22_000)
    }

    @MainActor
    func testDeterministicAdapterRunsEverySharedFinancialVectorExactly() async throws {
        try await runVectors(fileName: "v1.json", count: 15)
    }

    @MainActor
    func testProductionPlanReportBoundsAndExplicitOpeningDoNotInventEarlierHistory() async throws {
        let source = DemoWorkspaceDataSource()
        func snapshot(_ start: String, _ end: String) async throws -> WorkspaceSnapshot {
            let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate(start), end: BudgetWorkspaceStore.parseDate(end), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
            return try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        }
        let crossing = try await snapshot("2025-09-01", "2025-10-15")
        XCTAssertEqual(crossing.planPerformance?.points.map(\.periodStart), ["2025-10-01"])
        XCTAssertEqual(crossing.planPerformance?.points.map(\.periodEnd), ["2025-10-15"])
        let unsupported = try await snapshot("2025-09-01", "2025-09-30")
        XCTAssertTrue(try XCTUnwrap(unsupported.planPerformance).points.isEmpty)
        for (start, end) in [("2026-09-02", "2026-09-01"), ("1900-01-01", "2026-09-01")] {
            do { _ = try await snapshot(start, end); XCTFail("Invalid report range must be rejected before expensive projection") }
            catch {}
        }
    }

    @MainActor
    func testProductionDemoSplitAndMoveRecomputePendingAbsorption() async throws {
        let source = DemoWorkspaceDataSource(fresh: true, cashRolloverPolicies: [try .init(effectiveMonth: "2026-10-01", policy: .absorb, version: 1)])
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 50_000))
        let cash = try XCTUnwrap(source.demo.accounts.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Funded", group: "Needs"))
        let funded = try XCTUnwrap(source.demo.categories.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Unfunded", group: "Needs"))
        let unfunded = try XCTUnwrap(source.demo.categories.last?.id)
        try await services.planning.assign(.init(categoryID: funded, month: "2026-09-01", assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))
        try await services.transactions.record(.init(accountID: cash, categoryID: nil, amountMinor: -15_000,
            occurredOn: "2026-09-02", payeeName: "Split", memo: "", isCleared: false,
            splits: [.init(categoryID: funded, amountMinor: -9_000, memo: ""), .init(categoryID: unfunded, amountMinor: -6_000, memo: "")], flag: nil, tags: [], attachmentMetadata: []))
        XCTAssertEqual(source.demo.readyToAssign, 34_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-10-01").categories[unfunded]?.availableMinor, 0)
        try await services.planning.move(.init(sourceCategoryID: funded, destinationCategoryID: unfunded, amountMinor: 1_000,
            occurredOn: "2026-09-03", note: "Cover before boundary", expectedVersion: source.demo.allocationVersion))
        XCTAssertEqual(source.demo.readyToAssign, 35_000)
        XCTAssertEqual(source.demo.accounts.first?.balance, 35_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").categories[unfunded]?.availableMinor, -5_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-10-01").categories[unfunded]?.availableMinor, 0)
        let count = source.demo.allocationEvents.count
        let transactionID = try XCTUnwrap(source.demo.transactions.first(where: { $0.payee == "Split" })?.id)
        XCTAssertTrue(source.demo.deleteTransaction(id: transactionID))
        XCTAssertEqual(source.demo.readyToAssign, 40_000)
        XCTAssertEqual(source.demo.allocationEvents.count, count)
    }

    @MainActor
    func testProductionDemoEffectivePolicyHistoryDoesNotRewriteEarlierPeriods() async throws {
        let source = DemoWorkspaceDataSource(fresh: true, cashRolloverPolicies: [
            try .init(effectiveMonth: "2026-09-01", policy: .absorb, version: 1),
            try .init(effectiveMonth: "2026-09-01", policy: .carry, version: 2),
            try .init(effectiveMonth: "2026-11-01", policy: .absorb, version: 3),
            try .init(effectiveMonth: "2026-12-01", policy: .carry, version: 4),
        ])
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let cash = try XCTUnwrap(source.demo.accounts.last?.id)
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
        let category = try XCTUnwrap(source.demo.categories.last?.id)
        for (amount, categoryID) in [(Int64(50_000), Optional<String>.none), (-5_000, Optional(category))] {
            try await services.transactions.record(.init(accountID: cash, categoryID: categoryID, amountMinor: amount,
                occurredOn: "2026-08-01", payeeName: "History", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        }
        let september = try source.demo.planningSnapshot(month: "2026-09-01")
        XCTAssertEqual(september.categories[category]?.availableMinor, -5_000)
        XCTAssertEqual(september.readyToAssignMinor, 50_000)
        XCTAssertEqual(september.allDateUnassignedMinor, 45_000)
        for month in ["2026-11-01", "2026-12-01", "2027-01-01"] {
            let plan = try source.demo.planningSnapshot(month: month)
            XCTAssertEqual(plan.categories[category]?.availableMinor, 0)
            XCTAssertEqual(plan.readyToAssignMinor, 45_000)
        }
        XCTAssertTrue(source.demo.allocationEvents.isEmpty, "Policy effects are not fake allocations")
    }

    @MainActor
    func testProductionDeterministicAdapterRunsEverySharedPlanningPeriodVectorExactly() async throws {
        try await runVectors(fileName: "planning-periods-v1.json", count: 7)
    }

    @MainActor
    private func runVectors(fileName: String, count: Int) async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("server/tests/financial_vectors/\(fileName)")
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, count, "the native suite must consume the complete shared vector file")

        for vector in cases {
            let vectorID = try XCTUnwrap(vector["id"] as? String)
            let source = DemoWorkspaceDataSource(fresh: true)
            let services = BudgetApplicationServices(repository: source)
            var accountRefs: [String: String] = [:]
            var categoryRefs: [String: String] = [:]
            var scheduleRefs: [String: String] = [:]
            var transactionRefs: [String: String] = [:]

            for operation in try XCTUnwrap(vector["operations"] as? [[String: Any]]) {
                let kind = try XCTUnwrap(operation["op"] as? String)
                let occurredOn = operation["occurred_on"] as? String ?? "2026-09-01"
                switch kind {
                case "create_account":
                    let name = string(operation, "name")
                    try await services.accounts.create(.init(name: name, kind: string(operation, "kind"), isOnBudget: bool(operation, "on_budget"), openingBalanceMinor: integer(operation, "opening_minor")))
                    accountRefs[string(operation, "ref")] = try XCTUnwrap(source.demo.accounts.last(where: { $0.name == name })?.id)
                case "create_category":
                    XCTAssertTrue(source.demo.createCategory(name: string(operation, "name"), group: string(operation, "group")), vectorID)
                    categoryRefs[string(operation, "ref")] = try XCTUnwrap(source.demo.categories.last?.id)
                case "assign":
                    let id = try XCTUnwrap(categoryRefs[string(operation, "category")])
                    let intent = AssignMoneyOperation(categoryID: id, month: operation["month"] as? String ?? "2026-09-01", assignedMinor: integer(operation, "amount_minor"), expectedVersion: source.demo.allocationVersion)
                    if operation["expected_error"] != nil {
                        let before = source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs)
                        let events = source.demo.allocationEvents.map(\.id)
                        do { try await services.planning.assign(intent); XCTFail("Expected funding refusal: \(vectorID)") } catch {}
                        XCTAssertEqual(source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs), before)
                        XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
                    } else { try await services.planning.assign(intent) }
                case "move":
                    try await services.planning.move(.init(sourceCategoryID: try XCTUnwrap(categoryRefs[string(operation, "source")]), destinationCategoryID: try XCTUnwrap(categoryRefs[string(operation, "destination")]), amountMinor: integer(operation, "amount_minor"), occurredOn: occurredOn, note: "vector", expectedVersion: source.demo.allocationVersion))
                case "transaction", "edit_transaction":
                    let splits = (operation["splits"] as? [String: Any] ?? [:]).map {
                        TransactionSplitOperation(categoryID: categoryRefs[$0.key]!, amountMinor: ($0.value as! NSNumber).int64Value, memo: "")
                    }
                    let category = (operation["category"] as? String).flatMap { categoryRefs[$0] }
                    let intent = RecordTransactionOperation(accountID: try XCTUnwrap(accountRefs[string(operation, "account")]), categoryID: category, amountMinor: integer(operation, "amount_minor"), occurredOn: occurredOn, payeeName: "Vector transaction", memo: "", isCleared: operation["cleared"] as? Bool ?? true, splits: splits, flag: nil, tags: [], attachmentMetadata: [])
                    if kind == "edit_transaction" {
                        try await services.transactions.update(id: try XCTUnwrap(transactionRefs[string(operation, "ref")]), operation: intent)
                    } else {
                        try await services.transactions.record(intent)
                        if let ref = operation["ref"] as? String { transactionRefs[ref] = try XCTUnwrap(source.demo.transactions.first?.id) }
                    }
                    if !splits.isEmpty {
                        XCTAssertEqual(source.demo.transactions.first?.categoryIDs, splits.map(\.categoryID), "Preserve canonical split order in \(vectorID)")
                    }
                case "transfer":
                    try await services.transactions.transfer(.init(sourceAccountID: try XCTUnwrap(accountRefs[string(operation, "source")]), destinationAccountID: try XCTUnwrap(accountRefs[string(operation, "destination")]), amountMinor: integer(operation, "amount_minor"), occurredOn: occurredOn, memo: "vector", isCleared: true))
                case "reconcile":
                    let accountID = try XCTUnwrap(accountRefs[string(operation, "account")])
                    let cleared = try XCTUnwrap(source.demo.accounts.first(where: { $0.id == accountID })?.cleared)
                    try await services.accounts.reconcile(.init(accountID: accountID, statementBalanceMinor: integer(operation, "statement_minor"), throughDate: operation["through_date"] as? String ?? BudgetWorkspaceStore.dateString(Date()), createAdjustment: bool(operation, "create_adjustment"), reason: "vector", expectedClearedBalanceMinor: cleared))
                case "schedule":
                    let name = "Vector \(string(operation, "ref"))"
                    try await services.schedules.create(.init(accountID: try XCTUnwrap(accountRefs[string(operation, "account")]), categoryID: (operation["category"] as? String).flatMap { categoryRefs[$0] }, name: name, amountMinor: integer(operation, "amount_minor"), nextDate: operation["next_date"] as? String ?? "2026-09-01", recurrenceUnit: string(operation, "recurrence")))
                    scheduleRefs[string(operation, "ref")] = try XCTUnwrap(source.demo.schedules.last(where: { $0.name == name })?.id)
                case "realize":
                    _ = try await services.schedules.realize(id: try XCTUnwrap(scheduleRefs[string(operation, "schedule")]))
                case "observe":
                    let expected = try XCTUnwrap(operation["expected"] as? [String: Any])
                    let actual = source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs)
                    if let month = operation["month"] as? String {
                        let report = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate(month), end: BudgetWorkspaceStore.parseDate("2026-12-31"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
                        let before = source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs)
                        let snapshot = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate(month), report: report)
                        let summary = try XCTUnwrap(snapshot.summary)
                        let categories = categoryRefs.compactMapValues { id in summary.categories.first { $0.categoryID == id }.map { CategoryBalanceObservation(assignedMinor: $0.assignedMinor, activityMinor: $0.activityMinor, availableMinor: $0.availableMinor) } }
                        assert(expected, equals: .init(accounts: actual.accounts, categories: categories, cards: actual.cards, unassignedMinor: summary.readyToAssignMinor, totalBudgetCashMinor: actual.totalBudgetCashMinor, netWorthMinor: actual.netWorthMinor, transactionCount: actual.transactionCount, allocationPostingsSumMinor: actual.allocationPostingsSumMinor), vectorID: vectorID)
                        for (ref, raw) in expected["categories"] as? [String: [String: Any]] ?? [:] {
                            let row = try XCTUnwrap(summary.categories.first { $0.categoryID == categoryRefs[ref] })
                            if let value = raw["carried_available_minor"] as? NSNumber { XCTAssertEqual(row.carriedAvailableMinor, value.int64Value, vectorID) }
                            if let value = raw["cash_overspent_minor"] as? NSNumber { XCTAssertEqual(row.cashOverspentMinor, value.int64Value, vectorID) }
                            if let value = raw["credit_overspent_minor"] as? NSNumber { XCTAssertEqual(row.creditOverspentMinor, value.int64Value, vectorID) }
                        }
                        for (ref, raw) in expected["account_balances"] as? [String: [String: Any]] ?? [:] {
                            let balance = try XCTUnwrap(snapshot.accountBalances[try XCTUnwrap(accountRefs[ref])])
                            if let value = raw["working_balance_minor"] as? NSNumber { XCTAssertEqual(balance.workingBalanceMinor, value.int64Value, vectorID) }
                            if let value = raw["cleared_balance_minor"] as? NSNumber { XCTAssertEqual(balance.clearedBalanceMinor, value.int64Value, vectorID) }
                            if let value = raw["uncleared_balance_minor"] as? NSNumber { XCTAssertEqual(balance.unclearedBalanceMinor, value.int64Value, vectorID) }
                            if raw["reconciled_balance_minor"] is NSNull { XCTAssertNil(balance.reconciledBalanceMinor, vectorID) }
                            else if let value = raw["reconciled_balance_minor"] as? NSNumber { XCTAssertEqual(balance.reconciledBalanceMinor, value.int64Value, vectorID) }
                        }
                        if let value = expected["funding_limit_minor"] as? NSNumber {
                            let funding = try await source.smartFundingPreview(month: month)
                            XCTAssertEqual(funding.fundingLimitMinor, value.int64Value, vectorID)
                        }
                        let repeated = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate(month), report: report)
                        XCTAssertEqual(repeated.summary, snapshot.summary, vectorID)
                        XCTAssertEqual(source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs), before, "Reads do not post money")
                    } else { assert(expected, equals: actual, vectorID: vectorID) }
                    XCTAssertEqual(source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs).allocationPostingsSumMinor, 0,
                                   "Allocation journal remains balanced after spending/refunds/transfers in \(vectorID)")
                default:
                    XCTFail("Unsupported operation \(kind) in \(vectorID)")
                }
            }
        }
    }

    @MainActor
    func testFutureAssignmentCannotFundEarlierCardPurchaseAndFailedEditRestoresReserve() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 20_000))
        try await services.accounts.create(.init(name: "Card", kind: "credit", isOnBudget: true, openingBalanceMinor: 0))
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
        let card = try XCTUnwrap(source.demo.accounts.last?.id)
        let category = try XCTUnwrap(source.demo.categories.last?.id)
        try await services.planning.assign(.init(categoryID: category, month: "2026-10-01", assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))
        try await services.transactions.record(.init(accountID: card, categoryID: category, amountMinor: -5_000, occurredOn: "2026-09-01", payeeName: "Earlier purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 0, "Future allocation is not category funding on the earlier purchase date")
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").categories[category]?.availableMinor, -5_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-10-01").categories[category]?.availableMinor, 5_000)
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))
        try await services.transactions.record(.init(accountID: card, categoryID: category, amountMinor: -5_000, occurredOn: "2026-09-02", payeeName: "Funded purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let fundedID = try XCTUnwrap(source.demo.transactions.first?.id)
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 5_000)
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 0, expectedVersion: source.demo.allocationVersion))
        let accounts = source.demo.accounts, categories = source.demo.categories, transactions = source.demo.transactions
        let ready = source.demo.readyToAssign
        do {
            try await services.transactions.update(id: fundedID, operation: .init(accountID: "missing", categoryID: category, amountMinor: -5_000, occurredOn: "2026-09-02", payeeName: "Rejected", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
            XCTFail("Invalid edit must be rejected")
        } catch {}
        XCTAssertEqual(source.demo.accounts, accounts)
        XCTAssertEqual(source.demo.categories, categories)
        XCTAssertEqual(source.demo.transactions, transactions)
        XCTAssertEqual(source.demo.readyToAssign, ready)
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 5_000, "Rollback restores the original reserve event, not a newly recalculated one")
    }

    @MainActor
    func testDatedVoidKeepsOriginalHistoryAndNetsSubsequentReserveRefunds() async throws {
        let today = BudgetWorkspaceStore.dateString(Date())
        let currentMonth = String(today.prefix(7)) + "-01"
        let earlier = Calendar.current.date(byAdding: .month, value: -1, to: BudgetWorkspaceStore.parseDate(currentMonth))!
        let earlierMonth = BudgetWorkspaceStore.dateString(earlier)
        for kind in ["checking", "credit"] {
            let source = DemoWorkspaceDataSource(fresh: true)
            let services = BudgetApplicationServices(repository: source)
            try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 20_000))
            if kind == "credit" { try await services.accounts.create(.init(name: "Card", kind: "credit", isOnBudget: true, openingBalanceMinor: 0)) }
            let account = try XCTUnwrap(source.demo.accounts.last?.id)
            XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
            let category = try XCTUnwrap(source.demo.categories.first?.id)
            try await services.planning.assign(.init(categoryID: category, month: earlierMonth, assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))
            func transaction(_ amount: Int64, _ date: String) -> RecordTransactionOperation {
                .init(accountID: account, categoryID: category, amountMinor: amount, occurredOn: date, payeeName: "Lifecycle", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])
            }
            try await services.transactions.record(transaction(-5_000, earlierMonth))
            let original = try XCTUnwrap(source.demo.transactions.first?.id)
            try await source.voidTransaction(id: original, reason: "Dated reversal")
            let previous = try source.demo.planningSnapshot(month: earlierMonth)
            let current = try source.demo.planningSnapshot(month: currentMonth)
            XCTAssertEqual(previous.categories[category]?.activityMinor, -5_000)
            XCTAssertEqual(previous.categories[category]?.availableMinor, 5_000)
            XCTAssertEqual(current.categories[category]?.activityMinor, 5_000)
            XCTAssertEqual(current.categories[category]?.carriedAvailableMinor, 5_000)
            XCTAssertEqual(current.categories[category]?.availableMinor, 10_000)
            XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 0)
            try await services.transactions.record(transaction(-1_000, today))
            if kind == "credit" { XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 1_000) }
            try await services.transactions.record(transaction(1_000, today))
            XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 0)
            XCTAssertEqual(try source.demo.planningSnapshot(month: currentMonth).categories[category]?.availableMinor, 10_000)
            XCTAssertEqual(source.demo.transactions.first { $0.id == original }?.amount, -5_000)
        }
    }

    @MainActor
    func testApplicationServicesRejectInvalidIntentBeforeRepositoryMutation() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        let services = BudgetApplicationServices(repository: source)
        do {
            try await services.transactions.record(.init(accountID: "missing", categoryID: nil, amountMinor: 0, occurredOn: "2026-09-01", payeeName: "", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []))
            XCTFail("zero transaction unexpectedly reached the adapter")
        } catch let error as BudgetApplicationError {
            guard case .invalidOperation = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertTrue(source.demo.accounts.isEmpty)
        XCTAssertTrue(source.demo.transactions.isEmpty)

        try await services.accounts.create(.init(name: "Source", kind: "checking", isOnBudget: true, openingBalanceMinor: 1_000))
        try await services.accounts.create(.init(name: "Destination", kind: "savings", isOnBudget: true, openingBalanceMinor: 0))
        let sourceID = try XCTUnwrap(source.demo.accounts.first(where: { $0.name == "Source" })?.id)
        let destinationID = try XCTUnwrap(source.demo.accounts.first(where: { $0.name == "Destination" })?.id)
        let transactionCountBeforeInvalidTransfers = source.demo.transactions.count
        for invalid in [
            TransferMoneyOperation(sourceAccountID: sourceID, destinationAccountID: destinationID, amountMinor: 0, occurredOn: "2026-09-09", memo: "", isCleared: false),
            TransferMoneyOperation(sourceAccountID: sourceID, destinationAccountID: sourceID, amountMinor: 100, occurredOn: "2026-09-09", memo: "", isCleared: false)
        ] {
            do {
                try await services.transactions.transfer(invalid)
                XCTFail("invalid transfer unexpectedly reached the adapter")
            } catch let error as BudgetApplicationError {
                guard case .invalidOperation = error else { return XCTFail("wrong error: \(error)") }
            }
        }
        XCTAssertEqual(source.demo.transactions.count, transactionCountBeforeInvalidTransfers)
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == sourceID })?.balance, 1_000)
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == destinationID })?.balance, 0)
    }

    @MainActor
    func testDeterministicEditAndDeleteReverseRefundAndCreditReserveExactly() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        let services = BudgetApplicationServices(repository: source)
        try await services.accounts.create(.init(name: "Cash", kind: "checking", isOnBudget: true, openingBalanceMinor: 10_000))
        try await services.accounts.create(.init(name: "Card", kind: "credit", isOnBudget: true, openingBalanceMinor: 0))
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Needs"))
        let cash = source.demo.accounts.first(where: { $0.name == "Cash" })!.id
        let card = source.demo.accounts.first(where: { $0.name == "Card" })!.id
        let category = source.demo.categories.last!.id
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 10_000, expectedVersion: source.demo.allocationVersion))

        let cardPurchase = RecordTransactionOperation(accountID: card, categoryID: category, amountMinor: -8_000, occurredOn: "2026-09-01", payeeName: "Purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await services.transactions.record(cardPurchase)
        let purchaseID = source.demo.transactions.first(where: { $0.payee == "Purchase" })!.id
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == card })?.paymentReserved, 8_000)
        try await services.transactions.update(id: purchaseID, operation: .init(accountID: card, categoryID: category, amountMinor: -3_000, occurredOn: "2026-09-01", payeeName: "Purchase", memo: "edited", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == card })?.paymentReserved, 3_000)
        XCTAssertEqual(source.demo.categories.first(where: { $0.id == category })?.available, 7_000)
        try await services.transactions.delete(id: purchaseID)
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == card })?.paymentReserved, 0)
        XCTAssertEqual(source.demo.categories.first(where: { $0.id == category })?.available, 10_000)

        try await services.transactions.record(.init(accountID: cash, categoryID: category, amountMinor: -3_000, occurredOn: "2026-09-01", payeeName: "Cash purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        try await services.transactions.record(.init(accountID: cash, categoryID: category, amountMinor: 1_000, occurredOn: "2026-09-01", payeeName: "Refund", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let refundID = source.demo.transactions.first(where: { $0.payee == "Refund" })!.id
        try await services.transactions.update(id: refundID, operation: .init(accountID: cash, categoryID: category, amountMinor: 1_500, occurredOn: "2026-09-01", payeeName: "Refund", memo: "edited", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        XCTAssertEqual(source.demo.categories.first(where: { $0.id == category })?.activity, -1_500)
        try await services.transactions.delete(id: refundID)
        XCTAssertEqual(source.demo.categories.first(where: { $0.id == category })?.activity, -3_000)
        XCTAssertEqual(source.demo.unassignedMinor, 0, "a categorized refund has exactly one destination")
    }

    func testLiveAdapterTranslationsPreserveExactOperationIntent() {
        let transaction = RecordTransactionOperation(accountID: "a", categoryID: nil, amountMinor: -10_001, occurredOn: "2026-09-01", payeeName: "Payee", memo: "memo", isCleared: true, splits: [.init(categoryID: "c1", amountMinor: -7_001, memo: "one"), .init(categoryID: "c2", amountMinor: -3_000, memo: "two")], flag: "blue", tags: ["tag"], attachmentMetadata: [["name": "receipt"]]).apiValue
        XCTAssertEqual(transaction.amountMinor, -10_001)
        XCTAssertEqual(transaction.splits.map(\.amountMinor), [-7_001, -3_000])
        XCTAssertEqual(transaction.tags, ["tag"])
        let transfer = TransferMoneyOperation(sourceAccountID: "a", destinationAccountID: "b", amountMinor: 9_999, occurredOn: "2026-09-02", memo: "payment", isCleared: true).apiValue
        XCTAssertEqual(transfer.amountMinor, 9_999)
        XCTAssertEqual(transfer.destinationAccountID, "b")
        let schedule = ScheduleOperation(accountID: "a", categoryID: "c1", name: "Bill", amountMinor: -2_500, nextDate: "2026-09-03", recurrenceUnit: "months", intervalCount: 2).apiValue
        XCTAssertEqual(schedule.amountMinor, -2_500)
        XCTAssertEqual(schedule.intervalCount, 2)
    }

    private func assert(_ expected: [String: Any], equals actual: FinancialObservation, vectorID: String, file: StaticString = #filePath, line: UInt = #line) {
        if let value = expected["unassigned_minor"] { XCTAssertEqual(actual.unassignedMinor, (value as! NSNumber).int64Value, vectorID, file: file, line: line) }
        if let value = expected["total_budget_cash_minor"] { XCTAssertEqual(actual.totalBudgetCashMinor, (value as! NSNumber).int64Value, vectorID, file: file, line: line) }
        if let value = expected["net_worth_minor"] { XCTAssertEqual(actual.netWorthMinor, (value as! NSNumber).int64Value, vectorID, file: file, line: line) }
        if let value = expected["transaction_count"] { XCTAssertEqual(actual.transactionCount, (value as! NSNumber).intValue, vectorID, file: file, line: line) }
        if let value = expected["allocation_postings_sum_minor"] { XCTAssertEqual(actual.allocationPostingsSumMinor, (value as! NSNumber).int64Value, vectorID, file: file, line: line) }
        for (ref, value) in expected["accounts"] as? [String: Any] ?? [:] { XCTAssertEqual(actual.accounts[ref]?.balanceMinor, (value as! NSNumber).int64Value, "\(vectorID).accounts.\(ref)", file: file, line: line) }
        for (ref, raw) in expected["categories"] as? [String: Any] ?? [:] {
            let value = raw as! [String: Any], category = actual.categories[ref]
            if let amount = value["assigned_minor"] { XCTAssertEqual(category?.assignedMinor, (amount as! NSNumber).int64Value, "\(vectorID).categories.\(ref).assigned", file: file, line: line) }
            if let amount = value["activity_minor"] { XCTAssertEqual(category?.activityMinor, (amount as! NSNumber).int64Value, "\(vectorID).categories.\(ref).activity", file: file, line: line) }
            if let amount = value["available_minor"] { XCTAssertEqual(category?.availableMinor, (amount as! NSNumber).int64Value, "\(vectorID).categories.\(ref).available", file: file, line: line) }
        }
        for (ref, raw) in expected["cards"] as? [String: Any] ?? [:] {
            let value = raw as! [String: Any], card = actual.cards[ref]
            XCTAssertEqual(card?.liabilityMinor, integer(value, "liability_minor"), "\(vectorID).cards.\(ref).liability", file: file, line: line)
            XCTAssertEqual(card?.reservedMinor, integer(value, "reserved_minor"), "\(vectorID).cards.\(ref).reserved", file: file, line: line)
            XCTAssertEqual(card?.unfundedDebtMinor, integer(value, "unfunded_debt_minor"), "\(vectorID).cards.\(ref).unfunded", file: file, line: line)
        }
    }

    private func string(_ value: [String: Any], _ key: String) -> String { value[key] as! String }
    private func integer(_ value: [String: Any], _ key: String) -> Int64 { (value[key] as! NSNumber).int64Value }
    private func bool(_ value: [String: Any], _ key: String) -> Bool { (value[key] as! NSNumber).boolValue }
}
