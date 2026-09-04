import Foundation

struct TokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

public enum APIBudgetPermission: String, Decodable, Equatable, Sendable {
    case view, contribute, manage, owner

    public var canContribute: Bool { self != .view }
    public var canManage: Bool { self == .manage || self == .owner }
}

public struct APIBudget: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let householdID: String
    public let name: String
    public let currencyCode: String
    public let effectivePermission: APIBudgetPermission

    public init(
        id: String,
        householdID: String,
        name: String,
        currencyCode: String,
        effectivePermission: APIBudgetPermission = .owner
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.currencyCode = currencyCode
        self.effectivePermission = effectivePermission
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case householdID = "household_id"
        case currencyCode = "currency_code"
        case effectivePermission = "effective_permission"
    }
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

public struct BootstrapRequest: Encodable, Sendable {
    let email: String
    let password: String
    let displayName: String
    let householdName: String

    public init(email: String, password: String, displayName: String, householdName: String) {
        self.email = email
        self.password = password
        self.displayName = displayName
        self.householdName = householdName
    }

    enum CodingKeys: String, CodingKey {
        case email, password
        case displayName = "display_name"
        case householdName = "household_name"
    }
}

struct APIErrorBody: Decodable {
    let detail: String?
}

public struct APIAccount: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let name: String
    public let accountType: String
    public let isOnBudget: Bool
    public let isClosed: Bool
    public let reconciledBalanceMinor: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name
        case budgetID = "budget_id"
        case accountType = "account_type"
        case isOnBudget = "is_on_budget"
        case isClosed = "is_closed"
        case reconciledBalanceMinor = "reconciled_balance_minor"
    }
}

public struct APITransactionSplit: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let categoryID: String
    public let amountMinor: Int64
    public let memo: String

    enum CodingKeys: String, CodingKey {
        case id, memo
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
    }
}

public struct APITransaction: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let categoryID: String?
    public let amountMinor: Int64
    public let occurredOn: String
    public let payeeName: String
    public let memo: String
    public let isCleared: Bool
    public let isReconciled: Bool
    public let transferID: String?
    public let splits: [APITransactionSplit]

    enum CodingKeys: String, CodingKey {
        case id, memo, splits
        case accountID = "account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case occurredOn = "occurred_on"
        case payeeName = "payee_name"
        case isCleared = "is_cleared"
        case isReconciled = "is_reconciled"
        case transferID = "transfer_id"
    }
}

public struct APICategoryMonth: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { categoryID }
    public let categoryID: String
    public let name: String
    public let assignedMinor: Int64
    public let activityMinor: Int64
    public let carriedAvailableMinor: Int64
    public let availableMinor: Int64
    public let isOverspent: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case categoryID = "category_id"
        case assignedMinor = "assigned_minor"
        case activityMinor = "activity_minor"
        case carriedAvailableMinor = "carried_available_minor"
        case availableMinor = "available_minor"
        case isOverspent = "is_overspent"
    }
}

public struct APIMonthSummary: Decodable, Equatable, Sendable {
    public let month: String
    public let currencyCode: String
    public let readyToAssignMinor: Int64
    public let totalAssignedMinor: Int64
    public let totalOverspentMinor: Int64
    public let categories: [APICategoryMonth]

    enum CodingKeys: String, CodingKey {
        case month, categories
        case currencyCode = "currency_code"
        case readyToAssignMinor = "ready_to_assign_minor"
        case totalAssignedMinor = "total_assigned_minor"
        case totalOverspentMinor = "total_overspent_minor"
    }
}

public struct APICategory: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let groupID: String
    public let name: String
    public let sortOrder: Int
    public let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case budgetID = "budget_id"
        case groupID = "group_id"
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
    }
}

public struct APITransactionCreate: Encodable, Equatable, Sendable {
    public let accountID: String
    public let categoryID: String?
    public let amountMinor: Int64
    public let occurredOn: String
    public let payeeName: String
    public let memo: String
    public let isCleared: Bool

    public init(
        accountID: String,
        categoryID: String?,
        amountMinor: Int64,
        occurredOn: String,
        payeeName: String,
        memo: String = "",
        isCleared: Bool = false
    ) {
        self.accountID = accountID
        self.categoryID = categoryID
        self.amountMinor = amountMinor
        self.occurredOn = occurredOn
        self.payeeName = payeeName
        self.memo = memo
        self.isCleared = isCleared
    }

    enum CodingKeys: String, CodingKey {
        case memo
        case accountID = "account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case occurredOn = "occurred_on"
        case payeeName = "payee_name"
        case isCleared = "is_cleared"
    }
}

struct APIAssignmentUpdate: Encodable {
    let month: String
    let assignedMinor: Int64

    enum CodingKeys: String, CodingKey {
        case month
        case assignedMinor = "assigned_minor"
    }
}

public struct APIAssignment: Decodable, Equatable, Sendable {
    public let budgetID: String
    public let categoryID: String
    public let month: String
    public let assignedMinor: Int64

    enum CodingKeys: String, CodingKey {
        case month
        case budgetID = "budget_id"
        case categoryID = "category_id"
        case assignedMinor = "assigned_minor"
    }
}
