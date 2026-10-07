import Foundation

/// Ephemeral assumptions applied to an authoritative forecast. Scenarios never become ledger data.
public struct ForecastScenarioAssumptions: Equatable, Sendable {
    public let monthlyIncomeChangeMinor: Int64
    public let monthlyCostChangeMinor: Int64
    public let activeMonths: Int
    public let majorPurchaseMinor: Int64

    public init(
        monthlyIncomeChangeMinor: Int64 = 0,
        monthlyCostChangeMinor: Int64 = 0,
        activeMonths: Int,
        majorPurchaseMinor: Int64 = 0
    ) {
        self.monthlyIncomeChangeMinor = monthlyIncomeChangeMinor
        self.monthlyCostChangeMinor = monthlyCostChangeMinor
        self.activeMonths = activeMonths
        self.majorPurchaseMinor = majorPurchaseMinor
    }
}

public struct ForecastScenarioProjection: Equatable, Sendable {
    public let baselineProjectedMinor: Int64
    public let scenarioProjectedMinor: Int64
    public let differenceMinor: Int64
}

public enum ForecastScenarioCalculator {
    public static func project(
        baselineProjectedMinor: Int64,
        currencyCode: String,
        assumptions: ForecastScenarioAssumptions
    ) throws -> ForecastScenarioProjection {
        guard assumptions.activeMonths >= 0,
              assumptions.monthlyCostChangeMinor >= 0,
              assumptions.majorPurchaseMinor >= 0 else {
            throw ForecastScenarioError.invalidAssumption
        }
        var deltas: [Int64] = []
        deltas.reserveCapacity(assumptions.activeMonths * 2 + 1)
        for _ in 0..<assumptions.activeMonths {
            deltas.append(assumptions.monthlyIncomeChangeMinor)
            deltas.append(try Money(minorUnits: assumptions.monthlyCostChangeMinor, currencyCode: currencyCode).negated().minorUnits)
        }
        deltas.append(try Money(minorUnits: assumptions.majorPurchaseMinor, currencyCode: currencyCode).negated().minorUnits)
        let difference = try Money.sumMinorUnits(deltas)
        let projected = try Money(minorUnits: baselineProjectedMinor, currencyCode: currencyCode)
            .adding(Money(minorUnits: difference, currencyCode: currencyCode)).minorUnits
        return ForecastScenarioProjection(
            baselineProjectedMinor: baselineProjectedMinor,
            scenarioProjectedMinor: projected,
            differenceMinor: difference
        )
    }
}

public enum ForecastScenarioError: Error, Equatable, Sendable {
    case invalidAssumption
}
