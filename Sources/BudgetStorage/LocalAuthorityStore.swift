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
    public let amountMinor: Int64
    public let occurredOn: String
    public let memo: String
    public let isCleared: Bool
    public let isReconciled: Bool
    public let status: String
    public let transferID: String?
    public let createdByUserID: String
    public let createdAt: String
    public let splits: [LocalTransactionSplitRecord]

    public init(id: String, budgetID: String, accountID: String, payeeID: String? = nil,
                amountMinor: Int64, occurredOn: String, memo: String = "", isCleared: Bool = false,
                isReconciled: Bool = false, status: String = "posted", transferID: String? = nil,
                createdByUserID: String, createdAt: String, splits: [LocalTransactionSplitRecord]) {
        self.id = id; self.budgetID = budgetID; self.accountID = accountID; self.payeeID = payeeID
        self.amountMinor = amountMinor; self.occurredOn = occurredOn; self.memo = memo
        self.isCleared = isCleared; self.isReconciled = isReconciled; self.status = status
        self.transferID = transferID; self.createdByUserID = createdByUserID
        self.createdAt = createdAt; self.splits = splits
    }
}

public struct LocalAuthoritySnapshot: Equatable, Sendable {
    public let identity: LocalAuthorityIdentity
    public let accounts: [LocalAccountRecord]
    public let groups: [LocalCategoryGroupRecord]
    public let categories: [LocalCategoryRecord]
    public let payees: [LocalPayeeRecord]
    public let transactions: [LocalTransactionRecord]
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
            "UPDATE transactions SET account_id=?,payee_id=?,amount_minor=?,occurred_on=?,memo=?,is_cleared=?,is_reconciled=?,status=?,transfer_id=? WHERE id=? AND budget_id=?",
            values: [.text(value.accountID), optionalText(value.payeeID), .integer(value.amountMinor),
                     .text(value.occurredOn), .text(value.memo), .integer(value.isCleared ? 1 : 0),
                     .integer(value.isReconciled ? 1 : 0), .text(value.status), optionalText(value.transferID),
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

    public func snapshot(budgetID: String) async throws -> LocalAuthoritySnapshot {
        let identityRows = try await database.rows(.init(
            "SELECT h.id AS household_id,h.name AS household_name,u.id AS owner_user_id,u.display_name AS owner_display_name,b.id AS budget_id,b.name AS budget_name,b.currency_code FROM budgets b JOIN households h ON h.id=b.household_id JOIN memberships m ON m.household_id=h.id AND m.role='owner' AND m.is_active=1 JOIN users u ON u.id=m.user_id WHERE b.id=? ORDER BY u.id LIMIT 1",
            values: [.text(budgetID)]
        ))
        guard let row = identityRows.first else { throw LocalStorageError.operationFailed("Local budget was not found") }
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
        return .init(identity: identity, accounts: accounts, groups: groups, categories: categories, payees: payees, transactions: transactions)
    }

    public func integrityCheck() async throws { try await database.integrityCheck() }

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

    private func loadTransactions(budgetID: String) async throws -> [LocalTransactionRecord] {
        let rows = try await database.rows(.init("SELECT * FROM transactions WHERE budget_id=? ORDER BY occurred_on,id", values: [.text(budgetID)]))
        var result: [LocalTransactionRecord] = []
        for row in rows {
            let transactionID = try text(row, "id")
            let splits = try await database.rows(.init("SELECT * FROM transaction_splits WHERE transaction_id=? ORDER BY id", values: [.text(transactionID)])).map {
                try LocalTransactionSplitRecord(id: text($0, "id"), categoryID: text($0, "category_id"), amountMinor: integer($0, "amount_minor"), memo: text($0, "memo"))
            }
            result.append(try .init(id: transactionID, budgetID: text(row, "budget_id"), accountID: text(row, "account_id"), payeeID: optionalText(row, "payee_id"), amountMinor: integer(row, "amount_minor"), occurredOn: text(row, "occurred_on"), memo: text(row, "memo"), isCleared: bool(row, "is_cleared"), isReconciled: bool(row, "is_reconciled"), status: text(row, "status"), transferID: optionalText(row, "transfer_id"), createdByUserID: text(row, "created_by_user_id"), createdAt: text(row, "created_at"), splits: splits))
        }
        return result
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
        guard total == value.amountMinor else {
            throw LocalStorageError.operationFailed("Transaction splits must equal the transaction amount")
        }
    }

    private func transactionInsert(_ value: LocalTransactionRecord) -> LocalSQLStatement {
        .init(
            "INSERT INTO transactions(id,budget_id,account_id,payee_id,amount_minor,occurred_on,memo,is_cleared,is_reconciled,status,transfer_id,created_by_user_id,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values: [.text(value.id), .text(value.budgetID), .text(value.accountID), optionalText(value.payeeID),
                     .integer(value.amountMinor), .text(value.occurredOn), .text(value.memo),
                     .integer(value.isCleared ? 1 : 0), .integer(value.isReconciled ? 1 : 0),
                     .text(value.status), optionalText(value.transferID), .text(value.createdByUserID), .text(value.createdAt)]
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
