import Foundation
import SQLite3

public enum LocalStorageError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case operationFailed(String)
    case invalidSnapshot(String)
    case destinationExists

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message), let .operationFailed(message), let .invalidSnapshot(message): message
        case .destinationExists: "The local storage destination already exists."
        }
    }
}

public enum LocalSQLiteValue: Equatable, Sendable {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null
}

public struct LocalSQLStatement: Equatable, Sendable {
    public let sql: String
    public let values: [LocalSQLiteValue]

    public init(_ sql: String, values: [LocalSQLiteValue] = []) {
        self.sql = sql
        self.values = values
    }
}

public struct LocalSQLiteRow: Equatable, Sendable {
    public let values: [String: LocalSQLiteValue]

    public subscript(_ column: String) -> LocalSQLiteValue? { values[column] }
}

/// The low-level durable boundary for the single-user Local Device provider.
///
/// This actor owns one private SQLite connection. It intentionally provides persistence,
/// transactions, migrations, and consistent snapshots only; financial consequences belong to the
/// shared application-service/accounting command layer that will sit above it.
public actor LocalDatabase {
    public static let schemaVersion = 1
    public static let applicationID: Int32 = 0x42554447 // "BUDG"

    public let fileURL: URL
    private var handle: OpaquePointer?

    public init(fileURL: URL) throws {
        self.fileURL = fileURL.standardizedFileURL
        let parent = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Self.applyPrivateDirectoryProtection(to: parent)
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            self.fileURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let database { sqlite3_close_v2(database) }
            throw LocalStorageError.openFailed(message)
        }
        handle = database
        do {
            try Self.execute("PRAGMA foreign_keys = ON", on: database)
            try Self.execute("PRAGMA journal_mode = WAL", on: database)
            try Self.execute("PRAGMA synchronous = FULL", on: database)
            try Self.execute("PRAGMA busy_timeout = 5000", on: database)
            try Self.migrate(database)
            try Self.applyPrivateFileProtection(to: self.fileURL)
        } catch {
            sqlite3_close_v2(database)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func execute(_ statement: LocalSQLStatement) throws {
        try Self.execute(statement.sql, values: statement.values, on: requireHandle())
    }

    public func transaction(_ statements: [LocalSQLStatement]) throws {
        let database = try requireHandle()
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            for statement in statements {
                try Self.execute(statement.sql, values: statement.values, on: database)
            }
            try Self.execute("COMMIT", on: database)
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func rows(_ statement: LocalSQLStatement) throws -> [LocalSQLiteRow] {
        try Self.rows(statement.sql, values: statement.values, on: requireHandle())
    }

    public func integrityCheck() throws {
        let result = try Self.rows("PRAGMA integrity_check", on: requireHandle())
        guard result.count == 1, result[0].values.values.first == .text("ok") else {
            throw LocalStorageError.invalidSnapshot("SQLite integrity check failed")
        }
        let foreignKeys = try Self.rows("PRAGMA foreign_key_check", on: requireHandle())
        guard foreignKeys.isEmpty else {
            throw LocalStorageError.invalidSnapshot("SQLite foreign-key check failed")
        }
    }

    /// Uses SQLite's online backup API so a snapshot is consistent even while WAL is active.
    /// Existing destinations are refused; callers must preserve known-good generations.
    public func snapshot(to destinationURL: URL) throws {
        let destinationURL = destinationURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw LocalStorageError.destinationExists
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var destination: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            destinationURL.path, &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard openStatus == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to create snapshot"
            if let destination { sqlite3_close_v2(destination) }
            throw LocalStorageError.operationFailed(message)
        }
        var succeeded = false
        defer {
            sqlite3_close_v2(destination)
            if !succeeded { try? FileManager.default.removeItem(at: destinationURL) }
        }
        guard let backup = sqlite3_backup_init(destination, "main", try requireHandle(), "main") else {
            throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(destination)))
        }
        let backupStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard backupStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(destination)))
        }
        try Self.validateSnapshot(destination)
        try Self.applyPrivateFileProtection(to: destinationURL)
        succeeded = true
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw LocalStorageError.operationFailed("Local database is closed") }
        return handle
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute("CREATE TABLE IF NOT EXISTS local_schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL) STRICT", on: database)
        let currentRows = try rows("SELECT COALESCE(MAX(version), 0) AS version FROM local_schema_migrations", on: database)
        let current: Int64
        if case let .integer(value)? = currentRows.first?["version"] { current = value } else { current = 0 }
        guard current <= schemaVersion else {
            throw LocalStorageError.openFailed("Local database schema is newer than this app")
        }
        if current < 1 {
            try execute("BEGIN IMMEDIATE", on: database)
            do {
                for sql in schemaV1 { try execute(sql, on: database) }
                try execute(
                    "INSERT INTO local_schema_migrations(version, applied_at) VALUES (?, ?)",
                    values: [.integer(1), .text(Self.timestamp())], on: database
                )
                try execute("PRAGMA application_id = \(applicationID)", on: database)
                try execute("PRAGMA user_version = 1", on: database)
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
        let application = try rows("PRAGMA application_id", on: database)
        guard application.first?.values.values.first == .integer(Int64(applicationID)) else {
            throw LocalStorageError.openFailed("File is not a Budget App local database")
        }
    }

    private static let schemaV1 = [
        "CREATE TABLE local_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT",
        "CREATE TABLE households (id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name)) > 0), created_at TEXT NOT NULL) STRICT",
        "CREATE TABLE users (id TEXT PRIMARY KEY, display_name TEXT NOT NULL, email TEXT) STRICT",
        "CREATE TABLE budgets (id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id), name TEXT NOT NULL CHECK(length(trim(name)) > 0), currency_code TEXT NOT NULL CHECK(length(currency_code) = 3), cash_rollover_policy TEXT NOT NULL, created_at TEXT NOT NULL) STRICT",
        "CREATE TABLE memberships (household_id TEXT NOT NULL REFERENCES households(id), user_id TEXT NOT NULL REFERENCES users(id), role TEXT NOT NULL, is_active INTEGER NOT NULL CHECK(is_active IN (0,1)), PRIMARY KEY(household_id,user_id)) STRICT",
        "CREATE TABLE accounts (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), name TEXT NOT NULL, kind TEXT NOT NULL, is_on_budget INTEGER NOT NULL CHECK(is_on_budget IN (0,1)), is_closed INTEGER NOT NULL CHECK(is_closed IN (0,1)), opening_balance_minor INTEGER NOT NULL, created_at TEXT NOT NULL) STRICT",
        "CREATE TABLE category_groups (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL CHECK(is_archived IN (0,1))) STRICT",
        "CREATE TABLE categories (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), group_id TEXT NOT NULL REFERENCES category_groups(id), name TEXT NOT NULL, delegated_user_id TEXT REFERENCES users(id), is_archived INTEGER NOT NULL CHECK(is_archived IN (0,1)), sort_order INTEGER NOT NULL DEFAULT 0) STRICT",
        "CREATE TABLE payees (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), name TEXT NOT NULL, normalized_name TEXT NOT NULL, default_category_id TEXT REFERENCES categories(id), is_archived INTEGER NOT NULL CHECK(is_archived IN (0,1))) STRICT",
        "CREATE TABLE payee_aliases (id TEXT PRIMARY KEY, payee_id TEXT NOT NULL REFERENCES payees(id), display_name TEXT NOT NULL, normalized_name TEXT NOT NULL) STRICT",
        "CREATE TABLE transactions (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), account_id TEXT NOT NULL REFERENCES accounts(id), payee_id TEXT REFERENCES payees(id), amount_minor INTEGER NOT NULL, occurred_on TEXT NOT NULL, memo TEXT NOT NULL DEFAULT '', is_cleared INTEGER NOT NULL CHECK(is_cleared IN (0,1)), is_reconciled INTEGER NOT NULL CHECK(is_reconciled IN (0,1)), status TEXT NOT NULL, transfer_id TEXT, created_by_user_id TEXT REFERENCES users(id), created_at TEXT NOT NULL) STRICT",
        "CREATE TABLE transaction_splits (id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE, category_id TEXT NOT NULL REFERENCES categories(id), amount_minor INTEGER NOT NULL, memo TEXT NOT NULL DEFAULT '') STRICT",
        "CREATE TABLE allocation_operations (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), category_id TEXT REFERENCES categories(id), amount_minor INTEGER NOT NULL, occurred_on TEXT NOT NULL, kind TEXT NOT NULL, actor_user_id TEXT REFERENCES users(id), note TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL) STRICT",
        "CREATE TABLE reconciliations (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), statement_date TEXT NOT NULL, statement_balance_minor INTEGER NOT NULL, adjustment_transaction_id TEXT REFERENCES transactions(id), created_at TEXT NOT NULL) STRICT",
        "CREATE TABLE category_targets (category_id TEXT PRIMARY KEY REFERENCES categories(id), target_type TEXT NOT NULL, amount_minor INTEGER NOT NULL, cadence TEXT NOT NULL, effective_month TEXT NOT NULL, snoozed_month TEXT) STRICT",
        "CREATE TABLE scheduled_transactions (id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), account_id TEXT NOT NULL REFERENCES accounts(id), destination_account_id TEXT REFERENCES accounts(id), category_id TEXT REFERENCES categories(id), payee_id TEXT REFERENCES payees(id), name TEXT NOT NULL, amount_minor INTEGER NOT NULL, next_date TEXT NOT NULL, recurrence_unit TEXT NOT NULL, interval_count INTEGER NOT NULL CHECK(interval_count > 0), memo TEXT NOT NULL DEFAULT '', is_active INTEGER NOT NULL CHECK(is_active IN (0,1))) STRICT",
        "CREATE TABLE attachments (id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE, filename TEXT NOT NULL, content_type TEXT NOT NULL, size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0), sha256 TEXT NOT NULL, object_name TEXT NOT NULL, created_at TEXT NOT NULL) STRICT",
        "CREATE INDEX idx_accounts_budget ON accounts(budget_id)",
        "CREATE INDEX idx_categories_budget_group ON categories(budget_id,group_id)",
        "CREATE INDEX idx_transactions_budget_date ON transactions(budget_id,occurred_on,id)",
        "CREATE INDEX idx_splits_transaction ON transaction_splits(transaction_id)",
        "CREATE INDEX idx_allocations_budget_date ON allocation_operations(budget_id,occurred_on,id)",
        "CREATE INDEX idx_schedules_budget_date ON scheduled_transactions(budget_id,next_date,id)"
    ]

    private static func execute(
        _ sql: String, values: [LocalSQLiteValue] = [], on database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, database: database)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func rows(
        _ sql: String, values: [LocalSQLiteValue] = [], on database: OpaquePointer
    ) throws -> [LocalSQLiteRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, database: database)
        var result: [LocalSQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            var values: [String: LocalSQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index) {
                        values[name] = .blob(Data(bytes: bytes, count: count))
                    } else { values[name] = .blob(Data()) }
                default: values[name] = .null
                }
            }
            result.append(LocalSQLiteRow(values: values))
        }
    }

    private static func bind(
        _ values: [LocalSQLiteValue], to statement: OpaquePointer, database: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let .integer(number): status = sqlite3_bind_int64(statement, index, number)
            case let .text(text): status = sqlite3_bind_text(statement, index, text, -1, transient)
            case let .blob(data):
                status = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                throw LocalStorageError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func validateSnapshot(_ database: OpaquePointer) throws {
        let integrity = try rows("PRAGMA integrity_check", on: database)
        guard integrity.count == 1, integrity[0].values.values.first == .text("ok") else {
            throw LocalStorageError.invalidSnapshot("Snapshot integrity check failed")
        }
        let application = try rows("PRAGMA application_id", on: database)
        guard application.first?.values.values.first == .integer(Int64(applicationID)) else {
            throw LocalStorageError.invalidSnapshot("Snapshot application identity is invalid")
        }
    }

    private static func applyPrivateFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func applyPrivateDirectoryProtection(to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
