import BudgetAPI
import BudgetCore
import Foundation
import CryptoKit

func normalizedCategoryName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
}

// MARK: - Canonical product operations

struct CreateAccountOperation: Equatable, Sendable {
    let name: String
    let kind: String
    let isOnBudget: Bool
    let openingBalanceMinor: Int64
}

struct UpdateAccountMetadataOperation: Equatable, Sendable {
    let accountID: String
    let name: String
    let currentKind: String
    let kind: String
    let isOnBudget: Bool
    let isClosed: Bool
}

struct AssignMoneyOperation: Codable, Equatable, Sendable {
    let categoryID: String
    let month: String
    let assignedMinor: Int64
    let expectedVersion: Int
    var mutationOperationID: String? = nil
}

struct MoveMoneyOperation: Codable, Equatable, Sendable {
    let sourceCategoryID: String
    let destinationCategoryID: String
    let amountMinor: Int64
    let occurredOn: String
    let note: String
    let expectedVersion: Int
    var mutationOperationID: String? = nil
}

struct TransactionSplitOperation: Codable, Equatable, Sendable {
    let categoryID: String
    let amountMinor: Int64
    let memo: String
    var financialClassification: String? = nil
}

struct RecordTransactionOperation: Codable, Equatable, Sendable {
    let accountID: String
    let categoryID: String?
    let amountMinor: Int64
    let occurredOn: String
    let payeeName: String
    var payeeID: String? = nil
    let memo: String
    var financialClassification: String? = nil
    let isCleared: Bool
    let splits: [TransactionSplitOperation]
    let flag: String?
    let tags: [String]
    let attachmentMetadata: [[String: String]]
    var clientOperationID: String? = nil
    var expectedRevision: String? = nil
    var mutationOperationID: String? = nil
}

struct MakeRecurringOperation: Codable, Equatable, Sendable {
    let recurrenceUnit: String
    let intervalCount: Int
    let nextDate: String
    var expectedRevision: String? = nil
    var mutationOperationID: String? = nil

    var isValidPending: Bool {
        guard let revision = expectedRevision, revision.hasPrefix("v1:"), revision.count == 67,
              revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }),
              let identity = mutationOperationID, UUID(uuidString: identity) != nil,
              ["days", "weeks", "months", "years"].contains(recurrenceUnit), (1...365).contains(intervalCount) else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: nextDate) else { return false }
        return formatter.string(from: date) == nextDate
    }
}

struct CreatePayeeOperation: Equatable, Sendable { let displayName: String; let defaultCategoryID: String? }
struct UpdatePayeeOperation: Equatable, Sendable { let payeeID: String; let displayName: String; let isArchived: Bool; let defaultCategoryID: String? }

struct TransferMoneyOperation: Codable, Equatable, Sendable {
    var mutationOperationID: String? = nil
    var expectedRevisions: [String: String]? = nil
    let sourceAccountID: String
    let destinationAccountID: String
    let amountMinor: Int64
    let occurredOn: String
    let memo: String
    let isCleared: Bool
}

struct ReconcileAccountOperation: Codable, Equatable, Sendable {
    var mutationOperationID: String? = nil
    var expectedReviewRevision: String? = nil
    let accountID: String
    let statementBalanceMinor: Int64
    let throughDate: String
    let createAdjustment: Bool
    let reason: String
    let expectedClearedBalanceMinor: Int64
}

struct DeleteTransferOperation: Codable, Equatable, Sendable {
    let transferID: String
    let expectedRevisions: [String: String]
    var mutationOperationID: String? = nil
    var isValidPending: Bool {
        !transferID.isEmpty && mutationOperationID.flatMap(UUID.init(uuidString:)) != nil
            && expectedRevisions.count == 2 && expectedRevisions.allSatisfy { id, revision in
                !id.isEmpty && revision.hasPrefix("v1:") && revision.count == 67
                    && revision.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
            }
    }
}

struct DeleteTransactionOperation: Codable, Equatable, Sendable {
    let transactionID: String
    let expectedRevision: String?
    var mutationOperationID: String? = nil
    var isValidPending: Bool {
        guard !transactionID.isEmpty, let identity = mutationOperationID, UUID(uuidString: identity) != nil,
              let revision = expectedRevision else { return false }
        return revision.hasPrefix("v1:") && revision.count == 67
            && revision.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

struct DuplicateTransactionOperation: Codable, Equatable, Sendable {
    let transactionID: String
    let occurredOn: String
    let expectedRevision: String?
    var mutationOperationID: String? = nil
    var isValidPending: Bool {
        guard !transactionID.isEmpty, let identity = mutationOperationID, UUID(uuidString: identity) != nil,
              let revision = expectedRevision, revision.hasPrefix("v1:"), revision.count == 67,
              revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: occurredOn) else { return false }
        return formatter.string(from: date) == occurredOn
    }
}

struct VoidTransactionOperation: Codable, Equatable, Sendable {
    let transactionID: String
    let reason: String
    let expectedRevision: String?
    var mutationOperationID: String? = nil
}

enum AttachmentStagingError: LocalizedError {
    case invalid
    var errorDescription: String? { "Saved attachment bytes are missing or changed. The queued upload is preserved for review in Pending Sync." }
}

struct ScheduleOperation: Codable, Equatable, Sendable {
    var expectedRevision: String? = nil
    var mutationOperationID: String? = nil
    let accountID: String
    let destinationAccountID: String?
    let categoryID: String?
    let payeeID: String?
    let name: String
    let amountMinor: Int64
    let nextDate: String
    let recurrenceUnit: String
    let intervalCount: Int
    let endDate: String?
    let remainingOccurrences: Int?
    let memo: String
    let financialClassification: String?
    let isActive: Bool

    init(accountID: String, destinationAccountID: String? = nil, categoryID: String? = nil, payeeID: String? = nil, name: String,
         amountMinor: Int64, nextDate: String, recurrenceUnit: String, intervalCount: Int = 1,
         endDate: String? = nil, remainingOccurrences: Int? = nil, memo: String = "", financialClassification: String? = nil, isActive: Bool = true, expectedRevision: String? = nil, mutationOperationID: String? = nil) {
        self.expectedRevision = expectedRevision; self.mutationOperationID = mutationOperationID
        self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.categoryID = categoryID; self.payeeID = payeeID
        self.name = name; self.amountMinor = amountMinor; self.nextDate = nextDate; self.recurrenceUnit = recurrenceUnit
        self.intervalCount = intervalCount; self.endDate = endDate; self.remainingOccurrences = remainingOccurrences; self.memo = memo; self.financialClassification = financialClassification; self.isActive = isActive
    }

    var isValidPendingCreation: Bool {
        expectedRevision == nil && mutationOperationID == nil && isValidPendingShape(allowExhausted: false)
    }

    var isValidPendingEdit: Bool {
        guard let revision = expectedRevision, revision.hasPrefix("v1:"), revision.count == 67,
              revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }),
              let identity = mutationOperationID, UUID(uuidString: identity) != nil else { return false }
        return isValidPendingShape(allowExhausted: true)
    }

    private func isValidPendingShape(allowExhausted: Bool) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard !accountID.isEmpty, !name.isEmpty, name.count <= 150, memo.count <= 500,
              amountMinor != 0, (1...365).contains(intervalCount),
              ["once", "days", "weeks", "months", "years"].contains(recurrenceUnit),
              let date = formatter.date(from: nextDate), formatter.string(from: date) == nextDate else { return false }
        if let destinationAccountID {
            guard !destinationAccountID.isEmpty, destinationAccountID != accountID, amountMinor > 0,
                  categoryID == nil, payeeID == nil else { return false }
        }
        if let financialClassification {
            guard financialClassification == "interest_charge", amountMinor < 0 else { return false }
        }
        if let endDate {
            guard recurrenceUnit != "once", let end = formatter.date(from: endDate),
                  formatter.string(from: end) == endDate, end >= date, remainingOccurrences == nil else { return false }
        }
        if let remainingOccurrences {
            guard recurrenceUnit != "once", ((allowExhausted && !isActive ? 0 : 1)...10_000).contains(remainingOccurrences) else { return false }
        }
        return true
    }
}

struct DeleteScheduleOperation: Codable, Equatable, Sendable {
    let scheduleID: String
    let expectedRevision: String?
    var mutationOperationID: String? = nil

    var isValidPending: Bool {
        guard !scheduleID.isEmpty, let revision = expectedRevision, revision.hasPrefix("v1:"), revision.count == 67,
              revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }),
              let identity = mutationOperationID, UUID(uuidString: identity) != nil else { return false }
        return true
    }
}

struct RealizeScheduleOperation: Codable, Equatable, Sendable {
    let scheduleID: String
    let expectedRevision: String?
    var mutationOperationID: String? = nil

    var isValidPending: Bool {
        DeleteScheduleOperation(scheduleID: scheduleID, expectedRevision: expectedRevision,
                                mutationOperationID: mutationOperationID).isValidPending
    }
}

struct DetachAttachmentOperation: Codable, Equatable, Sendable {
    let transactionID: String
    let attachmentID: String
    let expectedSHA256: String
    let filename: String
    var mutationOperationID: String? = nil

