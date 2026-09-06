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

public struct APIHouseholdMember: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { userID }
    public let userID: String
    public let email: String
    public let displayName: String
    public let role: String
    public let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case email, role
        case userID = "user_id", displayName = "display_name", isActive = "is_active"
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

public struct APIScheduledTransaction: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let accountID: String
    public let destinationAccountID: String?
    public let categoryID: String?
    public let name: String
    public let amountMinor: Int64
    public let nextDate: String
    public let recurrenceUnit: String
    public let intervalCount: Int
    public let memo: String
    public let isActive: Bool
    public let lastRealizedOn: String?

    enum CodingKeys: String, CodingKey {
        case id, name, memo
        case budgetID = "budget_id"
        case accountID = "account_id"
        case destinationAccountID = "destination_account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case nextDate = "next_date"
        case recurrenceUnit = "recurrence_unit"
        case intervalCount = "interval_count"
        case isActive = "is_active"
        case lastRealizedOn = "last_realized_on"
    }
}

public struct APIScheduledTransactionCreate: Encodable, Sendable {
    public let accountID: String
    public let destinationAccountID: String?
    public let categoryID: String?
    public let name: String
    public let amountMinor: Int64
    public let nextDate: String
    public let recurrenceUnit: String
    public let intervalCount: Int
    public let memo: String
    public let isActive: Bool

    public init(accountID: String, destinationAccountID: String? = nil, categoryID: String? = nil, name: String, amountMinor: Int64, nextDate: String, recurrenceUnit: String, intervalCount: Int = 1, memo: String = "", isActive: Bool = true) {
        self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.categoryID = categoryID
        self.name = name; self.amountMinor = amountMinor; self.nextDate = nextDate
        self.recurrenceUnit = recurrenceUnit; self.intervalCount = intervalCount; self.memo = memo; self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case name, memo
        case accountID = "account_id"
        case destinationAccountID = "destination_account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case nextDate = "next_date"
        case recurrenceUnit = "recurrence_unit"
        case intervalCount = "interval_count"
        case isActive = "is_active"
    }
}

public struct APIScheduledRealization: Decodable, Equatable, Sendable {
    public let scheduledTransactionID: String
    public let transactionIDs: [String]
    public let realizedOn: String
    public let nextDate: String?
    public let isActive: Bool
    public let lastRealizedOn: String

    enum CodingKeys: String, CodingKey {
        case scheduledTransactionID = "scheduled_transaction_id"
        case transactionIDs = "transaction_ids"
        case realizedOn = "realized_on"
        case nextDate = "next_date"
        case isActive = "is_active"
        case lastRealizedOn = "last_realized_on"
    }
}

public struct APIBootstrapStatus: Decodable, Equatable, Sendable {
    public let initialized: Bool
    public let authenticationRequired: Bool
    public let apiVersion: String

    public init(initialized: Bool, authenticationRequired: Bool, apiVersion: String) {
        self.initialized = initialized; self.authenticationRequired = authenticationRequired; self.apiVersion = apiVersion
    }

    enum CodingKeys: String, CodingKey {
        case initialized
        case authenticationRequired = "authentication_required"
        case apiVersion = "api_version"
    }
}

struct APIErrorBody: Decodable {
    let detail: String?

    private enum CodingKeys: String, CodingKey { case detail }
    private struct DetailObject: Decodable { let message: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // FastAPI `detail` is usually a string, but several financial-conflict responses
        // (reconciliation mismatch, allocation/request version conflict, stale balance) return
        // an object like {"message": ..., "cleared_balance_minor": ...}. Surface either form so
        // the actionable message reaches the user instead of a generic status string.
        if let text = try? container.decode(String.self, forKey: .detail) {
            detail = text
        } else if let object = try? container.decode(DetailObject.self, forKey: .detail) {
            detail = object.message
        } else {
            detail = nil
        }
    }
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

public struct APIAccountBalance: Decodable, Equatable, Sendable {
    public let accountID: String; public let currencyCode: String; public let clearedBalanceMinor: Int64; public let unclearedBalanceMinor: Int64; public let workingBalanceMinor: Int64; public let reconciledBalanceMinor: Int64?
    enum CodingKeys: String, CodingKey { case accountID = "account_id", currencyCode = "currency_code", clearedBalanceMinor = "cleared_balance_minor", unclearedBalanceMinor = "uncleared_balance_minor", workingBalanceMinor = "working_balance_minor", reconciledBalanceMinor = "reconciled_balance_minor" }
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
    public let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case budgetID = "budget_id"
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
    }
}

