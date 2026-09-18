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
    public let promotionalRateBasisPoints: Int64?
    public let promotionalEndsOn: Date?

    public init(debtID: String, principalMinor: Int64, annualRateBasisPoints: Int64, plannedPaymentMinor: Int64, promotionalRateBasisPoints: Int64? = nil, promotionalEndsOn: Date? = nil) {
        self.debtID = debtID; self.principalMinor = principalMinor
        self.annualRateBasisPoints = annualRateBasisPoints
        self.plannedPaymentMinor = plannedPaymentMinor
        self.promotionalRateBasisPoints = promotionalRateBasisPoints
        self.promotionalEndsOn = promotionalEndsOn
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

    /// A fixed monthly scenario budget, normalized from the first scheduled payment.
    /// This is not a claim about an issuer's future minimum-payment rules.
    public static func monthlyStrategyPayment(principalMinor: Int64, firstPaymentOn: Date, terms: DebtProjectionTerms) throws -> Int64 {
        guard principalMinor >= 0, (0...100_000).contains(terms.annualRateBasisPoints),
              (0...100_000).contains(terms.promotionalRateBasisPoints ?? 0),
              (0...10_000).contains(terms.minimumRateBasisPoints ?? 0),
              (terms.scheduledPaymentMinor ?? 0) >= 0, (terms.minimumPaymentMinor ?? 0) >= 0 else { throw ProjectionError.invalidInput }
        let periods: Int64 = terms.frequency == .weekly ? 52 : terms.frequency == .biweekly ? 26 : 12
        let rate = terms.promotionalRateBasisPoints != nil && terms.promotionalEndsOn != nil && firstPaymentOn <= terms.promotionalEndsOn! ? terms.promotionalRateBasisPoints! : terms.annualRateBasisPoints
        let interest = try multipliedAndRounded(principalMinor, by: rate, dividedBy: 10_000 * periods)
        let statement = try checkedAdd(principalMinor, interest)
        let payment = try plannedPayment(statement: statement, terms: terms)
        return try multipliedAndRounded(payment, by: periods, dividedBy: 12)
    }

    private static func plannedPayment(statement: Int64, terms: DebtProjectionTerms) throws -> Int64 {
        if let scheduled = terms.scheduledPaymentMinor { return scheduled }
        let percentage = try multipliedAndRounded(statement, by: terms.minimumRateBasisPoints ?? 0, dividedBy: 10_000)
        switch terms.minimumRule {
        case .fixed: return terms.minimumPaymentMinor ?? 0
        case .percentage: return percentage
        case .greaterOf: return max(terms.minimumPaymentMinor ?? 0, percentage)
        case nil: throw ProjectionError.missingPaymentRule
        }
    }

    public static func project(principalMinor: Int64, firstPaymentOn: Date, terms: DebtProjectionTerms, extraPaymentMinor: Int64 = 0, maximumPeriods: Int = maximumPeriods, calendar: Calendar = Calendar(identifier: .gregorian)) throws -> DebtProjectionResult {
        guard principalMinor >= 0, extraPaymentMinor >= 0, (0...100_000).contains(terms.annualRateBasisPoints), (1...self.maximumPeriods).contains(maximumPeriods) else { throw ProjectionError.invalidInput }
        guard (terms.scheduledPaymentMinor ?? 0) >= 0, (terms.minimumPaymentMinor ?? 0) >= 0,
              (0...10_000).contains(terms.minimumRateBasisPoints ?? 0),
              (0...100_000).contains(terms.promotionalRateBasisPoints ?? 0) else { throw ProjectionError.invalidInput }
        if principalMinor == 0 { return .init(status: .paidOff, payoffDate: firstPaymentOn, projectedInterestMinor: 0, projectedTotalCostMinor: 0, points: []) }
        let periods: Int64 = terms.frequency == .weekly ? 52 : terms.frequency == .biweekly ? 26 : 12
        var principal = principalMinor, date = firstPaymentOn, interestTotal: Int64 = 0, paid: Int64 = 0
        var points: [DebtProjectionPoint] = []
        for number in 1...maximumPeriods {
            let rate = terms.promotionalRateBasisPoints != nil && terms.promotionalEndsOn != nil && date <= terms.promotionalEndsOn! ? terms.promotionalRateBasisPoints! : terms.annualRateBasisPoints
            let interest = try multipliedAndRounded(principal, by: rate, dividedBy: 10_000 * periods)
            let statement = try checkedAdd(principal, interest)
            let base = try plannedPayment(statement: statement, terms: terms)
            let planned = try checkedAdd(base, extraPaymentMinor)
            if planned <= interest { return .init(status: .nonAmortizing, payoffDate: nil, projectedInterestMinor: interestTotal, projectedTotalCostMinor: paid, points: points) }
            let payment = min(planned, statement), ending = statement - payment
            points.append(.init(paymentNumber: number, paymentDate: date, startingPrincipalMinor: principal, interestMinor: interest, paymentMinor: payment, endingPrincipalMinor: ending))
            interestTotal = try checkedAdd(interestTotal, interest); paid = try checkedAdd(paid, payment)
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
        guard debts.allSatisfy({ (0...100_000).contains($0.promotionalRateBasisPoints ?? 0)
            && (($0.promotionalRateBasisPoints == nil) == ($0.promotionalEndsOn == nil)) }) else { throw ProjectionError.invalidInput }
        if strategy == .custom && (customOrder.count != ids.count || Set(customOrder) != Set(ids)) {
            throw ProjectionError.invalidCustomOrder
        }
        var balances = Dictionary(uniqueKeysWithValues: debts.map { ($0.debtID, $0.principalMinor) })
        func ratesOn(_ date: Date) -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: debts.map { debt in
                let rate = debt.promotionalEndsOn.map { date <= $0 } == true ? debt.promotionalRateBasisPoints! : debt.annualRateBasisPoints
                return (debt.debtID, rate)
            })
        }
        var rates = ratesOn(firstPaymentOn)
        let payments = Dictionary(uniqueKeysWithValues: debts.map { ($0.debtID, $0.plannedPaymentMinor) })
        var interestByID = Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(0)) })
        var paidByID = Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(0)) })
        var payoffDates: [String: Date] = [:], payoffMonths: [String: Int] = [:]
        var payoffOrder: [String] = [], paymentDate = firstPaymentOn
        var rolloverPool: Int64 = 0

        func priority(_ active: [String]) -> [String] {
            // Non-custom strategies ignore customOrder, including duplicate values.
            let positions = strategy == .custom ? Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($0.element, $0.offset) }) : [:]
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
        func result(status: DebtProjectionStatus, date: Date?, count: Int) throws -> DebtStrategyProjectionResult {
            let interest = try interestByID.values.reduce(0, checkedAdd), paid = try paidByID.values.reduce(0, checkedAdd)
            return .init(status: status, strategy: strategy, rollover: rollover, payoffOrder: payoffOrder, debtFreeDate: date, paymentCount: count, projectedInterestMinor: interest, projectedTotalPaidMinor: paid, projectedTotalCostMinor: paid, debts: accountResults())
        }

        for id in priority(ids.filter { balances[$0] == 0 }) {
            payoffOrder.append(id); payoffDates[id] = firstPaymentOn; payoffMonths[id] = 0
        }
        for number in 1...maximumPeriods {
            rates = ratesOn(paymentDate)
            let active = ids.filter { balances[$0]! > 0 }
            if active.isEmpty { return try result(status: .paidOff, date: paymentDate, count: number - 1) }
            let startingTotal = try active.reduce(Int64(0)) { try checkedAdd($0, balances[$1]!) }
            var remaining: [String: Int64] = [:]
            for id in active {
                let interest = try multipliedAndRounded(balances[id]!, by: rates[id]!, dividedBy: 120_000)
                interestByID[id] = try checkedAdd(interestByID[id]!, interest)
                remaining[id] = try checkedAdd(balances[id]!, interest)
            }
            for id in active {
                let payment = min(payments[id]!, remaining[id]!)
                remaining[id]! -= payment; paidByID[id] = try checkedAdd(paidByID[id]!, payment)
            }
            var strategyMoney = try checkedAdd(extraPaymentMinor, rollover ? rolloverPool : 0)
            for id in priority(active.filter { remaining[$0]! > 0 }) {
                let payment = min(strategyMoney, remaining[id]!)
                remaining[id]! -= payment; paidByID[id] = try checkedAdd(paidByID[id]!, payment); strategyMoney -= payment
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
                if rollover { rolloverPool = try checkedAdd(rolloverPool, payments[id]!) }
            }
            if balances.values.allSatisfy({ $0 == 0 }) { return try result(status: .paidOff, date: paymentDate, count: number) }
            let upcomingRateChange = debts.contains { debt in
                balances[debt.debtID]! > 0 && debt.promotionalEndsOn.map { paymentDate <= $0 } == true
            }
            if try balances.values.reduce(0, checkedAdd) >= startingTotal && newlyPaid.isEmpty && !upcomingRateChange {
                return try result(status: .nonAmortizing, date: nil, count: number)
            }
            paymentDate = calendar.date(byAdding: .month, value: 1, to: paymentDate)!
        }
        return try result(status: .iterationLimit, date: nil, count: maximumPeriods)
    }

    private static func multipliedAndRounded(_ value: Int64, by multiplier: Int64, dividedBy denominator: Int64) throws -> Int64 {
        let quotient = value / denominator, remainder = value % denominator
        let (whole, overflow) = quotient.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw ProjectionError.amountOutOfRange }
        // Validated rates and denominators bound the remainder product below Int64.max.
        return try checkedAdd(whole, (remainder * multiplier + denominator / 2) / denominator)
    }
    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ProjectionError.amountOutOfRange }
        return value
    }
    public enum ProjectionError: LocalizedError {
        case invalidInput, missingPaymentRule, invalidCustomOrder, amountOutOfRange
        public var errorDescription: String? {
            switch self {
            case .amountOutOfRange: "Projection amounts exceed the supported exact-money range. Reduce the scenario amounts."
            case .invalidInput: "Review the projection amounts and rates."
            case .missingPaymentRule: "Add a payment rule in Debt Terms."
            case .invalidCustomOrder: "Include each selected debt once in the custom order."
            }
        }
    }
}