    var isValidPending: Bool {
        !transactionID.isEmpty && !attachmentID.isEmpty && !filename.isEmpty && filename.count <= 255
            && expectedSHA256.count == 64 && expectedSHA256.allSatisfy { "0123456789abcdef".contains($0) }
            && mutationOperationID.flatMap(UUID.init(uuidString:)) != nil
    }
}

struct AccountBalanceObservation: Equatable, Sendable { let balanceMinor: Int64 }
struct CategoryBalanceObservation: Equatable, Sendable {
    let assignedMinor: Int64; let activityMinor: Int64; let availableMinor: Int64
}
struct CreditCardObservation: Equatable, Sendable {
    let liabilityMinor: Int64; let reservedMinor: Int64; let unfundedDebtMinor: Int64
}
struct FinancialObservation: Equatable, Sendable {
    let accounts: [String: AccountBalanceObservation]
    let categories: [String: CategoryBalanceObservation]
    let cards: [String: CreditCardObservation]
    let unassignedMinor: Int64
    let totalBudgetCashMinor: Int64
    let netWorthMinor: Int64
    let transactionCount: Int
    let allocationPostingsSumMinor: Int64
}

struct ScheduledRealizationObservation: Equatable, Sendable {
    let scheduleID: String
    let transactionIDs: [String]
    let realizedOn: String
    let nextDate: String?
    let isActive: Bool
    let lastRealizedOn: String
}

// MARK: - Application error model

enum BudgetApplicationError: LocalizedError, Equatable, Sendable {
    case insufficientFunds(String)
    case permissionDenied(String)
    case invalidOperation(String)
    case notFound(String)
    case conflict(String)
    case temporarilyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .insufficientFunds(message), let .permissionDenied(message),
             let .invalidOperation(message), let .notFound(message),
             let .conflict(message), let .temporarilyUnavailable(message): message
        }
    }

    static func map(_ error: Error) -> BudgetApplicationError {
        if let application = error as? BudgetApplicationError { return application }
        let message = error.localizedDescription
        if case let APIClientError.server(status, _) = error {
            switch status {
            case 401, 403: return .permissionDenied(message)
            case 404: return .notFound(message)
            default: break
            }
        }
        let lowered = message.lowercased()
        if lowered.contains("not enough") || lowered.contains("insufficient") || lowered.contains("available to move") {
            return .insufficientFunds(message)
        }
        if lowered.contains("permission") || lowered.contains("not authorized") || lowered.contains("only change") {
            return .permissionDenied(message)
        }
        if lowered.contains("not found") || lowered.contains("no longer available") {
            return .notFound(message)
        }
        if lowered.contains("changed") || lowered.contains("conflict") || lowered.contains("reconciled") {
            return .conflict(message)
        }
        if error is URLError { return .temporarilyUnavailable(message) }
        return .invalidOperation(message)
    }
}

/// Historical observations must not survive an authoritative denial of their current scope.
enum HistoryObservationPolicy {
    static func mustDiscard(after error: Error) -> Bool {
        switch BudgetApplicationError.map(error) {
        case .permissionDenied, .notFound: return true
        default: return false
        }
    }
}

/// Retry the failed page, unless a scope denial has already discarded its parent rows.
enum HistoryRetryIntent {
    case refresh, older

    func shouldReset(hasLoadedRows: Bool) -> Bool {
        self == .refresh || !hasLoadedRows
    }
}

// MARK: - Durable Live transaction outbox

