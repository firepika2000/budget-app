import BudgetAPI
import Foundation

// MARK: - Canonical product operations

struct CreateAccountOperation: Equatable, Sendable {
    let name: String
    let kind: String
    let isOnBudget: Bool
    let openingBalanceMinor: Int64
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
}

struct RecordTransactionOperation: Equatable, Sendable {
    let accountID: String
    let categoryID: String?
    let amountMinor: Int64
    let occurredOn: String
    let payeeName: String
    let memo: String
    let isCleared: Bool
    let splits: [TransactionSplitOperation]
    let flag: String?
    let tags: [String]
    let attachmentMetadata: [[String: String]]
}

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
    let name: String
    let amountMinor: Int64
    let nextDate: String
    let recurrenceUnit: String
    let intervalCount: Int
    let memo: String
    let isActive: Bool

    init(accountID: String, destinationAccountID: String? = nil, categoryID: String? = nil, name: String,
         amountMinor: Int64, nextDate: String, recurrenceUnit: String, intervalCount: Int = 1,
         memo: String = "", isActive: Bool = true) {
        self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.categoryID = categoryID
        self.name = name; self.amountMinor = amountMinor; self.nextDate = nextDate; self.recurrenceUnit = recurrenceUnit
        self.intervalCount = intervalCount; self.memo = memo; self.isActive = isActive
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
    func transferMoney(_ operation: TransferMoneyOperation) async throws
}

@MainActor
protocol ScheduleCommandRepository: AnyObject {
    func createSchedule(_ operation: ScheduleOperation) async throws
    func updateSchedule(id: String, operation: ScheduleOperation) async throws
    func deleteSchedule(id: String) async throws
    func realizeSchedule(id: String) async throws -> ScheduledRealizationObservation
}

typealias CoreFinancialRepository = AccountCommandRepository & PlanningCommandRepository & TransactionCommandRepository & ScheduleCommandRepository

// MARK: - Shared application services

@MainActor
struct AccountService {
    private let repository: any AccountCommandRepository
    init(repository: any AccountCommandRepository) { self.repository = repository }

    func create(_ operation: CreateAccountOperation) async throws {
        guard !operation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BudgetApplicationError.invalidOperation("Enter an account name.")
        }
        do { try await repository.createAccount(operation) }
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
    private let repository: any TransactionCommandRepository
    init(repository: any TransactionCommandRepository) { self.repository = repository }

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

    func transfer(_ operation: TransferMoneyOperation) async throws {
        guard operation.amountMinor > 0, operation.sourceAccountID != operation.destinationAccountID else {
            throw BudgetApplicationError.invalidOperation("Choose two accounts and enter an amount greater than zero.")
        }
        do { try await repository.transferMoney(operation) }
        catch { throw BudgetApplicationError.map(error) }
    }

    private func validate(_ operation: RecordTransactionOperation) throws {
        guard operation.amountMinor != 0 else {
            throw BudgetApplicationError.invalidOperation("Transaction amount must not be zero.")
        }
        guard operation.categoryID == nil || operation.splits.isEmpty else {
            throw BudgetApplicationError.invalidOperation("Use either one category or transaction splits.")
        }
        if !operation.splits.isEmpty, operation.splits.reduce(Int64(0), { $0 + $1.amountMinor }) != operation.amountMinor {
            throw BudgetApplicationError.invalidOperation("Split amounts must equal the transaction amount.")
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

    init(repository: any CoreFinancialRepository) {
        accounts = AccountService(repository: repository)
        planning = BudgetPlanningService(repository: repository)
        transactions = TransactionService(repository: repository)
        schedules = ScheduleService(repository: repository)
    }
}

// MARK: - Live transport translation

extension RecordTransactionOperation {
    var apiValue: APITransactionCreate {
        APITransactionCreate(
            accountID: accountID,
            categoryID: categoryID,
            amountMinor: amountMinor,
            occurredOn: occurredOn,
            payeeName: payeeName,
            memo: memo,
            isCleared: isCleared,
            splits: splits.map { APITransactionSplitCreate(categoryID: $0.categoryID, amountMinor: $0.amountMinor, memo: $0.memo) },
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
        APIScheduledTransactionCreate(accountID: accountID, destinationAccountID: destinationAccountID, categoryID: categoryID, name: name, amountMinor: amountMinor, nextDate: nextDate, recurrenceUnit: recurrenceUnit, intervalCount: intervalCount, memo: memo, isActive: isActive)
    }
}
