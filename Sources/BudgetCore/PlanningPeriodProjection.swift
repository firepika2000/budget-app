import Foundation

/// Date-scoped read projection of canonical financial facts. This is not an authorization,
/// transaction-posting, credit-reserve, or persistence service. Providers supply only actual
/// posted activity and balanced allocation operations; schedules never enter this input.
public enum PlanningPeriodProjection {
    public enum InvalidInput: Error, Equatable {
        case date, month, allocation, beforeOpeningBoundary, insufficientFunds
        case unknownCategory(String)
    }

    public struct Day: Comparable, Hashable, Sendable {
        public let iso: String
        public var month: String { String(iso.prefix(7)) + "-01" }

        public init(_ iso: String) throws {
            let bytes = Array(iso.utf8)
            guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
                  bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
                  let year = Int(iso.prefix(4)), let month = Int(iso.dropFirst(5).prefix(2)),
                  let day = Int(iso.suffix(2)), (1...9999).contains(year), (1...12).contains(month)
            else { throw InvalidInput.date }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = month == 2 ? (leap ? 29 : 28) : ([4, 6, 9, 11].contains(month) ? 30 : 31)
            guard (1...days).contains(day) else { throw InvalidInput.date }
            self.iso = iso
        }

        public static func < (lhs: Day, rhs: Day) -> Bool { lhs.iso < rhs.iso }
    }

    public struct Posting: Equatable, Sendable {
        /// nil is the Unassigned bucket; a non-nil value is a category purpose.
        public let categoryID: String?
        public let amountMinor: Int64
        public init(categoryID: String?, amountMinor: Int64) {
            self.categoryID = categoryID; self.amountMinor = amountMinor
        }
    }

    public struct Allocation: Equatable, Sendable {
        public let occurredOn: Day
        public let postings: [Posting]
        public init(occurredOn: String, postings: [Posting]) throws {
            let day = try Day(occurredOn)
            var total = ExactSum()
            for posting in postings {
                guard posting.amountMinor != 0, posting.amountMinor != .min else { throw InvalidInput.allocation }
                try total.add(posting.amountMinor)
            }
            guard postings.count >= 2, try total.value() == 0 else { throw InvalidInput.allocation }
            self.occurredOn = day; self.postings = postings
        }
    }

    public struct PostedActivity: Equatable, Sendable {
        public let occurredOn: Day
        /// Includes exact split attribution and canonical payment-reserve activity when applicable.
        public let categoryAmounts: [String: Int64]
        /// Only actual uncategorized on-budget cash activity. Transfers and tracking activity are zero.
        public let unassignedMinor: Int64
        public init(occurredOn: String, categoryAmounts: [String: Int64] = [:], unassignedMinor: Int64 = 0) throws {
            self.occurredOn = try Day(occurredOn)
            self.categoryAmounts = categoryAmounts; self.unassignedMinor = unassignedMinor
        }
    }

    /// Explicit fixture/import opening observation, not a fabricated transaction or allocation.
    /// Earlier periods are unavailable, rather than silently populated with this opening state.
    public struct Opening: Equatable, Sendable {
        public let month: Day
        public let unassignedMinor: Int64
        public let categoryAvailable: [String: Int64]
        public init(month: String, unassignedMinor: Int64, categoryAvailable: [String: Int64]) throws {
            let day = try Day(month)
            guard day.month == month else { throw InvalidInput.month }
            self.month = day; self.unassignedMinor = unassignedMinor; self.categoryAvailable = categoryAvailable
        }
    }

    public struct Category: Equatable, Sendable {
        public let assignedMinor: Int64
        public let activityMinor: Int64
        public let carriedAvailableMinor: Int64
        public let availableMinor: Int64
    }

    public struct Snapshot: Equatable, Sendable {
        public let month: Day
        public let readyToAssignMinor: Int64
        public let allDateUnassignedMinor: Int64
        public let totalAssignedMinor: Int64
        public let totalOverspentMinor: Int64
        public var fundingLimitMinor: Int64 { min(max(readyToAssignMinor, 0), max(allDateUnassignedMinor, 0)) }
        public let categories: [String: Category]

        /// Pure assignment intent. The repository must still authorize, lock/version-check, and
        /// atomically persist these postings against the same authoritative snapshot.
        public func replacementAssignment(categoryID: String, assignedMinor: Int64) throws -> Allocation? {
            guard let category = categories[categoryID] else { throw InvalidInput.unknownCategory(categoryID) }
            let change = assignedMinor.subtractingReportingOverflow(category.assignedMinor)
            guard !change.overflow, change.partialValue != .min else { throw MoneyError.arithmeticOverflow }
            let delta = change.partialValue
            guard delta <= 0 || delta <= allDateUnassignedMinor else { throw InvalidInput.insufficientFunds }
            return delta == 0 ? nil : try Allocation(occurredOn: month.iso, postings: [
                Posting(categoryID: nil, amountMinor: -delta), Posting(categoryID: categoryID, amountMinor: delta),
            ])
        }
    }