public struct APICategoryGroupUpdate: Encodable, Sendable {
    public let name: String; public let sortOrder: Int; public let isArchived: Bool
    public init(name: String, sortOrder: Int, isArchived: Bool) { self.name=name;self.sortOrder=sortOrder;self.isArchived=isArchived }
    enum CodingKeys: String, CodingKey { case name; case sortOrder="sort_order", isArchived="is_archived" }
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

public struct APICategoryUpdate: Encodable, Sendable {
    public let groupID: String
    public let name: String
    public let sortOrder: Int
    public let isArchived: Bool
    public init(groupID: String, name: String, sortOrder: Int = 0, isArchived: Bool = false) {
        self.groupID = groupID; self.name = name; self.sortOrder = sortOrder; self.isArchived = isArchived
    }
    enum CodingKeys: String, CodingKey {
        case groupID = "group_id", name, sortOrder = "sort_order", isArchived = "is_archived"
    }
}

public struct APICategoryTarget: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let categoryID: String
    public let targetType: String
    public let targetAmountMinor: Int64
    public let targetDate: String?
    public let recurrenceMonths: Int?
    public let minimumContributionMinor: Int64
    public let priority: Int
    public let isActive: Bool
    public init(id: String, categoryID: String, targetType: String, targetAmountMinor: Int64, targetDate: String? = nil, recurrenceMonths: Int? = nil, minimumContributionMinor: Int64 = 0, priority: Int = 50, isActive: Bool = true) { self.id=id; self.categoryID=categoryID; self.targetType=targetType; self.targetAmountMinor=targetAmountMinor; self.targetDate=targetDate; self.recurrenceMonths=recurrenceMonths; self.minimumContributionMinor=minimumContributionMinor; self.priority=priority; self.isActive=isActive }
    enum CodingKeys: String, CodingKey { case id, priority; case categoryID="category_id", targetType="target_type", targetAmountMinor="target_amount_minor", targetDate="target_date", recurrenceMonths="recurrence_months", minimumContributionMinor="minimum_contribution_minor", isActive="is_active" }
}

public struct APICategoryTargetUpsert: Encodable, Equatable, Sendable {
    public let targetType: String; public let targetAmountMinor: Int64; public let targetDate: String?; public let recurrenceMonths: Int?; public let minimumContributionMinor: Int64; public let priority: Int; public let isActive: Bool
    public init(targetType: String, targetAmountMinor: Int64, targetDate: String? = nil, recurrenceMonths: Int? = nil, minimumContributionMinor: Int64 = 0, priority: Int = 50, isActive: Bool = true) { self.targetType=targetType;self.targetAmountMinor=targetAmountMinor;self.targetDate=targetDate;self.recurrenceMonths=recurrenceMonths;self.minimumContributionMinor=minimumContributionMinor;self.priority=priority;self.isActive=isActive }
    enum CodingKeys: String, CodingKey { case priority; case targetType="target_type", targetAmountMinor="target_amount_minor", targetDate="target_date", recurrenceMonths="recurrence_months", minimumContributionMinor="minimum_contribution_minor", isActive="is_active" }
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
    public let flag: String?
    public let tags: [String]?
    public let attachmentMetadata: [[String: String]]?
    public let splits: [APITransactionSplit]

    enum CodingKeys: String, CodingKey {
        case id, memo, splits, flag, tags
        case accountID = "account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case occurredOn = "occurred_on"
        case payeeName = "payee_name"
        case isCleared = "is_cleared"
        case isReconciled = "is_reconciled"
        case transferID = "transfer_id"
        case attachmentMetadata = "attachment_metadata"
    }
}

public struct APITransferCreate: Encodable, Sendable {
    public let sourceAccountID: String
    public let destinationAccountID: String
    public let amountMinor: Int64
    public let occurredOn: String
    public let memo: String
    public let isCleared: Bool

    public init(sourceAccountID: String, destinationAccountID: String, amountMinor: Int64, occurredOn: String, memo: String = "", isCleared: Bool = false) {
        self.sourceAccountID = sourceAccountID; self.destinationAccountID = destinationAccountID
        self.amountMinor = amountMinor; self.occurredOn = occurredOn; self.memo = memo; self.isCleared = isCleared
    }

