import XCTest
@testable import Budget_App

final class FinancialGoldenVectorTests: XCTestCase {
    @MainActor
    func testDeterministicAdapterRunsEverySharedFinancialVectorExactly() async throws {
        try await runVectors(fileName: "v1.json", count: 15)
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
                    let intent = AssignMoneyOperation(categoryID: id, month: operation["month"] as? String ?? "2026-09-01", assignedMinor: integer(operation, "amount_minor"), expectedVersion: 1)
                    if operation["expected_error"] != nil {
                        let before = source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs)
                        let events = source.demo.allocationEvents.map(\.id)
                        do { try await services.planning.assign(intent); XCTFail("Expected funding refusal: \(vectorID)") } catch {}
                        XCTAssertEqual(source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs), before)
                        XCTAssertEqual(source.demo.allocationEvents.map(\.id), events)
                    } else { try await services.planning.assign(intent) }
                case "move":
                    try await services.planning.move(.init(sourceCategoryID: try XCTUnwrap(categoryRefs[string(operation, "source")]), destinationCategoryID: try XCTUnwrap(categoryRefs[string(operation, "destination")]), amountMinor: integer(operation, "amount_minor"), occurredOn: occurredOn, note: "vector", expectedVersion: 1))
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
                    try await services.accounts.reconcile(.init(accountID: accountID, statementBalanceMinor: integer(operation, "statement_minor"), throughDate: operation["through_date"] as? String ?? "2026-09-01", createAdjustment: bool(operation, "create_adjustment"), reason: "vector", expectedClearedBalanceMinor: cleared))
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
        try await services.planning.assign(.init(categoryID: category, month: "2026-10-01", assignedMinor: 10_000, expectedVersion: 1))
        try await services.transactions.record(.init(accountID: card, categoryID: category, amountMinor: -5_000, occurredOn: "2026-09-01", payeeName: "Earlier purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 0, "Future allocation is not category funding on the earlier purchase date")
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-09-01").categories[category]?.availableMinor, -5_000)
        XCTAssertEqual(try source.demo.planningSnapshot(month: "2026-10-01").categories[category]?.availableMinor, 5_000)
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 10_000, expectedVersion: 1))
        try await services.transactions.record(.init(accountID: card, categoryID: category, amountMinor: -5_000, occurredOn: "2026-09-02", payeeName: "Funded purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let fundedID = try XCTUnwrap(source.demo.transactions.first?.id)
        XCTAssertEqual(source.demo.accounts.last?.paymentReserved, 5_000)
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 0, expectedVersion: 1))
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
            try await services.planning.assign(.init(categoryID: category, month: earlierMonth, assignedMinor: 10_000, expectedVersion: 1))
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
        try await services.planning.assign(.init(categoryID: category, month: "2026-09-01", assignedMinor: 10_000, expectedVersion: 1))

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
