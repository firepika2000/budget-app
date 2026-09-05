import Foundation

public enum FinancialPeriod: Equatable, Sendable {
    case rollingDays(Int)
    case monthContaining(Date)
    case yearToDate
    case calendarYear(Int)
    case custom(start: Date, endInclusive: Date)
}

public struct FinancialDateRange: Equatable, Sendable {
    public let start: Date
    public let endExclusive: Date

    public init(start: Date, endExclusive: Date) {
        self.start = start
        self.endExclusive = endExclusive
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < endExclusive
    }
}

public enum FinancialPeriodError: Error, Equatable, Sendable {
    case invalidRollingDays
    case invalidCustomRange
    case invalidCalendarDate
}

public struct FinancialPeriodCalculator: Sendable {
    public init() {}

    public func range(
        for period: FinancialPeriod,
        asOf: Date,
        calendar: Calendar = .current
    ) throws -> FinancialDateRange {
        let asOfDay = calendar.startOfDay(for: asOf)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: asOfDay) else {
            throw FinancialPeriodError.invalidCalendarDate
        }

        switch period {
        case let .rollingDays(days):
            guard days > 0,
                  let start = calendar.date(byAdding: .day, value: -(days - 1), to: asOfDay) else {
                throw FinancialPeriodError.invalidRollingDays
            }
            return FinancialDateRange(start: start, endExclusive: tomorrow)

        case let .monthContaining(date):
            guard let interval = calendar.dateInterval(of: .month, for: date) else {
                throw FinancialPeriodError.invalidCalendarDate
            }
            return FinancialDateRange(start: interval.start, endExclusive: interval.end)

        case .yearToDate:
            guard let interval = calendar.dateInterval(of: .year, for: asOf) else {
                throw FinancialPeriodError.invalidCalendarDate
            }
            return FinancialDateRange(start: interval.start, endExclusive: tomorrow)

        case let .calendarYear(year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else {
                throw FinancialPeriodError.invalidCalendarDate
            }
            return FinancialDateRange(start: start, endExclusive: end)

        case let .custom(start, endInclusive):
            let normalizedStart = calendar.startOfDay(for: start)
            let normalizedEnd = calendar.startOfDay(for: endInclusive)
            guard normalizedStart <= normalizedEnd,
                  let endExclusive = calendar.date(byAdding: .day, value: 1, to: normalizedEnd) else {
                throw FinancialPeriodError.invalidCustomRange
            }
            return FinancialDateRange(start: normalizedStart, endExclusive: endExclusive)
        }
    }

    public func previousRange(
        matching range: FinancialDateRange,
        calendar: Calendar = .current
    ) throws -> FinancialDateRange {
        let duration = range.endExclusive.timeIntervalSince(range.start)
        guard duration > 0 else { throw FinancialPeriodError.invalidCustomRange }
        return FinancialDateRange(
            start: range.start.addingTimeInterval(-duration),
            endExclusive: range.start
        )
    }
}

public struct ReportTransaction: Identifiable, Equatable, Sendable {
    public let id: String
    public var occurredOn: Date
    public var amountMinor: Int64
    public var categoryID: String?
    public var categoryName: String?
    public var categoryGroup: String?
    public var payee: String
    public var accountID: String
    public var memberID: String?
    public var isTransfer: Bool

    public init(
        id: String,
        occurredOn: Date,
        amountMinor: Int64,
        categoryID: String?,
        categoryName: String?,
        categoryGroup: String?,
        payee: String,
        accountID: String,
        memberID: String? = nil,
        isTransfer: Bool = false
    ) {
        self.id = id
        self.occurredOn = occurredOn
        self.amountMinor = amountMinor
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.categoryGroup = categoryGroup
        self.payee = payee
        self.accountID = accountID
        self.memberID = memberID
        self.isTransfer = isTransfer
    }
}

public struct ReportFilter: Equatable, Sendable {
    public var accountIDs: Set<String>
    public var categoryIDs: Set<String>
    public var categoryGroups: Set<String>
    public var memberIDs: Set<String>
    public var payees: Set<String>

