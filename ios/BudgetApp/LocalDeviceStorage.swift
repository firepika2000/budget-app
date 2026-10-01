import BudgetStorage
import BudgetAPI
import Foundation

struct LocalDeviceStoragePaths: Equatable {
    let rootDirectory: URL
    let database: URL
    let attachments: URL

    init(applicationSupportDirectory: URL) {
        rootDirectory = applicationSupportDirectory
            .appendingPathComponent("BudgetApp", isDirectory: true)
            .appendingPathComponent("LocalDevice", isDirectory: true)
        database = rootDirectory.appendingPathComponent("authority.sqlite3", isDirectory: false)
        attachments = rootDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }
}

/// Native composition boundary for the Local Device provider.
///
/// Constructing this value opens the durable authority and encrypted object store together. The
/// production workspace adapter routes the same application-service commands used by Live through
/// this boundary, so local mode is a real authority rather than a renamed demo fixture.
@MainActor
struct LocalDeviceStorageComposition {
    let paths: LocalDeviceStoragePaths
    let authority: LocalAuthorityStore
    let attachments: LocalAttachmentVault
    let attachmentKey: Data
    let keyManager: LocalDeviceKeyManager
    let operationGate: LocalDeviceOperationGate

    init(
        applicationSupportDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws {
        let paths = LocalDeviceStoragePaths(applicationSupportDirectory: applicationSupportDirectory)
        try LocalDeviceRestoreCoordinator.applyPendingRestoreBeforeOpening(
            applicationDirectory: paths.rootDirectory.deletingLastPathComponent(),
            keyManager: keyManager
        )
        let key = try keyManager.loadOrCreateAttachmentKey()
        self.paths = paths
        attachmentKey = key
        self.keyManager = keyManager
        operationGate = LocalDeviceOperationGate()
        authority = try LocalAuthorityStore(fileURL: paths.database)
        attachments = try LocalAttachmentVault(directoryURL: paths.attachments, keyData: key)
    }

    static func production(
        fileManager: FileManager = .default
    ) throws -> LocalDeviceStorageComposition {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LocalDeviceStorageCompositionError.applicationSupportUnavailable
        }
        return try LocalDeviceStorageComposition(
            applicationSupportDirectory: applicationSupport,
            keyManager: LocalDeviceKeyManager()
        )
    }
}

enum LocalDeviceEraseCoordinator {
    /// Irreversibly removes the active authority, pending imports/restores, retained rollback
    /// generations, encrypted attachment objects, and every matching device-only key. Exported
    /// Files/Dropbox packages remain external artifacts and are intentionally outside this sandbox.
    @MainActor
    static func erase(_ composition: LocalDeviceStorageComposition, fileManager: FileManager = .default) async throws {
        await composition.operationGate.acquire()
        var stagedEntries: [(original: URL, staged: URL)] = []
        do {
            await composition.authority.close()
            let applicationDirectory = composition.paths.rootDirectory.deletingLastPathComponent()
            let quarantineDirectory = applicationDirectory
                .appendingPathComponent(".LocalDevice-Erase-\(UUID().uuidString)", isDirectory: true)
            let entries = try fileManager.contentsOfDirectory(
                at: applicationDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) + (try fileManager.contentsOfDirectory(
                at: applicationDirectory,
                includingPropertiesForKeys: nil,
                options: []
            ).filter { $0.lastPathComponent.hasPrefix(".") })
            let uniqueEntries = entries.reduce(into: [String: URL]()) { result, entry in
                result[entry.standardizedFileURL.path] = entry
            }.values
            let rollbackIdentifiers = uniqueEntries.map(\.lastPathComponent).filter { $0.hasPrefix("LocalDevice-Rollback-") }
            let eraseEntries = uniqueEntries.filter { entry in
                let name = entry.lastPathComponent
                return name == "LocalDevice"
                        || name == "pending-local-restore.json"
                        || name.hasPrefix("LocalDevice-Rollback-")
                        || name.hasPrefix(".LocalDevice-Restore-")
                        || name.hasPrefix(".LocalDevice-Transfer-")
            }
            if !eraseEntries.isEmpty {
                try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: false)
            }
            do {
                for entry in eraseEntries {
                    let staged = quarantineDirectory.appendingPathComponent(entry.lastPathComponent)
                    try fileManager.moveItem(at: entry, to: staged)
                    stagedEntries.append((entry, staged))
                }
            } catch {
                for item in stagedEntries.reversed() where fileManager.fileExists(atPath: item.staged.path) {
                    try? fileManager.moveItem(at: item.staged, to: item.original)
                }
                try? fileManager.removeItem(at: quarantineDirectory)
                throw error
            }
            composition.keyManager.deleteLocalAuthorityKeys(rollbackIdentifiers: rollbackIdentifiers)
            if fileManager.fileExists(atPath: quarantineDirectory.path) {
                try fileManager.removeItem(at: quarantineDirectory)
            }
            await composition.operationGate.release()
        } catch {
            await composition.operationGate.release()
            throw error
        }
    }
}

