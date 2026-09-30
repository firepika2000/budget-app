import Foundation

public struct LocalAuthorityIdentity: Equatable, Sendable {
    public let householdID: String
    public let householdName: String
    public let ownerUserID: String
    public let ownerDisplayName: String
    public let budgetID: String
    public let budgetName: String
    public let currencyCode: String

    public init(householdID: String, householdName: String, ownerUserID: String,
                ownerDisplayName: String, budgetID: String, budgetName: String,
                currencyCode: String) {
        self.householdID = householdID; self.householdName = householdName
        self.ownerUserID = ownerUserID; self.ownerDisplayName = ownerDisplayName
        self.budgetID = budgetID; self.budgetName = budgetName; self.currencyCode = currencyCode
    }
}

public struct LocalAccountRecord: Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let name: String
    public let kind: String
    public let isOnBudget: Bool
    public let isClosed: Bool
    public let openingBalanceMinor: Int64
    public let createdAt: String

    public init(id: String, budgetID: String, name: String, kind: String, isOnBudget: Bool,
                isClosed: Bool = false, openingBalanceMinor: Int64, createdAt: String) {
        self.id = id; self.budgetID = budgetID; self.name = name; self.kind = kind
        self.isOnBudget = isOnBudget; self.isClosed = isClosed
        self.openingBalanceMinor = openingBalanceMinor; self.createdAt = createdAt
    }
}

public struct LocalCategoryGroupRecord: Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let name: String
    public let sortOrder: Int64
    public let isArchived: Bool

    public init(id: String, budgetID: String, name: String, sortOrder: Int64, isArchived: Bool = false) {
        self.id = id; self.budgetID = budgetID; self.name = name
        self.sortOrder = sortOrder; self.isArchived = isArchived
    }
}

public struct LocalCategoryRecord: Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let groupID: String
    public let name: String
    public let delegatedUserID: String?
    public let isArchived: Bool
    public let sortOrder: Int64

    public init(id: String, budgetID: String, groupID: String, name: String,
                delegatedUserID: String? = nil, isArchived: Bool = false, sortOrder: Int64) {
        self.id = id; self.budgetID = budgetID; self.groupID = groupID; self.name = name
        self.delegatedUserID = delegatedUserID; self.isArchived = isArchived; self.sortOrder = sortOrder
    }
}

public struct LocalPayeeRecord: Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let name: String
    public let normalizedName: String
    public let defaultCategoryID: String?
    public let isArchived: Bool

    public init(id: String, budgetID: String, name: String, normalizedName: String,
                defaultCategoryID: String? = nil, isArchived: Bool = false) {
        self.id = id; self.budgetID = budgetID; self.name = name
        self.normalizedName = normalizedName; self.defaultCategoryID = defaultCategoryID
        self.isArchived = isArchived
    }
}

public struct LocalPayeeAliasRecord: Equatable, Sendable {
    public let id: String; public let payeeID: String; public let displayName: String
    public let normalizedName: String
    public init(id: String, payeeID: String, displayName: String, normalizedName: String) {
        self.id = id; self.payeeID = payeeID; self.displayName = displayName
        self.normalizedName = normalizedName
    }
}

public struct LocalTransactionSplitRecord: Equatable, Sendable {
    public let id: String
    public let categoryID: String
    public let amountMinor: Int64
    public let memo: String

    public init(id: String, categoryID: String, amountMinor: Int64, memo: String = "") {
        self.id = id; self.categoryID = categoryID; self.amountMinor = amountMinor; self.memo = memo
    }
}

public struct LocalTransactionRecord: Equatable, Sendable {
    public let id: String
    public let budgetID: String
    public let accountID: String
    public let payeeID: String?
    public let payeeName: String
    public let amountMinor: Int64
    public let occurredOn: String
    public let memo: String
    public let isCleared: Bool
    public let isReconciled: Bool
    public let status: String
    public let transferID: String?
    public let flag: String?
    public let tags: [String]
    public let financialClassification: String?
    public let voidReason: String?
    public let reversalOfTransactionID: String?
    public let reversalTransactionID: String?
    public let createdByUserID: String
    public let createdAt: String
    public let splits: [LocalTransactionSplitRecord]

    public init(id: String, budgetID: String, accountID: String, payeeID: String? = nil,
                payeeName: String = "",
                amountMinor: Int64, occurredOn: String, memo: String = "", isCleared: Bool = false,
                isReconciled: Bool = false, status: String = "posted", transferID: String? = nil,
                flag: String? = nil, tags: [String] = [], financialClassification: String? = nil,
                voidReason: String? = nil, reversalOfTransactionID: String? = nil,
                reversalTransactionID: String? = nil,
                createdByUserID: String, createdAt: String, splits: [LocalTransactionSplitRecord]) {
        self.id = id; self.budgetID = budgetID; self.accountID = accountID; self.payeeID = payeeID
        self.payeeName = payeeName
        self.amountMinor = amountMinor; self.occurredOn = occurredOn; self.memo = memo
        self.isCleared = isCleared; self.isReconciled = isReconciled; self.status = status
        self.transferID = transferID; self.createdByUserID = createdByUserID
        self.flag = flag; self.tags = tags; self.financialClassification = financialClassification
        self.voidReason = voidReason; self.reversalOfTransactionID = reversalOfTransactionID
        self.reversalTransactionID = reversalTransactionID
        self.createdAt = createdAt; self.splits = splits
    }
}

