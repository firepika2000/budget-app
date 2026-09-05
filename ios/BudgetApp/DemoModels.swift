import Foundation
import SwiftUI

enum DemoPersona: String, CaseIterable, Identifiable {
    case rey = "Rey"
    case partner = "Jordan"
    case alex = "Alex"
    case mia = "Mia"

    var id: String { rawValue }
    var role: String {
        switch self {
        case .rey: "Owner"
        case .partner: "Partner · Full access"
        case .alex: "Teen · Delegated"
        case .mia: "Child · Delegated"
        }
    }
    var initials: String { String(rawValue.prefix(1)) }
    var isChild: Bool { self == .alex || self == .mia }
}

enum DemoAccountKind: String, Codable {
    case checking, savings, cash, credit, loan, asset, mortgage

    var title: String {
        switch self {
        case .credit: "Credit Cards"
        case .loan, .mortgage: "Loans & Debt"
        case .asset: "Tracking Assets"
        default: "Cash Accounts"
        }
    }
    var icon: String {
        switch self {
        case .checking: "building.columns.fill"
        case .savings: "leaf.fill"
        case .cash: "banknote.fill"
        case .credit: "creditcard.fill"
        case .loan: "car.fill"
        case .mortgage: "house.fill"
        case .asset: "chart.line.uptrend.xyaxis"
        }
    }
}

struct DemoAccount: Identifiable, Hashable {
    let id: String
    var name: String
    var kind: DemoAccountKind
    var balance: Int64
    var cleared: Int64
    var paymentReserved: Int64 = 0
    var fundedSpending: Int64 = 0
    var unfundedSpending: Int64 = 0
    var apr: Double? = nil
    var minimumPayment: Int64? = nil
    var dueText: String? = nil
    var restrictedFromChildren = true
}

struct DemoCategory: Identifiable, Hashable {
    let id: String
    var group: String
    var name: String
    var icon: String
    var assigned: Int64
    var activity: Int64
    var available: Int64
    var target: Int64?
    var targetDate: String? = nil
    var targetType: String = "savings_balance"
    var targetRecurrenceMonths: Int? = nil
    var targetMinimumContribution: Int64 = 0
    var targetPriority: Int = 50
    var targetIsActive: Bool = true
    var note: String = ""
    var pinned = false
    var delegatedTo: DemoPersona? = nil
    var isHidden = false

    var progress: Double {
        guard let target, target > 0 else { return available >= 0 ? 1 : 0 }
        return min(max(Double(available) / Double(target), 0), 1)
    }
    var status: String {
        if available < 0 { return "Overspent" }
        if let target, available < target { return "Needs funding" }
        return "Funded"
    }
}

struct DemoTransaction: Identifiable, Hashable {
    let id: String
    var date: Date
    var payee: String
    var memo: String
    var accountID: String
    var categoryIDs: [String]
    var categoryAmounts: [String: Int64] = [:]
    var amount: Int64
    var member: DemoPersona
    var cleared: Bool
    var flag: String? = nil
    var attachmentName: String? = nil
    var tags: [String] = []
    var scheduled = false
    var reconciled = false
    var transferID: String? = nil
}

enum DemoReportPeriod: String, CaseIterable, Identifiable {
    case thirtyDays = "30D"
    case sixtyDays = "60D"
    case ninetyDays = "90D"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case yearToDate = "YTD"
    case oneYear = "1Y"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .thirtyDays: "30 Days"
        case .sixtyDays: "60 Days"
        case .ninetyDays: "90 Days"
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .yearToDate: "Year to Date"
        case .oneYear: "1 Year"
        }
    }

    func contains(_ date: Date, asOf: Date = .demo(monthsAgo: 0, day: 30), calendar: Calendar = .current) -> Bool {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: asOf))!
        let start: Date
        switch self {
        case .thirtyDays, .sixtyDays, .ninetyDays:
            let days = self == .thirtyDays ? 30 : self == .sixtyDays ? 60 : 90
            start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: asOf))!
        case .threeMonths, .sixMonths, .oneYear:
            let months = self == .threeMonths ? 3 : self == .sixMonths ? 6 : 12
            start = calendar.date(byAdding: .month, value: -months, to: end)!
        case .yearToDate:
            start = calendar.dateInterval(of: .year, for: asOf)!.start
        }
        return date >= start && date < end
    }
}

enum DemoMutationError: LocalizedError, Equatable {
    case invalidAmount
    case categoryNotFound
    case transactionNotFound
    case accountNotFound
    case insufficientFunds(available: Int64)
    case exceedsDelegatedAuthority(available: Int64)
    case restrictedCategory

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter an amount greater than zero."
        case .categoryNotFound: "That category is no longer available."
        case .transactionNotFound: "That transaction is no longer available."
        case .accountNotFound: "That account is no longer available."
        case let .insufficientFunds(available): "Only \(available.demoCurrency) is available to move."
        case let .exceedsDelegatedAuthority(available): "This exceeds your delegated budget. You have \(available.demoCurrency) left to assign."
        case .restrictedCategory: "You can only change categories inside your delegated budget."
        }
    }
}

struct DemoRequest: Identifiable, Hashable {
    let id: String
    var member: DemoPersona
    var amount: Int64
    var approvedAmount: Int64?
    var categoryID: String
    var reason: String
    var status: String
    var date: Date
}

struct DemoAllowance: Identifiable, Hashable {
    let id: String
    var member: DemoPersona
    var amount: Int64
    var frequency: String
    var nextDate: String
    var source: String
    var splits: [(String, Int64)]
    var rollover: Bool
    var isPaused = false

    static func == (lhs: DemoAllowance, rhs: DemoAllowance) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct DemoForecastPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Int64
    let isActual: Bool
}

extension Int64 {
    var demoCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: Double(self) / 100)) ?? "$0.00"
    }
}

extension Date {
    static func demo(monthsAgo: Int, day: Int = 12) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
        return calendar.date(byAdding: .month, value: -monthsAgo, to: base)!
    }
}
