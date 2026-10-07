import XCTest
@testable import BudgetCore

final class TargetPlanningTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let type: String?
        let month: String
        let anchor: String
        let cadence: Int
        let amount: Int64?
        let assigned: Int64?
        let available: Int64?
        let minimum: Int64?
        let active: Bool?
        let due: String?
        let recommended: Int64
        let underfunded: Int64?
    }
    func testSharedExactCadenceVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: root.appendingPathComponent("server/tests/target_cadence_vectors.json")))
        for v in vectors {
            let result = try TargetPlanning.funding(type: v.type ?? "recurring_expense", amountMinor: v.amount ?? 120000,
                targetDate: v.anchor, recurrenceMonths: v.cadence, minimumMinor: v.minimum ?? 0,
                isActive: v.active ?? true, month: v.month, assignedMinor: v.assigned ?? 0, availableMinor: v.available ?? 0)
            XCTAssertEqual(result.recommendedContributionMinor, v.recommended, v.name)
            XCTAssertEqual(result.underfundedMinor, v.underfunded ?? v.recommended, v.name)
            XCTAssertEqual(result.effectiveTargetDate, v.due, v.name)
        }
    }

    func testWeeklySpendingCountsCalendarOccurrencesExactly() throws {
        let october = try TargetPlanning.funding(type: "weekly_spending", amountMinor: 2_500,
            targetDate: "2026-10-02", recurrenceMonths: nil, minimumMinor: 0, isActive: true,
            month: "2026-10-01", assignedMinor: 2_500, availableMinor: 2_500)
        let november = try TargetPlanning.funding(type: "weekly_spending", amountMinor: 2_500,
            targetDate: "2026-10-02", recurrenceMonths: nil, minimumMinor: 0, isActive: true,
            month: "2026-11-01", assignedMinor: 0, availableMinor: 0)
        XCTAssertEqual(october.recommendedContributionMinor, 12_500)
        XCTAssertEqual(october.underfundedMinor, 10_000)
        XCTAssertEqual(october.effectiveTargetDate, "2026-10-30")
        XCTAssertEqual(november.recommendedContributionMinor, 10_000)
        XCTAssertEqual(november.effectiveTargetDate, "2026-11-27")
    }
}
