import XCTest
@testable import BudgetCore

final class InsightsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testRollingThirtyDaysIncludesTodayAndTwentyNinePriorDays() throws {
        let range = try FinancialPeriodCalculator().range(
            for: .rollingDays(30),
            asOf: date(2026, 9, 4),
            calendar: calendar
        )
        XCTAssertEqual(range.start, date(2026, 8, 6))
        XCTAssertEqual(range.endExclusive, date(2026, 9, 5))
        XCTAssertTrue(range.contains(date(2026, 8, 6)))
        XCTAssertFalse(range.contains(date(2026, 8, 5)))
    }

    func testCalendarMonthIsNotRollingWindow() throws {
        let range = try FinancialPeriodCalculator().range(
            for: .monthContaining(date(2026, 9, 4)),
            asOf: date(2026, 9, 4),
            calendar: calendar
        )
        XCTAssertEqual(range.start, date(2026, 9, 1))
        XCTAssertEqual(range.endExclusive, date(2026, 10, 1))
    }

    func testCustomRangeIsInclusiveAtBothUserFacingEnds() throws {
        let range = try FinancialPeriodCalculator().range(
            for: .custom(start: date(2026, 8, 10), endInclusive: date(2026, 8, 12)),
            asOf: date(2026, 9, 4),
            calendar: calendar
        )
        XCTAssertTrue(range.contains(date(2026, 8, 12)))
        XCTAssertFalse(range.contains(date(2026, 8, 13)))
    }

    func testSpendingIsTraceableAndTransfersAreExcluded() {
        let values = [
            transaction("a", -3_182, "dining", "Dining Out"),
            transaction("b", -12_000, "dining", "Dining Out"),
            transaction("transfer", -50_000, nil, nil, isTransfer: true),
            transaction("income", 100_000, nil, nil)
        ]
        let report = InsightsCalculator().spendingByCategory(transactions: values)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report[0].spendingMinor, 15_182)
        XCTAssertEqual(Set(report[0].transactionIDs), ["a", "b"])
        XCTAssertEqual(report[0].averageTransactionMinor, 7_591)
    }

    func testChangingCategoryRecalculatesBothReports() {
        var values = [transaction("a", -12_000, "dining", "Dining Out")]
        XCTAssertEqual(InsightsCalculator().spendingByCategory(transactions: values).first?.id, "dining")
        values[0].categoryID = "groceries"
        values[0].categoryName = "Groceries"
        let report = InsightsCalculator().spendingByCategory(transactions: values)
        XCTAssertEqual(report.first?.id, "groceries")
        XCTAssertFalse(report.contains { $0.id == "dining" })
    }

    func testIncomeVersusSpendingExcludesTransfers() {
        let result = InsightsCalculator().incomeVersusSpending(transactions: [
            transaction("income", 100_000, nil, nil),
            transaction("expense", -60_000, "food", "Food"),
            transaction("transfer", -50_000, nil, nil, isTransfer: true)
        ])
        XCTAssertEqual(result.incomeMinor, 100_000)
        XCTAssertEqual(result.spendingMinor, 60_000)
        XCTAssertEqual(result.differenceMinor, 40_000)
        XCTAssertEqual(result.savingsRate, 0.4)
    }

    func testRefundReducesSpendingAndIsNotCountedAsIncome() {
        let values = [
            transaction("purchase", -10_000, "food", "Food"),
            transaction("refund", 2_500, "food", "Food"),
            transaction("income", 20_000, nil, nil)
        ]
        let spending = InsightsCalculator().spendingByCategory(transactions: values)
        XCTAssertEqual(spending.count, 1)
        XCTAssertEqual(spending[0].id, "food")
        XCTAssertEqual(spending[0].spendingMinor, 7_500)
        XCTAssertEqual(Set(spending[0].transactionIDs), ["purchase", "refund"])

        let result = InsightsCalculator().incomeVersusSpending(transactions: values)
        XCTAssertEqual(result.incomeMinor, 20_000)
        XCTAssertEqual(result.spendingMinor, 7_500)
        XCTAssertEqual(result.differenceMinor, 12_500)
    }

    func testExpandedSplitPortionsAreAttributedExactly() {
        let values = [
            transaction("food-portion", -7_001, "food", "Food"),
            transaction("fuel-portion", -2_999, "fuel", "Fuel")
        ]
        let report = InsightsCalculator().spendingByCategory(transactions: values)
        let byID = Dictionary(uniqueKeysWithValues: report.map { ($0.id, $0.spendingMinor) })
        XCTAssertEqual(byID["food"], 7_001)
        XCTAssertEqual(byID["fuel"], 2_999)
    }

    private func transaction(
        _ id: String,
        _ amount: Int64,
        _ categoryID: String?,
        _ categoryName: String?,
        isTransfer: Bool = false
    ) -> ReportTransaction {
        ReportTransaction(
            id: id,
            occurredOn: date(2026, 9, 4),
            amountMinor: amount,
            categoryID: categoryID,
            categoryName: categoryName,
            categoryGroup: categoryID == nil ? nil : "Everyday",
            payee: id,
            accountID: "checking",
            memberID: "rey",
            isTransfer: isTransfer
        )
    }
}
