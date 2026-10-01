import CryptoKit
import Foundation

public struct LocalDeviceBackupRecoveryKey: Equatable, Sendable {
    public let data: Data

    public init(data: Data) throws {
        guard data.count == 32 else {
            throw LocalStorageError.operationFailed("A local backup recovery key must contain exactly 32 bytes")
        }
        self.data = data
    }

    public init(encoded: String) throws {
        var value = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count.isMultiple(of: 4) == false { value.append("=") }
        guard let data = Data(base64Encoded: value) else {
            throw LocalStorageError.operationFailed("The local backup recovery key is invalid")
        }
        try self.init(data: data)
    }

    public static func generate() throws -> Self {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return try .init(data: Data(bytes))
    }

    public var encoded: String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct LocalDeviceBackupFile: Codable, Equatable, Sendable {
    public let payloadName: String
    public let restorePath: String
    public let role: String
    public let plaintextBytes: Int64
    public let plaintextSHA256: String
    public let encryptedBytes: Int64
    public let encryptedSHA256: String
}

public struct LocalDeviceBackupManifest: Codable, Equatable, Sendable {
    public static let format = "com.clearpocket.local-backup"
    public static let version = 1

    public let format: String
    public let version: Int
    public let createdAt: String
    public let localSchemaVersion: Int
    public let budgetID: String
    public let files: [LocalDeviceBackupFile]
    public let authentication: String

    private enum CodingKeys: String, CodingKey {
        case format, version, createdAt = "created_at", localSchemaVersion = "local_schema_version"
        case budgetID = "budget_id", files, authentication
    }
}

public struct LocalDeviceBackupRestoreResult: Equatable, Sendable {
    public let manifest: LocalDeviceBackupManifest
    public let attachmentKey: Data
}

/// Creates and validates an immutable encrypted generation for the Local Device authority.
///
/// The package is a directory so large authorities can be encrypted and verified one file at a
/// time. Every payload uses independently authenticated, chunked AES-GCM. The manifest is protected
/// by HMAC and covers exact plaintext/ciphertext sizes and hashes. Restore always targets a new path.
public enum LocalDeviceBackupService {
    private static let encryptedMagic = Data("CPBF1".utf8)
    private static let chunkBytes = 1_048_576
    private static let maximumChunkBytes = 1_100_000
    private static let manifestName = "manifest.json"
    private static let payloadDirectoryName = "payload"

    public static func create(
        authority: LocalAuthorityStore,
        budgetID: String,
        attachmentsDirectory: URL,
        attachmentKey: Data,
        destinationURL: URL,
        recoveryKey: LocalDeviceBackupRecoveryKey,
        now: Date = Date()
    ) async throws -> LocalDeviceBackupManifest {
        _ = try LocalDeviceBackupRecoveryKey(data: attachmentKey)
        let destination = destinationURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalStorageError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".clearpocket-backup-\(UUID().uuidString)", isDirectory: true)
        let scratch = parent.appendingPathComponent(".clearpocket-snapshot-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(staging)
        try createPrivateDirectory(scratch)
        var published = false
        defer {
            try? FileManager.default.removeItem(at: scratch)
            if !published { try? FileManager.default.removeItem(at: staging) }
        }

        let aggregate = try await authority.snapshot(budgetID: budgetID)
        let snapshot = scratch.appendingPathComponent("authority.sqlite3")
        try await authority.snapshotDatabase(to: snapshot)
        let payloadDirectory = staging.appendingPathComponent(payloadDirectoryName, isDirectory: true)
        try createPrivateDirectory(payloadDirectory)

        var sources: [(URL?, Data?, String, String)] = [
            (snapshot, nil, "authority.sqlite3", "database"),
            (nil, attachmentKey, "attachment-key.bin", "attachment_key")
        ]
        let attachmentRoot = attachmentsDirectory.standardizedFileURL
        if FileManager.default.fileExists(atPath: attachmentRoot.path) {
            for child in try attachmentFiles(root: attachmentRoot) {
                let relative = child.path.replacingOccurrences(of: attachmentRoot.path + "/", with: "")
                let role = relative.hasPrefix("objects/") ? "attachment_object" : "attachment_tombstone"
                sources.append((child, nil, "Attachments/\(relative)", role))
            }
        }
        let activeNames = Set(sources.filter { $0.3 == "attachment_object" }.map { URL(fileURLWithPath: $0.2).lastPathComponent })
        let missing = aggregate.attachments.map(\.objectName).filter { !activeNames.contains($0) }
        guard missing.isEmpty else {
            throw LocalStorageError.invalidSnapshot("An active attachment object is missing from local storage")
        }

        var records: [LocalDeviceBackupFile] = []
        for (index, source) in sources.sorted(by: { $0.2 < $1.2 }).enumerated() {
            let payloadName = String(format: "%06d.cpenc", index)
            let output = payloadDirectory.appendingPathComponent(payloadName)
            let observation: CipherObservation
            if let url = source.0 {
                observation = try encryptFile(url, to: output, key: recoveryKey.data)
            } else {
                observation = try encryptData(source.1 ?? Data(), to: output, key: recoveryKey.data)
            }
            records.append(.init(payloadName: payloadName, restorePath: source.2, role: source.3,
                                 plaintextBytes: observation.plaintextBytes,
                                 plaintextSHA256: observation.plaintextSHA256,
                                 encryptedBytes: observation.encryptedBytes,
                                 encryptedSHA256: observation.encryptedSHA256))
        }

        let timestamp = ISO8601DateFormatter().string(from: now)
        let unsigned = LocalDeviceBackupManifest(format: LocalDeviceBackupManifest.format,
            version: LocalDeviceBackupManifest.version, createdAt: timestamp,
            localSchemaVersion: LocalDatabase.schemaVersion, budgetID: budgetID,
            files: records, authentication: "")
        let unsignedData = try manifestData(unsigned)
        let authentication = hmac(unsignedData, key: recoveryKey.data)
        let manifest = LocalDeviceBackupManifest(format: unsigned.format, version: unsigned.version,
            createdAt: unsigned.createdAt, localSchemaVersion: unsigned.localSchemaVersion,
            budgetID: unsigned.budgetID, files: unsigned.files, authentication: authentication)
        try manifestData(manifest).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
        try applyPrivateProtection(staging.appendingPathComponent(manifestName))
        try FileManager.default.moveItem(at: staging, to: destination)
        try createPrivateDirectory(destination)
        published = true
        return manifest
    }

