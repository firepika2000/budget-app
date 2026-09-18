import XCTest
import BudgetAPI
@testable import Budget_App

final class FinancialGoldenVectorTests: XCTestCase {
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
