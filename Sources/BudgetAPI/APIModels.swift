import Foundation

public struct APIAuthTokens: Decodable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct APIRefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
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
    public let allocationVersion: Int
    public let capabilities: [String]?

    public init(
        id: String,
        householdID: String,
        name: String,
        currencyCode: String,
        effectivePermission: APIBudgetPermission = .owner,
        allocationVersion: Int = 0,
        capabilities: [String]? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.currencyCode = currencyCode
        self.effectivePermission = effectivePermission
        self.allocationVersion = allocationVersion
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case householdID = "household_id"
        case currencyCode = "currency_code"
        case effectivePermission = "effective_permission"
        case allocationVersion = "allocation_version"
        case capabilities
    }

    public func can(_ capability: String) -> Bool {
        if effectivePermission == .owner { return true }
        if let capabilities { return capabilities.contains(capability) }
        switch capability {
        case "create_transaction", "request_money": return effectivePermission.canContribute
        case "assign_money", "move_money", "reconcile_account", "manage_budget_structure", "manage_planning", "manage_allowances", "approve_request":
            return effectivePermission.canManage
        default: return true
        }
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

public struct APIInvitationAccept: Encodable, Sendable {
    public let invitationToken: String
    public let password: String
    public let displayName: String

    public init(invitationToken: String, password: String, displayName: String) {
        self.invitationToken = invitationToken
        self.password = password
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case password
        case invitationToken = "invitation_token"
        case displayName = "display_name"
    }
}

public struct APIHousehold: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let role: String
    public let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, role
        case isActive = "is_active"
    }
}

public struct APIProfile: Decodable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let displayName: String
    public let households: [APIHousehold]

    enum CodingKeys: String, CodingKey {
        case id, email, households
        case displayName = "display_name"
    }
}

public struct APIBudgetCreate: Encodable, Sendable {
    public let householdID: String
    public let name: String
    public let currencyCode: String

    public init(householdID: String, name: String, currencyCode: String) {
        self.householdID = householdID
        self.name = name
        self.currencyCode = currencyCode
    }

    enum CodingKeys: String, CodingKey {
        case name
        case householdID = "household_id"
        case currencyCode = "currency_code"
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
    public let paymentCategoryID: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case budgetID = "budget_id"
        case accountType = "account_type"
        case isOnBudget = "is_on_budget"
        case isClosed = "is_closed"
        case reconciledBalanceMinor = "reconciled_balance_minor"
        case paymentCategoryID = "payment_category_id"
    }
}

public struct APIAccountCreate: Encodable, Sendable {
    public let name: String
    public let accountType: String
    public let isOnBudget: Bool

    public init(name: String, accountType: String, isOnBudget: Bool = true) {
        self.name = name
        self.accountType = accountType
        self.isOnBudget = isOnBudget
    }

    enum CodingKeys: String, CodingKey {
        case name
        case accountType = "account_type"
        case isOnBudget = "is_on_budget"
    }
}

public struct APICategoryGroup: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let name: String
    public let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case budgetID = "budget_id"
        case sortOrder = "sort_order"
    }
}

public struct APICategoryGroupCreate: Encodable, Sendable {
    public let name: String
    public let sortOrder: Int

    public init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case name
        case sortOrder = "sort_order"
    }
}

public struct APICategoryCreate: Encodable, Sendable {
    public let groupID: String
    public let name: String
    public let sortOrder: Int
    public let delegatedUserID: String?

    public init(groupID: String, name: String, sortOrder: Int = 0, delegatedUserID: String? = nil) {
        self.groupID = groupID
        self.name = name
        self.sortOrder = sortOrder
        self.delegatedUserID = delegatedUserID
    }

    enum CodingKeys: String, CodingKey {
        case name
        case groupID = "group_id"
        case sortOrder = "sort_order"
        case delegatedUserID = "delegated_user_id"
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
    public let allocationVersion: Int
    public let categories: [APICategoryMonth]

    enum CodingKeys: String, CodingKey {
        case month, categories
        case currencyCode = "currency_code"
        case readyToAssignMinor = "ready_to_assign_minor"
        case totalAssignedMinor = "total_assigned_minor"
        case totalOverspentMinor = "total_overspent_minor"
        case allocationVersion = "allocation_version"
    }
}

public struct APICategory: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let groupID: String
    public let name: String
    public let sortOrder: Int
    public let isArchived: Bool
    public let systemType: String?
    public let linkedAccountID: String?
    public let delegatedUserID: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case budgetID = "budget_id"
        case groupID = "group_id"
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
        case systemType = "system_type"
        case linkedAccountID = "linked_account_id"
        case delegatedUserID = "delegated_user_id"
    }
}

public struct APIFinancialRequestCreate: Encodable, Sendable {
    public let requestType: String
    public let destinationCategoryID: String
    public let requestedAmountMinor: Int64
    public let reason: String

    public init(
        requestType: String = "additional_allocation",
        destinationCategoryID: String,
        requestedAmountMinor: Int64,
        reason: String
    ) {
        self.requestType = requestType
        self.destinationCategoryID = destinationCategoryID
        self.requestedAmountMinor = requestedAmountMinor
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case requestType = "request_type"
        case destinationCategoryID = "destination_category_id"
        case requestedAmountMinor = "requested_amount_minor"
    }
}

public struct APIRequestAction: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let actorUserID: String
    public let action: String
    public let amountMinor: Int64?
    public let note: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, action, note
        case actorUserID = "actor_user_id"
        case amountMinor = "amount_minor"
        case createdAt = "created_at"
    }
}

