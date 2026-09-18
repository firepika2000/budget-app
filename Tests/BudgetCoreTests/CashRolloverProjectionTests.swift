import XCTest
@testable import BudgetCore

final class CashRolloverProjectionTests: XCTestCase {
    private typealias P = CashRolloverProjection

    func testEverySharedRolloverVectorIsExactRepeatableAndOrderIndependent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("server/tests/financial_vectors/cash-rollover-v1.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 17)
        for item in cases {
            let name = try XCTUnwrap(item["id"] as? String)
            let through = try XCTUnwrap(item["through"] as? String)
            let policies = try XCTUnwrap(item["policies"] as? [[Any]]).map { row in
                try P.Change(effectiveMonth: XCTUnwrap(row[0] as? String), policy: XCTUnwrap(P.Policy(rawValue: XCTUnwrap(row[1] as? String))), version: XCTUnwrap(row[2] as? NSNumber).intValue)
            }
            let facts = try XCTUnwrap(item["facts"] as? [[Any]]).map { row in
                try P.Fact(occurredOn: XCTUnwrap(row[0] as? String), categoryID: XCTUnwrap(row[1] as? String), availableDeltaMinor: XCTUnwrap(row[2] as? NSNumber).int64Value, unfundedCreditDeltaMinor: XCTUnwrap(row[3] as? NSNumber).int64Value)
            }
            if item["error"] != nil {
                XCTAssertThrowsError(try P.effects(throughMonth: through, policies: policies, facts: facts), name) {
                    XCTAssertEqual($0 as? MoneyError, .arithmeticOverflow)
                }
                continue
            }
            let expected = try XCTUnwrap(item["effects"] as? [[Any]]).map { row in
                try P.Effect(month: XCTUnwrap(row[0] as? String), categoryID: XCTUnwrap(row[1] as? String), amountMinor: XCTUnwrap(row[2] as? NSNumber).int64Value, policyVersion: XCTUnwrap(row[3] as? NSNumber).intValue)
            }
            let result = try P.effects(throughMonth: through, policies: policies, facts: facts)
            XCTAssertEqual(result, expected, name)
            XCTAssertEqual(try P.effects(throughMonth: through, policies: policies, facts: facts), result, name)
            XCTAssertEqual(try P.effects(throughMonth: through, policies: policies.reversed(), facts: facts.reversed()), result, name)
            for change in policies {
                for earlier in Set(facts.map { $0.occurredOn.month }).filter({ $0 < change.effectiveMonth.iso }) {
                    let prior = policies.filter { $0.effectiveMonth < change.effectiveMonth }
                    XCTAssertEqual(try P.effects(throughMonth: earlier, policies: policies, facts: facts),
                                   try P.effects(throughMonth: earlier, policies: prior, facts: facts), name)
                }
            }
        }
    }

    func testInvalidHistoryAndHorizonFailInsteadOfSilentlyChoosingAPolicy() throws {
        XCTAssertThrowsError(try P.Change(effectiveMonth: "2026-10-02", policy: .absorb, version: 0))
        XCTAssertThrowsError(try P.Change(effectiveMonth: "2026-10-01", policy: .absorb, version: -1))
        let repeated = try [P.Change(effectiveMonth: "2026-10-01", policy: .absorb, version: 0), P.Change(effectiveMonth: "2026-11-01", policy: .carry, version: 0)]
        XCTAssertThrowsError(try P.effects(throughMonth: "2026-12-01", policies: repeated, facts: []))
        XCTAssertThrowsError(try P.effects(throughMonth: "2026-12-02", policies: [], facts: []))
    }

    func testEffectsEnterCarryAndUnassignedExactlyOnceWithoutBecomingAssignmentOrActivity() throws {
        typealias Period = PlanningPeriodProjection
        let policies = try [P.Change(effectiveMonth: "2026-09-01", policy: .absorb, version: 0)]
        let facts = try [P.Fact(occurredOn: "2026-09-01", categoryID: "food", availableDeltaMinor: 10000), P.Fact(occurredOn: "2026-09-30", categoryID: "food", availableDeltaMinor: -15000)]
        let effects = try P.effects(throughMonth: "2026-12-01", policies: policies, facts: facts)
        let allocations = try [Period.Allocation(occurredOn: "2026-09-01", postings: [.init(categoryID: nil, amountMinor: -10000), .init(categoryID: "food", amountMinor: 10000)])]
        let activity = try [Period.PostedActivity(occurredOn: "2026-09-01", unassignedMinor: 50000), Period.PostedActivity(occurredOn: "2026-09-30", categoryAmounts: ["food": -15000])]
        func snapshot(_ month: String) throws -> Period.Snapshot {
            try Period.snapshot(month: month, categoryIDs: ["food"], allocations: allocations, activity: activity, rolloverEffects: effects)
        }
        let september = try snapshot("2026-09-01")
        XCTAssertEqual(september.readyToAssignMinor, 40000)
        XCTAssertEqual(september.allDateUnassignedMinor, 35000, "Known future absorption reserves already-spent cash; it is not future income")
        XCTAssertEqual(september.categories["food"]?.assignedMinor, 10000)
        XCTAssertEqual(september.categories["food"]?.activityMinor, -15000)
        XCTAssertEqual(september.categories["food"]?.availableMinor, -5000)
        for month in ["2026-10-01", "2026-11-01", "2027-01-01"] {
            let result = try snapshot(month)
            XCTAssertEqual(result.readyToAssignMinor, 35000)
            XCTAssertEqual(result.allDateUnassignedMinor, 35000)
            XCTAssertEqual(result.categories["food"]?.carriedAvailableMinor, 0)
            XCTAssertEqual(result.categories["food"]?.assignedMinor, 0)
            XCTAssertEqual(result.categories["food"]?.activityMinor, 0)
            XCTAssertEqual(result.categories["food"]?.availableMinor, 0)
            XCTAssertEqual(try snapshot(month), result)
        }
        XCTAssertThrowsError(try september.replacementAssignment(categoryID: "food", assignedMinor: 45001))
        XCTAssertThrowsError(try Period.snapshot(month: "2026-10-01", categoryIDs: ["food"], allocations: allocations, activity: activity, rolloverEffects: effects + effects)) {
            XCTAssertEqual($0 as? Period.InvalidInput, .rollover)
        }
        let legacy = try Period.snapshot(month: "2026-10-01", categoryIDs: ["food"], allocations: allocations, activity: activity)
        XCTAssertEqual(legacy.readyToAssignMinor, 40000)
        XCTAssertEqual(legacy.categories["food"]?.carriedAvailableMinor, -5000)
    }
}
