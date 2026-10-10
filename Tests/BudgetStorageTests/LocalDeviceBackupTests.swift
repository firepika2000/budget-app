import Foundation
import XCTest
@testable import BudgetStorage

final class LocalDeviceBackupTests: XCTestCase {
    func testRestoreRejectsSymlinkToOtherwiseValidAuthenticatedManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (authority, attachments, attachmentKey, _) = try await fixture(in: root.appendingPathComponent("source"))
        let recovery = try LocalDeviceBackupRecoveryKey(data: Data(repeating: 7, count: 32))
        let package = root.appendingPathComponent("generation.clearpocketbackup")
        _ = try await LocalDeviceBackupService.create(authority: authority, budgetID: "budget",
            attachmentsDirectory: attachments, attachmentKey: attachmentKey, destinationURL: package, recoveryKey: recovery)
        let manifest = package.appendingPathComponent("manifest.json")
        let moved = root.appendingPathComponent("authentic-manifest.json")
        try FileManager.default.moveItem(at: manifest, to: moved)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: moved)
        let destination = root.appendingPathComponent("restored")
        do {
            _ = try await LocalDeviceBackupService.restore(packageURL: package, destinationRootURL: destination, recoveryKey: recovery)
            XCTFail("Restore accepted a symbolic-link manifest")
        } catch { XCTAssertTrue(error is LocalStorageError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func fixture(in root: URL) async throws -> (LocalAuthorityStore, URL, Data, Data) {
        let authority = try LocalAuthorityStore(fileURL: root.appendingPathComponent("authority.sqlite3"))
        let created = "2026-10-01T00:00:00Z"
        try await authority.bootstrap(.init(householdID: "household", householdName: "Household",
            ownerUserID: "owner", ownerDisplayName: "Owner", budgetID: "budget",
            budgetName: "Budget", currencyCode: "USD"), createdAt: created)
        try await authority.insertAccount(.init(id: "checking", budgetID: "budget", name: "Checking",
            kind: "checking", isOnBudget: true, openingBalanceMinor: 123_45, createdAt: created))
        try await authority.insertCategoryGroup(.init(id: "needs", budgetID: "budget", name: "Needs", sortOrder: 0))
        try await authority.insertCategory(.init(id: "food", budgetID: "budget", groupID: "needs", name: "Food", sortOrder: 0))
        try await authority.insertTransaction(.init(id: "purchase", budgetID: "budget", accountID: "checking",
            payeeName: "Market", amountMinor: -12_34, occurredOn: "2026-10-01", memo: "Durable",
            createdByUserID: "owner", createdAt: created,
            splits: [.init(id: "food-split", categoryID: "food", amountMinor: -12_34)]))
        let attachmentKey = Data((0..<32).map(UInt8.init))
        let attachmentData = Data("local encrypted receipt".utf8)
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        let vault = try LocalAttachmentVault(directoryURL: attachments, keyData: attachmentKey)
        let object = try await vault.store(attachmentData, objectName: "receipt.enc")
        try await authority.insertAttachment(.init(id: "receipt", transactionID: "purchase",
            filename: "receipt.jpg", contentType: "image/jpeg", sizeBytes: object.plaintextSize,
            sha256: object.plaintextSHA256, objectName: object.objectName, createdAt: created))
        let base = try await authority.snapshot(budgetID: "budget")
        try await authority.replaceWorkspaceState(.init(identity: base.identity, accounts: base.accounts,
            accountRevisions: [.init(id: "account-renamed", budgetID: "budget", accountID: "checking", action: "updated",
                actorUserID: "owner", beforeJSON: #"{"name":"Main","account_type":"checking","is_on_budget":true,"is_closed":false}"#,
                afterJSON: #"{"name":"Checking","account_type":"checking","is_on_budget":true,"is_closed":false}"#,
                createdAt: created)],
            structureRevisions: [.init(id: "category-renamed", budgetID: "budget", resourceType: "category", resourceID: "food",
                action: "updated", actorUserID: "owner", beforeJSON: #"{"group_id":"needs","name":"Meals","sort_order":0,"is_archived":false}"#,
                afterJSON: #"{"group_id":"needs","name":"Food","sort_order":0,"is_archived":false}"#, createdAt: created)],
            groups: base.groups, categories: base.categories, payees: base.payees, payeeAliases: base.payeeAliases,
            payeeRevisions: [.init(id: "payee-merge", budgetID: "budget", payeeID: "old-market", action: "merged",
                actorUserID: "owner", beforeJSON: #"{"display_name":"Old Market","aliases":["OM"]}"#,
                afterJSON: #"{"display_name":"Old Market","is_archived":true,"merged_into_payee_id":"market","aliases":[]}"#,
                createdAt: created)],
            transactions: base.transactions, allocations: base.allocations, reconciliations: base.reconciliations,
            targets: base.targets,
            targetRevisions: [.init(id: "target-deleted", budgetID: "budget", categoryID: "food", targetID: "old-target",
                action: "deleted", actorUserID: "owner", beforeJSON: #"{"target_type":"monthly_funding","target_amount_minor":9007199254740993,"minimum_contribution_minor":0,"priority":50,"is_active":true}"#,
                createdAt: created)],
            schedules: base.schedules,
            scheduleRevisions: [.init(id: "schedule-realized", budgetID: "budget", scheduleID: "old-schedule",
                action: "realized", actorUserID: "owner",
                beforeJSON: #"{"account_id":"checking","name":"Market","amount_minor":-1234,"next_date":"2026-10-01","recurrence_unit":"once","interval_count":1,"memo":"","is_active":true}"#,
                afterJSON: #"{"account_id":"checking","name":"Market","amount_minor":-1234,"next_date":"2026-10-01","recurrence_unit":"once","interval_count":1,"memo":"","is_active":false}"#,
                transactionIDs: ["purchase"], createdAt: created)],
            attachments: base.attachments,
            debtTermsRevisions: [.init(id: "terms-deleted", budgetID: "budget", accountID: "checking", action: "deleted",
                actorUserID: "owner", beforeJSON: #"{"terms_type":"loan","minimum_payment_minor":9007199254740993}"#,
                afterJSON: nil, createdAt: created)],
            debtPayoffPlanRevisions: [.init(id: "reset-plan", budgetID: "budget", userID: "owner", action: "deleted",
                beforeJSON: #"{"strategy":"avalanche","rollover":true,"extra_payment_minor":9007199254740993,"account_ids":[],"custom_order":[]}"#,
                afterJSON: nil, createdAt: created)]))
        return (authority, attachments, attachmentKey, attachmentData)
    }

    func testEncryptedGenerationRestoresCompleteAuthorityAndAttachmentIntoNewPath() async throws {
        let root = try temporaryDirectory()
        let (authority, attachments, attachmentKey, attachmentData) = try await fixture(in: root.appendingPathComponent("source"))
        let recovery = try LocalDeviceBackupRecoveryKey(data: Data(repeating: 7, count: 32))
        let original = try await authority.snapshot(budgetID: "budget")
        let package = root.appendingPathComponent("generation.clearpocketbackup")
        let created = try await LocalDeviceBackupService.create(authority: authority, budgetID: "budget",
            attachmentsDirectory: attachments, attachmentKey: attachmentKey, destinationURL: package,
            recoveryKey: recovery, now: Date(timeIntervalSince1970: 1_759_276_800))

        XCTAssertEqual(created.format, LocalDeviceBackupManifest.format)
        XCTAssertEqual(created.localSchemaVersion, LocalDatabase.schemaVersion)
        XCTAssertEqual(Set(created.files.map(\.role)), Set(["database", "attachment_key", "attachment_object"]))
        XCTAssertFalse(try Data(contentsOf: package.appendingPathComponent("payload").appendingPathComponent(
            try XCTUnwrap(created.files.first(where: { $0.role == "database" })?.payloadName)
        )).contains(Data("SQLite format 3".utf8)), "The database snapshot must not remain plaintext")

        let restoredRoot = root.appendingPathComponent("restored")
        let result = try await LocalDeviceBackupService.restore(packageURL: package,
            destinationRootURL: restoredRoot, recoveryKey: recovery)
        XCTAssertEqual(result.attachmentKey, attachmentKey)
        let restoredAuthority = try LocalAuthorityStore(fileURL: restoredRoot.appendingPathComponent("authority.sqlite3"))
        let snapshot = try await restoredAuthority.snapshot(budgetID: "budget")
        XCTAssertEqual(snapshot, original, "Encrypted restore must preserve the entire attributed authority, not only current balances")
        XCTAssertFalse(snapshot.accountRevisions?.isEmpty ?? true)
        XCTAssertFalse(snapshot.structureRevisions?.isEmpty ?? true)
        XCTAssertEqual(snapshot.payeeRevisions?.first?.action, "merged")
        XCTAssertEqual(snapshot.targetRevisions?.first?.action, "deleted")
        XCTAssertTrue(snapshot.targetRevisions?.first?.beforeJSON?.contains("9007199254740993") == true)
        XCTAssertNil(snapshot.targetRevisions?.first?.afterJSON)
        XCTAssertEqual(snapshot.scheduleRevisions?.first?.transactionIDs, ["purchase"])
        XCTAssertEqual(snapshot.debtTermsRevisions?.first?.action, "deleted")
        XCTAssertTrue(snapshot.debtTermsRevisions?.first?.beforeJSON?.contains("9007199254740993") == true)
        XCTAssertNil(snapshot.debtTermsRevisions?.first?.afterJSON)
        XCTAssertEqual(snapshot.accounts.map(\.openingBalanceMinor), [123_45])
        XCTAssertEqual(snapshot.transactions.map(\.amountMinor), [-12_34])
        XCTAssertEqual(snapshot.debtPayoffPlanRevisions?.first?.action, "deleted")
        XCTAssertTrue(snapshot.debtPayoffPlanRevisions?.first?.beforeJSON?.contains("9007199254740993") == true)
        let restoredVault = try LocalAttachmentVault(directoryURL: restoredRoot.appendingPathComponent("Attachments"), keyData: result.attachmentKey)
        let metadata = try XCTUnwrap(snapshot.attachments.first)
        let restoredAttachment = try await restoredVault.data(objectName: metadata.objectName, expectedSHA256: metadata.sha256)
        XCTAssertEqual(restoredAttachment, attachmentData)
    }

    func testWrongRecoveryKeyAndTamperedPayloadFailWithoutPublishingDestination() async throws {
        let root = try temporaryDirectory()
        let (authority, attachments, attachmentKey, _) = try await fixture(in: root.appendingPathComponent("source"))
        let recovery = try LocalDeviceBackupRecoveryKey(data: Data(repeating: 9, count: 32))
        let package = root.appendingPathComponent("generation.clearpocketbackup")
        let manifest = try await LocalDeviceBackupService.create(authority: authority, budgetID: "budget",
            attachmentsDirectory: attachments, attachmentKey: attachmentKey, destinationURL: package,
            recoveryKey: recovery)

        let wrongDestination = root.appendingPathComponent("wrong-key")
        do {
            _ = try await LocalDeviceBackupService.restore(packageURL: package,
                destinationRootURL: wrongDestination,
                recoveryKey: try .init(data: Data(repeating: 8, count: 32)))
            XCTFail("A wrong recovery key must not authenticate")
        } catch let error as LocalStorageError {
            guard case .invalidSnapshot = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongDestination.path))

        let payload = package.appendingPathComponent("payload").appendingPathComponent(try XCTUnwrap(manifest.files.first?.payloadName))
        var bytes = try Data(contentsOf: payload)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: payload, options: .atomic)
        let tamperedDestination = root.appendingPathComponent("tampered")
        do {
            _ = try await LocalDeviceBackupService.restore(packageURL: package,
                destinationRootURL: tamperedDestination, recoveryKey: recovery)
            XCTFail("A tampered payload must not restore")
        } catch let error as LocalStorageError {
            guard case .invalidSnapshot = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tamperedDestination.path))
    }

    func testGenerationAndRestoreNeverOverwriteExistingPaths() async throws {
        let root = try temporaryDirectory()
        let (authority, attachments, attachmentKey, _) = try await fixture(in: root.appendingPathComponent("source"))
        let recovery = try LocalDeviceBackupRecoveryKey(data: Data(repeating: 3, count: 32))
        let package = root.appendingPathComponent("generation.clearpocketbackup")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        do {
            _ = try await LocalDeviceBackupService.create(authority: authority, budgetID: "budget",
                attachmentsDirectory: attachments, attachmentKey: attachmentKey,
                destinationURL: package, recoveryKey: recovery)
            XCTFail("An existing generation must not be overwritten")
        } catch let error as LocalStorageError { XCTAssertEqual(error, .destinationExists) }
    }

    func testRestoreRejectsAuthenticatedRolePathMismatchAndNonRegularPayload() async throws {
        let root = try temporaryDirectory()
        let (authority, attachments, attachmentKey, _) = try await fixture(in: root.appendingPathComponent("source"))
        let recovery = try LocalDeviceBackupRecoveryKey(data: Data(repeating: 4, count: 32))
        let package = root.appendingPathComponent("generation.clearpocketbackup")
        let manifest = try await LocalDeviceBackupService.create(authority: authority, budgetID: "budget",
            attachmentsDirectory: attachments, attachmentKey: attachmentKey,
            destinationURL: package, recoveryKey: recovery)

        let payload = package.appendingPathComponent("payload").appendingPathComponent(
            try XCTUnwrap(manifest.files.first(where: { $0.role == "database" })?.payloadName)
        )
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)

        let destination = root.appendingPathComponent("non-regular")
        do {
            _ = try await LocalDeviceBackupService.restore(packageURL: package,
                destinationRootURL: destination, recoveryKey: recovery)
            XCTFail("A directory must never be accepted as an encrypted payload")
        } catch let error as LocalStorageError {
            guard case .invalidSnapshot = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