    public static func restore(
        packageURL: URL,
        destinationRootURL: URL,
        recoveryKey: LocalDeviceBackupRecoveryKey
    ) async throws -> LocalDeviceBackupRestoreResult {
        let package = packageURL.standardizedFileURL
        let destination = destinationRootURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalStorageError.destinationExists
        }
        let manifestURL = package.appendingPathComponent(manifestName)
        let rawManifest = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(LocalDeviceBackupManifest.self, from: rawManifest)
        guard manifest.format == LocalDeviceBackupManifest.format,
              manifest.version == LocalDeviceBackupManifest.version,
              manifest.localSchemaVersion <= LocalDatabase.schemaVersion else {
            throw LocalStorageError.invalidSnapshot("The local backup format or schema is not supported")
        }
        let unsigned = LocalDeviceBackupManifest(format: manifest.format, version: manifest.version,
            createdAt: manifest.createdAt, localSchemaVersion: manifest.localSchemaVersion,
            budgetID: manifest.budgetID, files: manifest.files, authentication: "")
        guard constantTimeEqual(manifest.authentication, hmac(try manifestData(unsigned), key: recoveryKey.data)) else {
            throw LocalStorageError.invalidSnapshot("The local backup manifest failed authentication")
        }
        try validateManifest(manifest)

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".clearpocket-restore-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(staging)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        var attachmentKey: Data?
        for file in manifest.files {
            let payload = package.appendingPathComponent(payloadDirectoryName).appendingPathComponent(file.payloadName)
            let payloadValues = try payload.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard payloadValues.isRegularFile == true, payloadValues.isSymbolicLink != true else {
                throw LocalStorageError.invalidSnapshot("A local backup payload is missing or is not a regular file")
            }
            if file.role == "attachment_key" {
                attachmentKey = try decryptData(payload, observation: file, key: recoveryKey.data)
                continue
            }
            let target = staging.appendingPathComponent(file.restorePath)
            try createPrivateDirectory(target.deletingLastPathComponent())
            try decryptFile(payload, to: target, observation: file, key: recoveryKey.data)
        }
        guard let attachmentKey else {
            throw LocalStorageError.invalidSnapshot("The local backup does not contain its attachment recovery key")
        }
        _ = try LocalDeviceBackupRecoveryKey(data: attachmentKey)
        let databaseURL = staging.appendingPathComponent("authority.sqlite3")
        let authority = try LocalAuthorityStore(fileURL: databaseURL)
        try await authority.integrityCheck()
        let aggregate = try await authority.snapshot(budgetID: manifest.budgetID)
        let vault = try LocalAttachmentVault(directoryURL: staging.appendingPathComponent("Attachments"), keyData: attachmentKey)
        for item in aggregate.attachments {
            _ = try await vault.data(objectName: item.objectName, expectedSHA256: item.sha256)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        try createPrivateDirectory(destination)
        published = true
        return .init(manifest: manifest, attachmentKey: attachmentKey)
    }

