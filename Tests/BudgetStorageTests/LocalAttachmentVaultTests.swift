import Foundation
import XCTest
@testable import BudgetStorage

final class LocalAttachmentVaultTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func testEncryptedObjectRoundTripsAndNeverWritesPlaintext() async throws {
        let directory = try temporaryDirectory()
        let vault = try LocalAttachmentVault(directoryURL: directory, keyData: Data(repeating: 7, count: 32))
        let plaintext = Data("private receipt contents".utf8)

        let stored = try await vault.store(plaintext, objectName: "receipt.enc")

        XCTAssertEqual(stored.plaintextSize, Int64(plaintext.count))
        XCTAssertEqual(stored.plaintextSHA256.count, 64)
        let ciphertext = try Data(contentsOf: directory.appendingPathComponent("objects/receipt.enc"))
        XCTAssertFalse(ciphertext.contains(plaintext), "The object file must not contain plaintext")
        let recovered = try await vault.data(objectName: stored.objectName, expectedSHA256: stored.plaintextSHA256)
        XCTAssertEqual(recovered, plaintext)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("objects/receipt.enc").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        do {
            _ = try await vault.store(plaintext, objectName: "receipt.enc")
            XCTFail("Known-good encrypted objects must not be overwritten")
        } catch let error as LocalStorageError {
            XCTAssertEqual(error, .destinationExists)
        }
    }

    func testTamperingAndWrongKeyFailAuthentication() async throws {
        let directory = try temporaryDirectory()
        let vault = try LocalAttachmentVault(directoryURL: directory, keyData: Data(repeating: 1, count: 32))
        let stored = try await vault.store(Data("receipt".utf8), objectName: "receipt.enc")
        let objectURL = directory.appendingPathComponent("objects/receipt.enc")
        var ciphertext = try Data(contentsOf: objectURL)
        ciphertext[ciphertext.index(before: ciphertext.endIndex)] ^= 0xff
        try ciphertext.write(to: objectURL)

        do {
            _ = try await vault.data(objectName: stored.objectName, expectedSHA256: stored.plaintextSHA256)
            XCTFail("Tampered ciphertext must fail closed")
        } catch let error as LocalStorageError {
            XCTAssertEqual(error, .invalidSnapshot("Encrypted attachment authentication failed"))
        }

        let secondDirectory = try temporaryDirectory()
        let correct = try LocalAttachmentVault(directoryURL: secondDirectory, keyData: Data(repeating: 2, count: 32))
        let second = try await correct.store(Data("another".utf8), objectName: "another.enc")
        let wrong = try LocalAttachmentVault(directoryURL: secondDirectory, keyData: Data(repeating: 3, count: 32))
        do {
            _ = try await wrong.data(objectName: second.objectName, expectedSHA256: second.plaintextSHA256)
            XCTFail("A different authority key must not decrypt the object")
        } catch let error as LocalStorageError {
            XCTAssertEqual(error, .invalidSnapshot("Encrypted attachment authentication failed"))
        }
    }

    func testDetachIsRecoverableUntilExplicitRetentionPurge() async throws {
        let directory = try temporaryDirectory()
        let vault = try LocalAttachmentVault(directoryURL: directory, keyData: Data(repeating: 9, count: 32))
        let plaintext = Data("recoverable".utf8)
        let stored = try await vault.store(plaintext, objectName: "recover.enc")
        let detachedAt = Date(timeIntervalSince1970: 1_000)

        let tombstone = try await vault.tombstone(objectName: stored.objectName, detachedAt: detachedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("objects/recover.enc").path))
        try await vault.restoreTombstone(named: tombstone, as: stored.objectName)
        let recovered = try await vault.data(objectName: stored.objectName, expectedSHA256: stored.plaintextSHA256)
        XCTAssertEqual(recovered, plaintext)

        let secondTombstone = try await vault.tombstone(objectName: stored.objectName, detachedAt: detachedAt)
        let purged = try await vault.purgeTombstones(detachedBefore: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(purged, 1)
        do {
            try await vault.restoreTombstone(named: secondTombstone, as: stored.objectName)
            XCTFail("A tombstone is unavailable only after explicit retention purge")
        } catch {}
    }

    func testTraversalAndInvalidKeyAreRejected() async throws {
        let directory = try temporaryDirectory()
        XCTAssertThrowsError(try LocalAttachmentVault(directoryURL: directory, keyData: Data(repeating: 0, count: 31)))
        let vault = try LocalAttachmentVault(directoryURL: directory, keyData: Data(repeating: 0, count: 32))
        do {
            _ = try await vault.store(Data(), objectName: "../escape.enc")
            XCTFail("Object names cannot escape the private vault")
        } catch {}
    }
}