struct LocalDeviceBackupExport: Equatable {
    let packageURL: URL
    let recoveryKey: String
    let createdAt: String
    let encryptedBytes: Int64
}

struct LocalDevicePreparedRestore: Equatable {
    let budgetID: String
    let createdAt: String
}

struct ServerToLocalDeviceTransferResult: Equatable {
    let prepared: LocalDevicePreparedRestore
    let sourceRevision: String
    let attachmentCount: Int
}

/// Stages a server budget as a new encrypted Local Device authority without mutating the server.
/// Every network operation resolves the session's current credential, and a second stable revision
/// read proves the server authority did not change while attachment bytes were being downloaded.
@MainActor
final class ServerToLocalDeviceTransferCoordinator {
    typealias CredentialProvider = @MainActor (_ caller: String) async throws -> (URL, String)

    private let credentialProvider: CredentialProvider
    private let clientFactory: (URL) throws -> APIClient
    private let applicationSupportDirectory: URL
    private let keyManager: LocalDeviceKeyManager

    init(
        credentialProvider: @escaping CredentialProvider,
        clientFactory: @escaping (URL) throws -> APIClient = { try APIClient(baseURL: $0) },
        applicationSupportDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) {
        self.credentialProvider = credentialProvider
        self.clientFactory = clientFactory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.keyManager = keyManager
    }

    convenience init(
        session: AppSession,
        fileManager: FileManager = .default,
        keyManager: LocalDeviceKeyManager? = nil
    ) throws {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw LocalDeviceStorageCompositionError.applicationSupportUnavailable
        }
        self.init(
            credentialProvider: { caller in
                try await session.currentLiveCredentials(caller: caller)
            },
            applicationSupportDirectory: applicationSupport,
            keyManager: keyManager ?? LocalDeviceKeyManager()
        )
    }

    func prepare(budgetID: String) async throws -> ServerToLocalDeviceTransferResult {
        let (sourceURL, initialToken) = try await credentialProvider("localTransfer.projection.start")
        let initialData = try await clientFactory(sourceURL).localDeviceTransferProjectionData(
            budgetID: budgetID, token: initialToken
        )
        let projection = try LocalDeviceTransferProjectionDecoder.decode(initialData)
        guard projection.snapshot.identity.budgetID == budgetID else {
            throw LocalStorageError.invalidSnapshot("The server returned a different budget authority")
        }

        let applicationDirectory = applicationSupportDirectory
            .appendingPathComponent("BudgetApp", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: applicationDirectory.path
        )
        let candidate = applicationDirectory.appendingPathComponent(
            ".LocalDevice-Transfer-\(UUID().uuidString)", isDirectory: true
        )
        let attachmentKey = try LocalDeviceBackupRecoveryKey.generate().data
        var journalPublished = false
        defer {
            if !journalPublished { try? FileManager.default.removeItem(at: candidate) }
        }

        let imported = try await LocalDeviceCandidateImportService.createStreaming(
            snapshot: projection.snapshot,
            authorityCreatedAt: projection.authorityCreatedAt,
            destinationRootURL: candidate,
            attachmentKey: attachmentKey
        ) { [credentialProvider, clientFactory] record in
            let (currentURL, currentToken) = try await credentialProvider(
                "localTransfer.attachment.\(record.id)"
            )
            guard currentURL == sourceURL else {
                throw LocalStorageError.operationFailed("The selected server changed during transfer")
            }
            return try await clientFactory(currentURL).downloadTransactionAttachment(
                budgetID: budgetID,
                transactionID: record.transactionID,
                attachmentID: record.id,
                token: currentToken
            )
        }

        let (finalURL, finalToken) = try await credentialProvider("localTransfer.projection.finish")
        guard finalURL == sourceURL else {
            throw LocalStorageError.operationFailed("The selected server changed during transfer")
        }
        let finalData = try await clientFactory(finalURL).localDeviceTransferProjectionData(
            budgetID: budgetID, token: finalToken
        )
        let finalProjection = try LocalDeviceTransferProjectionDecoder.decode(finalData)
        guard finalProjection.sourceRevision == projection.sourceRevision else {
            throw LocalStorageError.operationFailed(
                "The budget changed during transfer. Nothing was activated; try again."
            )
        }

        let prepared = try LocalDeviceRestoreCoordinator.prepareImportedCandidate(
            imported,
            attachmentKey: attachmentKey,
            createdAt: projection.generatedAt,
            applicationDirectory: applicationDirectory,
            keyManager: keyManager
        )
        journalPublished = true
        return .init(
            prepared: prepared,
            sourceRevision: projection.sourceRevision,
            attachmentCount: imported.attachmentCount
        )
    }
}

