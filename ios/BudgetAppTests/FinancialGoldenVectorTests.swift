import XCTest
@testable import Budget_App

final class FinancialGoldenVectorTests: XCTestCase {
    @MainActor
    func testDeterministicAdapterRunsEverySharedFinancialVectorExactly() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("server/tests/financial_vectors/v1.json")
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12, "the native suite must consume the complete shared vector file")

        for vector in cases {
            let vectorID = try XCTUnwrap(vector["id"] as? String)
            let source = DemoWorkspaceDataSource(fresh: true)
            let services = BudgetApplicationServices(repository: source)
            var accountRefs: [String: String] = [:]
            var categoryRefs: [String: String] = [:]
            var scheduleRefs: [String: String] = [:]

            for operation in try XCTUnwrap(vector["operations"] as? [[String: Any]]) {
                let kind = try XCTUnwrap(operation["op"] as? String)
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
                    try await services.planning.assign(.init(categoryID: id, month: "2026-09-01", assignedMinor: integer(operation, "amount_minor"), expectedVersion: 1))
                case "move":
                    try await services.planning.move(.init(sourceCategoryID: try XCTUnwrap(categoryRefs[string(operation, "source")]), destinationCategoryID: try XCTUnwrap(categoryRefs[string(operation, "destination")]), amountMinor: integer(operation, "amount_minor"), occurredOn: "2026-09-01", note: "vector", expectedVersion: 1))
                case "transaction":
                    let splits = (operation["splits"] as? [String: Any] ?? [:]).map {
                        TransactionSplitOperation(categoryID: categoryRefs[$0.key]!, amountMinor: ($0.value as! NSNumber).int64Value, memo: "")
                    }
                    let category = (operation["category"] as? String).flatMap { categoryRefs[$0] }
                    try await services.transactions.record(.init(accountID: try XCTUnwrap(accountRefs[string(operation, "account")]), categoryID: category, amountMinor: integer(operation, "amount_minor"), occurredOn: "2026-09-01", payeeName: "Vector transaction", memo: "", isCleared: true, splits: splits, flag: nil, tags: [], attachmentMetadata: []))
                case "transfer":
                    try await services.transactions.transfer(.init(sourceAccountID: try XCTUnwrap(accountRefs[string(operation, "source")]), destinationAccountID: try XCTUnwrap(accountRefs[string(operation, "destination")]), amountMinor: integer(operation, "amount_minor"), occurredOn: "2026-09-01", memo: "vector", isCleared: true))
                case "reconcile":
                    let accountID = try XCTUnwrap(accountRefs[string(operation, "account")])
                    let cleared = try XCTUnwrap(source.demo.accounts.first(where: { $0.id == accountID })?.cleared)
                    try await services.accounts.reconcile(.init(accountID: accountID, statementBalanceMinor: integer(operation, "statement_minor"), throughDate: "2026-09-01", createAdjustment: bool(operation, "create_adjustment"), reason: "vector", expectedClearedBalanceMinor: cleared))
                case "schedule":
                    let name = "Vector \(string(operation, "ref"))"
                    try await services.schedules.create(.init(accountID: try XCTUnwrap(accountRefs[string(operation, "account")]), categoryID: (operation["category"] as? String).flatMap { categoryRefs[$0] }, name: name, amountMinor: integer(operation, "amount_minor"), nextDate: "2026-09-01", recurrenceUnit: string(operation, "recurrence")))
                    scheduleRefs[string(operation, "ref")] = try XCTUnwrap(source.demo.schedules.last(where: { $0.name == name })?.id)
                case "realize":
                    _ = try await services.schedules.realize(id: try XCTUnwrap(scheduleRefs[string(operation, "schedule")]))
                case "observe":
                    let expected = try XCTUnwrap(operation["expected"] as? [String: Any])
                    assert(expected, equals: source.demo.financialObservation(accountReferences: accountRefs, categoryReferences: categoryRefs), vectorID: vectorID)
                default:
                    XCTFail("Unsupported operation \(kind) in \(vectorID)")
                }
            }
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