    enum CodingKeys: String, CodingKey {
        case sourceAccountID = "source_account_id", destinationAccountID = "destination_account_id"
        case amountMinor = "amount_minor", occurredOn = "occurred_on", memo, isCleared = "is_cleared"
    }
}

public struct APITransferResponse: Decodable, Equatable, Sendable {
    public let transferID: String
    public let source: APITransaction
    public let destination: APITransaction
    enum CodingKeys: String, CodingKey { case transferID = "transfer_id", source, destination }
}

public struct APIReconcileRequest: Encodable, Sendable {
    public let statementBalanceMinor: Int64
    public let throughDate: String
    public let createAdjustment: Bool
    public let adjustmentReason: String
    public let expectedClearedBalanceMinor: Int64?
    public init(statementBalanceMinor: Int64, throughDate: String, createAdjustment: Bool = false, adjustmentReason: String = "", expectedClearedBalanceMinor: Int64? = nil) {
        self.statementBalanceMinor = statementBalanceMinor; self.throughDate = throughDate
        self.createAdjustment = createAdjustment; self.adjustmentReason = adjustmentReason
        self.expectedClearedBalanceMinor = expectedClearedBalanceMinor
    }
    enum CodingKeys: String, CodingKey {
        case statementBalanceMinor = "statement_balance_minor", throughDate = "through_date"
        case createAdjustment = "create_adjustment", adjustmentReason = "adjustment_reason"
        case expectedClearedBalanceMinor = "expected_cleared_balance_minor"
    }
}

public struct APIReconcileResponse: Decodable, Equatable, Sendable {
    public let accountID: String
    public let reconciledBalanceMinor: Int64
    public let reconciledTransactionCount: Int
    public let adjustmentTransactionID: String?
    public let adjustmentAmountMinor: Int64
    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", reconciledBalanceMinor = "reconciled_balance_minor"
        case reconciledTransactionCount = "reconciled_transaction_count"
        case adjustmentTransactionID = "adjustment_transaction_id", adjustmentAmountMinor = "adjustment_amount_minor"
    }
}

public struct APISpendingCategoryReport: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { categoryID }
    public let categoryID: String
    public let categoryName: String
    public let categoryGroup: String
    public let spendingMinor: Int64
    public let transactionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id", categoryName = "category_name", categoryGroup = "category_group"
        case spendingMinor = "spending_minor", transactionIDs = "transaction_ids"
    }
}

public struct APISpendingReport: Decodable, Equatable, Sendable {
    public let startDate: String
    public let endDate: String
    public let currencyCode: String
    public let totalSpendingMinor: Int64
    public let categories: [APISpendingCategoryReport]

    enum CodingKeys: String, CodingKey {
        case categories
        case startDate = "start_date", endDate = "end_date", currencyCode = "currency_code"
        case totalSpendingMinor = "total_spending_minor"
    }
}

public struct APIIncomeSpendingReport: Decodable, Equatable, Sendable {
    public let startDate: String
    public let endDate: String
    public let currencyCode: String
    public let incomeMinor: Int64
    public let spendingMinor: Int64
    public let differenceMinor: Int64
    public let savingsRate: Double?
    public let incomeTransactionIDs: [String]
    public let spendingTransactionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case startDate = "start_date", endDate = "end_date", currencyCode = "currency_code"
        case incomeMinor = "income_minor", spendingMinor = "spending_minor", differenceMinor = "difference_minor"
        case savingsRate = "savings_rate", incomeTransactionIDs = "income_transaction_ids", spendingTransactionIDs = "spending_transaction_ids"
    }
}

public struct APIForecastOccurrence: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { "\(scheduledTransactionID)-\(occurredOn)" }
    public let scheduledTransactionID: String; public let name: String; public let occurredOn: String; public let accountID: String; public let destinationAccountID: String?; public let categoryID: String?; public let amountMinor: Int64
    enum CodingKeys: String, CodingKey { case name; case scheduledTransactionID = "scheduled_transaction_id", occurredOn = "occurred_on", accountID = "account_id", destinationAccountID = "destination_account_id", categoryID = "category_id", amountMinor = "amount_minor" }
}

