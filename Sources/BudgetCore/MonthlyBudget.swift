import Foundation

public struct CategoryID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct CategoryMonthInput: Equatable, Codable, Sendable {
    public let categoryID: CategoryID
    public var name: String
    /// Money remaining at the close of the previous month.
    public var carriedAvailable: Money
    /// Money deliberately given to (or removed from) this category this month.
    public var assigned: Money
    /// Net transaction activity. Spending is negative and refunds are positive.
    public var activity: Money

    public init(
        categoryID: CategoryID = CategoryID(),
        name: String,
        carriedAvailable: Money,
        assigned: Money,
        activity: Money
    ) {
        self.categoryID = categoryID
        self.name = name
        self.carriedAvailable = carriedAvailable
        self.assigned = assigned
        self.activity = activity
    }
}

public struct CategoryMonthResult: Equatable, Codable, Sendable {
    public let categoryID: CategoryID
    public let name: String
    public let assigned: Money
    public let activity: Money
    public let available: Money

    public var isOverspent: Bool { available.minorUnits < 0 }
}

public struct MonthlyBudgetResult: Equatable, Codable, Sendable {
    public let readyToAssign: Money
    public let totalAssigned: Money
    public let totalOverspent: Money
    public let categories: [CategoryMonthResult]
}

public enum MonthlyBudgetError: Error, Equatable, Sendable {
    case duplicateCategory(CategoryID)
    case money(MoneyError)
}

public struct MonthlyBudgetCalculator: Sendable {
    public init() {}

    /// Calculates the current month. `newIncome` includes inflows made available
    /// to budget this month; `startingReadyToAssign` carries any prior unassigned
    /// amount. Category activity changes category availability but does not alter
    /// Ready to Assign because inflows must be explicitly categorized as income.
    public func calculate(
        startingReadyToAssign: Money,
        newIncome: Money,
        categories: [CategoryMonthInput]
    ) throws -> MonthlyBudgetResult {
        var seenCategoryIDs = Set<CategoryID>()
        var totalAssigned = Money.zero(currencyCode: startingReadyToAssign.currencyCode)
        var totalOverspent = Money.zero(currencyCode: startingReadyToAssign.currencyCode)
        var results: [CategoryMonthResult] = []
        results.reserveCapacity(categories.count)

        do {
            var readyToAssign = try startingReadyToAssign.adding(newIncome)

            for category in categories {
                guard seenCategoryIDs.insert(category.categoryID).inserted else {
                    throw MonthlyBudgetError.duplicateCategory(category.categoryID)
                }

                totalAssigned = try totalAssigned.adding(category.assigned)
                readyToAssign = try readyToAssign.subtracting(category.assigned)
                let available = try category.carriedAvailable
                    .adding(category.assigned)
                    .adding(category.activity)
                if available.minorUnits < 0 {
                    totalOverspent = try totalOverspent.adding(available.negated())
                }

                results.append(
                    CategoryMonthResult(
                        categoryID: category.categoryID,
                        name: category.name,
                        assigned: category.assigned,
                        activity: category.activity,
                        available: available
                    )
                )
            }

            return MonthlyBudgetResult(
                readyToAssign: readyToAssign,
                totalAssigned: totalAssigned,
                totalOverspent: totalOverspent,
                categories: results
            )
        } catch let error as MonthlyBudgetError {
            throw error
        } catch let error as MoneyError {
            throw MonthlyBudgetError.money(error)
        }
    }
}
