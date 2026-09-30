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

/// Native composition boundary for the future Local Device provider.
///
/// Constructing this value opens the durable authority and encrypted object store together. It is
/// deliberately not selectable in the product until a complete `WorkspaceDataSource` adapter can
/// route every read and mutation through the shared application-service layer.
@MainActor
struct LocalDeviceStorageComposition {
    let paths: LocalDeviceStoragePaths
    let authority: LocalAuthorityStore
    let attachments: LocalAttachmentVault

    init(
        applicationSupportDirectory: URL,
        keyManager: LocalDeviceKeyManager
    ) throws {
        let paths = LocalDeviceStoragePaths(applicationSupportDirectory: applicationSupportDirectory)
        let key = try keyManager.loadOrCreateAttachmentKey()
        self.paths = paths
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

enum LocalDeviceStorageCompositionError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        "The app's private Application Support directory is unavailable."
    }
}
