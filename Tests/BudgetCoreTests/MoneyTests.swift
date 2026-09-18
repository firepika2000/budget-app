import XCTest
@testable import BudgetCore

final class MoneyTests: XCTestCase {
    func testExactSumAllowsCancellationButRejectsUnrepresentableFinalAmount() throws {
        XCTAssertEqual(try Money.sumMinorUnits([Int64.max, 1, -1]), .max)
        XCTAssertEqual(try Money.sumMinorUnits([Int64.min, -1, 1]), .min)
        XCTAssertEqual(try Money.sumMinorUnits([Int64.max, Int64.max, Int64.min, Int64.min]), -2)
        XCTAssertEqual(try Money.sumMinorUnits([Int64]()), 0)
        for amounts: [Int64] in [[.max, 1], [.min, -1]] {
            XCTAssertThrowsError(try Money.sumMinorUnits(amounts)) { XCTAssertEqual($0 as? MoneyError, .arithmeticOverflow) }
        }
    }

    func testMoneyUsesExactMinorUnitArithmetic() throws {
        let first = Money(minorUnits: 10, currencyCode: "usd")
        let second = Money(minorUnits: 20, currencyCode: "USD")

        XCTAssertEqual(
            try first.adding(second),
            Money(minorUnits: 30, currencyCode: "USD")
        )
    }

    func testMoneyRejectsMixedCurrencies() {
        XCTAssertThrowsError(
            try Money(minorUnits: 100, currencyCode: "USD")
                .adding(Money(minorUnits: 100, currencyCode: "EUR"))
        ) { error in
            XCTAssertEqual(
                error as? MoneyError,
                .currencyMismatch(expected: "USD", actual: "EUR")
            )
        }
    }

    func testMoneyDetectsOverflow() {
        XCTAssertThrowsError(
            try Money(minorUnits: .max, currencyCode: "USD")
                .adding(Money(minorUnits: 1, currencyCode: "USD"))
        ) { error in
            XCTAssertEqual(error as? MoneyError, .arithmeticOverflow)
        }
    }
}
