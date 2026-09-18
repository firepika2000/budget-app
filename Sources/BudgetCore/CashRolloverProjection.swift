import Foundation

/// Pure month-opening effects from canonical facts. Not a posting, policy-command or
/// authorization service. Repository activation requires every availability guard to agree.
public enum CashRolloverProjection {
    public enum Policy: String, Sendable { case carry = "carry_category_deficit", absorb = "absorb_next_month" }
    public enum InvalidInput: Error { case month, version }
    public struct Change: Sendable {
        public let effectiveMonth: PlanningPeriodProjection.Day
        public let policy: Policy
        public let version: Int
        public init(effectiveMonth: String, policy: Policy, version: Int) throws {
            let day = try PlanningPeriodProjection.Day(effectiveMonth)
            guard day.month == effectiveMonth else { throw InvalidInput.month }
            guard version >= 0 else { throw InvalidInput.version }
            self.effectiveMonth = day; self.policy = policy; self.version = version
        }
    }
    public struct Fact: Sendable {
        public let occurredOn: PlanningPeriodProjection.Day
        public let categoryID: String
        public let availableDeltaMinor: Int64
        /// Signed credit-category activity PLUS recorded reserve funding/release attribution.
        /// An unfunded purchase is negative; a funded purchase contributes zero.
        public let unfundedCreditDeltaMinor: Int64
        public init(occurredOn: String, categoryID: String, availableDeltaMinor: Int64, unfundedCreditDeltaMinor: Int64 = 0) throws {
            self.occurredOn = try PlanningPeriodProjection.Day(occurredOn); self.categoryID = categoryID
            self.availableDeltaMinor = availableDeltaMinor; self.unfundedCreditDeltaMinor = unfundedCreditDeltaMinor
        }
    }
    public struct Effect: Equatable, Sendable {
        public let month: String
        public let categoryID: String
        public let amountMinor: Int64
        public let policyVersion: Int
    }

    public static func effects(throughMonth: String, policies: [Change], facts: [Fact]) throws -> [Effect] {
        let through = try PlanningPeriodProjection.Day(throughMonth)
        guard through.month == throughMonth else { throw InvalidInput.month }
        guard Set(policies.map(\.version)).count == policies.count else { throw InvalidInput.version }
        let history = policies.sorted { ($0.effectiveMonth, $0.version) < ($1.effectiveMonth, $1.version) }
        let months = Dictionary(grouping: facts.filter { $0.occurredOn.month <= throughMonth }, by: { $0.occurredOn.month })
        var boundaries = Set(history.filter { $0.effectiveMonth <= through }.map { $0.effectiveMonth.iso })
        for month in months.keys {
            boundaries.insert(month)
            if let next = nextMonth(month), next <= throughMonth { boundaries.insert(next) }
        }
        var available: [String: ExactMinorUnitSum] = [:], credit: [String: ExactMinorUnitSum] = [:]
        var index = 0
        var policy: Change?
        var result: [Effect] = []
        for month in boundaries.sorted() {
            while index < history.count && history[index].effectiveMonth.iso <= month {
                policy = history[index]; index += 1
            }
            if let policy, policy.policy == .absorb {
                for category in available.keys.sorted() {
                    let balance = try available[category]!.value()
                    let debt = min(try credit[category]?.value() ?? 0, 0)
                    if balance < debt {
                        let delta = debt.subtractingReportingOverflow(balance)
                        guard !delta.overflow else { throw MoneyError.arithmeticOverflow }
                        try available[category]!.add(delta.partialValue)
                        result.append(.init(month: month, categoryID: category, amountMinor: delta.partialValue, policyVersion: policy.version))
                    }
                }
            }
            for fact in months[month] ?? [] {
                try available[fact.categoryID, default: .init()].add(fact.availableDeltaMinor)
                try credit[fact.categoryID, default: .init()].add(fact.unfundedCreditDeltaMinor)
            }
            for value in available.values { _ = try value.value() }
            for value in credit.values { _ = try value.value() }
        }
        return result
    }

    private static func nextMonth(_ month: String) -> String? {
        guard month != "9999-12-01" else { return nil }
        let year = Int(month.prefix(4))!, number = Int(month.dropFirst(5).prefix(2))!
        return String(format: "%04d-%02d-01", year + (number == 12 ? 1 : 0), number == 12 ? 1 : number + 1)
    }
}
