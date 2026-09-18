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
}
