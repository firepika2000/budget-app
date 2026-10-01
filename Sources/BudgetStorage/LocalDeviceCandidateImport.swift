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
        guard attachmentKey.count == 32 else {
            throw LocalStorageError.operationFailed("Local attachment key must contain exactly 32 bytes")
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
            for item in attachments {
                let stored = try await vault.store(item.plaintext, objectName: item.record.objectName)
                guard stored.plaintextSize == item.record.sizeBytes,
                      stored.plaintextSHA256 == item.record.sha256.lowercased() else {
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
        return .init(rootURL: destination, budgetID: snapshot.identity.budgetID, attachmentCount: attachments.count)
    }

    private static func validateProjection(
        expected: LocalAuthoritySnapshot,
        actual: LocalAuthoritySnapshot
    ) throws {
        guard actual == expected else {
            throw LocalStorageError.invalidSnapshot("Server transfer projection changed while creating Local Device storage")
        }
    }

}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
