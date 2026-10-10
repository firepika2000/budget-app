import Foundation

/// Manifests are untrusted metadata, not ledger payloads. Keep reads bounded
/// before JSON decoding or authentication, and refuse filesystem indirection.
enum BackupManifestIO {
    static let maximumBytes = 64 * 1_024 * 1_024
    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw LocalStorageError.invalidSnapshot("The backup manifest is missing, unsafe or exceeds the supported metadata size")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: size + 1) ?? Data()
        guard data.count == size, data.count <= maximumBytes else {
            throw LocalStorageError.invalidSnapshot("The backup manifest changed while reading or exceeds the supported metadata size")
        }
        return data
    }
}