struct LocalDeviceRollbackGeneration: Identifiable, Equatable {
    let id: String
    let retainedAt: Date
    let storedBytes: Int64
}

/// Crash-recoverable handoff from a verified backup into the production Local Device authority.
///
/// Restore never mutates an open SQLite authority. It decrypts into a new private directory and
/// records a small journal. The next cold composition applies that journal before opening SQLite,
/// retaining the prior authority and its attachment key as a rollback generation.
@MainActor
enum LocalDeviceRestoreCoordinator {
    private static let markerName = "pending-local-restore.json"
    private static var openedApplicationDirectories: Set<String> = []

    private struct Marker: Codable {
        let candidateName: String
        let rollbackName: String
        let budgetID: String
        let createdAt: String
        /// Absent in journals written before first-authority imports existed; those journals always
        /// replaced an existing Local Device authority and therefore require rollback preservation.
        let hadCurrentAuthority: Bool?
    }

    static func prepare(
        packageURL: URL,
        recoveryKey: LocalDeviceBackupRecoveryKey,
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) async throws -> LocalDevicePreparedRestore {
        let directory = applicationDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markerURL = directory.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            throw LocalStorageError.operationFailed("A verified restore is already waiting for the app to restart")
        }
        let identifier = UUID().uuidString
        let candidateName = ".LocalDevice-Restore-\(identifier)"
        let rollbackName = "LocalDevice-Rollback-\(identifier)"
        let candidate = directory.appendingPathComponent(candidateName, isDirectory: true)
        var preparedKey = false
        var publishedMarker = false
        defer {
            if !publishedMarker {
                if preparedKey { keyManager.clearPendingRestoreKey() }
                try? FileManager.default.removeItem(at: candidate)
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
        let result = try await LocalDeviceBackupService.restore(
            packageURL: packageURL,
            destinationRootURL: candidate,
            recoveryKey: recoveryKey
        )
        try keyManager.prepareRestoreKey(result.attachmentKey)
        preparedKey = true
        let marker = Marker(candidateName: candidateName, rollbackName: rollbackName,
                            budgetID: result.manifest.budgetID, createdAt: result.manifest.createdAt,
                            hadCurrentAuthority: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        publishedMarker = true
        return .init(budgetID: marker.budgetID, createdAt: marker.createdAt)
    }

    /// Publishes a fully verified server-import candidate into the same cold-start journal used by
    /// encrypted backup restore. The source server remains untouched; this only schedules local
    /// promotion and stores the candidate's independent attachment key in device-only Keychain.
    static func prepareImportedCandidate(
        _ result: LocalDeviceCandidateImportResult,
        attachmentKey: Data,
        createdAt: String,
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws -> LocalDevicePreparedRestore {
        let directory = applicationDirectory.standardizedFileURL
        let candidate = result.rootURL.standardizedFileURL
        let markerURL = directory.appendingPathComponent(markerName)
        guard candidate.deletingLastPathComponent() == directory,
              candidate.lastPathComponent.hasPrefix(".LocalDevice-Transfer-"),
              safeComponent(candidate.lastPathComponent) else {
            throw LocalStorageError.operationFailed("The verified transfer candidate path is invalid")
        }
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("authority.sqlite3").path
              ) else {
            throw LocalStorageError.invalidSnapshot("The verified transfer candidate is unavailable")
        }
        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            throw LocalStorageError.operationFailed("A verified restore is already waiting for the app to restart")
        }
        try keyManager.prepareRestoreKey(attachmentKey)
        var published = false
        defer {
            if !published {
                keyManager.clearPendingRestoreKey()
                try? FileManager.default.removeItem(at: candidate)
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
        let current = directory.appendingPathComponent("LocalDevice", isDirectory: true)
        let marker = Marker(
            candidateName: candidate.lastPathComponent,
            rollbackName: "LocalDevice-Rollback-\(UUID().uuidString)",
            budgetID: result.budgetID,
            createdAt: createdAt,
            hadCurrentAuthority: FileManager.default.fileExists(atPath: current.path)
        )
        try write(marker: marker, to: markerURL)
        published = true
        return .init(budgetID: marker.budgetID, createdAt: marker.createdAt)
    }

    @discardableResult
    static func applyPendingRestoreBeforeOpening(
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws -> Bool {
        let identity = applicationDirectory.standardizedFileURL.path
        guard !openedApplicationDirectories.contains(identity) else { return false }
        // Register before attempting the journal. A failed recovery must fail closed for the rest of
        // this process rather than retrying while another composition may partially initialize.
        openedApplicationDirectories.insert(identity)
        return try applyPendingRestore(applicationDirectory: applicationDirectory, keyManager: keyManager)
    }

    @discardableResult
    static func applyPendingRestore(
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws -> Bool {
        let directory = applicationDirectory.standardizedFileURL
        let markerURL = directory.appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return false }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        guard safeComponent(marker.candidateName), safeComponent(marker.rollbackName) else {
            throw LocalStorageError.invalidSnapshot("The pending local restore journal is invalid")
        }
        _ = try keyManager.pendingRestoreKey()
        let current = directory.appendingPathComponent("LocalDevice", isDirectory: true)
        let candidate = directory.appendingPathComponent(marker.candidateName, isDirectory: true)
        let rollback = directory.appendingPathComponent(marker.rollbackName, isDirectory: true)
        let fileManager = FileManager.default
        let hadCurrentAuthority = marker.hadCurrentAuthority ?? true
        var hasCurrent = fileManager.fileExists(atPath: current.path)
        var hasCandidate = fileManager.fileExists(atPath: candidate.path)
        var hasRollback = fileManager.fileExists(atPath: rollback.path)

        if hadCurrentAuthority {
            // Resume any interrupted replacement sequence using the journal's three states.
            if hasCurrent && hasCandidate && !hasRollback {
                try fileManager.moveItem(at: current, to: rollback)
                hasCurrent = false; hasRollback = true
            }
            if !hasCurrent && hasCandidate && hasRollback {
                do {
                    try fileManager.moveItem(at: candidate, to: current)
                    hasCurrent = true; hasCandidate = false
                } catch {
                    try? fileManager.moveItem(at: rollback, to: current)
                    throw error
                }
            }
            guard hasCurrent, !hasCandidate, hasRollback else {
                throw LocalStorageError.invalidSnapshot("The pending local restore journal does not match storage state")
            }
        } else {
            guard !hasRollback else {
                throw LocalStorageError.invalidSnapshot("A first Local Device import has an unexpected rollback")
            }
            if !hasCurrent && hasCandidate {
                try fileManager.moveItem(at: candidate, to: current)
                hasCurrent = true; hasCandidate = false
            }
            guard hasCurrent, !hasCandidate else {
                throw LocalStorageError.invalidSnapshot("The pending first Local Device import does not match storage state")
            }
        }
        do {
            try keyManager.activatePendingRestoreKey(
                rollbackIdentifier: hadCurrentAuthority ? marker.rollbackName : nil
            )
        } catch {
            // The active key was updated atomically by KeychainStore or not at all. Restore the old
            // directory when activation fails so authority bytes and key never intentionally diverge.
            try? fileManager.moveItem(at: current, to: candidate)
            if hadCurrentAuthority { try? fileManager.moveItem(at: rollback, to: current) }
            throw error
        }
        try fileManager.removeItem(at: markerURL)
        keyManager.clearPendingRestoreKey()
        if marker.candidateName.hasPrefix("LocalDevice-Rollback-") {
            keyManager.deleteRollbackKey(identifier: marker.candidateName)
        }
        return true
    }

    static func hasPendingRestore(applicationDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: applicationDirectory.appendingPathComponent(markerName).path)
    }

    static func rollbackGenerations(
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws -> [LocalDeviceRollbackGeneration] {
        let directory = applicationDirectory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let name = url.lastPathComponent
            let kind = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard name.hasPrefix("LocalDevice-Rollback-"), safeComponent(name),
                  kind.isDirectory == true, kind.isSymbolicLink != true else { return nil }
            _ = try keyManager.rollbackKey(identifier: name)
            let retained = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return LocalDeviceRollbackGeneration(id: name, retainedAt: retained, storedBytes: directorySize(url))
        }.sorted { $0.retainedAt > $1.retainedAt }
    }

    static func prepareRollback(
        _ generation: LocalDeviceRollbackGeneration,
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws -> LocalDevicePreparedRestore {
        let directory = applicationDirectory.standardizedFileURL
        let markerURL = directory.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            throw LocalStorageError.operationFailed("A verified restore is already waiting for the app to restart")
        }
        guard generation.id.hasPrefix("LocalDevice-Rollback-"), safeComponent(generation.id) else {
            throw LocalStorageError.invalidSnapshot("The rollback generation identifier is invalid")
        }
        let candidate = directory.appendingPathComponent(generation.id, isDirectory: true)
        let kind = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind.isDirectory == true, kind.isSymbolicLink != true else {
            throw LocalStorageError.invalidSnapshot("The rollback generation is no longer available")
        }
        let replacementKey = try keyManager.rollbackKey(identifier: generation.id)
        try keyManager.prepareRestoreKey(replacementKey)
        var published = false
        defer {
            if !published {
                keyManager.clearPendingRestoreKey()
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
        let newRollback = "LocalDevice-Rollback-\(UUID().uuidString)"
        let createdAt = ISO8601DateFormatter().string(from: generation.retainedAt)
        let marker = Marker(candidateName: generation.id, rollbackName: newRollback,
                            budgetID: "local-device-budget", createdAt: createdAt,
                            hadCurrentAuthority: true)
        try write(marker: marker, to: markerURL)
        published = true
        return .init(budgetID: marker.budgetID, createdAt: marker.createdAt)
    }

    static func deleteRollback(
        _ generation: LocalDeviceRollbackGeneration,
        applicationDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws {
        let directory = applicationDirectory.standardizedFileURL
        guard !hasPendingRestore(applicationDirectory: directory) else {
            throw LocalStorageError.operationFailed("Finish the pending restore before removing rollback generations")
        }
        guard generation.id.hasPrefix("LocalDevice-Rollback-"), safeComponent(generation.id) else {
            throw LocalStorageError.invalidSnapshot("The rollback generation identifier is invalid")
        }
        let target = directory.appendingPathComponent(generation.id, isDirectory: true)
        _ = try keyManager.rollbackKey(identifier: generation.id)
        try FileManager.default.removeItem(at: target)
        keyManager.deleteRollbackKey(identifier: generation.id)
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func write(marker: Marker, to markerURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(
            to: markerURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

enum LocalDeviceStorageCompositionError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        "The app's private Application Support directory is unavailable."
    }
}
