import XCTest
@testable import BudgetCore

final class MonthlyBudgetTests: XCTestCase {
    private let calculator = MonthlyBudgetCalculator()

    func testAssignmentsReduceReadyToAssignAndActivityChangesAvailability() throws {
        let groceries = CategoryMonthInput(
            name: "Groceries",
            carriedAvailable: usd(2_500),
            assigned: usd(40_000),
            activity: usd(-12_345)
        )
        let result = try calculator.calculate(
            startingReadyToAssign: usd(5_000),
            newIncome: usd(100_000),
            categories: [groceries]
        )

        XCTAssertEqual(result.readyToAssign, usd(65_000))
        XCTAssertEqual(result.totalAssigned, usd(40_000))
        XCTAssertEqual(result.categories[0].available, usd(30_155))
        XCTAssertFalse(result.categories[0].isOverspent)
    }

    func testOverspendingIsReportedWithoutChangingReadyToAssign() throws {
        let diningOut = CategoryMonthInput(
            name: "Dining out",
            carriedAvailable: usd(0),
            assigned: usd(5_000),
            activity: usd(-7_500)
        )
        let result = try calculator.calculate(
            startingReadyToAssign: usd(0),
            newIncome: usd(10_000),
            categories: [diningOut]
        )

        XCTAssertEqual(result.readyToAssign, usd(5_000))
        XCTAssertTrue(result.categories[0].isOverspent)
        XCTAssertEqual(result.totalOverspent, usd(2_500))
    }

    func testNegativeAssignmentMovesMoneyBackToReadyToAssign() throws {
        let vacation = CategoryMonthInput(
            name: "Vacation",
            carriedAvailable: usd(50_000),
            assigned: usd(-10_000),
            activity: usd(0)
        )
        let result = try calculator.calculate(
            startingReadyToAssign: usd(0),
            newIncome: usd(0),
            categories: [vacation]
        )

        XCTAssertEqual(result.readyToAssign, usd(10_000))
        XCTAssertEqual(result.categories[0].available, usd(40_000))
    }

    func testDuplicateCategoryIsRejected() {
        let categoryID = CategoryID()
        let category = CategoryMonthInput(
            categoryID: categoryID,
            name: "Housing",
            carriedAvailable: usd(0),
            assigned: usd(100_000),
            activity: usd(0)
        )

        XCTAssertThrowsError(
            try calculator.calculate(
                startingReadyToAssign: usd(0),
                newIncome: usd(100_000),
                categories: [category, category]
            )
        ) { error in
            XCTAssertEqual(error as? MonthlyBudgetError, .duplicateCategory(categoryID))
        }
    }

    func testCategoryCurrencyMustMatchBudgetCurrency() {
        let category = CategoryMonthInput(
            name: "Travel",
            carriedAvailable: usd(0),
            assigned: Money(minorUnits: 100, currencyCode: "EUR"),
            activity: usd(0)
        )

        XCTAssertThrowsError(
            try calculator.calculate(
                startingReadyToAssign: usd(0),
                newIncome: usd(100),
                categories: [category]
            )
        ) { error in
            XCTAssertEqual(
                error as? MonthlyBudgetError,
                .money(.currencyMismatch(expected: "USD", actual: "EUR"))
            )
        }
    }

    func testUnrepresentableOverspendingTotalFailsSafely() {
        let category = CategoryMonthInput(
            name: "Edge case",
            carriedAvailable: usd(.min),
            assigned: usd(0),
            activity: usd(0)
        )

        XCTAssertThrowsError(
            try calculator.calculate(
                startingReadyToAssign: usd(0),
                newIncome: usd(0),
                categories: [category]
            )
        ) { error in
            XCTAssertEqual(
                error as? MonthlyBudgetError,
                .money(.arithmeticOverflow)
            )
        }
    }

    private func usd(_ minorUnits: Int64) -> Money {
        Money(minorUnits: minorUnits, currencyCode: "USD")
    }
}