/// Persists identified transaction, planning and transfer commands while a shared server is unreachable. Entries carry
/// a server-enforced idempotency identity, so an uncertain response can be replayed without posting
/// money twice. Observed edits and reconciliation retain conflict preconditions;
/// authority mutations deliberately remain outside this queue.
@MainActor
final class LiveTransactionOutbox {
    struct AttachmentUpload: Codable, Equatable {
        let transactionID: String
        let filename: String
        let contentType: String
        let byteCount: Int
        let sha256: String
    }
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let queuedAt: Date
        let operation: RecordTransactionOperation?
        var requiresReview: Bool? = nil
        var transactionID: String? = nil
        var bulkUpdate: APITransactionBulkUpdate? = nil
        var assignment: AssignMoneyOperation? = nil
        var moneyMove: MoveMoneyOperation? = nil
        var accountTransfer: TransferMoneyOperation? = nil
        var transferID: String? = nil
        var reconciliation: ReconcileAccountOperation? = nil
        var voidCommand: VoidTransactionOperation? = nil
        var duplicateCommand: DuplicateTransactionOperation? = nil
        var deletionCommand: DeleteTransactionOperation? = nil
        var transferDeletionCommand: DeleteTransferOperation? = nil
        var attachmentUpload: AttachmentUpload? = nil
        var scheduleCreation: ScheduleOperation? = nil
        var makeRecurring: MakeRecurringOperation? = nil
        var scheduleEdit: ScheduleOperation? = nil
        var scheduleID: String? = nil
        var scheduleDeletion: DeleteScheduleOperation? = nil
        var scheduleRealization: RealizeScheduleOperation? = nil
        var attachmentRemoval: DetachAttachmentOperation? = nil
    }

    private let fileURL: URL
    private var persistedSnapshot: [Entry] = []
    private(set) var entries: [Entry] = []
    private(set) var loadErrorMessage: String?
    private(set) var isReplaying = false
    private(set) var requiresLegacyReview = false
    private var legacyFileURL: URL?
    private var bindingFileURL: URL?
    private var boundScope: String?

    init(budgetID: String, serverURL: URL, token: String, fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BudgetApp/LiveOutbox", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let legacyScope = "\(serverURL.host ?? "server")-\(serverURL.port ?? 0)-\(liveCredentialSubject(token))-\(budgetID)"
            .replacingOccurrences(of: "/", with: "-")
        let scope = liveServerStorageScope(budgetID: budgetID, serverURL: serverURL, token: token)
        fileURL = root.appendingPathComponent("outbox-v2-\(scope).json", isDirectory: false)
        configureLegacyReview(root.appendingPathComponent("\(legacyScope).json"), scope: scope)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do { entries = try Self.readEntries(from: fileURL); persistedSnapshot = entries }
        catch { entries = []; loadErrorMessage = "Pending changes could not be read. The saved queue has been preserved; do not delete app data. \(error.localizedDescription)" }
    }

    init(fileURL: URL, legacyFileURL: URL, scope: String) {
        self.fileURL = fileURL
        configureLegacyReview(legacyFileURL, scope: scope)
    }

    private func configureLegacyReview(_ legacy: URL, scope: String) {
        boundScope = scope
        legacyFileURL = legacy
        bindingFileURL = legacy.appendingPathExtension("server-binding")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                entries = try Self.readEntries(from: fileURL)
                persistedSnapshot = entries
                return
            }
            if let bindingFileURL, FileManager.default.fileExists(atPath: bindingFileURL.path) {
                let claimed = try JSONDecoder().decode(String.self, from: Data(contentsOf: bindingFileURL))
                guard claimed == scope else { return } // Another endpoint owns this preserved legacy queue.
            }
            entries = try Self.readEntries(from: legacy)
            requiresLegacyReview = !entries.isEmpty
        } catch {
            entries = []; loadErrorMessage = "Pending changes could not be read. The saved queue has been preserved; do not delete app data. \(error.localizedDescription)"
        }
    }

    func requireServer(budgetID: String, serverURL: URL, token: String) throws {
        guard let boundScope else { return } // Explicit file initializer is for isolated tests.
        guard boundScope == liveServerStorageScope(budgetID: budgetID, serverURL: serverURL, token: token) else {
            throw BudgetApplicationError.invalidOperation("Pending changes belong to another server connection. Reopen the budget using its original server.")
        }
    }

    /// Explicit local adoption only; never sends a request, changes operation IDs or deletes originals.
    func confirmLegacyServer() throws {
        guard requiresLegacyReview, !isReplaying, let legacyFileURL, let bindingFileURL, let boundScope else { return }
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              try Self.readEntries(from: legacyFileURL) == entries else {
            throw BudgetApplicationError.invalidOperation("Pending changes changed during review. Reopen this budget before confirming.")
        }
        if FileManager.default.fileExists(atPath: bindingFileURL.path) {
            guard try JSONDecoder().decode(String.self, from: Data(contentsOf: bindingFileURL)) == boundScope else {
                throw BudgetApplicationError.invalidOperation("These pending changes were already assigned to another server.")
            }
        } else {
            try JSONEncoder().encode(boundScope).write(to: bindingFileURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bindingFileURL.path)
        }
        try persist(entries)
        requiresLegacyReview = false
    }

    var count: Int { entries.count }

    func submit(_ operation: RecordTransactionOperation,
                shouldPause: (Error) -> Bool = { _ in false },
                send: (RecordTransactionOperation) async throws -> Void) async throws {
        // Publish the immutable identity before the first network suspension point.
        try enqueue(operation)
        try await replay(shouldPause: shouldPause, send: send)
    }

    func replay(shouldPause: (Error) -> Bool = { _ in false },
                send: (RecordTransactionOperation) async throws -> Void) async throws {
        try await replayCommands(shouldPause: shouldPause) { entry in
            guard entry.transactionID == nil, let operation = entry.operation else {
                throw BudgetApplicationError.invalidOperation("This pending edit requires the transaction command sender.")
            }
            try await send(operation)
        }
    }

    func replayCommands(shouldPause: (Error) -> Bool = { _ in false },
                        send: (Entry) async throws -> Void) async throws {
        guard try beginReplay() else { return }
        defer { finishReplay() }
        for entry in entries {
            guard entry.requiresReview != true else {
                throw BudgetApplicationError.invalidOperation("A saved transaction needs review in Profile & Settings → Pending Sync. Later changes are waiting behind it.")
            }
            do { try await send(entry) }
            catch {
                if shouldPause(error) { try setReview(id: entry.id, required: true) }
                throw error
            }
            try acknowledgeReplay(id: entry.id)
        }
    }

    func enqueueEdit(transactionID: String, operation: RecordTransactionOperation) throws {
        try requireReadableQueue()
        guard !transactionID.isEmpty, let id = operation.mutationOperationID,
              UUID(uuidString: id) != nil, operation.clientOperationID == nil,
              operation.expectedRevision != nil else {
            throw BudgetApplicationError.invalidOperation("Pending edits require a target, stable mutation identity and observed revision.")
        }
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.transactionID == transactionID && existing.operation == operation else {
                throw BudgetApplicationError.invalidOperation("A pending edit identity cannot be reused for different details.")
            }
            return
        }
        let next = entries + [Entry(id: id, queuedAt: Date(), operation: operation, transactionID: transactionID)]
        try persist(next)
        entries = next
    }

    func enqueueBulk(_ update: APITransactionBulkUpdate) throws {
        try requireReadableQueue()
        guard let id = update.mutationOperationID, UUID(uuidString: id) != nil,
              !update.transactionIDs.isEmpty, update.transactionIDs.count <= 200,
              Set(update.transactionIDs).count == update.transactionIDs.count,
              let revisions = update.expectedRevisions, Set(revisions.keys) == Set(update.transactionIDs) else {
            throw BudgetApplicationError.invalidOperation("Pending bulk actions require stable identity and observations for every selected transaction.")
        }
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.bulkUpdate == update else {
                throw BudgetApplicationError.invalidOperation("A pending command identity cannot be reused for different details.")
            }
            return
        }
        let next = entries + [Entry(id: id, queuedAt: Date(), operation: nil, bulkUpdate: update)]
        try persist(next)
        entries = next
    }

    func enqueueAssignment(_ assignment: AssignMoneyOperation) throws {
        guard let id = assignment.mutationOperationID, UUID(uuidString: id) != nil,
              !assignment.categoryID.isEmpty, assignment.expectedVersion >= 0 else {
            throw BudgetApplicationError.invalidOperation("Pending assignments require stable identity and an observed plan version.")
        }
        try enqueuePlanning(Entry(id: id, queuedAt: Date(), operation: nil, assignment: assignment))
    }

    func enqueueMoneyMove(_ move: MoveMoneyOperation) throws {
        guard let id = move.mutationOperationID, UUID(uuidString: id) != nil, move.expectedVersion >= 0,
              !move.sourceCategoryID.isEmpty, !move.destinationCategoryID.isEmpty,
              move.sourceCategoryID != move.destinationCategoryID, move.amountMinor > 0 else {
            throw BudgetApplicationError.invalidOperation("Pending moves require two categories, a positive amount, stable identity and an observed plan version.")
        }
        try enqueuePlanning(Entry(id: id, queuedAt: Date(), operation: nil, moneyMove: move))
    }

    func enqueueTransfer(_ transfer: TransferMoneyOperation, id transferID: String? = nil) throws {
        guard let id = transfer.mutationOperationID, UUID(uuidString: id) != nil,
              !transfer.sourceAccountID.isEmpty, !transfer.destinationAccountID.isEmpty,
              transfer.sourceAccountID != transfer.destinationAccountID, transfer.amountMinor > 0,
              transferID == nil || (transferID?.isEmpty == false && transfer.expectedRevisions?.count == 2) else {
            throw BudgetApplicationError.invalidOperation("Pending transfers require stable identity, two accounts and both observed revisions when editing.")
        }
        try enqueuePlanning(Entry(id: id, queuedAt: Date(), operation: nil, accountTransfer: transfer, transferID: transferID))
    }

    private func enqueuePlanning(_ entry: Entry) throws {
        try requireReadableQueue()
        if let existing = entries.first(where: { $0.id == entry.id }) {
            guard existing.assignment == entry.assignment && existing.moneyMove == entry.moneyMove,
                  existing.accountTransfer == entry.accountTransfer && existing.transferID == entry.transferID,
                  existing.reconciliation == entry.reconciliation,
                  existing.voidCommand == entry.voidCommand,
                  existing.duplicateCommand == entry.duplicateCommand,
                  existing.deletionCommand == entry.deletionCommand,
                  existing.transferDeletionCommand == entry.transferDeletionCommand,
                  existing.attachmentUpload == entry.attachmentUpload,
                  existing.scheduleCreation == entry.scheduleCreation,
                  existing.makeRecurring == entry.makeRecurring && existing.transactionID == entry.transactionID,
                  existing.scheduleEdit == entry.scheduleEdit && existing.scheduleID == entry.scheduleID,
                  existing.scheduleDeletion == entry.scheduleDeletion,
                  existing.scheduleRealization == entry.scheduleRealization,
                  existing.attachmentRemoval == entry.attachmentRemoval,
                  existing.operation == nil && existing.bulkUpdate == nil else {
                throw BudgetApplicationError.invalidOperation("A pending command identity cannot be reused for different details.")
            }
            return
        }
        let next = entries + [entry]
        try persist(next)
        entries = next
    }

    func enqueueReconciliation(_ operation: ReconcileAccountOperation) throws {
        guard let id = operation.mutationOperationID, UUID(uuidString: id) != nil,
              !operation.accountID.isEmpty, let revision = operation.expectedReviewRevision,
              revision.hasPrefix("v1:"), revision.count == 67,
              revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw BudgetApplicationError.invalidOperation("Saved reconciliation requires a stable identity and the server-reviewed transaction set.")
        }
        guard !entries.contains(where: { $0.id != id && $0.reconciliation?.accountID == operation.accountID }) else {
            throw BudgetApplicationError.invalidOperation("This account already has a saved reconciliation. Review it in Pending Sync before submitting another.")
        }
        try enqueuePlanning(Entry(id: id, queuedAt: Date(), operation: nil, reconciliation: operation))
    }

    func enqueueSchedule(id: String, operation: ScheduleOperation) throws {
        guard UUID(uuidString: id) != nil, operation.isValidPendingCreation else {
            throw BudgetApplicationError.invalidOperation("Enter a valid schedule amount, date and recurrence before saving.")
        }
        try enqueuePlanning(Entry(id: id, queuedAt: Date(), operation: nil, scheduleCreation: operation))
    }

    func enqueueMakeRecurring(transactionID: String, operation: MakeRecurringOperation) throws {
        guard !transactionID.isEmpty, operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen this transaction to review its template, date and recurrence before saving.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, transactionID: transactionID, makeRecurring: operation))
    }

    func enqueueScheduleEdit(scheduleID: String, operation: ScheduleOperation) throws {
        guard !scheduleID.isEmpty, operation.isValidPendingEdit, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen this schedule to review its current version before saving.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.scheduleID == scheduleID }) else {
            throw BudgetApplicationError.invalidOperation("This schedule already has a saved edit. Review it in Pending Sync before editing again.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, scheduleEdit: operation, scheduleID: scheduleID))
    }

    func enqueueAttachmentRemoval(_ operation: DetachAttachmentOperation) throws {
        guard operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen the attachment to review it before removing.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.attachmentRemoval?.attachmentID == operation.attachmentID }) else {
            throw BudgetApplicationError.invalidOperation("This attachment already has a saved removal. Review it in Pending Sync.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, attachmentRemoval: operation))
    }

    func enqueueScheduleRealization(_ operation: RealizeScheduleOperation) throws {
        guard operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen this schedule to review it before entering its occurrence.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.scheduleID == operation.scheduleID }) else {
            throw BudgetApplicationError.invalidOperation("This schedule already has a saved change. Review it in Pending Sync first.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil,
                                 scheduleID: operation.scheduleID, scheduleRealization: operation))
    }

    func enqueueScheduleDeletion(_ operation: DeleteScheduleOperation) throws {
        guard operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen this schedule to review it before deleting.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.scheduleID == operation.scheduleID }) else {
            throw BudgetApplicationError.invalidOperation("This schedule already has a saved change. Review it in Pending Sync before deleting.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, scheduleID: operation.scheduleID, scheduleDeletion: operation))
    }

    func enqueueTransferDeletion(_ operation: DeleteTransferOperation) throws {
        guard operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Review both transfer entries before deleting.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.transferDeletionCommand?.transferID == operation.transferID }) else {
            throw BudgetApplicationError.invalidOperation("This transfer already has a pending deletion.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, transferDeletionCommand: operation))
    }

    func enqueueDeletion(_ operation: DeleteTransactionOperation) throws {
        guard operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen this transaction to review it before deleting.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.deletionCommand?.transactionID == operation.transactionID }) else {
            throw BudgetApplicationError.invalidOperation("This transaction already has a saved deletion. Review it in Pending Sync.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, deletionCommand: operation))
    }

    func enqueueDuplicate(_ operation: DuplicateTransactionOperation) throws {
        guard operation.isValidPending, let identity = operation.mutationOperationID else {
            throw BudgetApplicationError.invalidOperation("Reopen this transaction to review its date and source before duplicating.")
        }
        guard !entries.contains(where: { $0.id != identity && $0.duplicateCommand?.transactionID == operation.transactionID }) else {
            throw BudgetApplicationError.invalidOperation("This transaction already has a saved duplicate. Resolve it in Pending Sync first.")
        }
        try enqueuePlanning(Entry(id: identity, queuedAt: Date(), operation: nil, duplicateCommand: operation))
    }

    func enqueueVoid(_ operation: VoidTransactionOperation) throws {
        guard let id = operation.mutationOperationID, UUID(uuidString: id) != nil,
              !operation.transactionID.isEmpty, operation.reason.count <= 500,
              let revision = operation.expectedRevision, revision.hasPrefix("v1:"), revision.count == 67,
              revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw BudgetApplicationError.invalidOperation("Saved voids require a target, stable identity, reviewed revision and a reason of at most 500 characters.")
        }
        guard !entries.contains(where: { $0.id != id && $0.voidCommand?.transactionID == operation.transactionID }) else {
            throw BudgetApplicationError.invalidOperation("This transaction already has a saved void. Resolve it in Pending Sync before submitting another.")
        }
        try enqueuePlanning(Entry(id: id, queuedAt: Date(), operation: nil, voidCommand: operation))
    }

    func enqueueAttachment(id: String, transactionID: String, filename: String, contentType: String, data: Data) throws {
        try requireReadableQueue()
        try requireCurrentSnapshot()
        let type = contentType.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let prefix = Array(data.prefix(12))
        let validSignature: Bool
        switch type {
        case "application/pdf": validSignature = data.starts(with: Data("%PDF-".utf8))
        case "image/jpeg": validSignature = data.starts(with: [0xff, 0xd8, 0xff])
        case "image/png": validSignature = data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "image/heic", "image/heif": validSignature = prefix.count == 12 && String(bytes: prefix[4..<8], encoding: .ascii) == "ftyp" && ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(String(bytes: prefix[8..<12], encoding: .ascii) ?? "")
        default: validSignature = false
        }
        guard UUID(uuidString: id) != nil, !transactionID.isEmpty, !data.isEmpty,
              data.count <= 10 * 1024 * 1024, validSignature else {
            throw BudgetApplicationError.invalidOperation("Choose a valid PDF, JPEG, PNG or HEIC file, 10 MB or smaller.")
        }
        let name = (filename.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = AttachmentUpload(transactionID: transactionID, filename: name.isEmpty ? "attachment" : String(name.prefix(255)),
                                       contentType: type, byteCount: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let entry = Entry(id: id, queuedAt: Date(), operation: nil, attachmentUpload: payload)
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.attachmentUpload == payload else { throw BudgetApplicationError.invalidOperation("A saved upload identity cannot be reused for another file.") }
            _ = try stagedAttachmentData(for: existing)
            return
        }
        guard entries.filter({ $0.attachmentUpload?.transactionID == transactionID }).count < 20 else {
            throw BudgetApplicationError.invalidOperation("This transaction already has 20 pending uploads. Let them synchronize before adding more.")
        }
        let destination = attachmentStagingURL(id: id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.deletingLastPathComponent().path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try stagedAttachmentData(for: entry) // Never overwrite a retained publication with different bytes.
        } else {
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        // Publish metadata only after bytes are durably protected. Failed publication retains
        // the staged object; never delete bytes when an atomic write's outcome is uncertain.
        try enqueuePlanning(entry)
    }

    private func attachmentStagingURL(id: String) -> URL {
        fileURL.appendingPathExtension("attachments").appendingPathComponent(id)
    }

    func stagedAttachmentData(for entry: Entry) throws -> Data {
        guard UUID(uuidString: entry.id) != nil, let payload = entry.attachmentUpload else { throw AttachmentStagingError.invalid }
        let url = attachmentStagingURL(id: entry.id)
        let data: Data
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == payload.byteCount else { throw AttachmentStagingError.invalid }
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { throw AttachmentStagingError.invalid }
        guard data.count == payload.byteCount, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == payload.sha256 else {
            throw AttachmentStagingError.invalid
        }
        return data
    }

    func retryReviewed(id: String) throws {
        guard !isReplaying else { throw BudgetApplicationError.invalidOperation("Wait for synchronization to finish before retrying.") }
        try setReview(id: id, required: false)
    }

    private func setReview(id: String, required: Bool) throws {
        try requireReadableQueue()
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].requiresReview = required
        try persist(next)
        entries = next
    }

    func enqueue(_ operation: RecordTransactionOperation) throws {
        try requireReadableQueue()
        guard let id = operation.clientOperationID, UUID(uuidString: id) != nil else {
            throw BudgetApplicationError.invalidOperation("Queued transactions require a stable operation identity.")
        }
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.operation == operation else { throw BudgetApplicationError.invalidOperation("A pending operation identity cannot be reused for different transaction details.") }
            return
        }
        let next = entries + [Entry(id: id, queuedAt: Date(), operation: operation)]
        try persist(next)
        entries = next
    }

    func remove(id: String) throws {
        guard !isReplaying else { throw BudgetApplicationError.invalidOperation("Wait for synchronization to finish before discarding pending changes.") }
        try removePersisted(id: id)
    }

    func beginReplay() throws -> Bool {
        try requireReadableQueue()
        guard !isReplaying else { return false }
        try requireCurrentSnapshot()
        isReplaying = true
        return true
    }

    func finishReplay() { isReplaying = false }

    func acknowledgeReplay(id: String) throws {
        guard isReplaying else { throw BudgetApplicationError.invalidOperation("No synchronization is in progress.") }
        try removePersisted(id: id)
    }

    private func removePersisted(id: String) throws {
        try requireReadableQueue()
        let staged = entries.first(where: { $0.id == id })?.attachmentUpload != nil
        let next = entries.filter { $0.id != id }
        try persist(next)
        entries = next
        if staged { try? FileManager.default.removeItem(at: attachmentStagingURL(id: id)) }
    }

    private func requireReadableQueue() throws {
        if let loadErrorMessage { throw BudgetApplicationError.invalidOperation(loadErrorMessage) }
        if requiresLegacyReview { throw BudgetApplicationError.invalidOperation("Review the destination server in Profile & Settings → Pending Sync before sending older pending changes.") }
    }

    private static func readEntries(from url: URL) throws -> [Entry] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let values = try JSONDecoder().decode([Entry].self, from: data)
        guard Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ entry in
                  guard UUID(uuidString: entry.id) != nil else { return false }
                  let payloadCount = [entry.operation != nil, entry.bulkUpdate != nil, entry.assignment != nil, entry.moneyMove != nil, entry.accountTransfer != nil, entry.reconciliation != nil, entry.voidCommand != nil, entry.duplicateCommand != nil, entry.deletionCommand != nil, entry.transferDeletionCommand != nil, entry.attachmentUpload != nil, entry.scheduleCreation != nil, entry.makeRecurring != nil, entry.scheduleEdit != nil, entry.scheduleDeletion != nil, entry.scheduleRealization != nil, entry.attachmentRemoval != nil].filter { $0 }.count
                  guard payloadCount == 1 else { return false }
                  if let removal = entry.attachmentRemoval {
                      return entry.scheduleID == nil && entry.transactionID == nil && entry.transferID == nil
                          && removal.mutationOperationID == entry.id && removal.isValidPending
                  }
                  if let realization = entry.scheduleRealization {
                      return entry.scheduleID == realization.scheduleID && entry.transactionID == nil && entry.transferID == nil
                          && realization.mutationOperationID == entry.id && realization.isValidPending
                  }
                  if let deletion = entry.scheduleDeletion {
                      return entry.scheduleID == deletion.scheduleID && entry.transactionID == nil && entry.transferID == nil
                          && deletion.mutationOperationID == entry.id && deletion.isValidPending
                  }
                  if let edit = entry.scheduleEdit {
                      return entry.scheduleID?.isEmpty == false && entry.transactionID == nil && entry.transferID == nil
                          && edit.mutationOperationID == entry.id && edit.isValidPendingEdit
                  }
                  guard entry.scheduleID == nil else { return false }
                  if let recurring = entry.makeRecurring {
                      return entry.transactionID?.isEmpty == false && entry.transferID == nil
                          && recurring.mutationOperationID == entry.id && recurring.isValidPending
                  }
                  if let schedule = entry.scheduleCreation {
                      return entry.transactionID == nil && entry.transferID == nil && schedule.isValidPendingCreation
                  }
                  if let upload = entry.attachmentUpload {
                      return entry.transactionID == nil && entry.transferID == nil && !upload.transactionID.isEmpty
                          && !upload.filename.isEmpty && upload.filename.count <= 255 && (1...10 * 1024 * 1024).contains(upload.byteCount)
                          && ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif"].contains(upload.contentType)
                          && upload.sha256.count == 64 && upload.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
                  }
                  if let command = entry.voidCommand {
                      guard let revision = command.expectedRevision else { return false }
                      return entry.transactionID == nil && entry.transferID == nil
                          && command.mutationOperationID == entry.id && !command.transactionID.isEmpty && command.reason.count <= 500
                          && revision.hasPrefix("v1:") && revision.count == 67
                          && revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) })
                  }
                  if let command = entry.duplicateCommand {
                      return entry.transactionID == nil && entry.transferID == nil
                          && command.mutationOperationID == entry.id && command.isValidPending
                  }
                  if let command = entry.deletionCommand {
                      return entry.transactionID == nil && entry.transferID == nil
                          && command.mutationOperationID == entry.id && command.isValidPending
                  }
                  if let command = entry.transferDeletionCommand {
                      return entry.transactionID == nil && entry.transferID == nil
                          && command.mutationOperationID == entry.id && command.isValidPending
                  }
                  if let reconciliation = entry.reconciliation {
                      guard let revision = reconciliation.expectedReviewRevision else { return false }
                      return entry.transactionID == nil && entry.transferID == nil
                          && reconciliation.mutationOperationID == entry.id && !reconciliation.accountID.isEmpty
                          && revision.hasPrefix("v1:") && revision.count == 67
                          && revision.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) })
                  }
                  if let transfer = entry.accountTransfer {
                      return entry.transactionID == nil && transfer.mutationOperationID == entry.id
                          && !transfer.sourceAccountID.isEmpty && !transfer.destinationAccountID.isEmpty
                          && transfer.sourceAccountID != transfer.destinationAccountID && transfer.amountMinor > 0
                          && (entry.transferID == nil || (entry.transferID?.isEmpty == false && transfer.expectedRevisions?.count == 2))
                  }
                  guard entry.transferID == nil else { return false }
                  if let assignment = entry.assignment {
                      return entry.transactionID == nil && assignment.mutationOperationID == entry.id
                          && !assignment.categoryID.isEmpty && assignment.expectedVersion >= 0
                  }
                  if let move = entry.moneyMove {
                      return entry.transactionID == nil && move.mutationOperationID == entry.id && move.expectedVersion >= 0
                          && !move.sourceCategoryID.isEmpty && !move.destinationCategoryID.isEmpty
                          && move.sourceCategoryID != move.destinationCategoryID && move.amountMinor > 0
                  }
                  if let bulk = entry.bulkUpdate {
                      return entry.operation == nil && entry.transactionID == nil
                          && bulk.mutationOperationID == entry.id && !bulk.transactionIDs.isEmpty
                          && bulk.transactionIDs.count <= 200 && Set(bulk.transactionIDs).count == bulk.transactionIDs.count
                          && bulk.expectedRevisions.map { Set($0.keys) == Set(bulk.transactionIDs) } == true
                  }
                  guard let operation = entry.operation else { return false }
                  if let target = entry.transactionID {
                      return !target.isEmpty && operation.mutationOperationID == entry.id
                          && operation.clientOperationID == nil && operation.expectedRevision != nil
                  }
                  return operation.clientOperationID == entry.id
              }) else {
            throw BudgetApplicationError.invalidOperation("The saved queue has invalid operation identities.")
        }
        return values
    }

    private func persist(_ next: [Entry]) throws {
        // All owners write synchronously on MainActor: compare and atomic replace cannot
        // interleave with another in-process owner. Never overwrite a newer queue snapshot.
        try requireCurrentSnapshot()
        let data = try JSONEncoder().encode(next)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        persistedSnapshot = next
    }

    private func requireCurrentSnapshot() throws {
        guard try Self.readEntries(from: fileURL) == persistedSnapshot else {
            throw BudgetApplicationError.invalidOperation("Pending changes were updated by another workspace. Reopen this budget to review the current saved queue. Saved changes are preserved; an in-flight request may already have reached the server.")
        }
    }
}

