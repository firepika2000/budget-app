import Foundation

/// Read-only target guidance. Dates are Gregorian ISO date-only values, independent of timezone.
public enum TargetPlanning {
    public struct Funding: Equatable, Sendable {
        public let recommendedContributionMinor: Int64
        public let underfundedMinor: Int64
        public let effectiveTargetDate: String?
    }
    public enum InvalidInput: Error { case date, cadence, amount }

    private static func days(_ year: Int, _ month: Int) -> Int {
        if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }
    private static func parse(_ value: String) throws -> (year: Int, month: Int, day: Int) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...9999).contains(y), (1...12).contains(m), (1...days(y, m)).contains(d)
        else { throw InvalidInput.date }
        return (y, m, d)
    }

    public static func funding(type: String, amountMinor: Int64, targetDate: String?,
                               recurrenceMonths: Int?, minimumMinor: Int64, isActive: Bool,
                               month: String, assignedMinor: Int64, availableMinor: Int64) throws -> Funding {
        guard amountMinor >= 0, minimumMinor >= 0 else { throw InvalidInput.amount }
        let current = try parse(month)
        var periods = 1
        var effective = targetDate
        if let targetDate {
            let anchor = try parse(targetDate)
            let delta = (current.year - anchor.year) * 12 + current.month - anchor.month
            var offset = 0
            if type == "recurring_expense", delta > 0 {
                guard let cadence = recurrenceMonths, (1...1200).contains(cadence)
                else { throw InvalidInput.cadence }
                offset = ((delta + cadence - 1) / cadence) * cadence
            }
            periods = max(1, offset - delta + 1)
            let index = anchor.year * 12 + anchor.month - 1 + offset
            let year = index / 12, dueMonth = index % 12 + 1
            effective = year <= 9999
                ? String(format: "%04d-%02d-%02d", year, dueMonth, min(anchor.day, days(year, dueMonth)))
                : nil
        }
        guard isActive else { return Funding(recommendedContributionMinor: 0, underfundedMinor: 0, effectiveTargetDate: effective) }
        // Clamp only the intermediate carry, not currency. Overflow above Int64.max already
        // covers any representable target; overflow below zero contributes no positive carry.
        let subtraction = availableMinor.subtractingReportingOverflow(assignedMinor)
        let carry = subtraction.overflow ? (availableMinor >= 0 ? Int64.max : 0) : max(subtraction.partialValue, 0)
        let gap = max(amountMinor - carry, 0)
        let recommended: Int64
        if type == "monthly_funding" { recommended = max(amountMinor, minimumMinor) }
        else if type == "savings_balance" { recommended = max(gap, minimumMinor) }
        else {
            let divisor = Int64(periods)
            recommended = max(gap / divisor + (gap % divisor == 0 ? 0 : 1), minimumMinor)
        }
        return Funding(recommendedContributionMinor: recommended,
                       underfundedMinor: max(recommended - max(assignedMinor, 0), 0),
                       effectiveTargetDate: effective)
    }
}