    public init(
        accountIDs: Set<String> = [],
        categoryIDs: Set<String> = [],
        categoryGroups: Set<String> = [],
        memberIDs: Set<String> = [],
        payees: Set<String> = []
    ) {
        self.accountIDs = accountIDs
        self.categoryIDs = categoryIDs
        self.categoryGroups = categoryGroups
        self.memberIDs = memberIDs
        self.payees = payees
    }

    public var isEmpty: Bool {
        accountIDs.isEmpty && categoryIDs.isEmpty && categoryGroups.isEmpty && memberIDs.isEmpty && payees.isEmpty
    }
}

public struct SpendingCategoryInsight: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let group: String
    public let spendingMinor: Int64
    public let transactionIDs: [String]

    public var transactionCount: Int { transactionIDs.count }
    public var averageTransactionMinor: Int64 {
        transactionCount == 0 ? 0 : spendingMinor / Int64(transactionCount)
    }
}

public struct IncomeSpendingInsight: Equatable, Sendable {
    public let incomeMinor: Int64
    public let spendingMinor: Int64
    public let incomeTransactionIDs: [String]
    public let spendingTransactionIDs: [String]

    public var differenceMinor: Int64 { incomeMinor - spendingMinor }
    public var savingsRate: Double? {
        guard incomeMinor > 0 else { return nil }
        return Double(differenceMinor) / Double(incomeMinor)
    }
}

public struct InsightsCalculator: Sendable {
    public init() {}

    public func transactions(
        from allTransactions: [ReportTransaction],
        in range: FinancialDateRange,
        filter: ReportFilter = ReportFilter()
    ) -> [ReportTransaction] {
        allTransactions.filter { transaction in
            range.contains(transaction.occurredOn)
                && (filter.accountIDs.isEmpty || filter.accountIDs.contains(transaction.accountID))
                && (filter.categoryIDs.isEmpty || transaction.categoryID.map(filter.categoryIDs.contains) == true)
                && (filter.categoryGroups.isEmpty || transaction.categoryGroup.map(filter.categoryGroups.contains) == true)
                && (filter.memberIDs.isEmpty || transaction.memberID.map(filter.memberIDs.contains) == true)
                && (filter.payees.isEmpty || filter.payees.contains(transaction.payee))
        }
    }

    public func spendingByCategory(
        transactions: [ReportTransaction]
    ) -> [SpendingCategoryInsight] {
        let spending = transactions.filter {
            !$0.isTransfer && $0.amountMinor < 0 && $0.categoryID != nil
        }
        let groups = Dictionary(grouping: spending) { $0.categoryID! }
        return groups.compactMap { categoryID, items in
            guard let first = items.first else { return nil }
            return SpendingCategoryInsight(
                id: categoryID,
                name: first.categoryName ?? "Uncategorized",
                group: first.categoryGroup ?? "Uncategorized",
                spendingMinor: items.reduce(0) { $0 + abs($1.amountMinor) },
                transactionIDs: items.sorted { $0.occurredOn > $1.occurredOn }.map(\.id)
            )
        }.sorted { lhs, rhs in
            lhs.spendingMinor == rhs.spendingMinor ? lhs.name < rhs.name : lhs.spendingMinor > rhs.spendingMinor
        }
    }

    public func incomeVersusSpending(
        transactions: [ReportTransaction]
    ) -> IncomeSpendingInsight {
        let included = transactions.filter { !$0.isTransfer }
        let income = included.filter { $0.amountMinor > 0 }
        let spending = included.filter { $0.amountMinor < 0 }
        return IncomeSpendingInsight(
            incomeMinor: income.reduce(0) { $0 + $1.amountMinor },
            spendingMinor: spending.reduce(0) { $0 + abs($1.amountMinor) },
            incomeTransactionIDs: income.map(\.id),
            spendingTransactionIDs: spending.map(\.id)
        )
    }
}