enum PendingTransactionVisibility {
    static func allows(_ operation: RecordTransactionOperation, canView: Bool,
                       accountIDs: Set<String>, categoryIDs: Set<String>) -> Bool {
        guard canView, accountIDs.contains(operation.accountID) else { return false }
        if let categoryID = operation.categoryID, !categoryIDs.contains(categoryID) { return false }
        return operation.splits.allSatisfy { categoryIDs.contains($0.categoryID) }
    }
}

struct LiveWorkspaceCachePayload: Codable {
    let savedAt: Date
    let accessRevision: String?
    let planMonth: String?
    let accounts: [APIAccount]
    let accountBalances: [String: APIAccountBalance]
    let categories: [APICategory]
    let groups: [APICategoryGroup]
    let transactions: [APITransaction]
    let summary: APIMonthSummary?
    let targets: [APICategoryTarget]
    let schedules: [APIScheduledTransaction]
    let forecast: APIForecast?
}

/// File-protected last-known authorized observation. It is display-only: permissions and all
/// financial commands are still revalidated by the server, and a 403/404 never falls back here.
@MainActor
final class LiveWorkspaceReadCache {
    private let fileURL: URL
    private var accessRevision: String?

    init(budgetID: String, serverURL: URL, token: String, accessRevision: String? = nil, fileManager: FileManager = .default) {
        self.accessRevision = accessRevision
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BudgetApp/LiveCache", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let scope = "read-v2-" + liveServerStorageScope(budgetID: budgetID, serverURL: serverURL, token: token)
        fileURL = root.appendingPathComponent("\(scope).json", isDirectory: false)
    }