public struct LocalAllocationRecord: Equatable, Sendable {
    public let id: String; public let operationID: String; public let budgetID: String
    public let sourceCategoryID: String?; public let categoryID: String?
    public let amountMinor: Int64; public let occurredOn: String; public let kind: String
    public let actorUserID: String; public let note: String; public let createdAt: String
    public init(id: String, operationID: String? = nil, budgetID: String,
                sourceCategoryID: String? = nil, categoryID: String?, amountMinor: Int64,
                occurredOn: String, kind: String, actorUserID: String, note: String = "", createdAt: String) {
        self.id = id; self.operationID = operationID ?? id; self.budgetID = budgetID
        self.sourceCategoryID = sourceCategoryID; self.categoryID = categoryID
        self.amountMinor = amountMinor; self.occurredOn = occurredOn; self.kind = kind
        self.actorUserID = actorUserID; self.note = note; self.createdAt = createdAt
    }
}

public struct LocalReconciliationRecord: Equatable, Sendable {
    public let id: String; public let accountID: String; public let statementDate: String
    public let statementBalanceMinor: Int64; public let adjustmentTransactionID: String?
    public let createdAt: String
    public init(id: String, accountID: String, statementDate: String, statementBalanceMinor: Int64,
                adjustmentTransactionID: String? = nil, createdAt: String) {
        self.id = id; self.accountID = accountID; self.statementDate = statementDate
        self.statementBalanceMinor = statementBalanceMinor
        self.adjustmentTransactionID = adjustmentTransactionID; self.createdAt = createdAt
    }
}

public struct LocalCategoryTargetRecord: Equatable, Sendable {
    public let categoryID: String; public let targetType: String; public let amountMinor: Int64
    public let cadence: String; public let effectiveMonth: String; public let snoozedMonth: String?
    public init(categoryID: String, targetType: String, amountMinor: Int64, cadence: String,
                effectiveMonth: String, snoozedMonth: String? = nil) {
        self.categoryID = categoryID; self.targetType = targetType; self.amountMinor = amountMinor
        self.cadence = cadence; self.effectiveMonth = effectiveMonth; self.snoozedMonth = snoozedMonth
    }
}

public struct LocalScheduleRecord: Equatable, Sendable {
    public let id: String; public let budgetID: String; public let accountID: String
    public let destinationAccountID: String?; public let categoryID: String?; public let payeeID: String?
    public let name: String; public let amountMinor: Int64; public let nextDate: String
    public let recurrenceUnit: String; public let intervalCount: Int64; public let memo: String
    public let isActive: Bool
    public init(id: String, budgetID: String, accountID: String, destinationAccountID: String? = nil,
                categoryID: String? = nil, payeeID: String? = nil, name: String, amountMinor: Int64,
                nextDate: String, recurrenceUnit: String, intervalCount: Int64, memo: String = "",
                isActive: Bool = true) {
        self.id = id; self.budgetID = budgetID; self.accountID = accountID
        self.destinationAccountID = destinationAccountID; self.categoryID = categoryID; self.payeeID = payeeID
        self.name = name; self.amountMinor = amountMinor; self.nextDate = nextDate
        self.recurrenceUnit = recurrenceUnit; self.intervalCount = intervalCount; self.memo = memo
        self.isActive = isActive
    }
}

public struct LocalAttachmentRecord: Equatable, Sendable {
    public let id: String; public let transactionID: String; public let filename: String
    public let contentType: String; public let sizeBytes: Int64; public let sha256: String
    public let objectName: String; public let createdAt: String
    public init(id: String, transactionID: String, filename: String, contentType: String,
                sizeBytes: Int64, sha256: String, objectName: String, createdAt: String) {
        self.id = id; self.transactionID = transactionID; self.filename = filename
        self.contentType = contentType; self.sizeBytes = sizeBytes; self.sha256 = sha256
        self.objectName = objectName; self.createdAt = createdAt
    }
}

public struct LocalAuthoritySnapshot: Equatable, Sendable {
    public let identity: LocalAuthorityIdentity
    public let accounts: [LocalAccountRecord]
    public let groups: [LocalCategoryGroupRecord]
    public let categories: [LocalCategoryRecord]
    public let payees: [LocalPayeeRecord]
    public let payeeAliases: [LocalPayeeAliasRecord]
    public let transactions: [LocalTransactionRecord]
    public let allocations: [LocalAllocationRecord]
    public let reconciliations: [LocalReconciliationRecord]
    public let targets: [LocalCategoryTargetRecord]
    public let schedules: [LocalScheduleRecord]
    public let attachments: [LocalAttachmentRecord]

    public init(identity: LocalAuthorityIdentity, accounts: [LocalAccountRecord],
                groups: [LocalCategoryGroupRecord], categories: [LocalCategoryRecord],
                payees: [LocalPayeeRecord], payeeAliases: [LocalPayeeAliasRecord],
                transactions: [LocalTransactionRecord], allocations: [LocalAllocationRecord],
                reconciliations: [LocalReconciliationRecord], targets: [LocalCategoryTargetRecord],
                schedules: [LocalScheduleRecord], attachments: [LocalAttachmentRecord]) {
        self.identity = identity; self.accounts = accounts; self.groups = groups
        self.categories = categories; self.payees = payees; self.payeeAliases = payeeAliases
        self.transactions = transactions; self.allocations = allocations
        self.reconciliations = reconciliations; self.targets = targets
        self.schedules = schedules; self.attachments = attachments
    }
}

