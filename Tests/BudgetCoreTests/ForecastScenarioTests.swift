import XCTest
@testable import BudgetCore

final class ForecastScenarioTests: XCTestCase {
    func testCombinesTemporaryIncomeRecurringCostAndPurchaseExactly() throws {
        let result = try ForecastScenarioCalculator.project(
            baselineProjectedMinor: 500_000,
            currencyCode: "USD",
            assumptions: .init(
                monthlyIncomeChangeMinor: -100_000,
                monthlyCostChangeMinor: 25_000,
                activeMonths: 3,
                majorPurchaseMinor: 50_000
            )
        )
        XCTAssertEqual(result.differenceMinor, -425_000)
        XCTAssertEqual(result.scenarioProjectedMinor, 75_000)
    }

    func testScenarioRejectsNegativeCostsAndArithmeticOverflow() {
        XCTAssertThrowsError(try ForecastScenarioCalculator.project(
            baselineProjectedMinor: 0,
            currencyCode: "USD",
            assumptions: .init(monthlyCostChangeMinor: -1, activeMonths: 1)
        )) { XCTAssertEqual($0 as? ForecastScenarioError, .invalidAssumption) }

        XCTAssertThrowsError(try ForecastScenarioCalculator.project(
            baselineProjectedMinor: .max,
            currencyCode: "USD",
            assumptions: .init(monthlyIncomeChangeMinor: 1, activeMonths: 1)
        )) { XCTAssertEqual($0 as? MoneyError, .arithmeticOverflow) }
    }
}