    init(fileURL: URL, accessRevision: String? = nil) { self.fileURL = fileURL; self.accessRevision = accessRevision }

    func updateAccessRevision(_ value: String?) { accessRevision = value }

    func save(_ snapshot: WorkspaceSnapshot, planMonth: String? = nil) throws {
        let destination = try cacheURL(planMonth: planMonth)
        let value = LiveWorkspaceCachePayload(
            savedAt: Date(), accessRevision: accessRevision, planMonth: planMonth, accounts: snapshot.accounts,
            accountBalances: snapshot.accountBalances, categories: snapshot.categories,
            groups: snapshot.groups, transactions: snapshot.transactions, summary: snapshot.summary,
            targets: snapshot.targets, schedules: snapshot.schedules, forecast: snapshot.forecast
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(value).write(to: destination, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func load(planMonth: String? = nil) throws -> LiveWorkspaceCachePayload {
        let value = try JSONDecoder().decode(LiveWorkspaceCachePayload.self, from: Data(contentsOf: cacheURL(planMonth: planMonth)))
        guard value.accessRevision == accessRevision else {
            throw BudgetApplicationError.invalidOperation("The saved workspace belongs to earlier access settings. Reconnect to load your current budget access.")
        }
        guard value.planMonth == planMonth else {
            throw BudgetApplicationError.invalidOperation("The saved plan belongs to another month. Reconnect to load this month.")
        }
        return value
    }

    private func cacheURL(planMonth: String?) throws -> URL {
        guard let planMonth else { return fileURL }
        // Month identity is server-shaped, never a caller-controlled path component.
        let parts = planMonth.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2,
              parts[2] == "01", planMonth.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(parts[0]), year > 0,
              let month = Int(parts[1]), (1...12).contains(month) else {
            throw BudgetApplicationError.invalidOperation("The saved plan month is invalid.")
        }
        return fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent)-plan-\(planMonth).json"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        let parent = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + "-plan-"
        for candidate in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            guard candidate.lastPathComponent.hasPrefix(prefix), candidate.pathExtension == "json" else { continue }
            let month = String(candidate.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            guard let expected = try? cacheURL(planMonth: month),
                  expected.standardizedFileURL.path == candidate.standardizedFileURL.path else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }
}

/// Bounded, protected last-authorized metadata only. Never stores attachment bytes or
/// substitutes for server authorization. Scope/access changes invalidate observations.
@MainActor
final class LiveAttachmentReadCache {
    private struct Observation: Codable {
        let transactionID: String
        let accessRevision: String?
        let savedAt: Date
        let attachments: [APITransactionAttachment]
    }
    private let directory: URL
    let storageScope: String
    private var accessRevision: String?
    private(set) var generation = UUID()

    init(budgetID: String, serverURL: URL, token: String, accessRevision: String?) {
        storageScope = liveServerStorageScope(budgetID: budgetID, serverURL: serverURL, token: token)
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BudgetApp/AttachmentLists/" + storageScope, isDirectory: true)
        self.accessRevision = accessRevision
    }

    init(directory: URL, storageScope: String, accessRevision: String? = nil) {
        self.directory = directory; self.storageScope = storageScope; self.accessRevision = accessRevision
    }

    func updateAuthority(_ revision: String?, changed: Bool) {
        accessRevision = revision
        if changed { removeAll() }
    }

    func requireScope(_ scope: String) throws {
        guard scope == storageScope else {
            throw BudgetApplicationError.invalidOperation("Attachment observations belong to another server or user. Reopen the budget.")
        }
    }

    func save(_ attachments: [APITransactionAttachment], transactionID: String, generation observed: UUID) throws {
        guard observed == generation, Self.valid(attachments, transactionID: transactionID) else {
            throw BudgetApplicationError.invalidOperation("The attachment observation is stale or invalid.")
        }
        if let previous = try? load(transactionID: transactionID) {
            for attachment in previous where !attachments.contains(attachment) {
                try? FileManager.default.removeItem(at: bytesURL(attachment))
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let observation = Observation(transactionID: transactionID, accessRevision: accessRevision,
                                      savedAt: Date(), attachments: attachments)
        let target = fileURL(transactionID)
        try JSONEncoder().encode(observation).write(to: target, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0.standardizedFileURL.path != target.standardizedFileURL.path }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in files.dropFirst(49) { try? FileManager.default.removeItem(at: file) }
    }

    func load(transactionID: String) throws -> [APITransactionAttachment] {
        let value = try JSONDecoder().decode(Observation.self, from: Data(contentsOf: fileURL(transactionID)))
        guard value.transactionID == transactionID, value.accessRevision == accessRevision,
              Self.valid(value.attachments, transactionID: transactionID) else {
            throw BudgetApplicationError.invalidOperation("Reconnect to load current attachment access.")
        }
        return value.attachments
    }

    func remove(transactionID: String) {
        // Resource denial must purge ciphertext even when its list metadata is corrupt or missing.
        let prefix = Self.digest(Data(transactionID.utf8)) + "-"
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "enc" && file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        try? FileManager.default.removeItem(at: fileURL(transactionID))
    }
    func saveBytes(_ data: Data, attachment: APITransactionAttachment, keyData: Data, generation observed: UUID) throws {
        guard observed == generation, keyData.count == 32,
              try load(transactionID: attachment.transactionID).contains(attachment),
              data.count == attachment.byteCount, Self.digest(data) == attachment.sha256 else {
            throw BudgetApplicationError.invalidOperation("Attachment integrity or access changed. Reconnect before opening it.")
        }
        let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw BudgetApplicationError.invalidOperation("Unable to protect attachment preview.") }
        let target = bytesURL(attachment)
        try combined.write(to: target, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "enc" && $0.standardizedFileURL.path != target.standardizedFileURL.path }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in files.dropFirst(9) { try? FileManager.default.removeItem(at: file) }
    }
    func loadBytes(attachment: APITransactionAttachment, keyData: Data) throws -> Data {
        guard keyData.count == 32, try load(transactionID: attachment.transactionID).contains(attachment) else {
            throw BudgetApplicationError.invalidOperation("Reconnect to verify attachment access.")
        }
        let target = bytesURL(attachment)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw BudgetApplicationError.invalidOperation("This file is not available offline. Connect and open it once to keep a protected preview on this device.")
        }
        let data: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: target))
            data = try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
        } catch {
            throw BudgetApplicationError.invalidOperation("The protected preview could not be verified. Reconnect to download a fresh copy.")
        }
        guard data.count == attachment.byteCount, Self.digest(data) == attachment.sha256 else {
            throw BudgetApplicationError.invalidOperation("Attachment integrity verification failed.")
        }
        return data
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func bytesURL(_ attachment: APITransactionAttachment) -> URL {
        directory.appendingPathComponent(Self.digest(Data(attachment.transactionID.utf8)) + "-"
            + Self.digest(Data((attachment.id + ":" + attachment.sha256).utf8)) + ".enc")
    }
    func acknowledgeRemoval(transactionID: String, attachmentID: String) {
        guard let previous = try? load(transactionID: transactionID) else { remove(transactionID: transactionID); return }
        for attachment in previous where attachment.id == attachmentID { try? FileManager.default.removeItem(at: bytesURL(attachment)) }
        do { try save(previous.filter { $0.id != attachmentID }, transactionID: transactionID, generation: generation) }
        catch { remove(transactionID: transactionID) }
    }
    func removeAll() {
        generation = UUID()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" || file.pathExtension == "enc" { try? FileManager.default.removeItem(at: file) }
    }
    private func fileURL(_ transactionID: String) -> URL {
        let digest = SHA256.hash(data: Data(transactionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private static func valid(_ attachments: [APITransactionAttachment], transactionID: String) -> Bool {
        !transactionID.isEmpty && attachments.count <= 20 && Set(attachments.map(\.id)).count == attachments.count
            && attachments.allSatisfy { $0.transactionID == transactionID && !$0.id.isEmpty && $0.detachedAt == nil
                && !$0.filename.isEmpty && $0.filename.count <= 255 && (1...10 * 1024 * 1024).contains($0.byteCount)
                && ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif"].contains($0.contentType)
                && $0.sha256.count == 64 && $0.sha256.allSatisfy { "0123456789abcdef".contains($0) } }
    }
}

private func liveCredentialSubject(_ token: String) -> String {
    let pieces = token.split(separator: ".")
    guard pieces.count > 1 else { return "unknown-user" }
    var value = String(pieces[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let subject = object["sub"] as? String else { return "unknown-user" }
    return subject.replacingOccurrences(of: "/", with: "-")
}

/// Storage namespace only, never authentication. Preserve server path/scheme separation while
/// allowing credential rotation and equivalent root/default-port spellings to reuse observations.
func liveServerStorageScope(budgetID: String, serverURL: URL, token: String) -> String {
    let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: true)
    let scheme = components?.scheme?.lowercased() ?? ""
    let host = components?.host?.lowercased() ?? ""
    let port = components?.port ?? (scheme == "https" ? 443 : 80)
    var path = components?.percentEncodedPath ?? ""
    while path.hasSuffix("/") { path.removeLast() }
    let identity = [scheme, host, String(port), path, liveCredentialSubject(token), budgetID]
    // All components are strings, so JSON serialization cannot fail. Length framing through JSON
    // avoids the delimiter collisions of concatenated user/budget/host identifiers.
    let data = try! JSONSerialization.data(withJSONObject: identity)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func isTransientConnectivityFailure(_ error: Error) -> Bool {
    if error is URLError { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain { return true }
    if case let APIClientError.server(status, _) = error { return status == 408 || status == 429 || status >= 500 }
    if case .some(.temporarilyUnavailable) = error as? BudgetApplicationError { return true }
    return false
}

// MARK: - Capability-oriented repository contracts

@MainActor
protocol AccountCommandRepository: AnyObject {
    func createAccount(_ operation: CreateAccountOperation) async throws
    func updateAccount(_ operation: UpdateAccountMetadataOperation) async throws
    func accountHistory(accountID: String, limit: Int, offset: Int) async throws -> [APIAccountRevision]
    func accountDebtTerms(accountID: String) async throws -> APIAccountDebtTerms?
    func updateAccountDebtTerms(accountID: String, value: APIAccountDebtTermsUpsert) async throws -> APIAccountDebtTerms
    func deleteAccountDebtTerms(accountID: String) async throws
    func accountDebtTermsHistory(accountID: String, limit: Int, offset: Int) async throws -> [APIAccountDebtTermsRevision]
    func reconcileAccount(_ operation: ReconcileAccountOperation) async throws
    func reconciliationClearedObservation(accountID: String, throughDate: String) async throws -> Int64
    func reconciliationReviewObservation(accountID: String, throughDate: String) async throws -> ReconciliationReviewObservation
    func reconciliationHistory(accountID: String, limit: Int, offset: Int) async throws -> [APIReconciliationHistory]
    func recentReconciliationHistory(limit: Int) async throws -> [APIReconciliationHistory]
}

struct ReconciliationReviewObservation: Equatable, Sendable {
    let clearedBalanceMinor: Int64
    let reviewRevision: String?
}

extension AccountCommandRepository {
    func reconciliationReviewObservation(accountID: String, throughDate: String) async throws -> ReconciliationReviewObservation {
        ReconciliationReviewObservation(clearedBalanceMinor: try await reconciliationClearedObservation(accountID: accountID, throughDate: throughDate), reviewRevision: nil)
    }
}

@MainActor
protocol PlanningCommandRepository: AnyObject {
    func assignMoney(_ operation: AssignMoneyOperation) async throws
    func moveMoney(_ operation: MoveMoneyOperation) async throws
    func cashRolloverPolicy() async throws -> APICashRolloverPolicyObservation
    func selectCashRolloverPolicy(_ selection: APICashRolloverPolicySelection) async throws -> APICashRolloverPolicyObservation
    func cashRolloverPolicyHistory(beforeVersion: Int?) async throws -> APICashRolloverPolicyHistory
}

@MainActor
protocol TransactionCommandRepository: AnyObject {
    func recordTransaction(_ operation: RecordTransactionOperation) async throws
    func updateTransaction(id: String, operation: RecordTransactionOperation) async throws
    func deleteTransaction(id: String) async throws
    func deleteTransaction(_ operation: DeleteTransactionOperation) async throws
    func duplicateTransaction(id: String, occurredOn: String) async throws
    func duplicateTransaction(_ operation: DuplicateTransactionOperation) async throws
    func voidTransaction(id: String, reason: String) async throws
    func voidTransaction(_ operation: VoidTransactionOperation) async throws
    func createScheduleFromTransaction(id: String, operation: MakeRecurringOperation) async throws
    func transactionAttachments(id: String) async throws -> [APITransactionAttachment]
    func transactionHistory(id: String, limit: Int, offset: Int) async throws -> [APITransactionChange]
    func recentTransactionChanges(limit: Int) async throws -> [APITransactionChange]
    func uploadTransactionAttachment(id: String, filename: String, contentType: String, data: Data) async throws
    func downloadTransactionAttachment(transactionID: String, attachmentID: String) async throws -> Data
    func detachTransactionAttachment(transactionID: String, attachmentID: String) async throws
    func detachTransactionAttachment(_ operation: DetachAttachmentOperation) async throws
    func bulkUpdateTransactions(_ update: APITransactionBulkUpdate) async throws
    func transferMoney(_ operation: TransferMoneyOperation) async throws
    func updateTransfer(id: String, operation: TransferMoneyOperation) async throws
    func deleteTransfer(id: String) async throws
    func deleteTransfer(_ operation: DeleteTransferOperation) async throws
}

extension TransactionCommandRepository {
    func deleteTransfer(_ operation: DeleteTransferOperation) async throws {
        try await deleteTransfer(id: operation.transferID)
    }
    func deleteTransaction(_ operation: DeleteTransactionOperation) async throws {
        try await deleteTransaction(id: operation.transactionID)
    }
    func duplicateTransaction(_ operation: DuplicateTransactionOperation) async throws {
        try await duplicateTransaction(id: operation.transactionID, occurredOn: operation.occurredOn)
    }
    func detachTransactionAttachment(_ operation: DetachAttachmentOperation) async throws {
        try await detachTransactionAttachment(transactionID: operation.transactionID, attachmentID: operation.attachmentID)
    }
    func voidTransaction(_ operation: VoidTransactionOperation) async throws {
        try await voidTransaction(id: operation.transactionID, reason: operation.reason)
    }
}

@MainActor
protocol TransactionBrowserRepository: AnyObject {
    func browseTransactions(query: APITransactionQuery) async throws -> APITransactionPage
}

@MainActor
protocol PayeeCommandRepository: AnyObject {
    func searchPayees(query: String, includeArchived: Bool, limit: Int, cursor: String?) async throws -> APIPayeePage
    func createPayee(_ operation: CreatePayeeOperation) async throws
    func updatePayee(_ operation: UpdatePayeeOperation) async throws
    func mergePayee(sourceID: String, destinationID: String) async throws
    func createPayeeAlias(payeeID: String, displayName: String) async throws
    func deletePayeeAlias(payeeID: String, aliasID: String) async throws
    func payeeHistory(payeeID: String, limit: Int, offset: Int) async throws -> [APIPayeeRevision]
}

@MainActor
protocol ScheduleCommandRepository: AnyObject {
    func scheduleHistory(limit: Int, offset: Int) async throws -> [APIScheduledTransactionRevision]
    func createSchedule(_ operation: ScheduleOperation) async throws
    func updateSchedule(id: String, operation: ScheduleOperation) async throws
    func deleteSchedule(id: String) async throws
    func deleteSchedule(_ operation: DeleteScheduleOperation) async throws
    func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation
    func realizeSchedule(_ operation: RealizeScheduleOperation) async throws
}

extension ScheduleCommandRepository {
    func realizeSchedule(_ operation: RealizeScheduleOperation) async throws {
        _ = try await realizeSchedule(id: operation.scheduleID)
    }
    func deleteSchedule(_ operation: DeleteScheduleOperation) async throws {
        try await deleteSchedule(id: operation.scheduleID)
    }
}

typealias CoreFinancialRepository = AccountCommandRepository & PlanningCommandRepository & TransactionCommandRepository & TransactionBrowserRepository & ScheduleCommandRepository & PayeeCommandRepository

// MARK: - Shared application services

@MainActor
struct AccountService {
    private let repository: any AccountCommandRepository
    init(repository: any AccountCommandRepository) { self.repository = repository }

    func create(_ operation: CreateAccountOperation) async throws {
        guard !operation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BudgetApplicationError.invalidOperation("Enter an account name.")
        }
        let validKind = operation.isOnBudget
            ? ["checking", "savings", "cash", "credit"].contains(operation.kind)
            : ["loan", "mortgage", "asset", "tracking"].contains(operation.kind)
        guard validKind else {
            throw BudgetApplicationError.invalidOperation("Choose a budget account type for On budget, or Loan/Mortgage/Asset/Tracking for Tracking.")
        }
        do { try await repository.createAccount(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func update(_ operation: UpdateAccountMetadataOperation) async throws {
        guard !operation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BudgetApplicationError.invalidOperation("Enter an account name.")
        }
        let cashTypes = Set(["checking", "savings", "cash"])
        let trackingTypes = Set(["loan", "mortgage", "asset", "tracking"])
        let safe = operation.kind == operation.currentKind
            || (operation.isOnBudget && cashTypes.contains(operation.currentKind) && cashTypes.contains(operation.kind))
            || (!operation.isOnBudget && trackingTypes.contains(operation.currentKind) && trackingTypes.contains(operation.kind))
        guard safe else {
            throw BudgetApplicationError.invalidOperation("This type change could reinterpret financial history. Create the appropriate account and move or reconcile explicitly instead.")
        }
        do { try await repository.updateAccount(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func history(accountID: String, limit: Int, offset: Int) async throws -> [APIAccountRevision] {
        guard (1...100).contains(limit), offset >= 0 else {
            throw BudgetApplicationError.invalidOperation("Account history request is out of range.")
        }
        do { return try await repository.accountHistory(accountID: accountID, limit: limit, offset: offset) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func reconcile(_ operation: ReconcileAccountOperation) async throws {
        do { try await repository.reconcileAccount(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func reconciliationClearedObservation(accountID: String, throughDate: String) async throws -> Int64 {
        _ = try PlanningPeriodProjection.Day(throughDate)
        do { return try await repository.reconciliationClearedObservation(accountID: accountID, throughDate: throughDate) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func reconciliationReviewObservation(accountID: String, throughDate: String) async throws -> ReconciliationReviewObservation {
        _ = try PlanningPeriodProjection.Day(throughDate)
        do { return try await repository.reconciliationReviewObservation(accountID: accountID, throughDate: throughDate) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func reconciliationHistory(accountID: String, limit: Int, offset: Int) async throws -> [APIReconciliationHistory] {
        do { return try await repository.reconciliationHistory(accountID: accountID, limit: limit, offset: offset) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func recentReconciliationHistory(limit: Int) async throws -> [APIReconciliationHistory] {
        guard (1...25).contains(limit) else {
            throw BudgetApplicationError.invalidOperation("Recent reconciliation history must request between 1 and 25 entries.")
        }
        do { return try await repository.recentReconciliationHistory(limit: limit) }
        catch { throw BudgetApplicationError.map(error) }
    }
}

@MainActor
struct BudgetPlanningService {
    private let repository: any PlanningCommandRepository
    init(repository: any PlanningCommandRepository) { self.repository = repository }

    func cashRolloverPolicy() async throws -> APICashRolloverPolicyObservation {
        do { return try await repository.cashRolloverPolicy() }
        catch { throw BudgetApplicationError.map(error) }
    }

    func selectCashRolloverPolicy(_ selection: APICashRolloverPolicySelection) async throws -> APICashRolloverPolicyObservation {
        do { return try await repository.selectCashRolloverPolicy(selection) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func cashRolloverPolicyHistory(beforeVersion: Int? = nil) async throws -> APICashRolloverPolicyHistory {
        do { return try await repository.cashRolloverPolicyHistory(beforeVersion: beforeVersion) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func assign(_ operation: AssignMoneyOperation) async throws {
        do { try await repository.assignMoney(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func move(_ operation: MoveMoneyOperation) async throws {
        guard operation.amountMinor > 0, operation.sourceCategoryID != operation.destinationCategoryID else {
            throw BudgetApplicationError.invalidOperation("Choose two categories and enter an amount greater than zero.")
        }
        do { try await repository.moveMoney(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }
}

@MainActor
struct TransactionService {
    private let repository: any TransactionCommandRepository & TransactionBrowserRepository
    init(repository: any TransactionCommandRepository & TransactionBrowserRepository) { self.repository = repository }

    func browse(_ query: APITransactionQuery) async throws -> APITransactionPage {
        do { return try await repository.browseTransactions(query: query) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func record(_ operation: RecordTransactionOperation) async throws {
        try validate(operation)
        do { try await repository.recordTransaction(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func update(id: String, operation: RecordTransactionOperation) async throws {
        try validate(operation)
        do { try await repository.updateTransaction(id: id, operation: operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func delete(id: String) async throws {
        do { try await repository.deleteTransaction(id: id) }
        catch { throw BudgetApplicationError.map(error) }
    }
    func delete(_ operation: DeleteTransactionOperation) async throws {
        do { try await repository.deleteTransaction(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func duplicate(id: String, occurredOn: String) async throws {
        do { try await repository.duplicateTransaction(id: id, occurredOn: occurredOn) }
        catch { throw BudgetApplicationError.map(error) }
    }
    func duplicate(_ operation: DuplicateTransactionOperation) async throws {
        do { try await repository.duplicateTransaction(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func void(id: String, reason: String) async throws {
        do { try await repository.voidTransaction(id: id, reason: reason) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func void(_ operation: VoidTransactionOperation) async throws {
        do { try await repository.voidTransaction(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func makeRecurring(id: String, operation: MakeRecurringOperation) async throws {
        guard !operation.nextDate.isEmpty else { throw BudgetApplicationError.invalidOperation("Choose a future next occurrence.") }
        do { try await repository.createScheduleFromTransaction(id: id, operation: operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func attachments(id: String) async throws -> [APITransactionAttachment] {
        do { return try await repository.transactionAttachments(id: id) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func history(id: String, limit: Int = 50, offset: Int = 0) async throws -> [APITransactionChange] {
        guard (1...100).contains(limit), offset >= 0 else {
            throw BudgetApplicationError.invalidOperation("Transaction history page is invalid.")
        }
        do { return try await repository.transactionHistory(id: id, limit: limit, offset: offset) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func recentChanges(limit: Int = 5) async throws -> [APITransactionChange] {
        do { return try await repository.recentTransactionChanges(limit: limit) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func uploadAttachment(id: String, filename: String, contentType: String, data: Data) async throws {
        guard data.count <= 10 * 1024 * 1024 else { throw BudgetApplicationError.invalidOperation("Attachments must be 10 MB or smaller.") }
        do { try await repository.uploadTransactionAttachment(id: id, filename: filename, contentType: contentType, data: data) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func downloadAttachment(transactionID: String, attachmentID: String) async throws -> Data {
        do { return try await repository.downloadTransactionAttachment(transactionID: transactionID, attachmentID: attachmentID) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func detachAttachment(transactionID: String, attachmentID: String) async throws {
        do { try await repository.detachTransactionAttachment(transactionID: transactionID, attachmentID: attachmentID) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func detachAttachment(_ operation: DetachAttachmentOperation) async throws {
        do { try await repository.detachTransactionAttachment(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func bulkUpdate(_ update: APITransactionBulkUpdate) async throws {
        guard !update.transactionIDs.isEmpty else { throw BudgetApplicationError.invalidOperation("Select at least one transaction.") }
        do { try await repository.bulkUpdateTransactions(update) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func transfer(_ operation: TransferMoneyOperation) async throws {
        try validateTransfer(operation)
        do { try await repository.transferMoney(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func updateTransfer(id: String, operation: TransferMoneyOperation) async throws {
        try validateTransfer(operation)
        do { try await repository.updateTransfer(id: id, operation: operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func deleteTransfer(id: String) async throws {
        do { try await repository.deleteTransfer(id: id) }
        catch { throw BudgetApplicationError.map(error) }
    }
    func deleteTransfer(_ operation: DeleteTransferOperation) async throws {
        do { try await repository.deleteTransfer(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    private func validateTransfer(_ operation: TransferMoneyOperation) throws {
        guard operation.amountMinor > 0, operation.sourceAccountID != operation.destinationAccountID else {
            throw BudgetApplicationError.invalidOperation("Choose two accounts and enter an amount greater than zero.")
        }
    }

    func validate(_ operation: RecordTransactionOperation) throws {
        guard operation.amountMinor != 0 else {
            throw BudgetApplicationError.invalidOperation("Transaction amount must not be zero.")
        }
        guard operation.categoryID == nil || operation.splits.isEmpty else {
            throw BudgetApplicationError.invalidOperation("Use either one category or transaction splits.")
        }
        if !operation.splits.isEmpty {
            guard Set(operation.splits.map(\.categoryID)).count == operation.splits.count else {
                throw BudgetApplicationError.invalidOperation("Each split must use a different category.")
            }
            guard let total = try? Money.sumMinorUnits(operation.splits.map(\.amountMinor)), total == operation.amountMinor else {
                throw BudgetApplicationError.invalidOperation("Split amounts must equal the transaction amount and fit the supported amount range.")
            }
        }
    }
}

@MainActor
struct ScheduleService {
    private let repository: any ScheduleCommandRepository
    init(repository: any ScheduleCommandRepository) { self.repository = repository }

    func create(_ operation: ScheduleOperation) async throws {
        try validate(operation)
        do { try await repository.createSchedule(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func update(id: String, operation: ScheduleOperation) async throws {
        try validate(operation)
        do { try await repository.updateSchedule(id: id, operation: operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func delete(id: String) async throws {
        do { try await repository.deleteSchedule(id: id) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func delete(_ operation: DeleteScheduleOperation) async throws {
        do { try await repository.deleteSchedule(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func realize(id: String) async throws -> ScheduledRealizationObservation {
        do { return try await repository.realizeSchedule(id: id) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func realize(_ operation: RealizeScheduleOperation) async throws {
        do { try await repository.realizeSchedule(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    private func validate(_ operation: ScheduleOperation) throws {
        guard operation.amountMinor != 0, operation.intervalCount > 0 else {
            throw BudgetApplicationError.invalidOperation("Enter a non-zero amount and valid recurrence.")
        }
    }
}

@MainActor
struct BudgetApplicationServices {
    let accounts: AccountService
    let planning: BudgetPlanningService
    let transactions: TransactionService
    let schedules: ScheduleService
    let payees: PayeeService

    init(repository: any CoreFinancialRepository) {
        accounts = AccountService(repository: repository)
        planning = BudgetPlanningService(repository: repository)
        transactions = TransactionService(repository: repository)
        schedules = ScheduleService(repository: repository)
        payees = PayeeService(repository: repository)
    }
}

@MainActor
struct PayeeService {
    private let repository: any PayeeCommandRepository
    init(repository: any PayeeCommandRepository) { self.repository = repository }
    func search(query: String = "", includeArchived: Bool = false, limit: Int = 20, cursor: String? = nil) async throws -> APIPayeePage {
        do { return try await repository.searchPayees(query: query, includeArchived: includeArchived, limit: limit, cursor: cursor) }
        catch { throw BudgetApplicationError.map(error) }
    }
    func create(_ operation: CreatePayeeOperation) async throws {
        guard !operation.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BudgetApplicationError.invalidOperation("Enter a payee name.") }
        do { try await repository.createPayee(operation) } catch { throw BudgetApplicationError.map(error) }
    }
    func update(_ operation: UpdatePayeeOperation) async throws {
        guard !operation.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BudgetApplicationError.invalidOperation("Enter a payee name.") }
        do { try await repository.updatePayee(operation) } catch { throw BudgetApplicationError.map(error) }
    }
    func merge(sourceID: String, destinationID: String) async throws {
        guard sourceID != destinationID else { throw BudgetApplicationError.invalidOperation("Choose a different destination payee.") }
        do { try await repository.mergePayee(sourceID: sourceID, destinationID: destinationID) } catch { throw BudgetApplicationError.map(error) }
    }
    func createAlias(payeeID: String, displayName: String) async throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BudgetApplicationError.invalidOperation("Enter an alias.") }
        do { try await repository.createPayeeAlias(payeeID: payeeID, displayName: displayName) } catch { throw BudgetApplicationError.map(error) }
    }
    func deleteAlias(payeeID: String, aliasID: String) async throws {
        do { try await repository.deletePayeeAlias(payeeID: payeeID, aliasID: aliasID) } catch { throw BudgetApplicationError.map(error) }
    }
}

// MARK: - Live transport translation

extension RecordTransactionOperation {
    var apiValue: APITransactionCreate {
        APITransactionCreate(
            accountID: accountID,
            categoryID: categoryID,
            payeeID: payeeID,
            amountMinor: amountMinor,
            occurredOn: occurredOn,
            payeeName: payeeName,
            memo: memo,
            financialClassification: financialClassification,
            isCleared: isCleared,
            splits: splits.map { APITransactionSplitCreate(categoryID: $0.categoryID, amountMinor: $0.amountMinor, memo: $0.memo, financialClassification: $0.financialClassification) },
            flag: flag,
            tags: tags,
            attachmentMetadata: attachmentMetadata,
            clientOperationID: clientOperationID,
            expectedRevision: expectedRevision,
            mutationOperationID: mutationOperationID
        )
    }
}

extension TransferMoneyOperation {
    var apiValue: APITransferCreate {
        APITransferCreate(sourceAccountID: sourceAccountID, destinationAccountID: destinationAccountID, amountMinor: amountMinor, occurredOn: occurredOn, memo: memo, isCleared: isCleared, mutationOperationID: mutationOperationID, expectedRevisions: expectedRevisions)
    }
}

extension ScheduleOperation {
    var apiValue: APIScheduledTransactionCreate {
        APIScheduledTransactionCreate(accountID: accountID, destinationAccountID: destinationAccountID, categoryID: categoryID, payeeID: payeeID, name: name, amountMinor: amountMinor, nextDate: nextDate, recurrenceUnit: recurrenceUnit, intervalCount: intervalCount, endDate: endDate, remainingOccurrences: remainingOccurrences, memo: memo, financialClassification: financialClassification, isActive: isActive, expectedRevision: expectedRevision, mutationOperationID: mutationOperationID)
    }
}
