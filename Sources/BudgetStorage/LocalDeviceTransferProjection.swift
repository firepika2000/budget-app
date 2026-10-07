import Foundation

public struct LocalDeviceTransferObservation: Equatable, Sendable {
    public struct TransactionTotal: Equatable, Sendable {
        public let accountID: String; public let status: String; public let amountMinor: Int64
    }
    public struct AllocationTotal: Equatable, Sendable {
        public let bucket: String; public let categoryID: String?; public let amountMinor: Int64
    }
    public struct ReserveTotal: Equatable, Sendable {
        public let paymentCategoryID: String; public let amountMinor: Int64
    }
    public let transactionCount: Int
    public let transactions: [TransactionTotal]
    public let allocationPostingCount: Int
    public let allocations: [AllocationTotal]
    public let reserveEventCount: Int
    public let reserves: [ReserveTotal]
}

public struct LocalDeviceTransferProjection: Equatable, Sendable {
    public let sourceRevision: String
    public let generatedAt: String
    public let authorityCreatedAt: String
    public let snapshot: LocalAuthoritySnapshot
    public let observations: LocalDeviceTransferObservation
}

/// Strictly translates the server transfer contract into the provider's typed persistence model.
/// No financial consequence is recomputed here; aggregate checks prove that representation mapping
/// retained the exact server ledger observations before attachment download or candidate creation.
public enum LocalDeviceTransferProjectionDecoder {
    public static func decode(_ data: Data) throws -> LocalDeviceTransferProjection {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value: Envelope
        do { value = try decoder.decode(Envelope.self, from: data) }
        catch { throw LocalStorageError.invalidSnapshot("Server transfer projection is unreadable") }
        guard value.format == "com.clearpocket.local-device-transfer", value.version == 1 else {
            throw LocalStorageError.invalidSnapshot("Server transfer projection version is unsupported")
        }
        guard value.sourceRevision.count == 64,
              value.sourceRevision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw LocalStorageError.invalidSnapshot("Server transfer source revision is invalid")
        }
        let identity = LocalAuthorityIdentity(
            householdID: value.identity.householdId, householdName: value.identity.householdName,
            ownerUserID: value.identity.ownerUserId, ownerDisplayName: value.identity.ownerDisplayName,
            budgetID: value.identity.budgetId, budgetName: value.identity.budgetName,
            currencyCode: value.identity.currencyCode
        )
        let statementImports = try (value.statementImports ?? []).map { item -> LocalStatementImportRecord in
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let payload = try encoder.encode(item.payload)
            return .init(
                id: item.id, budgetID: item.budgetId, accountID: item.accountId,
                status: item.status, version: item.version, sourceFormat: item.sourceFormat,
                candidateCount: item.candidateCount,
                payloadJSON: String(decoding: payload, as: UTF8.self), createdAt: item.createdAt
            )
        }
        let snapshot = LocalAuthoritySnapshot(
            identity: identity,
            accounts: value.accounts.map { .init(id: $0.id, budgetID: $0.budgetId, name: $0.name, kind: $0.kind, isOnBudget: $0.isOnBudget, isClosed: $0.isClosed, openingBalanceMinor: $0.openingBalanceMinor, createdAt: $0.createdAt) },
            groups: value.groups.map { .init(id: $0.id, budgetID: $0.budgetId, name: $0.name, sortOrder: $0.sortOrder, isArchived: $0.isArchived) },
            categories: value.categories.map { .init(
                id: $0.id, budgetID: $0.budgetId, groupID: $0.groupId, name: $0.name,
                iconName: $0.iconName, note: $0.note ?? "",
                delegatedUserID: $0.delegatedUserId, isArchived: $0.isArchived,
                sortOrder: $0.sortOrder, isFavorite: $0.isFavorite,
                favoriteSortOrder: $0.favoriteSortOrder,
                isEssential: $0.isEssential ?? false,
                isEmergencyFund: $0.isEmergencyFund ?? false
            ) },
            payees: value.payees.map { .init(id: $0.id, budgetID: $0.budgetId, name: $0.name, normalizedName: $0.normalizedName, defaultCategoryID: $0.defaultCategoryId, isArchived: $0.isArchived) },
            payeeAliases: value.payeeAliases.map { .init(id: $0.id, payeeID: $0.payeeId, displayName: $0.displayName, normalizedName: $0.normalizedName) },
            transactions: value.transactions.map { item in .init(
                id: item.id, budgetID: item.budgetId, accountID: item.accountId,
                payeeID: item.payeeId, payeeName: item.payeeName, amountMinor: item.amountMinor,
                occurredOn: item.occurredOn, memo: item.memo, isCleared: item.isCleared,
                isReconciled: item.isReconciled, status: item.status, transferID: item.transferId,
                flag: item.flag, tags: item.tags, financialClassification: item.financialClassification,
                voidReason: item.voidReason, reversalOfTransactionID: item.reversalOfTransactionId,
                reversalTransactionID: item.reversalTransactionId,
                createdByUserID: item.createdByUserId, createdAt: item.createdAt,
                splits: item.splits.map { .init(id: $0.id, categoryID: $0.categoryId, amountMinor: $0.amountMinor, memo: $0.memo) }
            ) },
            allocations: value.allocations.map { .init(id: $0.id, operationID: $0.operationId, budgetID: $0.budgetId, sourceCategoryID: $0.sourceCategoryId, categoryID: $0.categoryId, amountMinor: $0.amountMinor, occurredOn: $0.occurredOn, kind: $0.kind, actorUserID: $0.actorUserId, note: $0.note, createdAt: $0.createdAt) },
            reconciliations: value.reconciliations.map { .init(id: $0.id, accountID: $0.accountId, statementDate: $0.statementDate, statementBalanceMinor: $0.statementBalanceMinor, adjustmentTransactionID: $0.adjustmentTransactionId, createdAt: $0.createdAt) },
            targets: value.targets.map { .init(categoryID: $0.categoryId, targetType: $0.targetType, amountMinor: $0.amountMinor, cadence: $0.cadence, effectiveMonth: $0.effectiveMonth, snoozedMonth: $0.snoozedMonth, targetDate: $0.targetDate, recurrenceMonths: $0.recurrenceMonths, minimumContributionMinor: $0.minimumContributionMinor, priority: $0.priority, isActive: $0.isActive, snoozedMonths: $0.snoozedMonths) },
            schedules: value.schedules.map { .init(id: $0.id, budgetID: $0.budgetId, accountID: $0.accountId, destinationAccountID: $0.destinationAccountId, categoryID: $0.categoryId, payeeID: $0.payeeId, name: $0.name, amountMinor: $0.amountMinor, nextDate: $0.nextDate, recurrenceUnit: $0.recurrenceUnit, intervalCount: $0.intervalCount, memo: $0.memo, endDate: $0.endDate, remainingOccurrences: $0.remainingOccurrences, isActive: $0.isActive, financialClassification: $0.financialClassification, lastRealizedOn: $0.lastRealizedOn) },
            attachments: value.attachments.map { .init(id: $0.id, transactionID: $0.transactionId, filename: $0.filename, contentType: $0.contentType, sizeBytes: $0.sizeBytes, sha256: $0.sha256, objectName: $0.objectName, createdAt: $0.createdAt) },
            debtTerms: value.debtTerms.map { .init(accountID: $0.accountId, termsType: $0.termsType, annualRateBasisPoints: $0.annualRateBasisPoints, rateType: $0.rateType, paymentFrequency: $0.paymentFrequency, scheduledPaymentMinor: $0.scheduledPaymentMinor, minimumPaymentRule: $0.minimumPaymentRule, minimumPaymentMinor: $0.minimumPaymentMinor, minimumPaymentRateBasisPoints: $0.minimumPaymentRateBasisPoints, dueDay: $0.dueDay, statementDay: $0.statementDay, originalPrincipalMinor: $0.originalPrincipalMinor, originalTermMonths: $0.originalTermMonths, remainingTermMonths: $0.remainingTermMonths, promotionalRateBasisPoints: $0.promotionalRateBasisPoints, promotionalEndsOn: $0.promotionalEndsOn, updatedAt: $0.updatedAt) },
            cashRolloverPolicies: value.cashRolloverPolicies.map { .init(id: $0.id, budgetID: $0.budgetId, effectiveMonth: $0.effectiveMonth, policy: $0.policy, version: $0.version, source: $0.source, actorUserID: $0.actorUserId, createdAt: $0.createdAt) },
            creditReserveAttributions: value.creditReserveAttributions.map { .init(transactionID: $0.transactionId, categoryID: $0.categoryId, amountMinor: $0.amountMinor) },
            transactionChanges: value.transactionChanges.map { .init(id: $0.id, budgetID: $0.budgetId, transactionID: $0.transactionId, actorUserID: $0.actorUserId, action: $0.action, beforeJSON: $0.beforeJson, afterJSON: $0.afterJson, createdAt: $0.createdAt) },
            creditReserveEvents: value.creditReserveEvents.map { .init(id: $0.id, budgetID: $0.budgetId, creditAccountID: $0.creditAccountId, paymentCategoryID: $0.paymentCategoryId, spendingCategoryID: $0.spendingCategoryId, sourceTransactionID: $0.sourceTransactionId, transferID: $0.transferId, occurredOn: $0.occurredOn, amountMinor: $0.amountMinor, kind: $0.kind, actorUserID: $0.actorUserId, createdAt: $0.createdAt) },
            statementImports: statementImports
        )
        let observations = LocalDeviceTransferObservation(
            transactionCount: value.observations.transactionCount,
            transactions: value.observations.transactions.map { .init(accountID: $0.accountId, status: $0.status, amountMinor: $0.amountMinor) },
            allocationPostingCount: value.observations.allocationCount,
            allocations: value.observations.allocations.map { .init(bucket: $0.bucket, categoryID: $0.categoryId, amountMinor: $0.amountMinor) },
            reserveEventCount: value.observations.reserveCount,
            reserves: value.observations.reserves.map { .init(paymentCategoryID: $0.paymentCategoryId, amountMinor: $0.amountMinor) }
        )
        try validate(snapshot: snapshot, observations: observations)
        return .init(sourceRevision: value.sourceRevision, generatedAt: value.generatedAt,
                     authorityCreatedAt: value.authorityCreatedAt, snapshot: snapshot,
                     observations: observations)
    }

    private static func validate(snapshot: LocalAuthoritySnapshot, observations: LocalDeviceTransferObservation) throws {
        let budgetID = snapshot.identity.budgetID
        let budgetRows = snapshot.accounts.map(\.budgetID) + snapshot.groups.map(\.budgetID)
            + snapshot.categories.map(\.budgetID) + snapshot.payees.map(\.budgetID)
            + snapshot.transactions.map(\.budgetID) + snapshot.allocations.map(\.budgetID)
            + snapshot.schedules.map(\.budgetID) + snapshot.cashRolloverPolicies.map(\.budgetID)
            + snapshot.statementImports.map(\.budgetID)
            + snapshot.transactionChanges.map(\.budgetID) + snapshot.creditReserveEvents.map(\.budgetID)
        guard budgetRows.allSatisfy({ $0 == budgetID }) else {
            throw LocalStorageError.invalidSnapshot("Server transfer projection mixes budget identities")
        }
        guard Set(snapshot.accounts.map(\.id)).count == snapshot.accounts.count,
              Set(snapshot.transactions.map(\.id)).count == snapshot.transactions.count,
              Set(snapshot.attachments.map(\.id)).count == snapshot.attachments.count else {
            throw LocalStorageError.invalidSnapshot("Server transfer projection contains duplicate identities")
        }

        var transactionTotals: [String: Int64] = [:]
        for item in snapshot.transactions {
            transactionTotals["\(item.accountID)\u{1f}\(item.status)", default: 0] += item.amountMinor
        }
        let expectedTransactions = try uniqueObservationMap(
            observations.transactions.map { ("\($0.accountID)\u{1f}\($0.status)", $0.amountMinor) },
            label: "transaction"
        )
        guard observations.transactionCount == snapshot.transactions.count,
              transactionTotals == expectedTransactions else {
            throw LocalStorageError.invalidSnapshot("Server transaction observations changed during transfer mapping")
        }

        var allocationTotals: [String: Int64] = [:]
        for item in snapshot.allocations {
            guard let categoryID = item.categoryID else {
                throw LocalStorageError.invalidSnapshot("Server allocation projection is missing a category")
            }
            allocationTotals["category\u{1f}\(categoryID)", default: 0] += item.amountMinor
            if let source = item.sourceCategoryID {
                allocationTotals["category\u{1f}\(source)", default: 0] -= item.amountMinor
            } else {
                allocationTotals["ready_to_assign\u{1f}", default: 0] -= item.amountMinor
            }
        }
        allocationTotals = allocationTotals.filter { $0.value != 0 }
        let expectedAllocations = try uniqueObservationMap(
            observations.allocations.map { ("\($0.bucket)\u{1f}\($0.categoryID ?? "")", $0.amountMinor) },
            label: "allocation"
        ).filter { $0.value != 0 }
        guard allocationTotals == expectedAllocations else {
            throw LocalStorageError.invalidSnapshot("Server allocation observations changed during transfer mapping")
        }

        var reserveTotals: [String: Int64] = [:]
        for item in snapshot.creditReserveEvents {
            reserveTotals[item.paymentCategoryID, default: 0] += item.amountMinor
        }
        reserveTotals = reserveTotals.filter { $0.value != 0 }
        let expectedReserves = try uniqueObservationMap(
            observations.reserves.map { ($0.paymentCategoryID, $0.amountMinor) },
            label: "reserve"
        ).filter { $0.value != 0 }
        guard observations.reserveEventCount == snapshot.creditReserveEvents.count,
              reserveTotals == expectedReserves else {
            throw LocalStorageError.invalidSnapshot("Server reserve observations changed during transfer mapping")
        }
    }

    private static func uniqueObservationMap(
        _ rows: [(String, Int64)], label: String
    ) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (key, value) in rows {
            guard result.updateValue(value, forKey: key) == nil else {
                throw LocalStorageError.invalidSnapshot(
                    "Server transfer projection contains duplicate \(label) observations"
                )
            }
        }
        return result
    }
}

