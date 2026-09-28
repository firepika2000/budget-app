import Foundation
import XCTest
@testable import BudgetStorage

final class LocalDatabaseTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func testSchemaPersistsExactMoneyAndRelationshipsAcrossDestructiveReopen() async throws {
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("household.sqlite")
        var database: LocalDatabase? = try LocalDatabase(fileURL: databaseURL)
        try await database?.transaction(fixtureStatements)
        try await database?.integrityCheck()
        database = nil

        let reopened = try LocalDatabase(fileURL: databaseURL)
        let accounts = try await reopened.rows(.init("SELECT name, opening_balance_minor FROM accounts"))
        XCTAssertEqual(accounts, [.init(values: ["name": .text("Checking"), "opening_balance_minor": .integer(9_007_199_254_740_991)] )])
        let transaction = try await reopened.rows(.init("SELECT amount_minor, memo FROM transactions"))
        XCTAssertEqual(transaction.first?["amount_minor"], .integer(-12_345))
        XCTAssertEqual(transaction.first?["memo"], .text("Exact local purchase"))
        let migration = try await reopened.rows(.init("SELECT version FROM local_schema_migrations"))
        XCTAssertEqual(migration.first?["version"], .integer(Int64(LocalDatabase.schemaVersion)))
        try await reopened.integrityCheck()
    }

    func testFailedTransactionRollsBackEveryStatement() async throws {
        let database = try LocalDatabase(fileURL: try temporaryDirectory().appendingPathComponent("rollback.sqlite"))
        do {
            try await database.transaction([
                .init("INSERT INTO households(id,name,created_at) VALUES (?,?,?)", values: [.text("h"), .text("Household"), .text("2026-09-27T00:00:00Z")]),
                .init("INSERT INTO budgets(id,household_id,name,currency_code,cash_rollover_policy,created_at) VALUES (?,?,?,?,?,?)", values: [.text("b"), .text("missing"), .text("Budget"), .text("USD"), .text("absorb"), .text("2026-09-27T00:00:00Z")])
            ])
            XCTFail("Expected the foreign-key violation")
        } catch {}
        let households = try await database.rows(.init("SELECT id FROM households"))
        XCTAssertTrue(households.isEmpty)
    }

    func testOnlineSnapshotIsVerifiedReopenableAndNeverOverwrites() async throws {
        let directory = try temporaryDirectory()
        let database = try LocalDatabase(fileURL: directory.appendingPathComponent("live.sqlite"))
        try await database.transaction(fixtureStatements)
        let snapshot = directory.appendingPathComponent("snapshot.sqlite")
        try await database.snapshot(to: snapshot)

        let restored = try LocalDatabase(fileURL: snapshot)
        let restoredTransactions = try await restored.rows(.init("SELECT amount_minor FROM transactions"))
        XCTAssertEqual(restoredTransactions.first?["amount_minor"], .integer(-12_345))
        do {
            try await database.snapshot(to: snapshot)
            XCTFail("Existing known-good snapshots must not be overwritten")
        } catch let error as LocalStorageError {
            XCTAssertEqual(error, .destinationExists)
        }
    }

    func testTypedAuthorityStorePersistsCompleteAggregateAcrossReopen() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("authority.sqlite")
        var store: LocalAuthorityStore? = try LocalAuthorityStore(fileURL: databaseURL)
        let timestamp = "2026-09-27T12:00:00Z"
        let identity = LocalAuthorityIdentity(
            householdID: "household", householdName: "Local Household",
            ownerUserID: "owner", ownerDisplayName: "Owner", budgetID: "budget",
            budgetName: "Local Budget", currencyCode: "usd"
        )
        try await store?.bootstrap(identity, createdAt: timestamp)
        try await store?.insertAccount(.init(
            id: "checking", budgetID: "budget", name: "Checking", kind: "checking",
            isOnBudget: true, openingBalanceMinor: 9_007_199_254_740_991, createdAt: timestamp
        ))
        try await store?.insertCategoryGroup(.init(id: "needs", budgetID: "budget", name: "Needs", sortOrder: 0))
        try await store?.insertCategory(.init(id: "groceries", budgetID: "budget", groupID: "needs", name: "Groceries", sortOrder: 0))
        try await store?.insertPayee(.init(id: "market", budgetID: "budget", name: "Market", normalizedName: "market", defaultCategoryID: "groceries"))
        try await store?.insertTransaction(.init(
            id: "purchase", budgetID: "budget", accountID: "checking", payeeID: "market",
            amountMinor: -12_345, occurredOn: "2026-09-27", memo: "Exact purchase",
            createdByUserID: "owner", createdAt: timestamp,
            splits: [.init(id: "food", categoryID: "groceries", amountMinor: -10_000),
                     .init(id: "tax", categoryID: "groceries", amountMinor: -2_345)]
        ))
        try await store?.integrityCheck()
        store = nil

        let reopened = try LocalAuthorityStore(fileURL: databaseURL)
        let snapshot = try await reopened.snapshot(budgetID: "budget")
        XCTAssertEqual(snapshot.identity.currencyCode, "USD")
        XCTAssertEqual(snapshot.accounts.map(\.openingBalanceMinor), [9_007_199_254_740_991])
        XCTAssertEqual(snapshot.groups.map(\.name), ["Needs"])
        XCTAssertEqual(snapshot.categories.map(\.name), ["Groceries"])
        XCTAssertEqual(snapshot.payees.map(\.name), ["Market"])
        XCTAssertEqual(snapshot.transactions.map(\.amountMinor), [-12_345])
        XCTAssertEqual(snapshot.transactions.first?.splits.map(\.amountMinor), [-10_000, -2_345])
        try await reopened.integrityCheck()
    }

    func testTypedAuthorityStoreRefusesInvalidSplitAggregateWithoutPartialWrite() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("atomic.sqlite")
        let store = try LocalAuthorityStore(fileURL: databaseURL)
        let timestamp = "2026-09-27T12:00:00Z"
        try await store.bootstrap(.init(
            householdID: "household", householdName: "Local Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "budget", budgetName: "Local Budget", currencyCode: "USD"
        ), createdAt: timestamp)
        try await store.insertAccount(.init(id: "checking", budgetID: "budget", name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0, createdAt: timestamp))
        try await store.insertCategoryGroup(.init(id: "needs", budgetID: "budget", name: "Needs", sortOrder: 0))
        try await store.insertCategory(.init(id: "groceries", budgetID: "budget", groupID: "needs", name: "Groceries", sortOrder: 0))

        do {
            try await store.insertTransaction(.init(
                id: "invalid", budgetID: "budget", accountID: "checking", amountMinor: -500,
                occurredOn: "2026-09-27", createdByUserID: "owner", createdAt: timestamp,
                splits: [.init(id: "split", categoryID: "groceries", amountMinor: -499)]
            ))
            XCTFail("Mismatched split aggregate must be refused")
        } catch {}

        let snapshot = try await store.snapshot(budgetID: "budget")
        XCTAssertTrue(snapshot.transactions.isEmpty)
    }

    private var fixtureStatements: [LocalSQLStatement] {
        let created = LocalSQLiteValue.text("2026-09-27T00:00:00Z")
        return [
            .init("INSERT INTO households(id,name,created_at) VALUES (?,?,?)", values: [.text("household"), .text("Local Household"), created]),
            .init("INSERT INTO users(id,display_name,email) VALUES (?,?,?)", values: [.text("owner"), .text("Owner"), .null]),
            .init("INSERT INTO memberships(household_id,user_id,role,is_active) VALUES (?,?,?,?)", values: [.text("household"), .text("owner"), .text("owner"), .integer(1)]),
            .init("INSERT INTO budgets(id,household_id,name,currency_code,cash_rollover_policy,created_at) VALUES (?,?,?,?,?,?)", values: [.text("budget"), .text("household"), .text("Local Budget"), .text("USD"), .text("absorb"), created]),
            .init("INSERT INTO accounts(id,budget_id,name,kind,is_on_budget,is_closed,opening_balance_minor,created_at) VALUES (?,?,?,?,?,?,?,?)", values: [.text("checking"), .text("budget"), .text("Checking"), .text("checking"), .integer(1), .integer(0), .integer(9_007_199_254_740_991), created]),
            .init("INSERT INTO category_groups(id,budget_id,name,sort_order,is_archived) VALUES (?,?,?,?,?)", values: [.text("needs"), .text("budget"), .text("Needs"), .integer(0), .integer(0)]),
            .init("INSERT INTO categories(id,budget_id,group_id,name,delegated_user_id,is_archived,sort_order) VALUES (?,?,?,?,?,?,?)", values: [.text("groceries"), .text("budget"), .text("needs"), .text("Groceries"), .null, .integer(0), .integer(0)]),
            .init("INSERT INTO transactions(id,budget_id,account_id,payee_id,amount_minor,occurred_on,memo,is_cleared,is_reconciled,status,transfer_id,created_by_user_id,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", values: [.text("transaction"), .text("budget"), .text("checking"), .null, .integer(-12_345), .text("2026-09-27"), .text("Exact local purchase"), .integer(0), .integer(0), .text("posted"), .null, .text("owner"), created]),
            .init("INSERT INTO transaction_splits(id,transaction_id,category_id,amount_minor,memo) VALUES (?,?,?,?,?)", values: [.text("split"), .text("transaction"), .text("groceries"), .integer(-12_345), .text("")])
        ]
    }
}
