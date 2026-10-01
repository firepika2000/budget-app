import CryptoKit
import Foundation
import XCTest
@testable import BudgetStorage

final class LocalDeviceCandidateImportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func fixture(attachment: Data) -> (LocalAuthoritySnapshot, LocalAttachmentRecord) {
        let timestamp = "2026-10-01T12:00:00Z"
        let identity = LocalAuthorityIdentity(
            householdID: "household", householdName: "Personal", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "budget", budgetName: "Budget", currencyCode: "USD"
        )
        let record = LocalAttachmentRecord(
            id: "attachment", transactionID: "transaction", filename: "receipt.jpg",
            contentType: "image/jpeg", sizeBytes: Int64(attachment.count),
            sha256: SHA256.hash(data: attachment).map { String(format: "%02x", $0) }.joined(),
            objectName: "attachment.enc", createdAt: timestamp
        )
        let snapshot = LocalAuthoritySnapshot(
            identity: identity,
            accounts: [.init(id: "checking", budgetID: "budget", name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0, createdAt: timestamp)],
            groups: [.init(id: "living", budgetID: "budget", name: "Living", sortOrder: 0)],
            categories: [.init(id: "food", budgetID: "budget", groupID: "living", name: "Food", sortOrder: 0)],
            payees: [.init(id: "market", budgetID: "budget", name: "Market", normalizedName: "market")],
            payeeAliases: [],
            transactions: [.init(id: "transaction", budgetID: "budget", accountID: "checking", payeeID: "market", payeeName: "Market", amountMinor: -1_234, occurredOn: "2026-10-01", createdByUserID: "owner", createdAt: timestamp, splits: [.init(id: "split", categoryID: "food", amountMinor: -1_234)])],
            allocations: [.init(id: "allocation", budgetID: "budget", categoryID: "food", amountMinor: 5_000, occurredOn: "2026-10-01", kind: "assignment", actorUserID: "owner", createdAt: timestamp)],
            reconciliations: [], targets: [], schedules: [], attachments: [record]
        )
        return (snapshot, record)
    }

    func testCreatesPrivateVerifiedAuthorityWithoutChangingSourceProjection() async throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent("candidate", isDirectory: true)
        let plaintext = Data("receipt payload".utf8)
        let (snapshot, record) = fixture(attachment: plaintext)
        let key = Data(repeating: 17, count: 32)

        let result = try await LocalDeviceCandidateImportService.create(
            snapshot: snapshot, authorityCreatedAt: "2026-10-01T12:00:00Z",
            attachments: [.init(record: record, plaintext: plaintext)],
            destinationRootURL: destination, attachmentKey: key
        )

        XCTAssertEqual(result.budgetID, "budget")
        XCTAssertEqual(result.attachmentCount, 1)
        let reopened = try LocalAuthorityStore(fileURL: destination.appendingPathComponent("authority.sqlite3"))
        let reopenedSnapshot = try await reopened.snapshot(budgetID: "budget")
        XCTAssertEqual(reopenedSnapshot, snapshot)
        let vault = try LocalAttachmentVault(directoryURL: destination.appendingPathComponent("Attachments"), keyData: key)
        let recovered = try await vault.data(objectName: record.objectName, expectedSHA256: record.sha256)
        XCTAssertEqual(recovered, plaintext)
    }

    func testMissingOrMismatchedAttachmentNeverPublishesCandidate() async throws {
        let parent = try temporaryDirectory()
        let plaintext = Data("receipt payload".utf8)
        let (snapshot, record) = fixture(attachment: plaintext)
        for (name, payloads) in [
            ("missing", [LocalDeviceImportAttachment]()),
            ("damaged", [.init(record: record, plaintext: Data("wrong".utf8))]),
        ] {
            let destination = parent.appendingPathComponent(name, isDirectory: true)
            do {
                _ = try await LocalDeviceCandidateImportService.create(
                    snapshot: snapshot, authorityCreatedAt: "2026-10-01T12:00:00Z",
                    attachments: payloads, destinationRootURL: destination,
                    attachmentKey: Data(repeating: 17, count: 32)
                )
                XCTFail("Invalid transfer unexpectedly published")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testExistingDestinationIsNeverOverwritten() async throws {
        let parent = try temporaryDirectory()
        let destination = parent.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let plaintext = Data("receipt payload".utf8)
        let (snapshot, record) = fixture(attachment: plaintext)

        do {
            _ = try await LocalDeviceCandidateImportService.create(
                snapshot: snapshot, authorityCreatedAt: "2026-10-01T12:00:00Z",
                attachments: [.init(record: record, plaintext: plaintext)],
                destinationRootURL: destination, attachmentKey: Data(repeating: 17, count: 32)
            )
            XCTFail("Existing destination unexpectedly overwritten")
        } catch let error as LocalStorageError {
            XCTAssertEqual(error, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    }
}
