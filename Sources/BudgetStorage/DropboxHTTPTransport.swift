import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol DropboxAccessTokenProviding: Sendable {
    /// Returns a currently usable access token, refreshing it when necessary.
    func validAccessToken() async throws -> String
    /// Invalidates only the rejected value so a newer concurrently rotated token is not discarded.
    func rejectAccessToken(_ token: String) async
}

public enum DropboxHTTPTransportError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, String)
    case malformedMetadata

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Dropbox returned an invalid HTTP response."
        case let .httpStatus(status, message): "Dropbox request failed (\(status)): \(message)"
        case .malformedMetadata: "Dropbox returned incomplete file metadata."
        }
    }
}

/// Dropbox API v2 adapter. It owns no credential state: every request asks the credential provider
/// for the current token, and one 401 rejection is handed back to that provider before a retry.
public final class DropboxHTTPTransport: DropboxBackupTransport, @unchecked Sendable {
    private let tokenProvider: DropboxAccessTokenProviding
    private let session: URLSession
    private let apiBaseURL: URL
    private let contentBaseURL: URL

    public init(
        tokenProvider: DropboxAccessTokenProviding,
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.dropboxapi.com/2/")!,
        contentBaseURL: URL = URL(string: "https://content.dropboxapi.com/2/")!
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.contentBaseURL = contentBaseURL
    }

    public func createFolder(path: String) async throws {
        do {
            _ = try await rpc("files/create_folder_v2", body: ["path": path, "autorename": false])
        } catch let error as DropboxHTTPTransportError {
            // create_folder_v2 is used as ensure-folder by the destination. An existing folder is
            // safe to reuse; a file conflict fails on the subsequent child operation.
            if case let .httpStatus(409, message) = error, message.contains("conflict") { return }
            throw error
        }
    }

    public func upload(path: String, data: Data) async throws -> DropboxBackupMetadata {
        let response = try await content(
            "files/upload",
            argument: commit(path),
            body: data
        )
        return try decodeMetadata(response)
    }

    public func startUploadSession(data: Data) async throws -> String {
        let response = try await content("files/upload_session/start", argument: ["close": false], body: data)
        let value = try JSONDecoder().decode(SessionStart.self, from: response)
        guard !value.sessionID.isEmpty else { throw DropboxHTTPTransportError.malformedMetadata }
        return value.sessionID
    }

    public func appendUploadSession(id: String, offset: Int64, data: Data) async throws {
        _ = try await content(
            "files/upload_session/append_v2",
            argument: ["cursor": ["session_id": id, "offset": offset], "close": false],
            body: data
        )
    }

    public func finishUploadSession(
        id: String,
        offset: Int64,
        data: Data,
        path: String
    ) async throws -> DropboxBackupMetadata {
        let response = try await content(
            "files/upload_session/finish",
            argument: ["cursor": ["session_id": id, "offset": offset], "commit": commit(path)],
            body: data
        )
        return try decodeMetadata(response)
    }

    public func move(from: String, to: String) async throws {
        _ = try await rpc("files/move_v2", body: [
            "from_path": from, "to_path": to, "autorename": false,
            "allow_ownership_transfer": false
        ])
    }

    public func delete(path: String) async throws {
        _ = try await rpc("files/delete_v2", body: ["path": path])
    }

    public func list(path: String, recursive: Bool, cursor: String?) async throws -> DropboxBackupPage {
        let response: Data
        if let cursor {
            response = try await rpc("files/list_folder/continue", body: ["cursor": cursor])
        } else {
            response = try await rpc("files/list_folder", body: [
                "path": path, "recursive": recursive, "include_deleted": false,
                "include_mounted_folders": false, "limit": 200
            ])
        }
        let result = try JSONDecoder().decode(ListResult.self, from: response)
        return .init(
            entries: try result.entries.map(Self.entry),
            cursor: result.hasMore ? result.cursor : nil
        )
    }

    public func download(path: String) async throws -> (DropboxBackupMetadata, Data) {
        var request = URLRequest(url: endpoint(contentBaseURL, "files/download"))
        request.httpMethod = "POST"
        request.setValue(try argumentHeader(["path": path]), forHTTPHeaderField: "Dropbox-API-Arg")
        let (body, response) = try await authorized(request)
        guard let header = response.value(forHTTPHeaderField: "Dropbox-API-Result"),
              let metadataData = header.data(using: .utf8) else {
            throw DropboxHTTPTransportError.malformedMetadata
        }
        return (try decodeMetadata(metadataData), body)
    }

    private func rpc(_ route: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint(apiBaseURL, route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await authorized(request).0
    }

    private func content(_ route: String, argument: [String: Any], body: Data) async throws -> Data {
        var request = URLRequest(url: endpoint(contentBaseURL, route))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(try argumentHeader(argument), forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = body
        return try await authorized(request).0
    }

    private func authorized(_ original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            let token = try await tokenProvider.validAccessToken()
            var request = original
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw DropboxHTTPTransportError.invalidResponse
            }
            if response.statusCode == 401, attempt == 0 {
                await tokenProvider.rejectAccessToken(token)
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                let message = String(data: data.prefix(2_048), encoding: .utf8) ?? "Unknown error"
                throw DropboxHTTPTransportError.httpStatus(response.statusCode, message)
            }
            return (data, response)
        }
        throw DropboxHTTPTransportError.invalidResponse
    }

    private func argumentHeader(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw DropboxHTTPTransportError.invalidResponse
        }
        return result
    }

    private func commit(_ path: String) -> [String: Any] {
        ["path": path, "mode": "add", "autorename": false, "mute": true, "strict_conflict": true]
    }

    private func decodeMetadata(_ data: Data) throws -> DropboxBackupMetadata {
        let value = try JSONDecoder().decode(APIEntry.self, from: data)
        guard value.tag == "file", let path = value.pathDisplay ?? value.pathLower,
              let size = value.size, let hash = value.contentHash else {
            throw DropboxHTTPTransportError.malformedMetadata
        }
        return .init(path: path, size: size, contentHash: hash)
    }

    private func endpoint(_ base: URL, _ route: String) -> URL {
        route.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private static func entry(_ value: APIEntry) throws -> DropboxBackupEntry {
        guard let path = value.pathDisplay ?? value.pathLower else {
            throw DropboxHTTPTransportError.malformedMetadata
        }
        if value.tag == "folder" {
            return .init(path: path, name: value.name, isFolder: true)
        }
        guard value.tag == "file", let size = value.size, let hash = value.contentHash else {
            throw DropboxHTTPTransportError.malformedMetadata
        }
        return .init(path: path, name: value.name, isFolder: false, size: size, contentHash: hash)
    }

    private struct SessionStart: Decodable {
        let sessionID: String
        enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
    }

    private struct ListResult: Decodable {
        let entries: [APIEntry]
        let cursor: String
        let hasMore: Bool
        enum CodingKeys: String, CodingKey { case entries, cursor; case hasMore = "has_more" }
    }

    private struct APIEntry: Decodable {
        let tag: String
        let name: String
        let pathLower: String?
        let pathDisplay: String?
        let size: Int64?
        let contentHash: String?
        enum CodingKeys: String, CodingKey {
            case tag = ".tag", name, size
            case pathLower = "path_lower"
            case pathDisplay = "path_display"
            case contentHash = "content_hash"
        }
    }
}
