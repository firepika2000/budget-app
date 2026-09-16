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
}
