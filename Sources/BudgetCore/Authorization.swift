import Foundation

public enum BudgetAction: Sendable {
    case view
    case addTransaction
    case editBudget
    case changeSharing

    var requiredPermission: BudgetPermission {
        switch self {
        case .view: .view
        case .addTransaction: .contribute
        case .editBudget: .manage
        case .changeSharing: .manage
        }
    }
}

public enum AccessDecision: Equatable, Sendable {
    case allowed
    /// Used for both missing budgets and hidden budgets to avoid leaking names
    /// or identifiers through different error responses.
    case notFound
    case forbidden
}

public struct BudgetAuthorizer: Sendable {
    public init() {}

    public func authorize(
        member: HouseholdMember?,
        budget: Budget,
        grants: [BudgetGrant],
        action: BudgetAction
    ) -> AccessDecision {
        guard let member,
              member.isActive,
              member.householdID == budget.householdID else {
            return .notFound
        }

        if member.role == .owner {
            return .allowed
        }

        guard let grant = grants.first(where: {
            $0.budgetID == budget.id && $0.userID == member.userID
        }) else {
            return .notFound
        }

        return grant.permission >= action.requiredPermission ? .allowed : .forbidden
    }

    public func visibleBudgets(
        for member: HouseholdMember?,
        budgets: [Budget],
        grants: [BudgetGrant]
    ) -> [Budget] {
        budgets.filter {
            authorize(member: member, budget: $0, grants: grants, action: .view) == .allowed
        }
    }
}