/// Typed persistence boundary for a single-writer Local Device authority.
///
/// Financial commands must be validated by the shared application-service layer before reaching
/// this store. This type converts complete, validated aggregates into atomic SQLite transactions;
/// it never computes balances, category activity, card reserves, or other accounting consequences.
public actor LocalAuthorityStore {
    private let database: LocalDatabase

    public init(fileURL: URL) throws {
        database = try LocalDatabase(fileURL: fileURL)
    }

    public func bootstrap(_ identity: LocalAuthorityIdentity, createdAt: String) async throws {
        guard !identity.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.budgetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identity.currencyCode.count == 3 else {
            throw LocalStorageError.operationFailed("Local authority identity is invalid")
        }
        try await database.transaction([
            .init("INSERT INTO households(id,name,created_at) VALUES (?,?,?)", values: [.text(identity.householdID), .text(identity.householdName), .text(createdAt)]),
            .init("INSERT INTO users(id,display_name,email) VALUES (?,?,NULL)", values: [.text(identity.ownerUserID), .text(identity.ownerDisplayName)]),
            .init("INSERT INTO memberships(household_id,user_id,role,is_active) VALUES (?,?,?,1)", values: [.text(identity.householdID), .text(identity.ownerUserID), .text("owner")]),
            .init("INSERT INTO budgets(id,household_id,name,currency_code,cash_rollover_policy,created_at) VALUES (?,?,?,?,?,?)", values: [.text(identity.budgetID), .text(identity.householdID), .text(identity.budgetName), .text(identity.currencyCode.uppercased()), .text("carry_category_deficit"), .text(createdAt)])
        ])
    }

    public func insertAccount(_ value: LocalAccountRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO accounts(id,budget_id,name,kind,is_on_budget,is_closed,opening_balance_minor,created_at) VALUES (?,?,?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), .text(value.name), .text(value.kind),
                     .integer(value.isOnBudget ? 1 : 0), .integer(value.isClosed ? 1 : 0),
                     .integer(value.openingBalanceMinor), .text(value.createdAt)]
        ))
    }

    public func updateAccount(_ value: LocalAccountRecord) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "UPDATE accounts SET name=?,kind=?,is_on_budget=?,is_closed=? WHERE id=? AND budget_id=?",
            values: [.text(value.name), .text(value.kind), .integer(value.isOnBudget ? 1 : 0),
                     .integer(value.isClosed ? 1 : 0), .text(value.id), .text(value.budgetID)]
        ))
        try requireOneChange(changes, record: "account")
    }

    public func insertCategoryGroup(_ value: LocalCategoryGroupRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO category_groups(id,budget_id,name,sort_order,is_archived) VALUES (?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), .text(value.name), .integer(value.sortOrder), .integer(value.isArchived ? 1 : 0)]
        ))
    }

    public func updateCategoryGroup(_ value: LocalCategoryGroupRecord) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "UPDATE category_groups SET name=?,sort_order=?,is_archived=? WHERE id=? AND budget_id=?",
            values: [.text(value.name), .integer(value.sortOrder), .integer(value.isArchived ? 1 : 0), .text(value.id), .text(value.budgetID)]
        ))
        try requireOneChange(changes, record: "category group")
    }

    public func insertCategory(_ value: LocalCategoryRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO categories(id,budget_id,group_id,name,delegated_user_id,is_archived,sort_order) VALUES (?,?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), .text(value.groupID), .text(value.name), optionalText(value.delegatedUserID), .integer(value.isArchived ? 1 : 0), .integer(value.sortOrder)]
        ))
    }

    public func updateCategory(_ value: LocalCategoryRecord) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "UPDATE categories SET group_id=?,name=?,delegated_user_id=?,is_archived=?,sort_order=? WHERE id=? AND budget_id=?",
            values: [.text(value.groupID), .text(value.name), optionalText(value.delegatedUserID),
                     .integer(value.isArchived ? 1 : 0), .integer(value.sortOrder), .text(value.id), .text(value.budgetID)]
        ))
        try requireOneChange(changes, record: "category")
    }

    public func insertPayee(_ value: LocalPayeeRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO payees(id,budget_id,name,normalized_name,default_category_id,is_archived) VALUES (?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), .text(value.name), .text(value.normalizedName), optionalText(value.defaultCategoryID), .integer(value.isArchived ? 1 : 0)]
        ))
    }

    public func updatePayee(_ value: LocalPayeeRecord) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "UPDATE payees SET name=?,normalized_name=?,default_category_id=?,is_archived=? WHERE id=? AND budget_id=?",
            values: [.text(value.name), .text(value.normalizedName), optionalText(value.defaultCategoryID),
                     .integer(value.isArchived ? 1 : 0), .text(value.id), .text(value.budgetID)]
        ))
        try requireOneChange(changes, record: "payee")
    }

    public func insertPayeeAlias(_ value: LocalPayeeAliasRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO payee_aliases(id,payee_id,display_name,normalized_name) VALUES (?,?,?,?)",
            values: [.text(value.id), .text(value.payeeID), .text(value.displayName), .text(value.normalizedName)]
        ))
    }

    public func deletePayeeAlias(id: String, payeeID: String) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "DELETE FROM payee_aliases WHERE id=? AND payee_id=?", values: [.text(id), .text(payeeID)]
        ))
        try requireOneChange(changes, record: "payee alias")
    }

    public func insertTransaction(_ value: LocalTransactionRecord) async throws {
        try validateTransaction(value)
        try await database.transaction([transactionInsert(value)] + splitInserts(value))
    }

    public func replaceTransaction(_ value: LocalTransactionRecord) async throws {
        try validateTransaction(value)
        let existing = try await database.rows(.init(
            "SELECT id FROM transactions WHERE id=? AND budget_id=?", values: [.text(value.id), .text(value.budgetID)]
        ))
        guard existing.count == 1 else { throw LocalStorageError.operationFailed("Local transaction was not found") }
        let update = LocalSQLStatement(
            "UPDATE transactions SET account_id=?,payee_id=?,amount_minor=?,occurred_on=?,memo=?,is_cleared=?,is_reconciled=?,status=?,transfer_id=?,payee_name=?,flag=?,tags_json=?,financial_classification=?,void_reason=?,reversal_of_transaction_id=?,reversal_transaction_id=? WHERE id=? AND budget_id=?",
            values: [.text(value.accountID), optionalText(value.payeeID), .integer(value.amountMinor),
                     .text(value.occurredOn), .text(value.memo), .integer(value.isCleared ? 1 : 0),
                     .integer(value.isReconciled ? 1 : 0), .text(value.status), optionalText(value.transferID),
                     .text(value.payeeName), optionalText(value.flag), .text(json(value.tags)),
                     optionalText(value.financialClassification), optionalText(value.voidReason),
                     optionalText(value.reversalOfTransactionID), optionalText(value.reversalTransactionID),
                     .text(value.id), .text(value.budgetID)]
        )
        try await database.transaction([update, .init("DELETE FROM transaction_splits WHERE transaction_id=?", values: [.text(value.id)])] + splitInserts(value))
    }

    public func deleteTransaction(id: String, budgetID: String) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "DELETE FROM transactions WHERE id=? AND budget_id=?", values: [.text(id), .text(budgetID)]
        ))
        try requireOneChange(changes, record: "transaction")
    }

    public func insertAllocation(_ value: LocalAllocationRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO allocation_operations(id,budget_id,category_id,amount_minor,occurred_on,kind,actor_user_id,note,created_at,operation_id,source_category_id) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), optionalText(value.categoryID), .integer(value.amountMinor),
                     .text(value.occurredOn), .text(value.kind), .text(value.actorUserID), .text(value.note), .text(value.createdAt),
                     .text(value.operationID), optionalText(value.sourceCategoryID)]
        ))
    }

    public func insertReconciliation(_ value: LocalReconciliationRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO reconciliations(id,account_id,statement_date,statement_balance_minor,adjustment_transaction_id,created_at) VALUES (?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.accountID), .text(value.statementDate),
                     .integer(value.statementBalanceMinor), optionalText(value.adjustmentTransactionID), .text(value.createdAt)]
        ))
    }

    public func upsertTarget(_ value: LocalCategoryTargetRecord) async throws {
        try await database.execute(.init(
            "INSERT INTO category_targets(category_id,target_type,amount_minor,cadence,effective_month,snoozed_month) VALUES (?,?,?,?,?,?) ON CONFLICT(category_id) DO UPDATE SET target_type=excluded.target_type,amount_minor=excluded.amount_minor,cadence=excluded.cadence,effective_month=excluded.effective_month,snoozed_month=excluded.snoozed_month",
            values: [.text(value.categoryID), .text(value.targetType), .integer(value.amountMinor),
                     .text(value.cadence), .text(value.effectiveMonth), optionalText(value.snoozedMonth)]
        ))
    }

    public func deleteTarget(categoryID: String) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "DELETE FROM category_targets WHERE category_id=?", values: [.text(categoryID)]
        ))
        try requireOneChange(changes, record: "category target")
    }

    public func upsertSchedule(_ value: LocalScheduleRecord) async throws {
        guard value.intervalCount > 0 else { throw LocalStorageError.operationFailed("Schedule interval must be positive") }
        try await database.execute(.init(
            "INSERT INTO scheduled_transactions(id,budget_id,account_id,destination_account_id,category_id,payee_id,name,amount_minor,next_date,recurrence_unit,interval_count,memo,is_active) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,destination_account_id=excluded.destination_account_id,category_id=excluded.category_id,payee_id=excluded.payee_id,name=excluded.name,amount_minor=excluded.amount_minor,next_date=excluded.next_date,recurrence_unit=excluded.recurrence_unit,interval_count=excluded.interval_count,memo=excluded.memo,is_active=excluded.is_active",
            values: [.text(value.id), .text(value.budgetID), .text(value.accountID), optionalText(value.destinationAccountID),
                     optionalText(value.categoryID), optionalText(value.payeeID), .text(value.name), .integer(value.amountMinor),
                     .text(value.nextDate), .text(value.recurrenceUnit), .integer(value.intervalCount), .text(value.memo),
                     .integer(value.isActive ? 1 : 0)]
        ))
    }

    public func deleteSchedule(id: String, budgetID: String) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "DELETE FROM scheduled_transactions WHERE id=? AND budget_id=?", values: [.text(id), .text(budgetID)]
        ))
        try requireOneChange(changes, record: "schedule")
    }

    /// Records metadata only after the encrypted object has been durably published by the caller.
    public func insertAttachment(_ value: LocalAttachmentRecord) async throws {
        guard value.sizeBytes >= 0 else { throw LocalStorageError.operationFailed("Attachment size is invalid") }
        try await database.execute(.init(
            "INSERT INTO attachments(id,transaction_id,filename,content_type,size_bytes,sha256,object_name,created_at) VALUES (?,?,?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.transactionID), .text(value.filename), .text(value.contentType),
                     .integer(value.sizeBytes), .text(value.sha256), .text(value.objectName), .text(value.createdAt)]
        ))
    }

    /// Removes metadata only after the encrypted object has entered the caller's recoverable tombstone lifecycle.
    public func deleteAttachment(id: String, transactionID: String) async throws {
        let changes = try await database.executeReturningChanges(.init(
            "DELETE FROM attachments WHERE id=? AND transaction_id=?", values: [.text(id), .text(transactionID)]
        ))
        try requireOneChange(changes, record: "attachment")
    }

    public func snapshot(budgetID: String) async throws -> LocalAuthoritySnapshot {
        let identityRows = try await database.rows(.init(
            "SELECT h.id AS household_id,h.name AS household_name,u.id AS owner_user_id,u.display_name AS owner_display_name,b.id AS budget_id,b.name AS budget_name,b.currency_code FROM budgets b JOIN households h ON h.id=b.household_id JOIN memberships m ON m.household_id=h.id AND m.role='owner' AND m.is_active=1 JOIN users u ON u.id=m.user_id WHERE b.id=? ORDER BY u.id LIMIT 1",
            values: [.text(budgetID)]
        ))
        guard let row = identityRows.first else { throw LocalStorageError.recordNotFound("budget") }
        let identity = try LocalAuthorityIdentity(
            householdID: text(row, "household_id"), householdName: text(row, "household_name"),
            ownerUserID: text(row, "owner_user_id"), ownerDisplayName: text(row, "owner_display_name"),
            budgetID: text(row, "budget_id"), budgetName: text(row, "budget_name"), currencyCode: text(row, "currency_code")
        )
        let accounts = try await loadAccounts(budgetID: budgetID)
        let groups = try await loadGroups(budgetID: budgetID)
        let categories = try await loadCategories(budgetID: budgetID)
        let payees = try await loadPayees(budgetID: budgetID)
        let transactions = try await loadTransactions(budgetID: budgetID)
        let payeeAliases = try await loadPayeeAliases(payeeIDs: Set(payees.map(\.id)))
        let allocations = try await loadAllocations(budgetID: budgetID)
        let reconciliations = try await loadReconciliations(accountIDs: Set(accounts.map(\.id)))
        let targets = try await loadTargets(categoryIDs: Set(categories.map(\.id)))
        let schedules = try await loadSchedules(budgetID: budgetID)
        let attachments = try await loadAttachments(transactionIDs: Set(transactions.map(\.id)))
        return .init(identity: identity, accounts: accounts, groups: groups, categories: categories,
                     payees: payees, payeeAliases: payeeAliases, transactions: transactions, allocations: allocations,
                     reconciliations: reconciliations, targets: targets, schedules: schedules,
                     attachments: attachments)
    }

    public func integrityCheck() async throws { try await database.integrityCheck() }

    /// Atomically publishes a complete, already-validated workspace projection. This is the commit
    /// boundary used by the on-device application-service adapter: readers observe either the old
    /// authority or the new one, never a partially persisted command.
    public func replaceWorkspaceState(_ value: LocalAuthoritySnapshot) async throws {
        for transaction in value.transactions { try validateTransaction(transaction) }
        let budgetID = value.identity.budgetID
        var statements: [LocalSQLStatement] = [
            .init("DELETE FROM attachments WHERE transaction_id IN (SELECT id FROM transactions WHERE budget_id=?)", values: [.text(budgetID)]),
            .init("DELETE FROM reconciliations WHERE account_id IN (SELECT id FROM accounts WHERE budget_id=?)", values: [.text(budgetID)]),
            .init("DELETE FROM category_targets WHERE category_id IN (SELECT id FROM categories WHERE budget_id=?)", values: [.text(budgetID)]),
            .init("DELETE FROM scheduled_transactions WHERE budget_id=?", values: [.text(budgetID)]),
            .init("DELETE FROM transaction_splits WHERE transaction_id IN (SELECT id FROM transactions WHERE budget_id=?)", values: [.text(budgetID)]),
            .init("DELETE FROM transactions WHERE budget_id=?", values: [.text(budgetID)]),
            .init("DELETE FROM allocation_operations WHERE budget_id=?", values: [.text(budgetID)]),
            .init("DELETE FROM payee_aliases WHERE payee_id IN (SELECT id FROM payees WHERE budget_id=?)", values: [.text(budgetID)]),
            .init("DELETE FROM payees WHERE budget_id=?", values: [.text(budgetID)]),
            .init("DELETE FROM categories WHERE budget_id=?", values: [.text(budgetID)]),
            .init("DELETE FROM category_groups WHERE budget_id=?", values: [.text(budgetID)]),
            .init("DELETE FROM accounts WHERE budget_id=?", values: [.text(budgetID)])
        ]
        statements += value.accounts.map { item in
            .init("INSERT INTO accounts(id,budget_id,name,kind,is_on_budget,is_closed,opening_balance_minor,created_at) VALUES (?,?,?,?,?,?,?,?)", values: [.text(item.id), .text(item.budgetID), .text(item.name), .text(item.kind), .integer(item.isOnBudget ? 1 : 0), .integer(item.isClosed ? 1 : 0), .integer(item.openingBalanceMinor), .text(item.createdAt)])
        }
        statements += value.groups.map { item in
            .init("INSERT INTO category_groups(id,budget_id,name,sort_order,is_archived) VALUES (?,?,?,?,?)", values: [.text(item.id), .text(item.budgetID), .text(item.name), .integer(item.sortOrder), .integer(item.isArchived ? 1 : 0)])
        }
        statements += value.categories.map { item in
            .init("INSERT INTO categories(id,budget_id,group_id,name,delegated_user_id,is_archived,sort_order) VALUES (?,?,?,?,?,?,?)", values: [.text(item.id), .text(item.budgetID), .text(item.groupID), .text(item.name), optionalText(item.delegatedUserID), .integer(item.isArchived ? 1 : 0), .integer(item.sortOrder)])
        }
        statements += value.payees.map { item in
            .init("INSERT INTO payees(id,budget_id,name,normalized_name,default_category_id,is_archived) VALUES (?,?,?,?,?,?)", values: [.text(item.id), .text(item.budgetID), .text(item.name), .text(item.normalizedName), optionalText(item.defaultCategoryID), .integer(item.isArchived ? 1 : 0)])
        }
        statements += value.payeeAliases.map { item in
            .init("INSERT INTO payee_aliases(id,payee_id,display_name,normalized_name) VALUES (?,?,?,?)", values: [.text(item.id), .text(item.payeeID), .text(item.displayName), .text(item.normalizedName)])
        }
        for item in value.transactions { statements += [transactionInsert(item)] + splitInserts(item) }
        statements += value.allocations.map { item in
            .init("INSERT INTO allocation_operations(id,budget_id,category_id,amount_minor,occurred_on,kind,actor_user_id,note,created_at,operation_id,source_category_id) VALUES (?,?,?,?,?,?,?,?,?,?,?)", values: [.text(item.id), .text(item.budgetID), optionalText(item.categoryID), .integer(item.amountMinor), .text(item.occurredOn), .text(item.kind), .text(item.actorUserID), .text(item.note), .text(item.createdAt), .text(item.operationID), optionalText(item.sourceCategoryID)])
        }
        statements += value.reconciliations.map { item in
            .init("INSERT INTO reconciliations(id,account_id,statement_date,statement_balance_minor,adjustment_transaction_id,created_at) VALUES (?,?,?,?,?,?)", values: [.text(item.id), .text(item.accountID), .text(item.statementDate), .integer(item.statementBalanceMinor), optionalText(item.adjustmentTransactionID), .text(item.createdAt)])
        }
        statements += value.targets.map { item in
            .init("INSERT INTO category_targets(category_id,target_type,amount_minor,cadence,effective_month,snoozed_month) VALUES (?,?,?,?,?,?)", values: [.text(item.categoryID), .text(item.targetType), .integer(item.amountMinor), .text(item.cadence), .text(item.effectiveMonth), optionalText(item.snoozedMonth)])
        }
        statements += value.schedules.map { item in
            .init("INSERT INTO scheduled_transactions(id,budget_id,account_id,destination_account_id,category_id,payee_id,name,amount_minor,next_date,recurrence_unit,interval_count,memo,is_active) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", values: [.text(item.id), .text(item.budgetID), .text(item.accountID), optionalText(item.destinationAccountID), optionalText(item.categoryID), optionalText(item.payeeID), .text(item.name), .integer(item.amountMinor), .text(item.nextDate), .text(item.recurrenceUnit), .integer(item.intervalCount), .text(item.memo), .integer(item.isActive ? 1 : 0)])
        }
        statements += value.attachments.map { item in
            .init("INSERT INTO attachments(id,transaction_id,filename,content_type,size_bytes,sha256,object_name,created_at) VALUES (?,?,?,?,?,?,?,?)", values: [.text(item.id), .text(item.transactionID), .text(item.filename), .text(item.contentType), .integer(item.sizeBytes), .text(item.sha256), .text(item.objectName), .text(item.createdAt)])
        }
        try await database.transaction(statements)
    }

    private func loadAccounts(budgetID: String) async throws -> [LocalAccountRecord] {
        try await database.rows(.init("SELECT * FROM accounts WHERE budget_id=? ORDER BY created_at,id", values: [.text(budgetID)])).map {
            try .init(id: text($0, "id"), budgetID: text($0, "budget_id"), name: text($0, "name"), kind: text($0, "kind"), isOnBudget: bool($0, "is_on_budget"), isClosed: bool($0, "is_closed"), openingBalanceMinor: integer($0, "opening_balance_minor"), createdAt: text($0, "created_at"))
        }
    }

    private func loadGroups(budgetID: String) async throws -> [LocalCategoryGroupRecord] {
        try await database.rows(.init("SELECT * FROM category_groups WHERE budget_id=? ORDER BY sort_order,id", values: [.text(budgetID)])).map {
            try .init(id: text($0, "id"), budgetID: text($0, "budget_id"), name: text($0, "name"), sortOrder: integer($0, "sort_order"), isArchived: bool($0, "is_archived"))
        }
    }

    private func loadCategories(budgetID: String) async throws -> [LocalCategoryRecord] {
        try await database.rows(.init("SELECT * FROM categories WHERE budget_id=? ORDER BY sort_order,id", values: [.text(budgetID)])).map {
            try .init(id: text($0, "id"), budgetID: text($0, "budget_id"), groupID: text($0, "group_id"), name: text($0, "name"), delegatedUserID: optionalText($0, "delegated_user_id"), isArchived: bool($0, "is_archived"), sortOrder: integer($0, "sort_order"))
        }
    }

    private func loadPayees(budgetID: String) async throws -> [LocalPayeeRecord] {
        try await database.rows(.init("SELECT * FROM payees WHERE budget_id=? ORDER BY normalized_name,id", values: [.text(budgetID)])).map {
            try .init(id: text($0, "id"), budgetID: text($0, "budget_id"), name: text($0, "name"), normalizedName: text($0, "normalized_name"), defaultCategoryID: optionalText($0, "default_category_id"), isArchived: bool($0, "is_archived"))
        }
    }

    private func loadPayeeAliases(payeeIDs: Set<String>) async throws -> [LocalPayeeAliasRecord] {
        guard !payeeIDs.isEmpty else { return [] }
        let rows = try await database.rows(.init("SELECT * FROM payee_aliases ORDER BY normalized_name,id"))
        return try rows.compactMap {
            let payeeID = try text($0, "payee_id")
            guard payeeIDs.contains(payeeID) else { return nil }
            return try .init(id: text($0, "id"), payeeID: payeeID, displayName: text($0, "display_name"), normalizedName: text($0, "normalized_name"))
        }
    }

    private func loadTransactions(budgetID: String) async throws -> [LocalTransactionRecord] {
        let rows = try await database.rows(.init("SELECT * FROM transactions WHERE budget_id=? ORDER BY occurred_on,id", values: [.text(budgetID)]))
        var result: [LocalTransactionRecord] = []
        for row in rows {
            let transactionID = try text(row, "id")
            let splits = try await database.rows(.init("SELECT * FROM transaction_splits WHERE transaction_id=? ORDER BY id", values: [.text(transactionID)])).map {
                try LocalTransactionSplitRecord(id: text($0, "id"), categoryID: text($0, "category_id"), amountMinor: integer($0, "amount_minor"), memo: text($0, "memo"))
            }
            result.append(try .init(id: transactionID, budgetID: text(row, "budget_id"), accountID: text(row, "account_id"), payeeID: optionalText(row, "payee_id"), payeeName: text(row, "payee_name"), amountMinor: integer(row, "amount_minor"), occurredOn: text(row, "occurred_on"), memo: text(row, "memo"), isCleared: bool(row, "is_cleared"), isReconciled: bool(row, "is_reconciled"), status: text(row, "status"), transferID: optionalText(row, "transfer_id"), flag: optionalText(row, "flag"), tags: stringArray(row, "tags_json"), financialClassification: optionalText(row, "financial_classification"), voidReason: optionalText(row, "void_reason"), reversalOfTransactionID: optionalText(row, "reversal_of_transaction_id"), reversalTransactionID: optionalText(row, "reversal_transaction_id"), createdByUserID: text(row, "created_by_user_id"), createdAt: text(row, "created_at"), splits: splits))
        }
        return result
    }

    private func loadAllocations(budgetID: String) async throws -> [LocalAllocationRecord] {
        try await database.rows(.init("SELECT * FROM allocation_operations WHERE budget_id=? ORDER BY occurred_on,id", values: [.text(budgetID)])).map {
            try .init(id: text($0, "id"), operationID: text($0, "operation_id"), budgetID: text($0, "budget_id"), sourceCategoryID: optionalText($0, "source_category_id"), categoryID: optionalText($0, "category_id"), amountMinor: integer($0, "amount_minor"), occurredOn: text($0, "occurred_on"), kind: text($0, "kind"), actorUserID: text($0, "actor_user_id"), note: text($0, "note"), createdAt: text($0, "created_at"))
        }
    }

    private func loadReconciliations(accountIDs: Set<String>) async throws -> [LocalReconciliationRecord] {
        guard !accountIDs.isEmpty else { return [] }
        let rows = try await database.rows(.init("SELECT * FROM reconciliations ORDER BY statement_date,id"))
        return try rows.compactMap {
            let accountID = try text($0, "account_id")
            guard accountIDs.contains(accountID) else { return nil }
            return try .init(id: text($0, "id"), accountID: accountID, statementDate: text($0, "statement_date"), statementBalanceMinor: integer($0, "statement_balance_minor"), adjustmentTransactionID: optionalText($0, "adjustment_transaction_id"), createdAt: text($0, "created_at"))
        }
    }

    private func loadTargets(categoryIDs: Set<String>) async throws -> [LocalCategoryTargetRecord] {
        guard !categoryIDs.isEmpty else { return [] }
        let rows = try await database.rows(.init("SELECT * FROM category_targets ORDER BY category_id"))
        return try rows.compactMap {
            let categoryID = try text($0, "category_id")
            guard categoryIDs.contains(categoryID) else { return nil }
            return try .init(categoryID: categoryID, targetType: text($0, "target_type"), amountMinor: integer($0, "amount_minor"), cadence: text($0, "cadence"), effectiveMonth: text($0, "effective_month"), snoozedMonth: optionalText($0, "snoozed_month"))
        }
    }

    private func loadSchedules(budgetID: String) async throws -> [LocalScheduleRecord] {
        try await database.rows(.init("SELECT * FROM scheduled_transactions WHERE budget_id=? ORDER BY next_date,id", values: [.text(budgetID)])).map {
            try .init(id: text($0, "id"), budgetID: text($0, "budget_id"), accountID: text($0, "account_id"), destinationAccountID: optionalText($0, "destination_account_id"), categoryID: optionalText($0, "category_id"), payeeID: optionalText($0, "payee_id"), name: text($0, "name"), amountMinor: integer($0, "amount_minor"), nextDate: text($0, "next_date"), recurrenceUnit: text($0, "recurrence_unit"), intervalCount: integer($0, "interval_count"), memo: text($0, "memo"), isActive: bool($0, "is_active"))
        }
    }

    private func loadAttachments(transactionIDs: Set<String>) async throws -> [LocalAttachmentRecord] {
        guard !transactionIDs.isEmpty else { return [] }
        let rows = try await database.rows(.init("SELECT * FROM attachments ORDER BY created_at,id"))
        return try rows.compactMap {
            let transactionID = try text($0, "transaction_id")
            guard transactionIDs.contains(transactionID) else { return nil }
            return try .init(id: text($0, "id"), transactionID: transactionID, filename: text($0, "filename"), contentType: text($0, "content_type"), sizeBytes: integer($0, "size_bytes"), sha256: text($0, "sha256"), objectName: text($0, "object_name"), createdAt: text($0, "created_at"))
        }
    }

    private func validateTransaction(_ value: LocalTransactionRecord) throws {
        var total: Int64 = 0
        var splitIDs = Set<String>()
        for split in value.splits {
            guard splitIDs.insert(split.id).inserted else {
                throw LocalStorageError.operationFailed("Transaction split identifiers must be unique")
            }
            let (next, overflow) = total.addingReportingOverflow(split.amountMinor)
            guard !overflow else { throw LocalStorageError.operationFailed("Transaction split total overflow") }
            total = next
        }
        guard value.splits.isEmpty || total == value.amountMinor else {
            throw LocalStorageError.operationFailed("Transaction splits must equal the transaction amount")
        }
    }

    private func transactionInsert(_ value: LocalTransactionRecord) -> LocalSQLStatement {
        .init(
            "INSERT INTO transactions(id,budget_id,account_id,payee_id,amount_minor,occurred_on,memo,is_cleared,is_reconciled,status,transfer_id,created_by_user_id,created_at,payee_name,flag,tags_json,financial_classification,void_reason,reversal_of_transaction_id,reversal_transaction_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), .text(value.accountID), optionalText(value.payeeID),
                     .integer(value.amountMinor), .text(value.occurredOn), .text(value.memo),
                     .integer(value.isCleared ? 1 : 0), .integer(value.isReconciled ? 1 : 0),
                     .text(value.status), optionalText(value.transferID), .text(value.createdByUserID), .text(value.createdAt),
                     .text(value.payeeName), optionalText(value.flag), .text(json(value.tags)),
                     optionalText(value.financialClassification), optionalText(value.voidReason),
                     optionalText(value.reversalOfTransactionID), optionalText(value.reversalTransactionID)]
        )
    }

    private func splitInserts(_ value: LocalTransactionRecord) -> [LocalSQLStatement] {
        value.splits.map { split in
            .init("INSERT INTO transaction_splits(id,transaction_id,category_id,amount_minor,memo) VALUES (?,?,?,?,?)",
                  values: [.text(split.id), .text(value.id), .text(split.categoryID), .integer(split.amountMinor), .text(split.memo)])
        }
    }

    private func requireOneChange(_ changes: Int64, record: String) throws {
        guard changes == 1 else { throw LocalStorageError.operationFailed("Local \(record) was not found") }
    }

    private func optionalText(_ value: String?) -> LocalSQLiteValue { value.map(LocalSQLiteValue.text) ?? .null }
    private func json(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
    private func stringArray(_ row: LocalSQLiteRow, _ key: String) -> [String] {
        guard case let .text(value)? = row[key], let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    private func text(_ row: LocalSQLiteRow, _ key: String) throws -> String {
        guard case let .text(value)? = row[key] else { throw LocalStorageError.operationFailed("Invalid local value for \(key)") }
        return value
    }
    private func optionalText(_ row: LocalSQLiteRow, _ key: String) -> String? {
        guard case let .text(value)? = row[key] else { return nil }
        return value
    }
    private func integer(_ row: LocalSQLiteRow, _ key: String) throws -> Int64 {
        guard case let .integer(value)? = row[key] else { throw LocalStorageError.operationFailed("Invalid local value for \(key)") }
        return value
    }
    private func bool(_ row: LocalSQLiteRow, _ key: String) throws -> Bool { try integer(row, key) != 0 }
}
