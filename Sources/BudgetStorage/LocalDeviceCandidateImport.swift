import Foundation

public struct LocalDeviceImportAttachment: Equatable, Sendable {
    public let record: LocalAttachmentRecord
    public let plaintext: Data

    public init(record: LocalAttachmentRecord, plaintext: Data) {
        self.record = record
        self.plaintext = plaintext
    }
}

public struct LocalDeviceCandidateImportResult: Equatable, Sendable {
    public let rootURL: URL
    public let budgetID: String
    public let attachmentCount: Int

    public init(rootURL: URL, budgetID: String, attachmentCount: Int) {
        self.rootURL = rootURL
        self.budgetID = budgetID
        self.attachmentCount = attachmentCount
    }
}

/// Builds a new Local Device authority from a complete, application-service-validated projection.
///
/// This is the provider cutover boundary, not an accounting converter. The caller must derive the
/// snapshot through the canonical server export/financial engine and compare its observations before
/// activation. This service verifies structural fidelity, attachment coverage, encryption, SQLite
/// integrity, and no-overwrite publication into a brand-new private directory.
public enum LocalDeviceCandidateImportService {
    public static func create(
        snapshot: LocalAuthoritySnapshot,
        authorityCreatedAt: String,
        attachments: [LocalDeviceImportAttachment],
        destinationRootURL: URL,
        attachmentKey: Data
    ) async throws -> LocalDeviceCandidateImportResult {
        let expectedRecords = Dictionary(grouping: snapshot.attachments, by: \.id)
        let supplied = Dictionary(grouping: attachments, by: { $0.record.id })
        guard expectedRecords.count == snapshot.attachments.count,
              supplied.count == attachments.count,
              Set(expectedRecords.keys) == Set(supplied.keys) else {
            throw LocalStorageError.invalidSnapshot("Server transfer attachment coverage is incomplete or ambiguous")
        }
        for item in attachments {
            guard expectedRecords[item.record.id]?.only == item.record,
                  Int64(item.plaintext.count) == item.record.sizeBytes else {
                throw LocalStorageError.invalidSnapshot("Server transfer attachment metadata does not match its payload")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.record.id, $0.plaintext) })
        return try await createStreaming(
            snapshot: snapshot, authorityCreatedAt: authorityCreatedAt,
            destinationRootURL: destinationRootURL, attachmentKey: attachmentKey
        ) { record in
            guard let value = byID[record.id] else {
                throw LocalStorageError.invalidSnapshot("Server transfer attachment payload is missing")
            }
            return value
        }
    }

    /// Fetches and encrypts one attachment at a time so a large authority never requires every
    /// plaintext object to coexist in memory. The loader must resolve the authorized manifest record
    /// supplied by this service; size and SHA-256 are verified before candidate publication.
    public static func createStreaming(
        snapshot: LocalAuthoritySnapshot,
        authorityCreatedAt: String,
        destinationRootURL: URL,
        attachmentKey: Data,
        attachmentLoader: (LocalAttachmentRecord) async throws -> Data
    ) async throws -> LocalDeviceCandidateImportResult {
        guard attachmentKey.count == 32 else {
            throw LocalStorageError.operationFailed("Local attachment key must contain exactly 32 bytes")
        }
        guard Set(snapshot.attachments.map(\.id)).count == snapshot.attachments.count,
              Set(snapshot.attachments.map(\.objectName)).count == snapshot.attachments.count else {
            throw LocalStorageError.invalidSnapshot("Server transfer attachment coverage is ambiguous")
        }
        let destination = destinationRootURL.standardizedFileURL
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LocalStorageError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".local-device-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        var published = false
        defer { if !published { try? fileManager.removeItem(at: staging) } }

        var authority: LocalAuthorityStore? = try LocalAuthorityStore(
            fileURL: staging.appendingPathComponent("authority.sqlite3")
        )
        let vault = try LocalAttachmentVault(
            directoryURL: staging.appendingPathComponent("Attachments", isDirectory: true),
            keyData: attachmentKey
        )
        do {
            guard let openedAuthority = authority else {
                throw LocalStorageError.operationFailed("Unable to create Local Device authority")
            }
            try await openedAuthority.bootstrap(snapshot.identity, createdAt: authorityCreatedAt)
            for record in snapshot.attachments {
                let plaintext = try await attachmentLoader(record)
                guard Int64(plaintext.count) == record.sizeBytes else {
                    throw LocalStorageError.invalidSnapshot("Server transfer attachment size does not match")
                }
                let stored = try await vault.store(plaintext, objectName: record.objectName)
                guard stored.plaintextSize == record.sizeBytes,
                      stored.plaintextSHA256 == record.sha256.lowercased() else {
                    throw LocalStorageError.invalidSnapshot("Server transfer attachment integrity does not match")
                }
            }
            try await openedAuthority.replaceWorkspaceState(snapshot)
            try await openedAuthority.integrityCheck()
            let reopened = try await openedAuthority.snapshot(budgetID: snapshot.identity.budgetID)
            try validateProjection(expected: snapshot, actual: reopened)
        }
        authority = nil

        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LocalStorageError.destinationExists
        }
        try fileManager.moveItem(at: staging, to: destination)
        published = true
        return .init(rootURL: destination, budgetID: snapshot.identity.budgetID,
                     attachmentCount: snapshot.attachments.count)
    }

    private static func validateProjection(
        expected: LocalAuthoritySnapshot,
        actual: LocalAuthoritySnapshot
    ) throws {
        guard canonicalSnapshot(actual) == canonicalSnapshot(expected) else {
            throw LocalStorageError.invalidSnapshot("Server transfer projection changed while creating Local Device storage")
        }
    }

    /// Optional collections exist only so older authority documents remain decodable. Once written
    /// to the current schema, an absent collection reopens as an explicit empty collection; those
    /// two representations are semantically identical and must not block an otherwise exact move.
    private static func canonicalSnapshot(_ value: LocalAuthoritySnapshot) -> LocalAuthoritySnapshot {
        LocalAuthoritySnapshot(
            identity: value.identity, accounts: value.accounts,
            accountRevisions: value.accountRevisions ?? [], structureRevisions: value.structureRevisions ?? [],
            groups: value.groups,
            categories: value.categories, payees: value.payees, payeeAliases: value.payeeAliases,
            transactions: value.transactions, allocations: value.allocations,
            reconciliations: value.reconciliations, targets: value.targets,
            targetRevisions: value.targetRevisions ?? [], schedules: value.schedules,
            scheduleRevisions: value.scheduleRevisions ?? [], attachments: value.attachments,
            attachmentTombstones: value.attachmentTombstones, debtTerms: value.debtTerms,
            debtPayoffPlans: value.debtPayoffPlans ?? [],
            cashRolloverPolicies: value.cashRolloverPolicies,
            creditReserveAttributions: value.creditReserveAttributions,
            transactionChanges: value.transactionChanges,
            creditReserveEvents: value.creditReserveEvents,
            statementImports: value.statementImports
        )
    }

}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
