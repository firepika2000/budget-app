import Foundation
import XCTest
@testable import BudgetStorage

final class BackupManifestIOTests: XCTestCase {
    func testRegularMetadataReadsExactlyAndRejectsSymlinkDirectoryAndEmptyFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("manifest.json")
        let bytes = Data(#"{"metadata":"unchanged"}"#.utf8)
        try bytes.write(to: file)
        XCTAssertEqual(try BackupManifestIO.read(file), bytes)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BackupManifestIO.read(link))
        XCTAssertThrowsError(try BackupManifestIO.read(root))
        try Data().write(to: file)
        XCTAssertThrowsError(try BackupManifestIO.read(file))
    }
    func testOversizedSparseManifestIsRejectedBeforeReadingContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(BackupManifestIO.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try BackupManifestIO.read(file))
    }
}
