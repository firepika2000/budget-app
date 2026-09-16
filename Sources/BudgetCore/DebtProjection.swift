import Foundation

public enum DebtPaymentFrequency: String, Sendable { case weekly, biweekly, monthly }
public enum DebtMinimumPaymentRule: String, Sendable { case fixed, percentage, greaterOf }
public enum DebtProjectionStatus: String, Sendable { case paidOff, nonAmortizing, iterationLimit }

public struct DebtProjectionTerms: Sendable {
    public let annualRateBasisPoints: Int64
    public let frequency: DebtPaymentFrequency
    public let scheduledPaymentMinor: Int64?
    public let minimumRule: DebtMinimumPaymentRule?
    public let minimumPaymentMinor: Int64?
    public let minimumRateBasisPoints: Int64?
    public let promotionalRateBasisPoints: Int64?
    public let promotionalEndsOn: Date?

    public init(annualRateBasisPoints: Int64, frequency: DebtPaymentFrequency, scheduledPaymentMinor: Int64? = nil, minimumRule: DebtMinimumPaymentRule? = nil, minimumPaymentMinor: Int64? = nil, minimumRateBasisPoints: Int64? = nil, promotionalRateBasisPoints: Int64? = nil, promotionalEndsOn: Date? = nil) {
        self.annualRateBasisPoints = annualRateBasisPoints; self.frequency = frequency
        self.scheduledPaymentMinor = scheduledPaymentMinor; self.minimumRule = minimumRule
        self.minimumPaymentMinor = minimumPaymentMinor; self.minimumRateBasisPoints = minimumRateBasisPoints
        self.promotionalRateBasisPoints = promotionalRateBasisPoints; self.promotionalEndsOn = promotionalEndsOn
    }
}

public struct DebtProjectionPoint: Equatable, Sendable {
    public let paymentNumber: Int; public let paymentDate: Date
    public let startingPrincipalMinor: Int64; public let interestMinor: Int64
    public let paymentMinor: Int64; public let endingPrincipalMinor: Int64
}

public struct DebtProjectionResult: Sendable {
    public let status: DebtProjectionStatus; public let payoffDate: Date?
    public let projectedInterestMinor: Int64; public let projectedTotalCostMinor: Int64
    public let points: [DebtProjectionPoint]
    public var paymentCount: Int { points.count }
}

public enum DebtProjectionEngine {
    public static let maximumPeriods = 1_200

    public static func project(principalMinor: Int64, firstPaymentOn: Date, terms: DebtProjectionTerms, extraPaymentMinor: Int64 = 0, maximumPeriods: Int = maximumPeriods, calendar: Calendar = Calendar(identifier: .gregorian)) throws -> DebtProjectionResult {
        guard principalMinor >= 0, extraPaymentMinor >= 0, (0...100_000).contains(terms.annualRateBasisPoints), (1...self.maximumPeriods).contains(maximumPeriods) else { throw ProjectionError.invalidInput }
        if principalMinor == 0 { return .init(status: .paidOff, payoffDate: firstPaymentOn, projectedInterestMinor: 0, projectedTotalCostMinor: 0, points: []) }
        let periods: Int64 = terms.frequency == .weekly ? 52 : terms.frequency == .biweekly ? 26 : 12
        var principal = principalMinor, date = firstPaymentOn, interestTotal: Int64 = 0, paid: Int64 = 0
        var points: [DebtProjectionPoint] = []
        for number in 1...maximumPeriods {
            let rate = terms.promotionalRateBasisPoints != nil && terms.promotionalEndsOn != nil && date <= terms.promotionalEndsOn! ? terms.promotionalRateBasisPoints! : terms.annualRateBasisPoints
            let interest = multipliedAndRounded(principal, by: rate, dividedBy: 10_000 * periods)
            let statement = principal + interest
            let percentage = multipliedAndRounded(statement, by: terms.minimumRateBasisPoints ?? 0, dividedBy: 10_000)
            let base: Int64
            if let scheduled = terms.scheduledPaymentMinor { base = scheduled }
            else if terms.minimumRule == .fixed { base = terms.minimumPaymentMinor ?? 0 }
            else if terms.minimumRule == .percentage { base = percentage }
            else if terms.minimumRule == .greaterOf { base = max(terms.minimumPaymentMinor ?? 0, percentage) }
            else { throw ProjectionError.missingPaymentRule }
            let planned = base + extraPaymentMinor
            if planned <= interest { return .init(status: .nonAmortizing, payoffDate: nil, projectedInterestMinor: interestTotal, projectedTotalCostMinor: paid, points: points) }
            let payment = min(planned, statement), ending = statement - payment
            points.append(.init(paymentNumber: number, paymentDate: date, startingPrincipalMinor: principal, interestMinor: interest, paymentMinor: payment, endingPrincipalMinor: ending))
            interestTotal += interest; paid += payment
            if ending == 0 { return .init(status: .paidOff, payoffDate: date, projectedInterestMinor: interestTotal, projectedTotalCostMinor: paid, points: points) }
            principal = ending
            let component: Calendar.Component = terms.frequency == .monthly ? .month : .day
            let increment = terms.frequency == .weekly ? 7 : terms.frequency == .biweekly ? 14 : 1
            date = calendar.date(byAdding: component, value: increment, to: date)!
        }
        return .init(status: .iterationLimit, payoffDate: nil, projectedInterestMinor: interestTotal, projectedTotalCostMinor: paid, points: points)
    }

    private static func multipliedAndRounded(_ value: Int64, by multiplier: Int64, dividedBy denominator: Int64) -> Int64 {
        let quotient = value / denominator, remainder = value % denominator
        return quotient * multiplier + (remainder * multiplier + denominator / 2) / denominator
    }
    public enum ProjectionError: Error { case invalidInput, missingPaymentRule }
}
