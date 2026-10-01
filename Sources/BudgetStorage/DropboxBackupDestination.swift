import CryptoKit
import Foundation

public struct DropboxBackupMetadata: Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let contentHash: String

    public init(path: String, size: Int64, contentHash: String) {
        self.path = path; self.size = size; self.contentHash = contentHash
    }
}

public struct DropboxBackupEntry: Equatable, Sendable {
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64?
    public let contentHash: String?

    public init(path: String, name: String, isFolder: Bool, size: Int64? = nil, contentHash: String? = nil) {
        self.path = path; self.name = name; self.isFolder = isFolder
        self.size = size; self.contentHash = contentHash
    }
}

public struct DropboxBackupPage: Equatable, Sendable {
    public let entries: [DropboxBackupEntry]
    public let cursor: String?

    public init(entries: [DropboxBackupEntry], cursor: String? = nil) {
        self.entries = entries; self.cursor = cursor
    }
}

/// Narrow application-service boundary around Dropbox's files API. OAuth/token rotation belongs to
/// the adapter, while encrypted-generation publication and verification stay provider-neutral here.
public protocol DropboxBackupTransport: Sendable {
    func createFolder(path: String) async throws
    func upload(path: String, data: Data) async throws -> DropboxBackupMetadata
    func startUploadSession(data: Data) async throws -> String
    func appendUploadSession(id: String, offset: Int64, data: Data) async throws
    func finishUploadSession(id: String, offset: Int64, data: Data, path: String) async throws -> DropboxBackupMetadata
    func move(from: String, to: String) async throws
    func delete(path: String) async throws
    func list(path: String, recursive: Bool, cursor: String?) async throws -> DropboxBackupPage
    func download(path: String) async throws -> (DropboxBackupMetadata, Data)
}

public struct DropboxBackupPublication: Equatable, Sendable {
    public let remotePath: String
    public let encryptedBytes: Int64
    public let fileCount: Int
}

public enum DropboxBackupDestinationError: LocalizedError, Equatable {
    case invalidFolder
    case invalidPackage(String)
    case invalidRetention
    case integrityFailure(String)
    case destinationExists

    public var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose a Dropbox app folder below the root."
        case let .invalidPackage(message): message
        case .invalidRetention: "Dropbox backup retention must be between 1 and 100 generations."
        case let .integrityFailure(path): "Dropbox could not verify the encrypted backup file at \(path)."
        case .destinationExists: "That encrypted backup generation already exists in Dropbox."
        }
    }
}

