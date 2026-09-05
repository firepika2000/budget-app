import XCTest
@testable import BudgetCore

final class DelegatedBudgetTests: XCTestCase {
    private let service = DelegatedBudgetService()

    func testCreatingCategoryDoesNotCreateAuthority() throws {
        let initial = state()
        let result = try service.createCategory(in: initial, id: "concert", name: "Concert")
        XCTAssertEqual(result.authorityMinor, 20_000)
        XCTAssertEqual(result.assignedMinor, 15_000)
        XCTAssertEqual(result.availableToAssignMinor, 5_000)
    }

    func testReallocationConservesDelegatedTotal() throws {
        let result = try service.move(in: state(), amountMinor: 2_000, from: "other", to: "games")
        XCTAssertEqual(result.assignedMinor, 15_000)
        XCTAssertEqual(result.categories.first(where: { $0.id == "games" })?.assignedMinor, 8_000)
        XCTAssertEqual(result.categories.first(where: { $0.id == "other" })?.assignedMinor, 2_000)
    }

    func testCannotAssignBeyondDelegatedAuthority() {
        XCTAssertThrowsError(try service.move(in: state(), amountMinor: 5_001, from: nil, to: "games")) {
            XCTAssertEqual($0 as? DelegatedBudgetError, .exceedsAuthority)
        }
    }

    func testHardSavingsMinimumCannotBeViolated() {
        var value = state()
        value.categories[1].minimumMinor = 4_000
        value.categories[1].withdrawalRule = .hardLimit
        XCTAssertThrowsError(try service.move(in: value, amountMinor: 1_001, from: "savings", to: "games")) {
            XCTAssertEqual(
                $0 as? DelegatedBudgetError,
                .violatesCategoryMinimum(categoryID: "savings", minimumMinor: 4_000)
            )
        }
    }

    func testApprovalGatedWithdrawalReturnsExplicitOutcome() {
        var value = state()
        value.categories[1].withdrawalRule = .approvalGated
        XCTAssertThrowsError(try service.move(in: value, amountMinor: 500, from: "savings", to: "games")) {
            XCTAssertEqual($0 as? DelegatedBudgetError, .requiresApproval(categoryID: "savings"))
        }
    }

    func testMaximumIsEnforced() {
        var value = state()
        value.categories[0].maximumMinor = 7_000
        XCTAssertThrowsError(try service.move(in: value, amountMinor: 2_000, from: "other", to: "games")) {
            XCTAssertEqual(
                $0 as? DelegatedBudgetError,
                .exceedsCategoryMaximum(categoryID: "games", maximumMinor: 7_000)
            )
        }
    }

    private func state() -> DelegatedBudgetState {
        DelegatedBudgetState(
            memberID: "alex",
            authorityMinor: 20_000,
            categories: [
                .init(id: "games", name: "Games", assignedMinor: 6_000),
                .init(id: "savings", name: "Savings", assignedMinor: 5_000),
                .init(id: "other", name: "Other", assignedMinor: 4_000)
            ]
        )
    }
}