    private struct CipherObservation {
        let plaintextBytes: Int64; let plaintextSHA256: String
        let encryptedBytes: Int64; let encryptedSHA256: String
    }

    private static func encryptData(_ data: Data, to output: URL, key: Data) throws -> CipherObservation {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        var plainHash = SHA256(), encryptedHash = SHA256()
        var encryptedBytes: Int64 = 0
        try write(encryptedMagic, to: destination, hash: &encryptedHash, count: &encryptedBytes)
        plainHash.update(data: data)
        if !data.isEmpty {
            let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key))
            guard let combined = sealed.combined else {
                throw LocalStorageError.operationFailed("Unable to encode a local backup payload")
            }
            var length = UInt32(combined.count).bigEndian
            try write(withUnsafeBytes(of: &length) { Data($0) }, to: destination,
                      hash: &encryptedHash, count: &encryptedBytes)
            try write(combined, to: destination, hash: &encryptedHash, count: &encryptedBytes)
        }
        var terminator = UInt32(0).bigEndian
        try write(withUnsafeBytes(of: &terminator) { Data($0) }, to: destination,
                  hash: &encryptedHash, count: &encryptedBytes)
        try destination.synchronize()
        try applyPrivateProtection(output)
        return .init(plaintextBytes: Int64(data.count), plaintextSHA256: hex(plainHash.finalize()),
                     encryptedBytes: encryptedBytes, encryptedSHA256: hex(encryptedHash.finalize()))
    }

    private static func encryptFile(_ input: URL, to output: URL, key: Data) throws -> CipherObservation {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let source = try FileHandle(forReadingFrom: input)
        let destination = try FileHandle(forWritingTo: output)
        defer { try? source.close(); try? destination.close() }
        let symmetricKey = SymmetricKey(data: key)
        var plainHash = SHA256(), encryptedHash = SHA256()
        var plainBytes: Int64 = 0, encryptedBytes: Int64 = 0
        try write(encryptedMagic, to: destination, hash: &encryptedHash, count: &encryptedBytes)
        while let chunk = try source.read(upToCount: chunkBytes), !chunk.isEmpty {
            plainHash.update(data: chunk); plainBytes += Int64(chunk.count)
            let sealed = try AES.GCM.seal(chunk, using: symmetricKey)
            guard let combined = sealed.combined else {
                throw LocalStorageError.operationFailed("Unable to encode a local backup payload")
            }
            var length = UInt32(combined.count).bigEndian
            let lengthData = withUnsafeBytes(of: &length) { Data($0) }
            try write(lengthData, to: destination, hash: &encryptedHash, count: &encryptedBytes)
            try write(combined, to: destination, hash: &encryptedHash, count: &encryptedBytes)
        }
        var terminator = UInt32(0).bigEndian
        try write(withUnsafeBytes(of: &terminator) { Data($0) }, to: destination, hash: &encryptedHash, count: &encryptedBytes)
        try destination.synchronize()
        try applyPrivateProtection(output)
        return .init(plaintextBytes: plainBytes, plaintextSHA256: hex(plainHash.finalize()),
                     encryptedBytes: encryptedBytes, encryptedSHA256: hex(encryptedHash.finalize()))
    }

    private static func decryptData(_ input: URL, observation: LocalDeviceBackupFile, key: Data) throws -> Data {
        let temporary = input.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).restored")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try decryptFile(input, to: temporary, observation: observation, key: key)
        return try Data(contentsOf: temporary)
    }

    private static func decryptFile(_ input: URL, to output: URL, observation: LocalDeviceBackupFile, key: Data) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let source = try FileHandle(forReadingFrom: input)
        let destination = try FileHandle(forWritingTo: output)
        var succeeded = false
        defer {
            try? source.close(); try? destination.close()
            if !succeeded { try? FileManager.default.removeItem(at: output) }
        }
        var plainHash = SHA256(), encryptedHash = SHA256()
        var plainBytes: Int64 = 0, encryptedBytes: Int64 = 0
        let magic = try readExactly(encryptedMagic.count, from: source)
        guard magic == encryptedMagic else { throw LocalStorageError.invalidSnapshot("Encrypted backup payload format is invalid") }
        encryptedHash.update(data: magic); encryptedBytes += Int64(magic.count)
        let symmetricKey = SymmetricKey(data: key)
        while true {
            let lengthData = try readExactly(4, from: source)
            encryptedHash.update(data: lengthData); encryptedBytes += 4
            let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length == 0 { break }
            guard length <= maximumChunkBytes else { throw LocalStorageError.invalidSnapshot("Encrypted backup chunk is too large") }
            let combined = try readExactly(Int(length), from: source)
            encryptedHash.update(data: combined); encryptedBytes += Int64(combined.count)
            do {
                let plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: symmetricKey)
                try destination.write(contentsOf: plaintext)
                plainHash.update(data: plaintext); plainBytes += Int64(plaintext.count)
            } catch {
                throw LocalStorageError.invalidSnapshot("Encrypted backup payload authentication failed")
            }
        }
        guard try source.read(upToCount: 1)?.isEmpty != false else {
            throw LocalStorageError.invalidSnapshot("Encrypted backup payload has trailing data")
        }
        try destination.synchronize()
        guard plainBytes == observation.plaintextBytes,
              encryptedBytes == observation.encryptedBytes,
              constantTimeEqual(hex(plainHash.finalize()), observation.plaintextSHA256),
              constantTimeEqual(hex(encryptedHash.finalize()), observation.encryptedSHA256) else {
            throw LocalStorageError.invalidSnapshot("Encrypted backup payload integrity does not match its manifest")
        }
        try applyPrivateProtection(output)
        succeeded = true
    }

    private static func validateManifest(_ manifest: LocalDeviceBackupManifest) throws {
        guard !manifest.budgetID.isEmpty, manifest.files.count >= 2,
              manifest.files.filter({ $0.role == "database" }).count == 1,
              manifest.files.filter({ $0.role == "attachment_key" }).count == 1,
              Set(manifest.files.map(\.payloadName)).count == manifest.files.count,
              Set(manifest.files.map(\.restorePath)).count == manifest.files.count else {
            throw LocalStorageError.invalidSnapshot("The local backup manifest is incomplete or ambiguous")
        }
        for file in manifest.files {
            guard isSafeComponent(file.payloadName), file.payloadName.hasSuffix(".cpenc"),
                  file.plaintextBytes >= 0, file.encryptedBytes > 0,
                  file.plaintextSHA256.count == 64, file.encryptedSHA256.count == 64 else {
                throw LocalStorageError.invalidSnapshot("The local backup manifest contains an invalid file record")
            }
            let validRoleAndPath: Bool
            switch file.role {
            case "database":
                validRoleAndPath = file.restorePath == "authority.sqlite3"
            case "attachment_key":
                validRoleAndPath = file.restorePath == "attachment-key.bin"
            case "attachment_object":
                validRoleAndPath = file.restorePath.hasPrefix("Attachments/objects/")
            case "attachment_tombstone":
                validRoleAndPath = file.restorePath.hasPrefix("Attachments/tombstones/")
            default:
                validRoleAndPath = false
            }
            guard validRoleAndPath,
                  file.restorePath.split(separator: "/").allSatisfy({ isSafeComponent(String($0)) }) else {
                throw LocalStorageError.invalidSnapshot("The local backup manifest contains an unsafe restore path")
            }
        }
    }

    private static func attachmentFiles(root: URL) throws -> [URL] {
        let allowed = [root.appendingPathComponent("objects", isDirectory: true), root.appendingPathComponent("tombstones", isDirectory: true)]
        var result: [URL] = []
        for directory in allowed where FileManager.default.fileExists(atPath: directory.path) {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for name in names.sorted() {
                guard isSafeComponent(name) else { throw LocalStorageError.invalidSnapshot("Local attachment name is unsafe") }
                let url = directory.appendingPathComponent(name)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LocalStorageError.invalidSnapshot("Local attachment storage contains a non-regular file")
                }
                result.append(url)
            }
        }
        return result
    }

    private static func manifestData(_ manifest: LocalDeviceBackupManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    private static func hmac(_ data: Data, key: Data) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let next = try handle.read(upToCount: count - result.count), !next.isEmpty else {
                throw LocalStorageError.invalidSnapshot("Encrypted backup payload is truncated")
            }
            result.append(next)
        }
        return result
    }

    private static func write(_ data: Data, to handle: FileHandle, hash: inout SHA256, count: inout Int64) throws {
        try handle.write(contentsOf: data); hash.update(data: data); count += Int64(data.count)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private static func applyPrivateProtection(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