public struct APIForecastAccount: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { accountID }; public let accountID: String; public let name: String; public let actualBalanceMinor: Int64; public let projectedBalanceMinor: Int64
    enum CodingKeys: String, CodingKey { case name; case accountID = "account_id", actualBalanceMinor = "actual_balance_minor", projectedBalanceMinor = "projected_balance_minor" }
}

public struct APIForecast: Decodable, Equatable, Sendable {
    public let asOf: String; public let through: String; public let currencyCode: String; public let actualTotalOnBudgetMinor: Int64; public let projectedTotalOnBudgetMinor: Int64; public let lowestProjectedTotalMinor: Int64; public let accounts: [APIForecastAccount]; public let occurrences: [APIForecastOccurrence]
    enum CodingKeys: String, CodingKey { case accounts, occurrences; case asOf = "as_of", through, currencyCode = "currency_code", actualTotalOnBudgetMinor = "actual_total_on_budget_minor", projectedTotalOnBudgetMinor = "projected_total_on_budget_minor", lowestProjectedTotalMinor = "lowest_projected_total_minor" }
}

public struct APIDelegatedCategoryRule: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let categoryID: String
    public let ruleKind: String
    public let minimumMinor: Int64?
    public let maximumMinor: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case categoryID = "category_id", ruleKind = "rule_kind", minimumMinor = "minimum_minor", maximumMinor = "maximum_minor"
    }
}

public struct APIDelegatedBudget: Decodable, Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let userID: String
    public let poolCategoryID: String
    public let authorityMinor: Int64
    public let assignedMinor: Int64
    public let availableToAssignMinor: Int64
    public let allowCategoryCreation: Bool
    public let allowReallocation: Bool
    public let rules: [APIDelegatedCategoryRule]

    enum CodingKeys: String, CodingKey {
        case id, rules
        case budgetID = "budget_id", userID = "user_id", poolCategoryID = "pool_category_id"
        case authorityMinor = "authority_minor", assignedMinor = "assigned_minor", availableToAssignMinor = "available_to_assign_minor"
        case allowCategoryCreation = "allow_category_creation", allowReallocation = "allow_reallocation"
    }
}

public struct APIDelegatedRuleUpsert: Encodable, Sendable {
    public let categoryID: String; public let ruleKind: String; public let minimumMinor: Int64?; public let maximumMinor: Int64?
    public init(categoryID: String, ruleKind: String, minimumMinor: Int64? = nil, maximumMinor: Int64? = nil) { self.categoryID = categoryID; self.ruleKind = ruleKind; self.minimumMinor = minimumMinor; self.maximumMinor = maximumMinor }
    enum CodingKeys: String, CodingKey { case categoryID = "category_id", ruleKind = "rule_kind", minimumMinor = "minimum_minor", maximumMinor = "maximum_minor" }
}

public struct APIDelegatedBudgetUpsert: Encodable, Sendable {
    public let userID: String; public let poolCategoryID: String; public let authorityMinor: Int64; public let allowCategoryCreation: Bool; public let allowReallocation: Bool; public let expectedAllocationVersion: Int?; public let rules: [APIDelegatedRuleUpsert]
    public init(userID: String, poolCategoryID: String, authorityMinor: Int64, allowCategoryCreation: Bool, allowReallocation: Bool, expectedAllocationVersion: Int? = nil, rules: [APIDelegatedRuleUpsert] = []) { self.userID = userID; self.poolCategoryID = poolCategoryID; self.authorityMinor = authorityMinor; self.allowCategoryCreation = allowCategoryCreation; self.allowReallocation = allowReallocation; self.expectedAllocationVersion = expectedAllocationVersion; self.rules = rules }
    enum CodingKeys: String, CodingKey { case userID = "user_id", poolCategoryID = "pool_category_id", authorityMinor = "authority_minor", allowCategoryCreation = "allow_category_creation", allowReallocation = "allow_reallocation", expectedAllocationVersion = "expected_allocation_version", rules }
}

struct APICategoryDelegationUpdate: Encodable { let delegatedUserID: String?; enum CodingKeys: String, CodingKey { case delegatedUserID = "delegated_user_id" } }

