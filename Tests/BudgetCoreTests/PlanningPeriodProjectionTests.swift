import XCTest
@testable import BudgetCore

final class PlanningPeriodProjectionTests: XCTestCase {
    private typealias P = PlanningPeriodProjection

    /// This tests period projection, NOT the full Demo repository, account posting, or card engine.
    /// Those services must additionally pass the complete fixture observations before migration closes.
    func testPeriodFieldsFromAllSixCanonicalServerOperationVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("server/tests/financial_vectors/planning-periods-v1.json"))) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7)
        for vector in cases {
            let name = try string(vector, "id")
            var categories = Set<String>()
            var accounts: [String: String] = [:]
            var allocations: [P.Allocation] = []
            var activity: [String: P.PostedActivity] = [:]
            var schedules: [String: [String: Any]] = [:]
            func projection(_ month: String) throws -> P.Snapshot {
                try P.snapshot(month: month, categoryIDs: categories, allocations: allocations, activity: activity.values)
            }
            func posted(_ operation: [String: Any], dateKey: String) throws -> P.PostedActivity {
                var amounts = (operation["splits"] as? [String: NSNumber] ?? [:]).mapValues(\.int64Value)
                if let category = operation["category"] as? String { amounts[category] = try integer(operation, "amount_minor") }
                let kind = try XCTUnwrap(accounts[try string(operation, "account")])
                let cash = ["checking", "savings", "cash"].contains(kind)
                return try P.PostedActivity(occurredOn: string(operation, dateKey), categoryAmounts: amounts,
                    unassignedMinor: cash && amounts.isEmpty ? integer(operation, "amount_minor") : 0)
            }
            for operation in try XCTUnwrap(vector["operations"] as? [[String: Any]]) {
                switch try string(operation, "op") {
                case "create_account":
                    XCTAssertEqual(try integer(operation, "opening_minor"), 0, "Extend fixture adapter explicitly for nonzero openings")
                    XCTAssertEqual(operation["on_budget"] as? Bool, true)
                    accounts[try string(operation, "ref")] = try string(operation, "kind")
                case "create_category": categories.insert(try string(operation, "ref"))
                case "assign":
                    let month = try string(operation, "month")
                    let snapshot = try projection(month)
                    let id = try string(operation, "category"), amount = try integer(operation, "amount_minor")
                    if operation["expected_error"] != nil {
                        XCTAssertEqual(operation["expected_error"] as? String, "insufficient_funds")
                        XCTAssertThrowsError(try snapshot.replacementAssignment(categoryID: id, assignedMinor: amount)) {
                            XCTAssertEqual($0 as? P.InvalidInput, .insufficientFunds, name)
                        }
                    } else {
                        if let allocation = try snapshot.replacementAssignment(categoryID: id, assignedMinor: amount) {
                            XCTAssertEqual(allocation.occurredOn.iso, month)
                            allocations.append(allocation)
                        }
                    }
                case "transaction", "edit_transaction":
                    activity[operation["ref"] as? String ?? UUID().uuidString] = try posted(operation, dateKey: "occurred_on")
                case "schedule": schedules[try string(operation, "ref")] = operation
                case "realize":
                    let schedule = try XCTUnwrap(schedules[try string(operation, "schedule")])
                    XCTAssertEqual(schedule["recurrence"] as? String, "once")
                    activity["schedule-" + (try string(operation, "schedule"))] = try posted(schedule, dateKey: "next_date")
                case "transfer":
                    for key in ["source", "destination"] {
                        XCTAssertTrue(["checking", "savings", "cash"].contains(try XCTUnwrap(accounts[try string(operation, key)])))
                    } // Existing-cash account transfers have no category or Unassigned posting.
                case "reconcile":
                    XCTAssertEqual(operation["create_adjustment"] as? Bool, false, "Adjustment posting requires an explicit adapter extension")
                case "observe":
                    let result = try projection(string(operation, "month"))
                    let expected = try XCTUnwrap(operation["expected"] as? [String: Any])
                    if let amount = expected["unassigned_minor"] as? NSNumber { XCTAssertEqual(result.readyToAssignMinor, amount.int64Value, name) }
                    if let amount = expected["funding_limit_minor"] as? NSNumber { XCTAssertEqual(result.fundingLimitMinor, amount.int64Value, name) }
                    for (id, fields) in expected["categories"] as? [String: [String: Any]] ?? [:] {
                        let category = try XCTUnwrap(result.categories[id])
                        let actual = ["assigned_minor": category.assignedMinor, "activity_minor": category.activityMinor,
                                      "carried_available_minor": category.carriedAvailableMinor, "available_minor": category.availableMinor]
                        for (key, amount) in actual where fields[key] != nil {
                            XCTAssertEqual(amount, try integer(fields, key), "\(name).\(id).\(key)")
                        }
                    }
                    XCTAssertEqual(try projection(string(operation, "month")), result, "Projection has no mutation side effects")
                default: XCTFail("Unimplemented fixture operation in \(name)")
                }
            }
        }
    }

    func testExactCancellationDoesNotDependOnEventOrder() throws {
        for (amounts, expected): ([Int64], Int64) in [([.max, 1, -.max], 1), ([1, -.max, .max], 1), ([-.max, .max, 1], 1), ([-.max, -2, .max], -2)] {
            let events = try amounts.map { try P.PostedActivity(occurredOn: "2026-09-01", categoryAmounts: ["c": $0], unassignedMinor: $0) }
            let result = try P.snapshot(month: "2026-09-01", categoryIDs: ["c"], allocations: [P.Allocation](), activity: events)
            XCTAssertEqual(result.readyToAssignMinor, expected)
            XCTAssertEqual(result.categories["c"]?.activityMinor, expected)
            XCTAssertEqual(result.categories["c"]?.availableMinor, expected)
        }
        let events = try [Int64.max, 1].map { try P.PostedActivity(occurredOn: "2026-09-01", unassignedMinor: $0) }
        XCTAssertThrowsError(try P.snapshot(month: "2026-09-01", categoryIDs: [], allocations: [P.Allocation](), activity: events)) {
            XCTAssertEqual($0 as? MoneyError, .arithmeticOverflow)
        }
    }

    func testOpeningBoundaryIsExplicitAndDoesNotFabricateEarlierPeriods() throws {
        let opening = try P.Opening(month: "2026-09-01", unassignedMinor: 50, categoryAvailable: ["c": -10])
        for month in ["2026-09-01", "2026-10-01", "9999-12-01"] {
            let result = try P.snapshot(month: month, categoryIDs: ["c"], opening: opening,
                                        allocations: [P.Allocation](), activity: [P.PostedActivity]())
            XCTAssertEqual(result.categories["c"]?.assignedMinor, 0)
            XCTAssertEqual(result.categories["c"]?.carriedAvailableMinor, -10)
            XCTAssertEqual(result.totalOverspentMinor, 10)
            XCTAssertEqual(result.readyToAssignMinor, 50)
        }
        XCTAssertThrowsError(try P.snapshot(month: "2026-08-01", categoryIDs: ["c"], opening: opening,
                                            allocations: [P.Allocation](), activity: [P.PostedActivity]())) {
            XCTAssertEqual($0 as? P.InvalidInput, .beforeOpeningBoundary)
        }
        let old = try P.PostedActivity(occurredOn: "2026-08-31", unassignedMinor: 1)
        XCTAssertThrowsError(try P.snapshot(month: "2026-09-01", categoryIDs: ["c"], opening: opening,
                                            allocations: [P.Allocation](), activity: [old]))
    }

    func testBalancedWideOperationsAndFinalAggregateOverflowAreChecked() throws {
        let balanced = try P.Allocation(occurredOn: "2026-09-01", postings: [
            .init(categoryID: "c", amountMinor: .max), .init(categoryID: "d", amountMinor: 1),
            .init(categoryID: "c", amountMinor: -.max), .init(categoryID: "d", amountMinor: -1),
        ])
        let zero = try P.snapshot(month: "2026-09-01", categoryIDs: ["c", "d"], allocations: [balanced], activity: [P.PostedActivity]())
        XCTAssertEqual(zero.totalAssignedMinor, 0)
        XCTAssertEqual(zero.allDateUnassignedMinor, 0)
        let large = try P.Allocation(occurredOn: "2026-09-01", postings: [
            .init(categoryID: "c", amountMinor: .max), .init(categoryID: nil, amountMinor: -.max),
            .init(categoryID: "d", amountMinor: 1), .init(categoryID: nil, amountMinor: -1),
        ])
        XCTAssertThrowsError(try P.snapshot(month: "2026-09-01", categoryIDs: ["c", "d"], allocations: [large], activity: [P.PostedActivity]())) {
            XCTAssertEqual($0 as? MoneyError, .arithmeticOverflow)
        }
        let deficit = try P.Opening(month: "2026-09-01", unassignedMinor: -50, categoryAvailable: [:])
        let negative = try P.snapshot(month: "2026-09-01", categoryIDs: [], opening: deficit, allocations: [P.Allocation](), activity: [P.PostedActivity]())
        XCTAssertEqual(negative.readyToAssignMinor, -50)
        XCTAssertEqual(negative.fundingLimitMinor, 0)
    }

    func testCalendarAndInputValidationAreDateOnlyAndFailClosed() throws {
        for invalid in ["2026-02-29", "1900-02-29", "0000-01-01", "10000-01-01", "2026-9-01", "+026-09-01", "2026-09-01T00:00:00Z"] {
            XCTAssertThrowsError(try P.Day(invalid))
        }
        for valid in ["0001-01-01", "2000-02-29", "2024-02-29", "9999-12-31"] { XCTAssertEqual(try P.Day(valid).iso, valid) }
        XCTAssertThrowsError(try P.snapshot(month: "2026-09-02", categoryIDs: [], allocations: [P.Allocation](), activity: [P.PostedActivity]()))
        XCTAssertThrowsError(try P.Allocation(occurredOn: "2026-09-01", postings: [.init(categoryID: "c", amountMinor: 1), .init(categoryID: nil, amountMinor: -2)]))
        let unknown = try P.PostedActivity(occurredOn: "2026-09-01", categoryAmounts: ["hidden": 1])
        XCTAssertThrowsError(try P.snapshot(month: "2026-09-01", categoryIDs: [], allocations: [P.Allocation](), activity: [unknown])) {
            XCTAssertEqual($0 as? P.InvalidInput, .unknownCategory("hidden"))
        }
    }

    private func string(_ value: [String: Any], _ key: String) throws -> String { try XCTUnwrap(value[key] as? String) }
    private func integer(_ value: [String: Any], _ key: String) throws -> Int64 { try XCTUnwrap(value[key] as? NSNumber).int64Value }
}
