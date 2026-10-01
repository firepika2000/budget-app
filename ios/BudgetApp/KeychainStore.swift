import Foundation
import Security
import BudgetStorage

/// Minimal token persistence surface used by `AppSession`. Abstracted so credential storage can be
/// faked deterministically in tests without touching the real Keychain.
protocol TokenStoring {
    func save(_ value: String, account: String) throws
    func read(account: String) -> String?
    func delete(account: String)
}

protocol SecretDataStoring {
    func saveData(_ value: Data, account: String) throws
    func readData(account: String) -> Data?
    func deleteData(account: String)
}

#if DEBUG
/// Process-local secret scope for UI automation that runs an unsigned Simulator application.
/// Production Local Device composition always uses the device-only Keychain store.
final class UITestSecretDataStore: SecretDataStoring {
    private var values: [String: Data] = [:]
    func saveData(_ value: Data, account: String) throws { values[account] = value }
    func readData(account: String) -> Data? { values[account] }
    func deleteData(account: String) { values.removeValue(forKey: account) }
}
#endif

struct KeychainStore: TokenStoring, SecretDataStoring, Sendable {
    private let service: String

    init(service: String = "com.firepika.BudgetApp") {
        self.service = service
    }

    func save(_ value: String, account: String) throws {
        try saveData(Data(value.utf8), account: account)
    }

    func saveData(_ value: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unhandled(updateStatus) }
        var insert = query
        insert[kSecValueData as String] = value
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func read(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    func delete(account: String) {
        deleteData(account: account)
    }

    func deleteData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Dropbox refresh credentials remain device-only Keychain data. Access tokens are deliberately
/// memory-only and are resolved/refreshed by `DropboxOAuthCredential` for every transport request.
struct DropboxRefreshTokenKeychainStore: DropboxRefreshTokenStoring, Sendable {
    static let account = "dropbox-refresh-token-v1"
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) { self.keychain = keychain }
    func loadRefreshToken() throws -> String? { keychain.read(account: Self.account) }
    func saveRefreshToken(_ value: String) throws { try keychain.save(value, account: Self.account) }
    func deleteRefreshToken() { keychain.delete(account: Self.account) }
}

@MainActor
final class LocalDeviceKeyManager {
    nonisolated static let attachmentKeyAccount = "local-device-attachment-key-v1"
    nonisolated static let pendingRestoreKeyAccount = "local-device-pending-restore-key-v1"
    nonisolated static let rollbackKeyAccountPrefix = "local-device-rollback-key-v1-"
    private let store: SecretDataStoring

    init(store: SecretDataStoring = KeychainStore()) {
        self.store = store
    }

    func loadOrCreateAttachmentKey() throws -> Data {
        if let existing = store.readData(account: Self.attachmentKeyAccount) {
            guard existing.count == 32 else { throw KeychainError.invalidSecret }
            return existing
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        try store.saveData(bytes, account: Self.attachmentKeyAccount)
        return bytes
    }

    func prepareRestoreKey(_ value: Data) throws {
        guard value.count == 32 else { throw KeychainError.invalidSecret }
        try store.saveData(value, account: Self.pendingRestoreKeyAccount)
    }

    func pendingRestoreKey() throws -> Data {
        guard let value = store.readData(account: Self.pendingRestoreKeyAccount), value.count == 32 else {
            throw KeychainError.invalidSecret
        }
        return value
    }

    func activatePendingRestoreKey(rollbackIdentifier: String) throws {
        let replacement = try pendingRestoreKey()
        let current = try loadOrCreateAttachmentKey()
        let rollbackAccount = Self.rollbackKeyAccountPrefix + rollbackIdentifier
        if let existingRollback = store.readData(account: rollbackAccount) {
            guard existingRollback.count == 32 else { throw KeychainError.invalidSecret }
        } else {
            try store.saveData(current, account: rollbackAccount)
        }
        try store.saveData(replacement, account: Self.attachmentKeyAccount)
    }

    nonisolated static func rollbackKeyAccount(for identifier: String) -> String {
        rollbackKeyAccountPrefix + identifier
    }

    func rollbackKey(identifier: String) throws -> Data {
        guard let value = store.readData(account: Self.rollbackKeyAccount(for: identifier)), value.count == 32 else {
            throw KeychainError.invalidSecret
        }
        return value
    }

    func deleteRollbackKey(identifier: String) {
        store.deleteData(account: Self.rollbackKeyAccount(for: identifier))
    }

    func clearPendingRestoreKey() {
        store.deleteData(account: Self.pendingRestoreKeyAccount)
    }
}

enum KeychainError: Error {
    case unhandled(OSStatus)
    case invalidSecret
}