public struct APISmartFundingProposal: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { categoryID }
    public let categoryID: String
    public let categoryName: String
    public let amountMinor: Int64
    public let beforeAvailableMinor: Int64
    public let afterAvailableMinor: Int64
    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id", categoryName = "category_name", amountMinor = "amount_minor"
        case beforeAvailableMinor = "before_available_minor", afterAvailableMinor = "after_available_minor"
    }
}

public struct APISmartFundingPreview: Decodable, Equatable, Sendable {
    public let month: String; public let currencyCode: String
    public let beforeReadyToAssignMinor: Int64; public let proposedMinor: Int64; public let afterReadyToAssignMinor: Int64
    public let allocationVersion: Int; public let proposals: [APISmartFundingProposal]
    enum CodingKeys: String, CodingKey {
        case month, proposals
        case currencyCode = "currency_code", beforeReadyToAssignMinor = "before_ready_to_assign_minor"
        case proposedMinor = "proposed_minor", afterReadyToAssignMinor = "after_ready_to_assign_minor", allocationVersion = "allocation_version"
    }
}

struct APISmartFundingCommit: Encodable {
    let month: String; let expectedAllocationVersion: Int
    enum CodingKeys: String, CodingKey { case month; case expectedAllocationVersion = "expected_allocation_version" }
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
    public let targetType: String?
    public let targetAmountMinor: Int64?
    public let targetDate: String?
    public let recommendedContributionMinor: Int64?
    public let underfundedMinor: Int64?
    public let cashOverspentMinor: Int64?
    public let creditOverspentMinor: Int64?
    public let fundedCreditSpendingMinor: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case categoryID = "category_id"
        case assignedMinor = "assigned_minor"
        case activityMinor = "activity_minor"
        case carriedAvailableMinor = "carried_available_minor"
        case availableMinor = "available_minor"
        case isOverspent = "is_overspent"
        case targetType = "target_type", targetAmountMinor = "target_amount_minor", targetDate = "target_date"
        case recommendedContributionMinor = "recommended_contribution_minor", underfundedMinor = "underfunded_minor"
        case cashOverspentMinor = "cash_overspent_minor", creditOverspentMinor = "credit_overspent_minor", fundedCreditSpendingMinor = "funded_credit_spending_minor"
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

public struct APIFinancialRequestDecision: Encodable, Sendable {
    public let decision: String; public let expectedRequestVersion: Int; public let approvedAmountMinor: Int64?; public let sourceCategoryID: String?; public let note: String
    public init(decision: String, expectedRequestVersion: Int, approvedAmountMinor: Int64? = nil, sourceCategoryID: String? = nil, note: String = "") { self.decision = decision; self.expectedRequestVersion = expectedRequestVersion; self.approvedAmountMinor = approvedAmountMinor; self.sourceCategoryID = sourceCategoryID; self.note = note }
    enum CodingKeys: String, CodingKey { case decision, note; case expectedRequestVersion = "expected_request_version", approvedAmountMinor = "approved_amount_minor", sourceCategoryID = "source_category_id" }
}

struct APIFinancialRequestCancel: Encodable { let expectedRequestVersion: Int; let note: String; enum CodingKeys: String, CodingKey { case expectedRequestVersion = "expected_request_version", note } }

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
    public let flag: String?
    public let tags: [String]
    public let attachmentMetadata: [[String: String]]

    public init(
        accountID: String,
        categoryID: String?,
        amountMinor: Int64,
        occurredOn: String,
        payeeName: String,
        memo: String = "",
        isCleared: Bool = false,
        splits: [APITransactionSplitCreate] = [],
        flag: String? = nil,
        tags: [String] = [],
        attachmentMetadata: [[String: String]] = []
    ) {
        self.accountID = accountID
        self.categoryID = categoryID
        self.amountMinor = amountMinor
        self.occurredOn = occurredOn
        self.payeeName = payeeName
        self.memo = memo
        self.isCleared = isCleared
        self.splits = splits
        self.flag = flag
        self.tags = tags
        self.attachmentMetadata = attachmentMetadata
    }

    enum CodingKeys: String, CodingKey {
        case memo, splits, flag, tags
        case accountID = "account_id"
        case categoryID = "category_id"
        case amountMinor = "amount_minor"
        case occurredOn = "occurred_on"
        case payeeName = "payee_name"
        case isCleared = "is_cleared"
        case attachmentMetadata = "attachment_metadata"
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
