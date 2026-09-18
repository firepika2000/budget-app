import BudgetAPI
import BudgetCore
import Foundation

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
}

struct AssignMoneyOperation: Equatable, Sendable {
    let categoryID: String
    let month: String
    let assignedMinor: Int64
    let expectedVersion: Int
}

struct MoveMoneyOperation: Equatable, Sendable {
    let sourceCategoryID: String
    let destinationCategoryID: String
    let amountMinor: Int64
    let occurredOn: String
    let note: String
    let expectedVersion: Int
}

struct TransactionSplitOperation: Equatable, Sendable {
    let categoryID: String
    let amountMinor: Int64
    let memo: String
    var financialClassification: String? = nil
}

struct RecordTransactionOperation: Equatable, Sendable {
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
}

struct MakeRecurringOperation: Equatable, Sendable {
    let recurrenceUnit: String
    let intervalCount: Int
    let nextDate: String
}

struct CreatePayeeOperation: Equatable, Sendable { let displayName: String; let defaultCategoryID: String? }
struct UpdatePayeeOperation: Equatable, Sendable { let payeeID: String; let displayName: String; let isArchived: Bool; let defaultCategoryID: String? }

struct TransferMoneyOperation: Equatable, Sendable {
    let sourceAccountID: String
    let destinationAccountID: String
    let amountMinor: Int64
    let occurredOn: String
    let memo: String
    let isCleared: Bool
}

struct ReconcileAccountOperation: Equatable, Sendable {
    let accountID: String
    let statementBalanceMinor: Int64
    let throughDate: String
    let createAdjustment: Bool
    let reason: String
    let expectedClearedBalanceMinor: Int64
}

struct ScheduleOperation: Equatable, Sendable {
    let accountID: String
    let destinationAccountID: String?
    let categoryID: String?
    let payeeID: String?
    let name: String
    let amountMinor: Int64
    let nextDate: String
    let recurrenceUnit: String
    let intervalCount: Int
    let memo: String
    let financialClassification: String?
    let isActive: Bool

    init(accountID: String, destinationAccountID: String? = nil, categoryID: String? = nil, payeeID: String? = nil, name: String,
         amountMinor: Int64, nextDate: String, recurrenceUnit: String, intervalCount: Int = 1,
         memo: String = "", financialClassification: String? = nil, isActive: Bool = true) {
        self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.categoryID = categoryID; self.payeeID = payeeID
        self.name = name; self.amountMinor = amountMinor; self.nextDate = nextDate; self.recurrenceUnit = recurrenceUnit
        self.intervalCount = intervalCount; self.memo = memo; self.financialClassification = financialClassification; self.isActive = isActive
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

// MARK: - Capability-oriented repository contracts

@MainActor
protocol AccountCommandRepository: AnyObject {
    func createAccount(_ operation: CreateAccountOperation) async throws
    func updateAccount(_ operation: UpdateAccountMetadataOperation) async throws
    func accountDebtTerms(accountID: String) async throws -> APIAccountDebtTerms?
    func updateAccountDebtTerms(accountID: String, value: APIAccountDebtTermsUpsert) async throws -> APIAccountDebtTerms
    func deleteAccountDebtTerms(accountID: String) async throws
    func reconcileAccount(_ operation: ReconcileAccountOperation) async throws
}

@MainActor
protocol PlanningCommandRepository: AnyObject {
    func assignMoney(_ operation: AssignMoneyOperation) async throws
    func moveMoney(_ operation: MoveMoneyOperation) async throws
}

@MainActor
protocol TransactionCommandRepository: AnyObject {
    func recordTransaction(_ operation: RecordTransactionOperation) async throws
    func updateTransaction(id: String, operation: RecordTransactionOperation) async throws
    func deleteTransaction(id: String) async throws
    func duplicateTransaction(id: String, occurredOn: String) async throws
    func voidTransaction(id: String, reason: String) async throws
    func createScheduleFromTransaction(id: String, operation: MakeRecurringOperation) async throws
    func transactionAttachments(id: String) async throws -> [APITransactionAttachment]
    func uploadTransactionAttachment(id: String, filename: String, contentType: String, data: Data) async throws
    func downloadTransactionAttachment(transactionID: String, attachmentID: String) async throws -> Data
    func detachTransactionAttachment(transactionID: String, attachmentID: String) async throws
    func bulkUpdateTransactions(_ update: APITransactionBulkUpdate) async throws
    func transferMoney(_ operation: TransferMoneyOperation) async throws
    func updateTransfer(id: String, operation: TransferMoneyOperation) async throws
    func deleteTransfer(id: String) async throws
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
}

@MainActor
protocol ScheduleCommandRepository: AnyObject {
    func createSchedule(_ operation: ScheduleOperation) async throws
    func updateSchedule(id: String, operation: ScheduleOperation) async throws
    func deleteSchedule(id: String) async throws
    func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation
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
            : ["loan", "tracking"].contains(operation.kind)
        guard validKind else {
            throw BudgetApplicationError.invalidOperation("Choose a budget account type for On budget, or Loan/Tracking for Tracking.")
        }
        do { try await repository.createAccount(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func update(_ operation: UpdateAccountMetadataOperation) async throws {
        guard !operation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BudgetApplicationError.invalidOperation("Enter an account name.")
        }
        let cashTypes = Set(["checking", "savings", "cash"])
        let trackingTypes = Set(["loan", "tracking"])
        let safe = operation.kind == operation.currentKind
            || (operation.isOnBudget && cashTypes.contains(operation.currentKind) && cashTypes.contains(operation.kind))
            || (!operation.isOnBudget && trackingTypes.contains(operation.currentKind) && trackingTypes.contains(operation.kind))
        guard safe else {
            throw BudgetApplicationError.invalidOperation("This type change could reinterpret financial history. Create the appropriate account and move or reconcile explicitly instead.")
        }
        do { try await repository.updateAccount(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func reconcile(_ operation: ReconcileAccountOperation) async throws {
        do { try await repository.reconcileAccount(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }
}

@MainActor
struct BudgetPlanningService {
    private let repository: any PlanningCommandRepository
    init(repository: any PlanningCommandRepository) { self.repository = repository }

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

    func duplicate(id: String, occurredOn: String) async throws {
        do { try await repository.duplicateTransaction(id: id, occurredOn: occurredOn) }
        catch { throw BudgetApplicationError.map(error) }
    }

    func void(id: String, reason: String) async throws {
        do { try await repository.voidTransaction(id: id, reason: reason) }
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

    func realize(id: String) async throws -> ScheduledRealizationObservation {
        do { return try await repository.realizeSchedule(id: id) }
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
            attachmentMetadata: attachmentMetadata
        )
    }
}

extension TransferMoneyOperation {
    var apiValue: APITransferCreate {
        APITransferCreate(sourceAccountID: sourceAccountID, destinationAccountID: destinationAccountID, amountMinor: amountMinor, occurredOn: occurredOn, memo: memo, isCleared: isCleared)
    }
}

extension ScheduleOperation {
    var apiValue: APIScheduledTransactionCreate {
        APIScheduledTransactionCreate(accountID: accountID, destinationAccountID: destinationAccountID, categoryID: categoryID, payeeID: payeeID, name: name, amountMinor: amountMinor, nextDate: nextDate, recurrenceUnit: recurrenceUnit, intervalCount: intervalCount, memo: memo, financialClassification: financialClassification, isActive: isActive)
    }
}