private struct Envelope: Decodable {
    let format: String; let version: Int; let generatedAt: String; let authorityCreatedAt: String
    let sourceRevision: String; let identity: IdentityDTO
    let accounts: [AccountDTO]; let groups: [GroupDTO]; let categories: [CategoryDTO]
    let payees: [PayeeDTO]; let payeeAliases: [AliasDTO]; let transactions: [TransactionDTO]
    let allocations: [AllocationDTO]; let reconciliations: [ReconciliationDTO]
    let targets: [TargetDTO]; let schedules: [ScheduleDTO]; let attachments: [AttachmentDTO]
    let debtTerms: [DebtTermsDTO]; let cashRolloverPolicies: [RolloverDTO]
    let statementImports: [StatementImportDTO]?
    let creditReserveAttributions: [AttributionDTO]; let transactionChanges: [ChangeDTO]
    let creditReserveEvents: [ReserveEventDTO]; let observations: ObservationsDTO
}

private struct IdentityDTO: Decodable { let householdId: String; let householdName: String; let ownerUserId: String; let ownerDisplayName: String; let budgetId: String; let budgetName: String; let currencyCode: String }
private struct AccountDTO: Decodable { let id: String; let budgetId: String; let name: String; let kind: String; let isOnBudget: Bool; let isClosed: Bool; let openingBalanceMinor: Int64; let createdAt: String }
private struct GroupDTO: Decodable { let id: String; let budgetId: String; let name: String; let sortOrder: Int64; let isArchived: Bool }
private struct CategoryDTO: Decodable {
    let id: String; let budgetId: String; let groupId: String; let name: String
    let iconName: String?; let note: String?
    let delegatedUserId: String?; let isArchived: Bool; let sortOrder: Int64
    let isFavorite: Bool; let favoriteSortOrder: Int64
    let isEssential: Bool?; let isEmergencyFund: Bool?
}
private struct PayeeDTO: Decodable { let id: String; let budgetId: String; let name: String; let normalizedName: String; let defaultCategoryId: String?; let isArchived: Bool }
private struct AliasDTO: Decodable { let id: String; let payeeId: String; let displayName: String; let normalizedName: String }
private struct SplitDTO: Decodable { let id: String; let categoryId: String; let amountMinor: Int64; let memo: String }
private struct TransactionDTO: Decodable { let id: String; let budgetId: String; let accountId: String; let payeeId: String?; let payeeName: String; let amountMinor: Int64; let occurredOn: String; let memo: String; let isCleared: Bool; let isReconciled: Bool; let status: String; let transferId: String?; let flag: String?; let tags: [String]; let financialClassification: String?; let voidReason: String?; let reversalOfTransactionId: String?; let reversalTransactionId: String?; let createdByUserId: String; let createdAt: String; let splits: [SplitDTO] }
private struct AllocationDTO: Decodable { let id: String; let operationId: String; let budgetId: String; let sourceCategoryId: String?; let categoryId: String?; let amountMinor: Int64; let occurredOn: String; let kind: String; let actorUserId: String; let note: String; let createdAt: String }
private struct ReconciliationDTO: Decodable { let id: String; let accountId: String; let statementDate: String; let statementBalanceMinor: Int64; let adjustmentTransactionId: String?; let createdAt: String }
private struct TargetDTO: Decodable { let categoryId: String; let targetType: String; let amountMinor: Int64; let cadence: String; let effectiveMonth: String; let snoozedMonth: String?; let targetDate: String?; let recurrenceMonths: Int64?; let minimumContributionMinor: Int64; let priority: Int64; let isActive: Bool; let snoozedMonths: [String] }
private struct ScheduleDTO: Decodable { let id: String; let budgetId: String; let accountId: String; let destinationAccountId: String?; let categoryId: String?; let payeeId: String?; let name: String; let amountMinor: Int64; let nextDate: String; let recurrenceUnit: String; let intervalCount: Int64; let memo: String; let endDate: String?; let remainingOccurrences: Int64?; let isActive: Bool; let financialClassification: String?; let lastRealizedOn: String? }
private struct AttachmentDTO: Decodable { let id: String; let transactionId: String; let filename: String; let contentType: String; let sizeBytes: Int64; let sha256: String; let objectName: String; let createdAt: String }
private struct DebtTermsDTO: Decodable { let accountId: String; let termsType: String; let annualRateBasisPoints: Int64?; let rateType: String?; let paymentFrequency: String?; let scheduledPaymentMinor: Int64?; let minimumPaymentRule: String?; let minimumPaymentMinor: Int64?; let minimumPaymentRateBasisPoints: Int64?; let dueDay: Int64?; let statementDay: Int64?; let originalPrincipalMinor: Int64?; let originalTermMonths: Int64?; let remainingTermMonths: Int64?; let promotionalRateBasisPoints: Int64?; let promotionalEndsOn: String?; let updatedAt: String }
private struct RolloverDTO: Decodable { let id: String; let budgetId: String; let effectiveMonth: String; let policy: String; let version: Int64; let source: String; let actorUserId: String?; let createdAt: String }
private struct AttributionDTO: Decodable { let transactionId: String; let categoryId: String; let amountMinor: Int64 }
private struct ChangeDTO: Decodable { let id: String; let budgetId: String; let transactionId: String; let actorUserId: String; let action: String; let beforeJson: String?; let afterJson: String?; let createdAt: String }
private struct ReserveEventDTO: Decodable { let id: String; let budgetId: String; let creditAccountId: String; let paymentCategoryId: String; let spendingCategoryId: String?; let sourceTransactionId: String?; let transferId: String?; let occurredOn: String; let amountMinor: Int64; let kind: String; let actorUserId: String; let createdAt: String }
private struct StatementImportDTO: Decodable {
    let id: String; let budgetId: String; let accountId: String; let status: String
    let version: Int64; let sourceFormat: String; let candidateCount: Int64
    let createdAt: String; let payload: StatementImportPayloadDTO
}
private struct StatementImportPayloadDTO: Codable {
    let id: String; let budgetId: String; let accountId: String; let status: String
    let version: Int64; let sourceFormat: String; let candidateCount: Int64
    let createdAt: String; let candidates: [StatementImportCandidateDTO]
}
private struct StatementImportCandidateDTO: Codable {
    let sourceRow: Int; let occurredOn: String; let amountMinor: Int64; let payee: String; let memo: String
    let exactTransactionIds: [String]; let possibleTransactionIds: [String]
    let suggestionsTruncated: Bool; let duplicateSourceRow: Bool
    let approvalAction: String?; let postedTransactionId: String?; let reversalTransactionId: String?
}
private struct ObservationsDTO: Decodable { let transactionCount: Int; let transactions: [TransactionTotalDTO]; let allocationCount: Int; let allocations: [AllocationTotalDTO]; let reserveCount: Int; let reserves: [ReserveTotalDTO] }
private struct TransactionTotalDTO: Decodable { let accountId: String; let status: String; let amountMinor: Int64 }
private struct AllocationTotalDTO: Decodable { let bucket: String; let categoryId: String?; let amountMinor: Int64 }
private struct ReserveTotalDTO: Decodable { let paymentCategoryId: String; let amountMinor: Int64 }
