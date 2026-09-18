import XCTest
@testable import BudgetCore

final class DebtProjectionTests: XCTestCase {
    private struct StrategyVectorFile: Decodable {
        let formatVersion: Int
        let firstPaymentOn: String
        let cases: [StrategyVector]
    }
    private struct StrategyVector: Decodable {
        let id: String
        let strategy: String
        let rollover: Bool
        let extraPaymentMinor: Int64
        let customOrder: [String]?
        let debts: [StrategyVectorDebt]
        let expected: StrategyVectorExpected
    }
    private struct StrategyVectorDebt: Decodable {
        let id: String
        let principalMinor: Int64
        let annualRateBasisPoints: Int64
        let plannedPaymentMinor: Int64
    }
    private struct StrategyVectorExpected: Decodable {
        let status: String
        let payoffOrder: [String]
        let debtFreeDate: String?
        let paymentCount: Int
        let projectedInterestMinor: Int64
        let projectedTotalPaidMinor: Int64
    }

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

    func testSharedDebtStrategyGoldenVectorsMatchExactly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("server/tests/debt_strategy_vectors/v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(StrategyVectorFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.formatVersion, 1)

        for vector in vectors.cases {
            let strategy = try XCTUnwrap(DebtPayoffStrategy(rawValue: vector.strategy), vector.id)
            let expectedStatus = try XCTUnwrap([
                "paid_off": DebtProjectionStatus.paidOff,
                "non_amortizing": .nonAmortizing,
                "iteration_limit": .iterationLimit,
            ][vector.expected.status], "Unknown status in \(vector.id): \(vector.expected.status)")
            let result = try DebtProjectionEngine.projectStrategy(
                debts: vector.debts.map {
                    DebtStrategyInput(
                        debtID: $0.id,
                        principalMinor: $0.principalMinor,
                        annualRateBasisPoints: $0.annualRateBasisPoints,
                        plannedPaymentMinor: $0.plannedPaymentMinor
                    )
                },
                firstPaymentOn: date(vectors.firstPaymentOn),
                strategy: strategy,
                rollover: vector.rollover,
                extraPaymentMinor: vector.extraPaymentMinor,
                customOrder: vector.customOrder ?? [],
                calendar: calendar
            )
            XCTAssertEqual(result.status, expectedStatus, vector.id)
            XCTAssertEqual(result.payoffOrder, vector.expected.payoffOrder, vector.id)
            XCTAssertEqual(result.debtFreeDate.map { ISO8601DateFormatter().string(from: $0).prefix(10).description }, vector.expected.debtFreeDate, vector.id)
            XCTAssertEqual(result.paymentCount, vector.expected.paymentCount, vector.id)
            XCTAssertEqual(result.projectedInterestMinor, vector.expected.projectedInterestMinor, vector.id)
            XCTAssertEqual(result.projectedTotalPaidMinor, vector.expected.projectedTotalPaidMinor, vector.id)
        }
    }

    func testExtremeMoneyFailsWithoutTrappingOrRounding() throws {
        XCTAssertThrowsError(try DebtProjectionEngine.project(
            principalMinor: 100, firstPaymentOn: date("2026-01-01"),
            terms: .init(annualRateBasisPoints: 0, frequency: .monthly, scheduledPaymentMinor: 1),
            extraPaymentMinor: .max
        ))
        XCTAssertThrowsError(try DebtProjectionEngine.project(
            principalMinor: .max, firstPaymentOn: date("2026-01-01"),
            terms: .init(annualRateBasisPoints: 100_000, frequency: .monthly, scheduledPaymentMinor: .max)
        ))
        XCTAssertThrowsError(try DebtProjectionEngine.projectStrategy(
            debts: [.init(debtID: "one", principalMinor: .max, annualRateBasisPoints: 0, plannedPaymentMinor: 1),
                    .init(debtID: "two", principalMinor: 1, annualRateBasisPoints: 0, plannedPaymentMinor: 1)],
            firstPaymentOn: date("2026-01-01"), strategy: .avalanche, rollover: false
        ))
        let exact = try DebtProjectionEngine.project(
            principalMinor: .max, firstPaymentOn: date("2026-01-01"),
            terms: .init(annualRateBasisPoints: 0, frequency: .monthly, scheduledPaymentMinor: .max)
        )
        XCTAssertEqual(exact.projectedTotalCostMinor, .max)
        XCTAssertEqual(exact.paymentCount, 1)
    }

    func testUnusedDuplicateCustomOrderDoesNotCrashOtherStrategies() throws {
        let result = try DebtProjectionEngine.projectStrategy(
            debts: [.init(debtID: "one", principalMinor: 100, annualRateBasisPoints: 0, plannedPaymentMinor: 100)],
            firstPaymentOn: date("2026-01-01"), strategy: .avalanche, rollover: false,
            customOrder: ["ignored", "ignored"]
        )
        XCTAssertEqual(result.status, .paidOff)
    }
}
