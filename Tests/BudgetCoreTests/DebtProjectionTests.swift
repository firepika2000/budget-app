import XCTest
@testable import BudgetCore

final class DebtProjectionTests: XCTestCase {
    private let calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T00:00:00Z")! }

    func testExactGoldenVectorsMatchAuthoritativeProvider() throws {
        let baseline = try DebtProjectionEngine.project(principalMinor: 10_000, firstPaymentOn: date("2026-01-15"), terms: .init(annualRateBasisPoints: 1200, frequency: .monthly, minimumRule: .fixed, minimumPaymentMinor: 900), calendar: calendar)
        XCTAssertEqual(baseline.paymentCount, 12); XCTAssertEqual(baseline.projectedInterestMinor, 654); XCTAssertEqual(baseline.projectedTotalCostMinor, 10_654)
        let extra = try DebtProjectionEngine.project(principalMinor: 10_000, firstPaymentOn: date("2026-01-15"), terms: .init(annualRateBasisPoints: 1200, frequency: .monthly, minimumRule: .fixed, minimumPaymentMinor: 900), extraPaymentMinor: 5000, calendar: calendar)
        XCTAssertEqual(extra.paymentCount, 2); XCTAssertEqual(extra.projectedInterestMinor, 142)
    }

    func testNonAmortizingAndFinalPartialPaymentAreExplicit() throws {
        let stuck = try DebtProjectionEngine.project(principalMinor: 100_000, firstPaymentOn: date("2026-01-01"), terms: .init(annualRateBasisPoints: 3600, frequency: .monthly, minimumRule: .fixed, minimumPaymentMinor: 3000), calendar: calendar)
        XCTAssertEqual(stuck.status, .nonAmortizing); XCTAssertNil(stuck.payoffDate)
        let zero = try DebtProjectionEngine.project(principalMinor: 2501, firstPaymentOn: date("2026-01-31"), terms: .init(annualRateBasisPoints: 0, frequency: .monthly, scheduledPaymentMinor: 1000), calendar: calendar)
        XCTAssertEqual(zero.points.map(\.paymentMinor), [1000, 1000, 501])
    }

    func testMultiDebtSnowballRolloverIsExplicitAndExact() throws {
        let debts = [
            DebtStrategyInput(debtID: "large", principalMinor: 10_000, annualRateBasisPoints: 0, plannedPaymentMinor: 1_000),
            DebtStrategyInput(debtID: "small", principalMinor: 2_000, annualRateBasisPoints: 0, plannedPaymentMinor: 500),
        ]
        let without = try DebtProjectionEngine.projectStrategy(debts: debts, firstPaymentOn: date("2026-01-31"), strategy: .snowball, rollover: false, calendar: calendar)
        let with = try DebtProjectionEngine.projectStrategy(debts: debts, firstPaymentOn: date("2026-01-31"), strategy: .snowball, rollover: true, calendar: calendar)
        XCTAssertEqual(without.status, .paidOff)
        XCTAssertEqual(with.status, .paidOff)
        XCTAssertEqual(with.payoffOrder, ["small", "large"])
        XCTAssertEqual(without.paymentCount, 10)
        XCTAssertEqual(with.paymentCount, 8)
        XCTAssertEqual(with.debtFreeDate, date("2026-08-28"))
        XCTAssertEqual(with.projectedInterestMinor, 0)
        XCTAssertEqual(with.projectedTotalPaidMinor, 12_000)
        XCTAssertEqual(with.debts.reduce(0) { $0 + $1.projectedTotalPaidMinor }, 12_000)
    }

    func testAvalancheReportsLowerInterestForHighRateScenario() throws {
        let debts = [
            DebtStrategyInput(debtID: "high-rate", principalMinor: 10_000, annualRateBasisPoints: 2_400, plannedPaymentMinor: 500),
            DebtStrategyInput(debtID: "small", principalMinor: 3_000, annualRateBasisPoints: 0, plannedPaymentMinor: 500),
        ]
        let avalanche = try DebtProjectionEngine.projectStrategy(debts: debts, firstPaymentOn: date("2026-01-15"), strategy: .avalanche, rollover: true, extraPaymentMinor: 500, calendar: calendar)
        let snowball = try DebtProjectionEngine.projectStrategy(debts: debts, firstPaymentOn: date("2026-01-15"), strategy: .snowball, rollover: true, extraPaymentMinor: 500, calendar: calendar)
        XCTAssertEqual(avalanche.status, .paidOff)
        XCTAssertEqual(snowball.status, .paidOff)
        XCTAssertEqual([avalanche.paymentCount, Int(avalanche.projectedInterestMinor), Int(avalanche.projectedTotalPaidMinor)], [10, 1_179, 14_179])
        XCTAssertEqual([snowball.paymentCount, Int(snowball.projectedInterestMinor), Int(snowball.projectedTotalPaidMinor)], [10, 1_280, 14_280])
        XCTAssertLessThan(avalanche.projectedInterestMinor, snowball.projectedInterestMinor)
        XCTAssertLessThan(avalanche.projectedTotalPaidMinor, snowball.projectedTotalPaidMinor)
        XCTAssertEqual(debts[0].principalMinor, 10_000)
    }

    func testCustomStrategyRequiresCompleteOrderAndReportsNonAmortizing() throws {
        let debts = [
            DebtStrategyInput(debtID: "first", principalMinor: 10_000, annualRateBasisPoints: 1_200, plannedPaymentMinor: 50),
            DebtStrategyInput(debtID: "second", principalMinor: 5_000, annualRateBasisPoints: 0, plannedPaymentMinor: 0),
        ]
        XCTAssertThrowsError(try DebtProjectionEngine.projectStrategy(debts: debts, firstPaymentOn: date("2026-01-01"), strategy: .custom, rollover: true, customOrder: ["first"], calendar: calendar))
        let result = try DebtProjectionEngine.projectStrategy(debts: debts, firstPaymentOn: date("2026-01-01"), strategy: .custom, rollover: false, customOrder: ["second", "first"], calendar: calendar)
        XCTAssertEqual(result.status, .nonAmortizing)
        XCTAssertNil(result.debtFreeDate)
        XCTAssertEqual(result.paymentCount, 1)
    }
}
