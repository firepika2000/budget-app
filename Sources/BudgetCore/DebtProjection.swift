import Foundation

public enum DebtPaymentFrequency: String, Sendable { case weekly, biweekly, monthly }
public enum DebtMinimumPaymentRule: String, Sendable { case fixed, percentage, greaterOf }
public enum DebtProjectionStatus: String, Sendable { case paidOff, nonAmortizing, iterationLimit }
public enum DebtPayoffStrategy: String, Sendable { case avalanche, snowball, custom }

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

public struct DebtStrategyInput: Equatable, Sendable {
    public let debtID: String
    public let principalMinor: Int64
    public let annualRateBasisPoints: Int64
    public let plannedPaymentMinor: Int64

    public init(debtID: String, principalMinor: Int64, annualRateBasisPoints: Int64, plannedPaymentMinor: Int64) {
        self.debtID = debtID; self.principalMinor = principalMinor
        self.annualRateBasisPoints = annualRateBasisPoints
        self.plannedPaymentMinor = plannedPaymentMinor
    }
}

public struct DebtStrategyAccountResult: Equatable, Sendable {
    public let debtID: String
    public let payoffDate: Date?
    public let payoffMonth: Int?
    public let projectedInterestMinor: Int64
    public let projectedTotalPaidMinor: Int64
}

public struct DebtStrategyProjectionResult: Sendable {
    public let status: DebtProjectionStatus
    public let strategy: DebtPayoffStrategy
    public let rollover: Bool
    public let payoffOrder: [String]
    public let debtFreeDate: Date?
    public let paymentCount: Int
    public let projectedInterestMinor: Int64
    public let projectedTotalPaidMinor: Int64
    public let projectedTotalCostMinor: Int64
    public let debts: [DebtStrategyAccountResult]
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

    public static func projectStrategy(
        debts: [DebtStrategyInput],
        firstPaymentOn: Date,
        strategy: DebtPayoffStrategy,
        rollover: Bool,
        extraPaymentMinor: Int64 = 0,
        customOrder: [String] = [],
        maximumPeriods: Int = maximumPeriods,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DebtStrategyProjectionResult {
        guard !debts.isEmpty, extraPaymentMinor >= 0, (1...self.maximumPeriods).contains(maximumPeriods),
              debts.allSatisfy({ !$0.debtID.isEmpty && $0.principalMinor >= 0 && $0.plannedPaymentMinor >= 0 && (0...100_000).contains($0.annualRateBasisPoints) }),
              Set(debts.map(\.debtID)).count == debts.count else { throw ProjectionError.invalidInput }
        let ids = debts.map(\.debtID)
        if strategy == .custom && (customOrder.count != ids.count || Set(customOrder) != Set(ids)) {
            throw ProjectionError.invalidCustomOrder
        }
        var balances = Dictionary(uniqueKeysWithValues: debts.map { ($0.debtID, $0.principalMinor) })
        let rates = Dictionary(uniqueKeysWithValues: debts.map { ($0.debtID, $0.annualRateBasisPoints) })
        let payments = Dictionary(uniqueKeysWithValues: debts.map { ($0.debtID, $0.plannedPaymentMinor) })
        var interestByID = Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(0)) })
        var paidByID = Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(0)) })
        var payoffDates: [String: Date] = [:], payoffMonths: [String: Int] = [:]
        var payoffOrder: [String] = [], paymentDate = firstPaymentOn
        var rolloverPool: Int64 = 0

        func priority(_ active: [String]) -> [String] {
            let positions = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($0.element, $0.offset) })
            return active.sorted { lhs, rhs in
                switch strategy {
                case .avalanche:
                    if rates[lhs]! != rates[rhs]! { return rates[lhs]! > rates[rhs]! }
                    if balances[lhs]! != balances[rhs]! { return balances[lhs]! < balances[rhs]! }
                case .snowball:
                    if balances[lhs]! != balances[rhs]! { return balances[lhs]! < balances[rhs]! }
                    if rates[lhs]! != rates[rhs]! { return rates[lhs]! > rates[rhs]! }
                case .custom:
                    return positions[lhs]! < positions[rhs]!
                }
                return lhs < rhs
            }
        }
        func accountResults() -> [DebtStrategyAccountResult] {
            ids.map { .init(debtID: $0, payoffDate: payoffDates[$0], payoffMonth: payoffMonths[$0], projectedInterestMinor: interestByID[$0]!, projectedTotalPaidMinor: paidByID[$0]!) }
        }
        func result(status: DebtProjectionStatus, date: Date?, count: Int) -> DebtStrategyProjectionResult {
            let interest = interestByID.values.reduce(0, +), paid = paidByID.values.reduce(0, +)
            return .init(status: status, strategy: strategy, rollover: rollover, payoffOrder: payoffOrder, debtFreeDate: date, paymentCount: count, projectedInterestMinor: interest, projectedTotalPaidMinor: paid, projectedTotalCostMinor: paid, debts: accountResults())
        }

        for id in priority(ids.filter { balances[$0] == 0 }) {
            payoffOrder.append(id); payoffDates[id] = firstPaymentOn; payoffMonths[id] = 0
        }
        for number in 1...maximumPeriods {
            let active = ids.filter { balances[$0]! > 0 }
            if active.isEmpty { return result(status: .paidOff, date: paymentDate, count: number - 1) }
            let startingTotal = active.reduce(Int64(0)) { $0 + balances[$1]! }
            var remaining: [String: Int64] = [:]
            for id in active {
                let interest = multipliedAndRounded(balances[id]!, by: rates[id]!, dividedBy: 120_000)
                interestByID[id]! += interest; remaining[id] = balances[id]! + interest
            }
            for id in active {
                let payment = min(payments[id]!, remaining[id]!)
                remaining[id]! -= payment; paidByID[id]! += payment
            }
            var strategyMoney = extraPaymentMinor + (rollover ? rolloverPool : 0)
            for id in priority(active.filter { remaining[$0]! > 0 }) {
                let payment = min(strategyMoney, remaining[id]!)
                remaining[id]! -= payment; paidByID[id]! += payment; strategyMoney -= payment
                if strategyMoney == 0 { break }
            }
            var newlyPaid: [String] = []
            for id in active {
                balances[id] = remaining[id]!
                if balances[id] == 0 {
                    newlyPaid.append(id); payoffDates[id] = paymentDate; payoffMonths[id] = number
                }
            }
            for id in priority(newlyPaid) {
                payoffOrder.append(id)
                if rollover { rolloverPool += payments[id]! }
            }
            if balances.values.allSatisfy({ $0 == 0 }) { return result(status: .paidOff, date: paymentDate, count: number) }
            if balances.values.reduce(0, +) >= startingTotal && newlyPaid.isEmpty {
                return result(status: .nonAmortizing, date: nil, count: number)
            }
            paymentDate = calendar.date(byAdding: .month, value: 1, to: paymentDate)!
        }
        return result(status: .iterationLimit, date: nil, count: maximumPeriods)
    }

    private static func multipliedAndRounded(_ value: Int64, by multiplier: Int64, dividedBy denominator: Int64) -> Int64 {
        let quotient = value / denominator, remainder = value % denominator
        return quotient * multiplier + (remainder * multiplier + denominator / 2) / denominator
    }
    public enum ProjectionError: Error { case invalidInput, missingPaymentRule, invalidCustomOrder }
}
