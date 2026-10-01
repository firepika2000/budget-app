import BudgetStorage
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
                            budgetID: result.manifest.budgetID, createdAt: result.manifest.createdAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        publishedMarker = true
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
        var hasCurrent = fileManager.fileExists(atPath: current.path)
        var hasCandidate = fileManager.fileExists(atPath: candidate.path)
        var hasRollback = fileManager.fileExists(atPath: rollback.path)

        // Resume any interrupted rename sequence using the journal's three unambiguous states.
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
        do {
            try keyManager.activatePendingRestoreKey(rollbackIdentifier: marker.rollbackName)
        } catch {
            // The active key was updated atomically by KeychainStore or not at all. Restore the old
            // directory when activation fails so authority bytes and key never intentionally diverge.
            try? fileManager.moveItem(at: current, to: candidate)
            try? fileManager.moveItem(at: rollback, to: current)
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
                            budgetID: "local-device-budget", createdAt: createdAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(
            to: markerURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
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
