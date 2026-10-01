import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BudgetStorage

final class DropboxHTTPTransportTests: XCTestCase {
    override func tearDown() {
        DropboxMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testUnauthorizedRequestRejectsOnlyOldTokenAndRetriesWithCurrentCredential() async throws {
        let provider = RotatingDropboxTokenProvider(initial: "token-A", replacement: "token-B")
        let recorder = RequestRecorder()
        DropboxMockURLProtocol.handler = { request in
            recorder.append(request)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-A" {
                return Self.response(request, status: 401, body: #"{"error_summary":"expired_access_token/"}"#)
            }
            return Self.response(request, body: Self.fileMetadata(path: "/Backups/value.cpenc", size: 3))
        }
        let transport = makeTransport(provider)

        let metadata = try await transport.upload(path: "/Backups/value.cpenc", data: Data("abc".utf8))

        XCTAssertEqual(metadata.path, "/Backups/value.cpenc")
        XCTAssertEqual(recorder.authorizationHeaders(), ["Bearer token-A", "Bearer token-B"])
        let rejected = await provider.rejectedTokens()
        XCTAssertEqual(rejected, ["token-A"])
        XCTAssertEqual(recorder.bodies(), [Data("abc".utf8), Data("abc".utf8)])
    }

    func testListFolderAndContinueDecodeBoundedPages() async throws {
        let provider = RotatingDropboxTokenProvider(initial: "current", replacement: "unused")
        let recorder = RequestRecorder()
        DropboxMockURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path.hasSuffix("/files/list_folder/continue") == true {
                return Self.response(request, body:
                    #"{"entries":[{".tag":"file","name":"b.cpenc","path_display":"/Backups/b.cpenc","size":2,"content_hash":"bb"}],"cursor":"done","has_more":false}"#
                )
            }
            return Self.response(request, body:
                #"{"entries":[{".tag":"folder","name":"Generation.clearpocketbackup","path_display":"/Backups/Generation.clearpocketbackup"}],"cursor":"next","has_more":true}"#
            )
        }
        let transport = makeTransport(provider)

        let first = try await transport.list(path: "/Backups", recursive: false, cursor: nil)
        let second = try await transport.list(path: "/ignored", recursive: true, cursor: first.cursor)

        XCTAssertEqual(first.cursor, "next")
        XCTAssertEqual(first.entries.first?.isFolder, true)
        XCTAssertNil(second.cursor)
        XCTAssertEqual(second.entries.first?.size, 2)
        let requests = recorder.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/2/files/list_folder", "/2/files/list_folder/continue"])
        let continued = try XCTUnwrap(recorder.bodies().last ?? nil)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: continued) as? [String: String], ["cursor": "next"])
    }

    func testUploadSessionAndDownloadUseDropboxContentContracts() async throws {
        let provider = RotatingDropboxTokenProvider(initial: "current", replacement: "unused")
        let recorder = RequestRecorder()
        DropboxMockURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/2/files/upload_session/start":
                return Self.response(request, body: #"{"session_id":"session-1"}"#)
            case "/2/files/upload_session/append_v2":
                return Self.response(request, body: "")
            case "/2/files/upload_session/finish":
                return Self.response(request, body: Self.fileMetadata(path: "/Backups/final.cpenc", size: 9))
            case "/2/files/download":
                return Self.response(
                    request,
                    body: Data("ciphertext".utf8),
                    headers: ["Dropbox-API-Result": Self.fileMetadata(path: "/Backups/final.cpenc", size: 10)]
                )
            default:
                return Self.response(request, status: 404, body: "unexpected")
            }
        }
        let transport = makeTransport(provider)

        let sessionID = try await transport.startUploadSession(data: Data("one".utf8))
        try await transport.appendUploadSession(id: sessionID, offset: 3, data: Data("two".utf8))
        let finished = try await transport.finishUploadSession(
            id: sessionID, offset: 6, data: Data("end".utf8), path: "/Backups/final.cpenc"
        )
        let (downloadedMetadata, downloaded) = try await transport.download(path: finished.path)

        XCTAssertEqual(downloaded, Data("ciphertext".utf8))
        XCTAssertEqual(downloadedMetadata.size, 10)
        let requests = recorder.requests()
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer current" })
        XCTAssertEqual(recorder.bodies(), [Data("one".utf8), Data("two".utf8), Data("end".utf8), nil])
        let append = try XCTUnwrap(requests[1].value(forHTTPHeaderField: "Dropbox-API-Arg"))
        XCTAssertTrue(append.contains(#""offset":3"#))
        let finish = try XCTUnwrap(requests[2].value(forHTTPHeaderField: "Dropbox-API-Arg"))
        XCTAssertTrue(finish.contains(#""strict_conflict":true"#))
        let downloadArgument = try XCTUnwrap(requests[3].value(forHTTPHeaderField: "Dropbox-API-Arg")?.data(using: .utf8))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: downloadArgument) as? [String: String],
            ["path": "/Backups/final.cpenc"]
        )
    }

    func testFolderMoveAndDeleteUseNoOverwriteRPCContracts() async throws {
        let provider = RotatingDropboxTokenProvider(initial: "current", replacement: "unused")
        let recorder = RequestRecorder()
        DropboxMockURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path.hasSuffix("/files/create_folder_v2") == true,
               recorder.requests().count == 2 {
                return Self.response(request, status: 409, body: #"{"error_summary":"path/conflict/folder/"}"#)
            }
            return Self.response(request, body: "{}")
        }
        let transport = makeTransport(provider)

        try await transport.createFolder(path: "/Backups")
        try await transport.createFolder(path: "/Backups")
        try await transport.move(from: "/Backups/.upload-one", to: "/Backups/One.clearpocketbackup")
        try await transport.delete(path: "/Backups/Old.clearpocketbackup")

        let requests = recorder.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/2/files/create_folder_v2", "/2/files/create_folder_v2", "/2/files/move_v2", "/2/files/delete_v2"
        ])
        let moveBody = try XCTUnwrap(recorder.bodies()[2])
        let move = try XCTUnwrap(JSONSerialization.jsonObject(with: moveBody) as? [String: Any])
        XCTAssertEqual(move["autorename"] as? Bool, false)
        XCTAssertEqual(move["to_path"] as? String, "/Backups/One.clearpocketbackup")
    }

    private func makeTransport(_ provider: RotatingDropboxTokenProvider) -> DropboxHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DropboxMockURLProtocol.self]
        return DropboxHTTPTransport(tokenProvider: provider, session: URLSession(configuration: configuration))
    }

    private static func fileMetadata(path: String, size: Int) -> String {
        "{\".tag\":\"file\",\"name\":\"\((path as NSString).lastPathComponent)\",\"path_display\":\"\(path)\",\"size\":\(size),\"content_hash\":\"\(String(repeating: "a", count: 64))\"}"
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        response(request, status: status, body: Data(body.utf8), headers: headers)
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: Data,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, body)
    }
}

private actor RotatingDropboxTokenProvider: DropboxAccessTokenProviding {
    private var token: String
    private let replacement: String
    private var rejected: [String] = []

    init(initial: String, replacement: String) { token = initial; self.replacement = replacement }
    func validAccessToken() -> String { token }
    func rejectAccessToken(_ value: String) {
        rejected.append(value)
        if token == value { token = replacement }
    }
    func rejectedTokens() -> [String] { rejected }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var bodyValues: [Data?] = []
    func append(_ request: URLRequest) {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        lock.withLock { values.append(request); bodyValues.append(body) }
    }
    func requests() -> [URLRequest] { lock.withLock { values } }
    func bodies() -> [Data?] { lock.withLock { bodyValues } }
    func authorizationHeaders() -> [String] { requests().compactMap { $0.value(forHTTPHeaderField: "Authorization") } }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class DropboxMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler?(request) ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
