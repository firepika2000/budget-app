import Foundation
import XCTest
@testable import BudgetStorage

final class LocalDatabaseTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func testFreshLocalAuthorityInstallsStarterPlanWithoutFinancialStateOrDuplication() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("starter.sqlite")
        let store = try LocalAuthorityStore(fileURL: databaseURL)
        let identity = LocalAuthorityIdentity(
            householdID: "household", householdName: "My Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "budget", budgetName: "My Budget", currencyCode: "USD"
        )
        try await store.bootstrap(identity, createdAt: "2026-10-01T12:00:00Z", installStarterPlan: true)

        let snapshot = try await store.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(snapshot.groups.map(\.name), LocalAuthorityStore.starterPlan.map(\.group))
        let groupNames = Dictionary(uniqueKeysWithValues: snapshot.groups.map { ($0.id, $0.name) })
        let actualCategories = Dictionary(grouping: snapshot.categories, by: { groupNames[$0.groupID] ?? "" })
            .mapValues { Set($0.map(\.name)) }
        let expectedCategories = Dictionary(uniqueKeysWithValues: LocalAuthorityStore.starterPlan.map {
            ($0.group, Set($0.categories))
        })
        XCTAssertEqual(actualCategories, expectedCategories)
        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertTrue(snapshot.transactions.isEmpty)
        XCTAssertTrue(snapshot.allocations.isEmpty)
        XCTAssertTrue(snapshot.targets.isEmpty)
        XCTAssertTrue(snapshot.schedules.isEmpty)

        let reopened = try LocalAuthorityStore(fileURL: databaseURL)
        let afterRelaunch = try await reopened.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(afterRelaunch.groups.count, 4)
        XCTAssertEqual(afterRelaunch.categories.count, 11)
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
        let migration = try await reopened.rows(.init("SELECT MAX(version) AS version FROM local_schema_migrations"))
        XCTAssertEqual(migration.first?["version"], .integer(Int64(LocalDatabase.schemaVersion)))
        try await reopened.integrityCheck()
    }

    func testSchemaV3UpgradesInPlaceToCurrentWithoutChangingExistingFinancialRows() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("v3-upgrade.sqlite")
        var database: LocalDatabase? = try LocalDatabase(fileURL: databaseURL)
        try await database?.transaction(fixtureStatements)
        try await database?.transaction([
            .init("DROP TABLE credit_reserve_attributions"),
            .init("DROP TABLE credit_reserve_events"),
            .init("DROP TABLE transaction_changes"),
            .init("DELETE FROM local_schema_migrations WHERE version >= 4"),
            .init("PRAGMA user_version = 3"),
        ])
        database = nil

        let upgraded = try LocalDatabase(fileURL: databaseURL)
        let version = try await upgraded.rows(.init("PRAGMA user_version"))
        let transactions = try await upgraded.rows(.init("SELECT amount_minor,memo FROM transactions"))
        let reserveAttribution = try await upgraded.rows(.init("SELECT * FROM credit_reserve_attributions"))
        let changes = try await upgraded.rows(.init("SELECT * FROM transaction_changes"))
        let reserveEvents = try await upgraded.rows(.init("SELECT * FROM credit_reserve_events"))
        XCTAssertEqual(version.first?.values.values.first, .integer(Int64(LocalDatabase.schemaVersion)))
        XCTAssertEqual(transactions, [
            .init(values: ["amount_minor": .integer(-12_345), "memo": .text("Exact local purchase")])
        ])
        XCTAssertTrue(reserveAttribution.isEmpty)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(reserveEvents.isEmpty)
        try await upgraded.integrityCheck()
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
        try await store?.insertCategory(.init(id: "groceries", budgetID: "budget", groupID: "needs", name: "Groceries", sortOrder: 0, isFavorite: true, favoriteSortOrder: 3))
        try await store?.insertPayee(.init(id: "market", budgetID: "budget", name: "Market", normalizedName: "market", defaultCategoryID: "groceries"))
        try await store?.insertPayeeAlias(.init(id: "market-alias", payeeID: "market", displayName: "The Market", normalizedName: "the market"))
        try await store?.insertTransaction(.init(
            id: "purchase", budgetID: "budget", accountID: "checking", payeeID: "market",
            amountMinor: -12_345, occurredOn: "2026-09-27", memo: "Exact purchase",
            createdByUserID: "owner", createdAt: timestamp,
            splits: [.init(id: "food", categoryID: "groceries", amountMinor: -10_000),
                     .init(id: "tax", categoryID: "groceries", amountMinor: -2_345)]
        ))
        try await store?.insertAllocation(.init(id: "allocation", budgetID: "budget", categoryID: "groceries", amountMinor: 50_00, occurredOn: "2026-09-01", kind: "assign", actorUserID: "owner", createdAt: timestamp))
        try await store?.insertReconciliation(.init(id: "reconciliation", accountID: "checking", statementDate: "2026-09-27", statementBalanceMinor: 9_007_199_254_728_646, createdAt: timestamp))
        try await store?.upsertTarget(.init(categoryID: "groceries", targetType: "monthly", amountMinor: 60_00, cadence: "monthly", effectiveMonth: "2026-09", targetDate: "2027-01-01", recurrenceMonths: 3, minimumContributionMinor: 5_00, priority: 80, isActive: false, snoozedMonths: ["2026-10-01", "2026-11-01"]))
        try await store?.upsertSchedule(.init(id: "schedule", budgetID: "budget", accountID: "checking", categoryID: "groceries", payeeID: "market", name: "Weekly market", amountMinor: -12_345, nextDate: "2026-10-04", recurrenceUnit: "weeks", intervalCount: 1, financialClassification: "interest_charge", lastRealizedOn: "2026-09-27"))
        try await store?.insertAttachment(.init(id: "receipt", transactionID: "purchase", filename: "receipt.jpg", contentType: "image/jpeg", sizeBytes: 4_096, sha256: String(repeating: "a", count: 64), objectName: "objects/receipt.enc", createdAt: timestamp))
        try await store?.integrityCheck()
        store = nil

        let reopened = try LocalAuthorityStore(fileURL: databaseURL)
        var snapshot = try await reopened.snapshot(budgetID: "budget")
        try await reopened.replaceWorkspaceState(.init(identity: snapshot.identity, accounts: snapshot.accounts, groups: snapshot.groups, categories: snapshot.categories, payees: snapshot.payees, payeeAliases: snapshot.payeeAliases, transactions: snapshot.transactions, allocations: snapshot.allocations, reconciliations: snapshot.reconciliations, targets: snapshot.targets, schedules: snapshot.schedules, attachments: snapshot.attachments, debtTerms: [.init(accountID: "checking", termsType: "credit_card", annualRateBasisPoints: 1999, minimumPaymentMinor: 25_00, dueDay: 15, updatedAt: timestamp)], cashRolloverPolicies: [.init(id: "rollover-1", budgetID: "budget", effectiveMonth: "2026-10-01", policy: "absorb_next_month", version: 1, source: "user_selection", actorUserID: "owner", createdAt: timestamp)], creditReserveAttributions: [.init(transactionID: "purchase", categoryID: "groceries", amountMinor: 12_345)], transactionChanges: [.init(id: "change", budgetID: "budget", transactionID: "purchase", actorUserID: "owner", action: "create", afterJSON: "{\"amount_minor\":-12345}", createdAt: timestamp)], creditReserveEvents: [.init(id: "reserve", budgetID: "budget", creditAccountID: "checking", paymentCategoryID: "payment-category", spendingCategoryID: "groceries", sourceTransactionID: "purchase", occurredOn: "2026-09-27", amountMinor: 12_345, kind: "funded_purchase", actorUserID: "owner", createdAt: timestamp)]))
        snapshot = try await reopened.snapshot(budgetID: "budget")
        XCTAssertEqual(snapshot.identity.currencyCode, "USD")
        XCTAssertEqual(snapshot.accounts.map(\.openingBalanceMinor), [9_007_199_254_740_991])
        XCTAssertEqual(snapshot.groups.map(\.name), ["Needs"])
        XCTAssertEqual(snapshot.categories.map(\.name), ["Groceries"])
        XCTAssertEqual(snapshot.categories.first?.isFavorite, true)
        XCTAssertEqual(snapshot.categories.first?.favoriteSortOrder, 3)
        XCTAssertEqual(snapshot.payees.map(\.name), ["Market"])
        XCTAssertEqual(snapshot.payeeAliases.map(\.displayName), ["The Market"])
        XCTAssertEqual(snapshot.transactions.map(\.amountMinor), [-12_345])
        XCTAssertEqual(snapshot.transactions.first?.splits.map(\.amountMinor), [-10_000, -2_345])
        XCTAssertEqual(snapshot.allocations.map(\.amountMinor), [50_00])
        XCTAssertEqual(snapshot.reconciliations.map(\.statementBalanceMinor), [9_007_199_254_728_646])
        XCTAssertEqual(snapshot.targets.map(\.amountMinor), [60_00])
        XCTAssertEqual(snapshot.targets.first?.targetDate, "2027-01-01")
        XCTAssertEqual(snapshot.targets.first?.recurrenceMonths, 3)
        XCTAssertEqual(snapshot.targets.first?.minimumContributionMinor, 5_00)
        XCTAssertEqual(snapshot.targets.first?.priority, 80)
        XCTAssertEqual(snapshot.targets.first?.isActive, false)
        XCTAssertEqual(snapshot.targets.first?.snoozedMonths, ["2026-10-01", "2026-11-01"])
        XCTAssertEqual(snapshot.schedules.map(\.amountMinor), [-12_345])
        XCTAssertEqual(snapshot.schedules.first?.financialClassification, "interest_charge")
        XCTAssertEqual(snapshot.schedules.first?.lastRealizedOn, "2026-09-27")
        XCTAssertEqual(snapshot.attachments.map(\.objectName), ["objects/receipt.enc"])
        XCTAssertEqual(snapshot.debtTerms.first?.annualRateBasisPoints, 1999)
        XCTAssertEqual(snapshot.cashRolloverPolicies.first?.policy, "absorb_next_month")
        XCTAssertEqual(snapshot.creditReserveAttributions, [.init(transactionID: "purchase", categoryID: "groceries", amountMinor: 12_345)])
        XCTAssertEqual(snapshot.transactionChanges.first?.afterJSON, "{\"amount_minor\":-12345}")
        XCTAssertEqual(snapshot.creditReserveEvents.first?.amountMinor, 12_345)
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

    func testLocalSchemaV4PreservesTransactionMetadataAndAllowsUncategorizedIncome() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("metadata.sqlite")
        let store = try LocalAuthorityStore(fileURL: databaseURL)
        let timestamp = "2026-09-30T12:00:00Z"
        try await store.bootstrap(.init(householdID: "h", householdName: "Household", ownerUserID: "u", ownerDisplayName: "Owner", budgetID: "b", budgetName: "Budget", currencyCode: "USD"), createdAt: timestamp)
        try await store.insertAccount(.init(id: "a", budgetID: "b", name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0, createdAt: timestamp))
        try await store.insertTransaction(.init(id: "income", budgetID: "b", accountID: "a", payeeName: "Employer", amountMinor: 123_45, occurredOn: "2026-09-30", memo: "Payroll", isCleared: true, flag: "Green", tags: ["income", "monthly"], financialClassification: "income", createdByUserID: "u", createdAt: timestamp, splits: []))

        let value = try await store.snapshot(budgetID: "b").transactions.first
        XCTAssertEqual(value?.payeeName, "Employer")
        XCTAssertEqual(value?.flag, "Green")
        XCTAssertEqual(value?.tags, ["income", "monthly"])
        XCTAssertEqual(value?.financialClassification, "income")
        XCTAssertEqual(value?.amountMinor, 123_45)
        XCTAssertEqual(LocalDatabase.schemaVersion, 5)
    }

    func testTypedAuthorityStoreUpdateAndDeleteLifecyclePersistsAcrossReopen() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("lifecycle.sqlite")
        var store: LocalAuthorityStore? = try LocalAuthorityStore(fileURL: databaseURL)
        let timestamp = "2026-09-27T12:00:00Z"
        try await store?.bootstrap(.init(
            householdID: "household", householdName: "Local Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "budget", budgetName: "Local Budget", currencyCode: "USD"
        ), createdAt: timestamp)
        try await store?.insertAccount(.init(id: "checking", budgetID: "budget", name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 100_00, createdAt: timestamp))
        try await store?.insertCategoryGroup(.init(id: "needs", budgetID: "budget", name: "Needs", sortOrder: 0))
        try await store?.insertCategory(.init(id: "food", budgetID: "budget", groupID: "needs", name: "Food", sortOrder: 0))
        try await store?.insertPayee(.init(id: "market", budgetID: "budget", name: "Market", normalizedName: "market"))
        try await store?.insertTransaction(.init(
            id: "purchase", budgetID: "budget", accountID: "checking", payeeID: "market",
            amountMinor: -1_00, occurredOn: "2026-09-27", createdByUserID: "owner", createdAt: timestamp,
            splits: [.init(id: "original", categoryID: "food", amountMinor: -1_00)]
        ))

        try await store?.updateAccount(.init(id: "checking", budgetID: "budget", name: "Daily Checking", kind: "checking", isOnBudget: true, isClosed: false, openingBalanceMinor: 100_00, createdAt: timestamp))
        try await store?.updateCategoryGroup(.init(id: "needs", budgetID: "budget", name: "Essentials", sortOrder: 4))
        try await store?.updateCategory(.init(id: "food", budgetID: "budget", groupID: "needs", name: "Groceries", isArchived: false, sortOrder: 2))
        try await store?.updatePayee(.init(id: "market", budgetID: "budget", name: "Local Market", normalizedName: "local market", defaultCategoryID: "food"))
        try await store?.replaceTransaction(.init(
            id: "purchase", budgetID: "budget", accountID: "checking", payeeID: "market",
            amountMinor: -2_00, occurredOn: "2026-09-28", memo: "Updated", isCleared: true,
            createdByUserID: "owner", createdAt: timestamp,
            splits: [.init(id: "replacement", categoryID: "food", amountMinor: -2_00)]
        ))
        store = nil

        store = try LocalAuthorityStore(fileURL: databaseURL)
        var snapshot = try await store!.snapshot(budgetID: "budget")
        XCTAssertEqual(snapshot.accounts.first?.name, "Daily Checking")
        XCTAssertEqual(snapshot.accounts.first?.openingBalanceMinor, 100_00, "Metadata edits cannot rewrite opening money")
        XCTAssertEqual(snapshot.groups.first?.name, "Essentials")
        XCTAssertEqual(snapshot.categories.first?.name, "Groceries")
        XCTAssertEqual(snapshot.payees.first?.defaultCategoryID, "food")
        XCTAssertEqual(snapshot.transactions.first?.amountMinor, -2_00)
        XCTAssertEqual(snapshot.transactions.first?.splits.map(\.id), ["replacement"])
        XCTAssertEqual(snapshot.transactions.first?.createdByUserID, "owner", "Edits preserve creator identity")

        try await store?.deleteTransaction(id: "purchase", budgetID: "budget")
        store = nil
        let reopened = try LocalAuthorityStore(fileURL: databaseURL)
        snapshot = try await reopened.snapshot(budgetID: "budget")
        XCTAssertTrue(snapshot.transactions.isEmpty)
        try await reopened.integrityCheck()
    }

    func testTypedAuthorityAuxiliaryLifecycleDeletesOnlyRequestedRecords() async throws {
        let databaseURL = try temporaryDirectory().appendingPathComponent("auxiliary.sqlite")
        let store = try LocalAuthorityStore(fileURL: databaseURL)
        let timestamp = "2026-09-30T12:00:00Z"
        try await store.bootstrap(.init(householdID: "h", householdName: "Household", ownerUserID: "u", ownerDisplayName: "Owner", budgetID: "b", budgetName: "Budget", currencyCode: "USD"), createdAt: timestamp)
        try await store.insertAccount(.init(id: "a", budgetID: "b", name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0, createdAt: timestamp))
        try await store.insertCategoryGroup(.init(id: "g", budgetID: "b", name: "Needs", sortOrder: 0))
        try await store.insertCategory(.init(id: "c", budgetID: "b", groupID: "g", name: "Food", sortOrder: 0))
        try await store.insertPayee(.init(id: "p", budgetID: "b", name: "Market", normalizedName: "market"))
        try await store.insertPayeeAlias(.init(id: "alias", payeeID: "p", displayName: "Shop", normalizedName: "shop"))
        try await store.insertTransaction(.init(id: "t", budgetID: "b", accountID: "a", payeeID: "p", amountMinor: -1, occurredOn: "2026-09-30", createdByUserID: "u", createdAt: timestamp, splits: [.init(id: "s", categoryID: "c", amountMinor: -1)]))
        try await store.insertAttachment(.init(id: "attachment", transactionID: "t", filename: "receipt.png", contentType: "image/png", sizeBytes: 1, sha256: String(repeating: "b", count: 64), objectName: "objects/a.enc", createdAt: timestamp))
        try await store.upsertTarget(.init(categoryID: "c", targetType: "monthly", amountMinor: 10, cadence: "monthly", effectiveMonth: "2026-09"))
        try await store.upsertSchedule(.init(id: "schedule", budgetID: "b", accountID: "a", categoryID: "c", name: "Plan", amountMinor: -1, nextDate: "2026-10-01", recurrenceUnit: "months", intervalCount: 1))

        try await store.deleteAttachment(id: "attachment", transactionID: "t")
        try await store.deletePayeeAlias(id: "alias", payeeID: "p")
        try await store.deleteTarget(categoryID: "c")
        try await store.deleteSchedule(id: "schedule", budgetID: "b")

        let snapshot = try await store.snapshot(budgetID: "b")
        XCTAssertTrue(snapshot.attachments.isEmpty)
        XCTAssertTrue(snapshot.payeeAliases.isEmpty)
        XCTAssertTrue(snapshot.targets.isEmpty)
        XCTAssertTrue(snapshot.schedules.isEmpty)
        XCTAssertEqual(snapshot.transactions.map(\.id), ["t"])
        XCTAssertEqual(snapshot.payees.map(\.id), ["p"])
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
