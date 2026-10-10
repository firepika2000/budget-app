import XCTest
@testable import BudgetStorage

final class DropboxBackupDestinationTests: XCTestCase {
    func testInvalidAdvertisedManifestSizeRejectsBeforeAnyDownloadOrStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-manifest-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = "/Backups/Invalid.clearpocketbackup/manifest.json"
        let sizes: [Int64?] = [nil, 0, -1, Int64(BackupManifestIO.maximumBytes) + 1]
        for (index, size) in sizes.enumerated() {
            let transport = FakeDropboxBackupTransport()
            await transport.seedFile(path, data: Data("{}".utf8))
            await transport.overrideListedEntry(.init(path: path, name: "manifest.json", isFolder: false, size: size))
            let destination = try DropboxBackupDestination(transport: transport)
            let output = root.appendingPathComponent("Rejected-\(index).clearpocketbackup")
            do {
                try await destination.download(remotePath: "/Backups/Invalid.clearpocketbackup", destinationURL: output)
                XCTFail("Invalid manifest metadata must fail before fetching")
            } catch let error as DropboxBackupDestinationError {
                guard case .invalidPackage = error else { return XCTFail("Unexpected error: \(error)") }
            }
            let downloads = await transport.downloadedPaths()
            XCTAssertTrue(downloads.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testUnsupportedManifestRejectsBeforePayloadDownloadAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-manifest-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try makePackage(root: root, name: "Generation.clearpocketbackup", payloads: [Data("ciphertext".utf8)])
        let original = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        for field in ["format", "version"] {
            let transport = FakeDropboxBackupTransport()
            let destination = try DropboxBackupDestination(transport: transport)
            let published = try await destination.publish(packageURL: package)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if field == "format" { json[field] = "unsupported.backup" }
            else { json[field] = LocalDeviceBackupManifest.version + 1 }
            let manifestPath = published.remotePath + "/manifest.json"
            await transport.seedFile(manifestPath, data: try JSONSerialization.data(withJSONObject: json))
            let output = root.appendingPathComponent("Rejected-\(field).clearpocketbackup")
            do {
                try await destination.download(remotePath: published.remotePath, destinationURL: output)
                XCTFail("Unsupported manifest must not fetch payloads")
            } catch let error as DropboxBackupDestinationError {
                guard case .invalidPackage = error else { return XCTFail("Unexpected error: \(error)") }
            }
            let downloads = await transport.downloadedPaths()
            XCTAssertEqual(downloads, [manifestPath])
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [package.lastPathComponent])
            let remotePaths = await transport.paths()
            XCTAssertTrue(remotePaths.contains(published.remotePath + "/payload/000000.cpenc"), "Rejection must not remove remote backups")
        }
    }

    func testLostMoveResponseAndExplicitRetryRecoverOnlyIdenticalGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("original-ciphertext".utf8)
        let package = try makePackage(root: root, name: "Same.clearpocketbackup", payloads: [original])
        let transport = FakeDropboxBackupTransport(pageSize: 1, loseMoveResponse: true)
        let destination = try DropboxBackupDestination(transport: transport)
        let first = try await destination.publish(packageURL: package)
        let retry = try await destination.publish(packageURL: package)
        XCTAssertEqual(first, retry)
        XCTAssertTrue(first.retentionCleanupPending)
        let generations = try await destination.generations()
        XCTAssertEqual(generations.map(\.path), [first.remotePath])
        let paths = await transport.paths()
        XCTAssertFalse(paths.contains { $0.contains(".upload-") })
        await transport.seedFolder("/Backups/ZNewer.clearpocketbackup")
        let strictRetention = try DropboxBackupDestination(transport: transport, retention: 1)
        _ = try await strictRetention.publish(packageURL: package)
        let afterOldRetry = await transport.paths()
        XCTAssertTrue(afterOldRetry.contains("/Backups/ZNewer.clearpocketbackup"), "Retry must not evict a newer backup")

