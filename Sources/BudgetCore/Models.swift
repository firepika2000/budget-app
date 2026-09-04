import Foundation

public struct HouseholdID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct UserID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct BudgetID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum HouseholdRole: String, Codable, Sendable {
    case owner
    case adult
    case child
}

/// Membership establishes identity and household role. It does not, by itself,
/// grant visibility into every budget in the household.
public struct HouseholdMember: Equatable, Codable, Sendable {
    public let userID: UserID
    public let householdID: HouseholdID
    public var role: HouseholdRole
    public var isActive: Bool

    public init(
        userID: UserID,
        householdID: HouseholdID,
        role: HouseholdRole,
        isActive: Bool = true
    ) {
        self.userID = userID
        self.householdID = householdID
        self.role = role
        self.isActive = isActive
    }
}

public enum BudgetPermission: Int, Comparable, Codable, Sendable {
    case view = 10
    case contribute = 20
    case manage = 30

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Explicit grants are the source of truth for non-owners. Absence means the
/// budget and all of its transactions are undiscoverable to that member.
public struct BudgetGrant: Equatable, Codable, Sendable {
    public let budgetID: BudgetID
    public let userID: UserID
    public var permission: BudgetPermission

    public init(
        budgetID: BudgetID,
        userID: UserID,
        permission: BudgetPermission
    ) {
        self.budgetID = budgetID
        self.userID = userID
        self.permission = permission
    }
}

public struct Budget: Equatable, Codable, Sendable {
    public let id: BudgetID
    public let householdID: HouseholdID
    public var name: String

    public init(
        id: BudgetID = BudgetID(),
        householdID: HouseholdID,
        name: String
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
    }
}