    public static func snapshot<A: Sequence, T: Sequence>(month: String, categoryIDs: Set<String>,
        opening: Opening? = nil, allocations: A, activity: T) throws -> Snapshot
        where A.Element == Allocation, T.Element == PostedActivity {
        let selected = try Day(month)
        guard selected.month == month else { throw InvalidInput.month }
        if let opening, selected < opening.month { throw InvalidInput.beforeOpeningBoundary }
        var rows = Dictionary(uniqueKeysWithValues: categoryIDs.map { ($0, Accumulator()) })
        var dated = ExactSum(), allDates = ExactSum()
        if let opening {
            try dated.add(opening.unassignedMinor); try allDates.add(opening.unassignedMinor)
            for (id, value) in opening.categoryAvailable {
                guard rows[id] != nil else { throw InvalidInput.unknownCategory(id) }
                try rows[id]!.carried.add(value)
            }
        }
        func checkBoundary(_ day: Day) throws {
            if let opening, day < opening.month { throw InvalidInput.beforeOpeningBoundary }
        }
        for operation in allocations {
            try checkBoundary(operation.occurredOn)
            for posting in operation.postings {
                if let id = posting.categoryID {
                    guard rows[id] != nil else { throw InvalidInput.unknownCategory(id) }
                    if operation.occurredOn.month < month { try rows[id]!.carried.add(posting.amountMinor) }
                    else if operation.occurredOn.month == month { try rows[id]!.assigned.add(posting.amountMinor) }
                } else {
                    try allDates.add(posting.amountMinor)
                    if operation.occurredOn.month <= month { try dated.add(posting.amountMinor) }
                }
            }
        }
        for transaction in activity {
            try checkBoundary(transaction.occurredOn)
            try allDates.add(transaction.unassignedMinor)
            if transaction.occurredOn.month <= month { try dated.add(transaction.unassignedMinor) }
            for (id, amount) in transaction.categoryAmounts {
                guard rows[id] != nil else { throw InvalidInput.unknownCategory(id) }
                if transaction.occurredOn.month < month { try rows[id]!.carried.add(amount) }
                else if transaction.occurredOn.month == month { try rows[id]!.activity.add(amount) }
            }
        }
        let categories = try rows.mapValues { row in
            let assigned = try row.assigned.value(), activity = try row.activity.value(), carry = try row.carried.value()
            var available = ExactSum()
            try available.add(carry); try available.add(assigned); try available.add(activity)
            return Category(assignedMinor: assigned, activityMinor: activity, carriedAvailableMinor: carry,
                            availableMinor: try available.value())
        }
        var assignedTotal = ExactSum(), overspentTotal = ExactSum()
        for category in categories.values {
            try assignedTotal.add(category.assignedMinor)
            if category.availableMinor < 0 {
                guard category.availableMinor != .min else { throw MoneyError.arithmeticOverflow }
                try overspentTotal.add(-category.availableMinor)
            }
        }
        return Snapshot(month: selected, readyToAssignMinor: try dated.value(), allDateUnassignedMinor: try allDates.value(),
                        totalAssignedMinor: try assignedTotal.value(), totalOverspentMinor: try overspentTotal.value(), categories: categories)
    }

    private struct Accumulator {
        var assigned = ExactSum(), activity = ExactSum(), carried = ExactSum()
    }

    /// Two-word signed accumulation permits exact cancellation independent of input order.
    /// Final API observations must fit Int64. No Double/Decimal rounding or silent saturation.
    private struct ExactSum {
        var high: Int64 = 0
        var low: UInt64 = 0
        mutating func add(_ value: Int64) throws {
            let addition = low.addingReportingOverflow(UInt64(bitPattern: value))
            let highDelta: Int64 = (value < 0 ? -1 : 0) + (addition.overflow ? 1 : 0)
            let upper = high.addingReportingOverflow(highDelta)
            guard !upper.overflow else { throw MoneyError.arithmeticOverflow }
            low = addition.partialValue; high = upper.partialValue
        }
        func value() throws -> Int64 {
            if high == 0, low <= UInt64(Int64.max) { return Int64(low) }
            if high == -1, low >= UInt64(1) << 63 { return Int64(bitPattern: low) }
            throw MoneyError.arithmeticOverflow
        }
    }
}