public struct APIFinancialRequest: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let requesterUserID: String
    public let requestType: String
    public let destinationCategoryID: String
    public let requestedAmountMinor: Int64
    public let reason: String
    public let status: String
    public let version: Int
    public let approvedAmountMinor: Int64?
    public let sourceCategoryID: String?
    public let allocationOperationID: String?
    public let actions: [APIRequestAction]

    enum CodingKeys: String, CodingKey {
        case id, reason, status, version, actions
        case requesterUserID = "requester_user_id"
        case requestType = "request_type"
        case destinationCategoryID = "destination_category_id"
        case requestedAmountMinor = "requested_amount_minor"
        case approvedAmountMinor = "approved_amount_minor"
        case sourceCategoryID = "source_category_id"
        case allocationOperationID = "allocation_operation_id"
    }
}

public struct APIAllowanceSplit: Decodable, Equatable, Sendable {
    public let destinationCategoryID: String
    public let amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case destinationCategoryID = "destination_category_id"
        case amountMinor = "amount_minor"
    }
}

public struct APIAllowancePlan: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let delegatedUserID: String
    public let sourceCategoryID: String?
    public let name: String
    public let amountMinor: Int64
    public let nextIssueDate: String
    public let recurrenceUnit: String
    public let intervalCount: Int
    public let rolloverPolicy: String
    public let isActive: Bool
    public let splits: [APIAllowanceSplit]

    enum CodingKeys: String, CodingKey {
        case id, name, splits
        case delegatedUserID = "delegated_user_id"
        case sourceCategoryID = "source_category_id"
        case amountMinor = "amount_minor"
        case nextIssueDate = "next_issue_date"
        case recurrenceUnit = "recurrence_unit"
        case intervalCount = "interval_count"
        case rolloverPolicy = "rollover_policy"
        case isActive = "is_active"
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
    public let splits: [APITransactionSplitCreate]

    public init(
        accountID: String,
        categoryID: String?,
        amountMinor: Int64,
        occurredOn: String,
        payeeName: String,
        memo: String = "",
        isCleared: Bool = false,
        splits: [APITransactionSplitCreate] = []
    ) {
        self.accountID = accountID
        self.categoryID = categoryID
        self.amountMinor = amountMinor
        self.occurredOn = occurredOn
        self.payeeName = payeeName
        self.memo = memo
        self.isCleared = isCleared
        self.splits = splits
    }

    enum CodingKeys: String, CodingKey {
        case memo, splits
        case accountID = "account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case occurredOn = "occurred_on"
        case payeeName = "payee_name"
        case isCleared = "is_cleared"
    }
}

public struct APITransactionSplitCreate: Encodable, Equatable, Sendable {
    public let categoryID: String
    public let amountMinor: Int64
    public let memo: String

    public init(categoryID: String, amountMinor: Int64, memo: String = "") {
        self.categoryID = categoryID
        self.amountMinor = amountMinor
        self.memo = memo
    }

    enum CodingKeys: String, CodingKey {
        case memo
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
    }
}

struct APIAssignmentUpdate: Encodable {
    let month: String
    let assignedMinor: Int64
    let expectedAllocationVersion: Int

    enum CodingKeys: String, CodingKey {
        case month
        case assignedMinor = "assigned_minor"
        case expectedAllocationVersion = "expected_allocation_version"
    }
}

public struct APIAssignment: Decodable, Equatable, Sendable {
    public let budgetID: String
    public let categoryID: String
    public let month: String
    public let assignedMinor: Int64
    public let allocationVersion: Int

    enum CodingKeys: String, CodingKey {
        case month
        case budgetID = "budget_id"
        case categoryID = "category_id"
        case assignedMinor = "assigned_minor"
        case allocationVersion = "allocation_version"
    }
}

public struct APIAllocationTransferCreate: Encodable, Sendable {
    public let sourceCategoryID: String
    public let destinationCategoryID: String
    public let amountMinor: Int64
    public let occurredOn: String
    public let note: String
    public let expectedAllocationVersion: Int

    public init(
        sourceCategoryID: String,
        destinationCategoryID: String,
        amountMinor: Int64,
        occurredOn: String,
        note: String = "",
        expectedAllocationVersion: Int
    ) {
        self.sourceCategoryID = sourceCategoryID
        self.destinationCategoryID = destinationCategoryID
        self.amountMinor = amountMinor
        self.occurredOn = occurredOn
        self.note = note
        self.expectedAllocationVersion = expectedAllocationVersion
    }

    enum CodingKeys: String, CodingKey {
        case note
        case sourceCategoryID = "source_category_id"
        case destinationCategoryID = "destination_category_id"
        case amountMinor = "amount_minor"
        case occurredOn = "occurred_on"
        case expectedAllocationVersion = "expected_allocation_version"
    }
}

public struct APIAllocationPosting: Decodable, Equatable, Sendable {
    public let bucket: String
    public let categoryID: String?
    public let amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case bucket
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
    }
}

public struct APIAllocationOperation: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let occurredOn: String
    public let kind: String
    public let actorUserID: String
    public let note: String
    public let source: String
    public let allocationVersion: Int
    public let postings: [APIAllocationPosting]

    enum CodingKeys: String, CodingKey {
        case id, kind, note, source, postings
        case budgetID = "budget_id"
        case occurredOn = "occurred_on"
        case actorUserID = "actor_user_id"
        case allocationVersion = "allocation_version"
    }
}