/// Publishes immutable `.clearpocketbackup` directories without ever opening or synchronizing the
/// SQLite authority. A temporary remote folder becomes visible only after every ciphertext file is
/// size/content-hash verified. Downloads similarly publish locally only after all remote bytes pass.
public actor DropboxBackupDestination {
    private static let blockBytes = 4 * 1_024 * 1_024
    private static let uploadChunkBytes = 8 * 1_024 * 1_024
    private let transport: DropboxBackupTransport
    private let folder: String
    private let retention: Int

    public init(transport: DropboxBackupTransport, folder: String = "/Backups", retention: Int = 10) throws {
        guard folder.hasPrefix("/"), folder != "/", !folder.hasSuffix("/"),
              !folder.contains("//"), !folder.split(separator: "/").contains("..") else {
            throw DropboxBackupDestinationError.invalidFolder
        }
        guard (1...100).contains(retention) else { throw DropboxBackupDestinationError.invalidRetention }
        self.transport = transport; self.folder = folder; self.retention = retention
    }

    public func publish(packageURL: URL) async throws -> DropboxBackupPublication {
        let package = packageURL.standardizedFileURL
        let packageName = package.lastPathComponent
        guard packageName.hasSuffix(".clearpocketbackup") else {
            throw DropboxBackupDestinationError.invalidPackage("Choose a ClearPocket encrypted backup generation.")
        }
        let files = try Self.validatedPackageFiles(package)
        let temporaryPath = "\(folder)/.upload-\(UUID().uuidString)"
        let finalPath = "\(folder)/\(packageName)"
        try await transport.createFolder(path: folder)
        try await transport.createFolder(path: temporaryPath)
        do {
            var total: Int64 = 0
            var createdParents: Set<String> = []
            for file in files {
                let relative = file.path.replacingOccurrences(of: package.path + "/", with: "")
                let remote = "\(temporaryPath)/\(relative)"
                if relative.contains("/") {
                    let parent = (remote as NSString).deletingLastPathComponent
                    if createdParents.insert(parent).inserted {
                        try await transport.createFolder(path: parent)
                    }
                }
                let expectedSize = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let expectedHash = try Self.contentHash(file)
                let metadata = try await upload(file, to: remote, size: expectedSize)
                guard metadata.size == expectedSize, metadata.contentHash.lowercased() == expectedHash else {
                    throw DropboxBackupDestinationError.integrityFailure(remote)
                }
                total += expectedSize
            }
            do { try await transport.move(from: temporaryPath, to: finalPath) }
            catch {
                let existing = try await allEntries(path: folder, recursive: false)
                if existing.contains(where: { $0.path.caseInsensitiveCompare(finalPath) == .orderedSame }) {
                    throw DropboxBackupDestinationError.destinationExists
                }
                throw error
            }
            try await prune(excluding: finalPath)
            return .init(remotePath: finalPath, encryptedBytes: total, fileCount: files.count)
        } catch {
            try? await transport.delete(path: temporaryPath)
            throw error
        }
    }

    public func generations() async throws -> [DropboxBackupEntry] {
        try await allEntries(path: folder, recursive: false)
            .filter { $0.isFolder && $0.name.hasSuffix(".clearpocketbackup") }
            .sorted { $0.name > $1.name }
    }

    public func download(remotePath: String, destinationURL: URL) async throws {
        let remoteName = (remotePath as NSString).lastPathComponent
        guard (remotePath as NSString).deletingLastPathComponent == folder,
              Self.safeName(remoteName), remoteName.hasSuffix(".clearpocketbackup") else {
            throw DropboxBackupDestinationError.invalidPackage("The selected Dropbox generation is outside the configured backup folder.")
        }
        let destination = destinationURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DropboxBackupDestinationError.destinationExists
        }
        let entries = try await allEntries(path: remotePath, recursive: true).filter { !$0.isFolder }
        guard let manifestEntry = entries.first(where: { $0.path == remotePath + "/manifest.json" }) else {
            throw DropboxBackupDestinationError.invalidPackage("The Dropbox generation has no manifest.")
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".dropbox-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        let manifestData = try await verifiedDownload(manifestEntry)
        let manifest: LocalDeviceBackupManifest
        do { manifest = try JSONDecoder().decode(LocalDeviceBackupManifest.self, from: manifestData) }
        catch { throw DropboxBackupDestinationError.invalidPackage("The Dropbox generation manifest is invalid.") }
        guard Set(manifest.files.map(\.payloadName)).count == manifest.files.count,
              manifest.files.allSatisfy({ Self.safeName($0.payloadName) }) else {
            throw DropboxBackupDestinationError.invalidPackage("The Dropbox generation manifest has duplicate or unsafe payload names.")
        }
        let expected = Set(["manifest.json"] + manifest.files.map { "payload/\($0.payloadName)" })
        let observed = Set(entries.compactMap { entry -> String? in
            guard entry.path.hasPrefix(remotePath + "/") else { return nil }
            return String(entry.path.dropFirst(remotePath.count + 1))
        })
        guard observed == expected else {
            throw DropboxBackupDestinationError.invalidPackage("The Dropbox generation file set does not match its manifest.")
        }
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for record in manifest.files {
            let entry = try Self.only(entries.filter { $0.path == remotePath + "/payload/\(record.payloadName)" })
            let data = try await verifiedDownload(entry)
            try data.write(to: payload.appendingPathComponent(record.payloadName), options: .atomic)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        published = true
    }

    private func upload(_ file: URL, to remote: String, size: Int64) async throws -> DropboxBackupMetadata {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if size <= Int64(Self.uploadChunkBytes) {
            return try await transport.upload(path: remote, data: try handle.readToEnd() ?? Data())
        }
        let first = try handle.read(upToCount: Self.uploadChunkBytes) ?? Data()
        let id = try await transport.startUploadSession(data: first)
        var offset = Int64(first.count)
        while size - offset > Int64(Self.uploadChunkBytes) {
            let chunk = try handle.read(upToCount: Self.uploadChunkBytes) ?? Data()
            guard !chunk.isEmpty else { throw DropboxBackupDestinationError.integrityFailure(remote) }
            try await transport.appendUploadSession(id: id, offset: offset, data: chunk)
            offset += Int64(chunk.count)
        }
        let final = try handle.readToEnd() ?? Data()
        return try await transport.finishUploadSession(id: id, offset: offset, data: final, path: remote)
    }

    private func verifiedDownload(_ entry: DropboxBackupEntry) async throws -> Data {
        let (metadata, data) = try await transport.download(path: entry.path)
        let expectedSize = entry.size ?? metadata.size
        let expectedHash = entry.contentHash ?? metadata.contentHash
        guard Int64(data.count) == expectedSize,
              metadata.size == expectedSize,
              metadata.contentHash.lowercased() == expectedHash.lowercased(),
              Self.contentHash(data) == expectedHash.lowercased() else {
            throw DropboxBackupDestinationError.integrityFailure(entry.path)
        }
        return data
    }

    private func allEntries(path: String, recursive: Bool) async throws -> [DropboxBackupEntry] {
        var entries: [DropboxBackupEntry] = [], cursor: String?
        repeat {
            let page = try await transport.list(path: path, recursive: recursive, cursor: cursor)
            entries.append(contentsOf: page.entries)
            cursor = page.cursor
        } while cursor != nil
        return entries
    }

    private func prune(excluding current: String) async throws {
        let existing = try await generations().filter { $0.path != current }
        let excess = max(0, existing.count - (retention - 1))
        for generation in existing.suffix(excess) { try await transport.delete(path: generation.path) }
    }

    private static func validatedPackageFiles(_ package: URL) throws -> [URL] {
        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifest: LocalDeviceBackupManifest
        do { manifest = try JSONDecoder().decode(LocalDeviceBackupManifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw DropboxBackupDestinationError.invalidPackage("The encrypted backup manifest is invalid.") }
        guard manifest.format == LocalDeviceBackupManifest.format,
              manifest.version == LocalDeviceBackupManifest.version,
              manifest.files.allSatisfy({ safeName($0.payloadName) }),
              Set(manifest.files.map(\.payloadName)).count == manifest.files.count else {
            throw DropboxBackupDestinationError.invalidPackage("The encrypted backup manifest is unsupported.")
        }
        let files = [manifestURL] + manifest.files.map { package.appendingPathComponent("payload/\($0.payloadName)") }
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DropboxBackupDestinationError.invalidPackage("The encrypted backup contains an unsafe or missing payload.")
            }
        }
        return files
    }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func only(_ entries: [DropboxBackupEntry]) throws -> DropboxBackupEntry {
        guard entries.count == 1, let entry = entries.first else {
            throw DropboxBackupDestinationError.invalidPackage("The Dropbox generation contains duplicate or missing payloads.")
        }
        return entry
    }

    public static func contentHash(_ data: Data) -> String {
        var combined = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + blockBytes, data.count)
            combined.append(contentsOf: SHA256.hash(data: data[offset..<end]))
            offset = end
        }
        return SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
    }

    public static func contentHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var combined = Data()
        while let block = try handle.read(upToCount: blockBytes), !block.isEmpty {
            combined.append(contentsOf: SHA256.hash(data: block))
        }
        return SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
    }
}