        // A matching name is not evidence of a matching immutable generation.
        _ = try makePackage(root: root, name: "Same.clearpocketbackup", payloads: [Data("changed-ciphertext".utf8)])
        do {
            _ = try await destination.publish(packageURL: package)
            XCTFail("Different bytes under an existing name must never be accepted or overwrite it")
        } catch let error as DropboxBackupDestinationError {
            XCTAssertEqual(error, .destinationExists)
        }
        let (_, preserved) = try await transport.download(path: first.remotePath + "/payload/000000.cpenc")
        XCTAssertEqual(preserved, original)
        let finalPaths = await transport.paths()
        XCTAssertFalse(finalPaths.contains { $0.contains(".upload-") })
    }

    func testCommittedPublicationSurvivesRetentionListingFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-maintenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try makePackage(root: root, name: "Verified.clearpocketbackup", payloads: [Data("ciphertext".utf8)])
        let transport = FakeDropboxBackupTransport(failListing: true)
        let destination = try DropboxBackupDestination(transport: transport)
        let publication = try await destination.publish(packageURL: package)
        XCTAssertTrue(publication.retentionCleanupPending)
        XCTAssertEqual(publication.remotePath, "/Backups/Verified.clearpocketbackup")
        let paths = await transport.paths()
        XCTAssertTrue(paths.contains(publication.remotePath))
        XCTAssertTrue(paths.contains(publication.remotePath + "/manifest.json"))
        XCTAssertFalse(paths.contains { $0.contains(".upload-") })
        let (_, downloaded) = try await transport.download(path: publication.remotePath + "/payload/000000.cpenc")
        XCTAssertEqual(downloaded, Data("ciphertext".utf8))
    }

    func testDropboxHashMatchesPublishedReferenceVector() {
        XCTAssertEqual(
            DropboxBackupDestination.contentHash(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            DropboxBackupDestination.contentHash(Data("abc".utf8)),
            "4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358"
        )
    }

    func testEncryptedGenerationPublishesAtomicallyPrunesAndDownloadsExactly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-destination-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = FakeDropboxBackupTransport(pageSize: 2)
        await transport.seedFolder("/Backups/20260101.clearpocketbackup")
        await transport.seedFolder("/Backups/20260201.clearpocketbackup")
        let package = try makePackage(root: root, name: "ClearPocket-20260301.clearpocketbackup",
                                      payloads: [Data(repeating: 7, count: 9), Data(repeating: 11, count: 17)])
        let destination = try DropboxBackupDestination(transport: transport, retention: 2)

        let result = try await destination.publish(packageURL: package)
        XCTAssertEqual(result.remotePath, "/Backups/ClearPocket-20260301.clearpocketbackup")
        XCTAssertEqual(result.fileCount, 3)
        let paths = await transport.paths()
        XCTAssertFalse(paths.contains { $0.contains(".upload-") }, "Temporary generations must never remain visible")
        XCTAssertFalse(paths.contains { $0.hasPrefix("/Backups/20260101.clearpocketbackup") })
        XCTAssertTrue(paths.contains("/Backups/20260201.clearpocketbackup"))

        let restored = root.appendingPathComponent("Downloaded.clearpocketbackup", isDirectory: true)
        try await destination.download(remotePath: result.remotePath, destinationURL: restored)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("manifest.json")),
                       try Data(contentsOf: package.appendingPathComponent("manifest.json")))
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("payload/000000.cpenc")),
                       Data(repeating: 7, count: 9))
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("payload/000001.cpenc")),
                       Data(repeating: 11, count: 17))
        let listCalls = await transport.listCalls()
        XCTAssertGreaterThan(listCalls, 1, "Pagination must be consumed rather than silently truncated")
    }

    func testFailedIntegrityNeverPromotesRemoteOrLocalGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try makePackage(root: root, name: "Generation.clearpocketbackup",
                                      payloads: [Data("ciphertext".utf8)])
        let badUpload = FakeDropboxBackupTransport(corruptUploadMetadata: true)
        let destination = try DropboxBackupDestination(transport: badUpload)
        do { _ = try await destination.publish(packageURL: package); XCTFail("Corrupt metadata must fail") }
        catch is DropboxBackupDestinationError {}
        let failedPaths = await badUpload.paths()
        XCTAssertFalse(failedPaths.contains("/Backups/Generation.clearpocketbackup"))

        let transport = FakeDropboxBackupTransport()
        let healthy = try DropboxBackupDestination(transport: transport)
        let publication = try await healthy.publish(packageURL: package)
        await transport.corruptDownload(path: publication.remotePath + "/payload/000000.cpenc")
        let output = root.appendingPathComponent("Rejected.clearpocketbackup", isDirectory: true)
        do { try await healthy.download(remotePath: publication.remotePath, destinationURL: output); XCTFail("Tampering must fail") }
        catch is DropboxBackupDestinationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testLargeEncryptedPayloadUsesBoundedUploadSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xa5, count: 8 * 1_024 * 1_024 + 17)
        let package = try makePackage(root: root, name: "Large.clearpocketbackup", payloads: [payload])
        let transport = FakeDropboxBackupTransport()
        let destination = try DropboxBackupDestination(transport: transport)

        let publication = try await destination.publish(packageURL: package)

        let sessionCount = await transport.uploadSessionCount()
        let largestChunk = await transport.largestUploadChunk()
        XCTAssertEqual(sessionCount, 1)
        XCTAssertLessThanOrEqual(largestChunk, 8 * 1_024 * 1_024)
        let (_, uploaded) = try await transport.download(path: publication.remotePath + "/payload/000000.cpenc")
        XCTAssertEqual(uploaded, payload)
    }

    func testInvalidConfigurationAndPackagePathsFailClosed() async throws {
        let transport = FakeDropboxBackupTransport()
        XCTAssertThrowsError(try DropboxBackupDestination(transport: transport, folder: "/"))
        XCTAssertThrowsError(try DropboxBackupDestination(transport: transport, folder: "/Backups/../Other"))
        XCTAssertThrowsError(try DropboxBackupDestination(transport: transport, retention: 0))

        let destination = try DropboxBackupDestination(transport: transport)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).clearpocketbackup")
        do {
            try await destination.download(remotePath: "/Other/Generation.clearpocketbackup", destinationURL: output)
            XCTFail("A remote generation outside the configured app folder must be rejected")
        } catch let error as DropboxBackupDestinationError {
            guard case .invalidPackage = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await destination.download(remotePath: "/Backups/Nested/Generation.clearpocketbackup", destinationURL: output)
            XCTFail("Only direct immutable generations in the configured app folder are valid")
        } catch let error as DropboxBackupDestinationError {
            guard case .invalidPackage = error else { return XCTFail("Unexpected error: \(error)") }
        }

        for unsafe in [
            "/Other/Generation.clearpocketbackup",
            "/Backups/Nested/Generation.clearpocketbackup",
            "/Backups/not-a-generation",
        ] {
            do {
                try await destination.deleteGeneration(remotePath: unsafe)
                XCTFail("Deletion outside one direct encrypted generation must fail")
            } catch let error as DropboxBackupDestinationError {
                guard case .invalidPackage = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testExplicitGenerationDeletionRemovesOnlySelectedBackup() async throws {
        let transport = FakeDropboxBackupTransport()
        await transport.seedFolder("/Backups/First.clearpocketbackup")
        await transport.seedFolder("/Backups/First.clearpocketbackup/payload")
        await transport.seedFile("/Backups/First.clearpocketbackup/payload/000000.cpenc", data: Data("one".utf8))
        await transport.seedFolder("/Backups/Second.clearpocketbackup")
        await transport.seedFile("/Backups/Second.clearpocketbackup/manifest.json", data: Data("two".utf8))
        let destination = try DropboxBackupDestination(transport: transport)

        try await destination.deleteGeneration(remotePath: "/Backups/First.clearpocketbackup")

        let paths = await transport.paths()
        XCTAssertFalse(paths.contains { $0.hasPrefix("/Backups/First.clearpocketbackup") })
        XCTAssertTrue(paths.contains("/Backups/Second.clearpocketbackup"))
        let remaining = try await destination.generations().map(\.name)
        XCTAssertEqual(remaining, ["Second.clearpocketbackup"])
    }

    private func makePackage(root: URL, name: String, payloads: [Data]) throws -> URL {
        let package = root.appendingPathComponent(name, isDirectory: true)
        let directory = package.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records = try payloads.enumerated().map { index, data -> LocalDeviceBackupFile in
            let name = String(format: "%06d.cpenc", index)
            try data.write(to: directory.appendingPathComponent(name))
            return .init(payloadName: name, restorePath: index == 0 ? "authority.sqlite3" : "attachment-key.bin",
                         role: index == 0 ? "database" : "attachment_key",
                         plaintextBytes: Int64(data.count), plaintextSHA256: String(repeating: "a", count: 64),
                         encryptedBytes: Int64(data.count), encryptedSHA256: String(repeating: "b", count: 64))
        }
        let manifest = LocalDeviceBackupManifest(format: LocalDeviceBackupManifest.format,
            version: LocalDeviceBackupManifest.version, createdAt: "2026-09-30T12:00:00Z",
            localSchemaVersion: LocalDatabase.schemaVersion, budgetID: "budget", files: records,
            authentication: "test-authentication")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        return package
    }
}

private actor FakeDropboxBackupTransport: DropboxBackupTransport {
    private var files: [String: Data] = [:]
    private var folders: Set<String> = []
    private var sessions: [String: Data] = [:]
    private var calls = 0
    private var sessionStarts = 0
    private var maximumChunk = 0
    private let pageSize: Int
    private let corruptUploadMetadata: Bool
    private let failListing: Bool
    private let loseMoveResponse: Bool
    private var corruptDownloads: Set<String> = []
    private var listedOverrides: [String: DropboxBackupEntry] = [:]
    private var downloads: [String] = []

    init(pageSize: Int = 100, corruptUploadMetadata: Bool = false, failListing: Bool = false, loseMoveResponse: Bool = false) {
        self.pageSize = pageSize; self.corruptUploadMetadata = corruptUploadMetadata
        self.failListing = failListing
        self.loseMoveResponse = loseMoveResponse
    }

    func seedFolder(_ path: String) { folders.insert(path) }
    func seedFile(_ path: String, data: Data) { files[path] = data }
    func overrideListedEntry(_ entry: DropboxBackupEntry) { listedOverrides[entry.path] = entry }
    func downloadedPaths() -> [String] { downloads }
    func paths() -> Set<String> { folders.union(files.keys) }
    func listCalls() -> Int { calls }
    func uploadSessionCount() -> Int { sessionStarts }
    func largestUploadChunk() -> Int { maximumChunk }
    func corruptDownload(path: String) { corruptDownloads.insert(path) }

    func createFolder(path: String) { folders.insert(path) }

    func upload(path: String, data: Data) -> DropboxBackupMetadata {
        maximumChunk = max(maximumChunk, data.count)
        files[path] = data
        return metadata(path, data)
    }

    func startUploadSession(data: Data) -> String {
        sessionStarts += 1; maximumChunk = max(maximumChunk, data.count)
        let id = UUID().uuidString; sessions[id] = data; return id
    }

    func appendUploadSession(id: String, offset: Int64, data: Data) throws {
        maximumChunk = max(maximumChunk, data.count)
        guard Int64(sessions[id]?.count ?? -1) == offset else { throw TestError.invalidOffset }
        sessions[id, default: Data()].append(data)
    }

    func finishUploadSession(id: String, offset: Int64, data: Data, path: String) throws -> DropboxBackupMetadata {
        try appendUploadSession(id: id, offset: offset, data: data)
        let result = sessions.removeValue(forKey: id) ?? Data(); files[path] = result
        return metadata(path, result)
    }

    func move(from: String, to: String) throws {
        guard folders.contains(from), !folders.contains(to) else { throw TestError.conflict }
        let childFolders = folders.filter { $0 == from || $0.hasPrefix(from + "/") }
        let childFiles = files.filter { $0.key.hasPrefix(from + "/") }
        for path in childFolders { folders.remove(path); folders.insert(to + path.dropFirst(from.count)) }
        for (path, data) in childFiles { files.removeValue(forKey: path); files[to + path.dropFirst(from.count)] = data }
        if loseMoveResponse { throw URLError(.networkConnectionLost) }
    }

    func delete(path: String) {
        folders = folders.filter { $0 != path && !$0.hasPrefix(path + "/") }
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    func list(path: String, recursive: Bool, cursor: String?) throws -> DropboxBackupPage {
        calls += 1
        if failListing { throw TestError.missing }
        let all: [DropboxBackupEntry] = (folders.map { value in
            .init(path: value, name: (value as NSString).lastPathComponent, isFolder: true)
        } + files.map { value, data in
            .init(path: value, name: (value as NSString).lastPathComponent, isFolder: false,
                  size: Int64(data.count), contentHash: DropboxBackupDestination.contentHash(data))
        }).map { listedOverrides[$0.path] ?? $0 }.filter { entry in
            guard entry.path.hasPrefix(path + "/") else { return false }
            return recursive || !entry.path.dropFirst(path.count + 1).contains("/")
        }.sorted { $0.path < $1.path }
        let start = Int(cursor ?? "0") ?? 0
        let end = min(start + pageSize, all.count)
        return .init(entries: Array(all[start..<end]), cursor: end < all.count ? String(end) : nil)
    }

    func download(path: String) throws -> (DropboxBackupMetadata, Data) {
        downloads.append(path)
        guard var data = files[path] else { throw TestError.missing }
        let metadata = metadata(path, data)
        if corruptDownloads.contains(path), !data.isEmpty { data[0] ^= 0xff }
        return (metadata, data)
    }

    private func metadata(_ path: String, _ data: Data) -> DropboxBackupMetadata {
        .init(path: path, size: Int64(data.count),
              contentHash: corruptUploadMetadata ? String(repeating: "0", count: 64) : DropboxBackupDestination.contentHash(data))
    }

    enum TestError: Error { case invalidOffset, conflict, missing }
}
