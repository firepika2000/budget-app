import CryptoKit
import Foundation

public struct LocalStoredAttachmentObject: Equatable, Sendable {
    public let objectName: String
    public let plaintextSize: Int64
    public let plaintextSHA256: String

    public init(objectName: String, plaintextSize: Int64, plaintextSHA256: String) {
        self.objectName = objectName; self.plaintextSize = plaintextSize
        self.plaintextSHA256 = plaintextSHA256
    }
}

/// Authenticated encrypted object storage for the single-user Local Device authority.
///
/// Key creation and Keychain custody belong to the application composition. This vault accepts a
/// 256-bit key, never writes plaintext, refuses overwrites, and moves detached objects into a
/// recoverable tombstone directory before a later retention job may purge them.
public actor LocalAttachmentVault {
    private static let magic = Data("BAV1".utf8)
    private let rootURL: URL
    private let objectsURL: URL
    private let tombstonesURL: URL
    private let key: SymmetricKey

    public init(directoryURL: URL, keyData: Data) throws {
        guard keyData.count == 32 else {
            throw LocalStorageError.operationFailed("Local attachment key must contain exactly 32 bytes")
        }
        rootURL = directoryURL.standardizedFileURL
        objectsURL = rootURL.appendingPathComponent("objects", isDirectory: true)
        tombstonesURL = rootURL.appendingPathComponent("tombstones", isDirectory: true)
        key = SymmetricKey(data: keyData)
        try Self.createPrivateDirectory(rootURL)
        try Self.createPrivateDirectory(objectsURL)
        try Self.createPrivateDirectory(tombstonesURL)
    }

    public func store(_ plaintext: Data, objectName requestedName: String? = nil) throws -> LocalStoredAttachmentObject {
        let objectName = try validatedObjectName(requestedName ?? "\(UUID().uuidString.lowercased()).enc")
        let destination = objectsURL.appendingPathComponent(objectName, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalStorageError.destinationExists
        }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw LocalStorageError.operationFailed("Unable to encode encrypted attachment")
        }
        let payload = Self.magic + combined
        let temporary = objectsURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try payload.write(to: temporary, options: [.atomic])
            try Self.applyPrivateFileProtection(temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try Self.applyPrivateFileProtection(destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return .init(objectName: objectName, plaintextSize: Int64(plaintext.count), plaintextSHA256: Self.sha256(plaintext))
    }

    public func data(objectName: String, expectedSHA256: String) throws -> Data {
        let name = try validatedObjectName(objectName)
        let payload = try Data(contentsOf: objectsURL.appendingPathComponent(name), options: [.mappedIfSafe])
        guard payload.count > Self.magic.count, payload.prefix(Self.magic.count) == Self.magic else {
            throw LocalStorageError.invalidSnapshot("Encrypted attachment format is invalid")
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: payload.dropFirst(Self.magic.count))
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard Self.sha256(plaintext) == expectedSHA256.lowercased() else {
                throw LocalStorageError.invalidSnapshot("Attachment integrity hash does not match")
            }
            return plaintext
        } catch let error as LocalStorageError {
            throw error
        } catch {
            throw LocalStorageError.invalidSnapshot("Encrypted attachment authentication failed")
        }
    }

    @discardableResult
    public func tombstone(objectName: String, detachedAt: Date = Date()) throws -> String {
        let name = try validatedObjectName(objectName)
        let source = objectsURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw LocalStorageError.operationFailed("Local attachment object was not found")
        }
        let milliseconds = Int64(detachedAt.timeIntervalSince1970 * 1_000)
        let tombstoneName = "\(milliseconds)-\(UUID().uuidString.lowercased())-\(name)"
        let destination = tombstonesURL.appendingPathComponent(tombstoneName)
        try FileManager.default.moveItem(at: source, to: destination)
        try Self.applyPrivateFileProtection(destination)
        return tombstoneName
    }

    public func restoreTombstone(named tombstoneName: String, as objectName: String) throws {
        let tombstoneName = try validatedObjectName(tombstoneName)
        let objectName = try validatedObjectName(objectName)
        let source = tombstonesURL.appendingPathComponent(tombstoneName)
        let destination = objectsURL.appendingPathComponent(objectName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw LocalStorageError.operationFailed("Local attachment tombstone was not found")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalStorageError.destinationExists
        }
        try FileManager.default.moveItem(at: source, to: destination)
        try Self.applyPrivateFileProtection(destination)
    }

    public func purgeTombstones(detachedBefore cutoff: Date) throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(atPath: tombstonesURL.path)
        var removed = 0
        let cutoffMilliseconds = Int64(cutoff.timeIntervalSince1970 * 1_000)
        for name in names {
            guard let prefix = name.split(separator: "-", maxSplits: 1).first,
                  let detachedMilliseconds = Int64(prefix), detachedMilliseconds < cutoffMilliseconds else { continue }
            try FileManager.default.removeItem(at: tombstonesURL.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    private func validatedObjectName(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..",
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
              }) else {
            throw LocalStorageError.operationFailed("Local attachment object name is invalid")
        }
        return value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private static func applyPrivateFileProtection(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
