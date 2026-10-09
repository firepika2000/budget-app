import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BudgetStorage

final class DropboxOAuthTests: XCTestCase {
    override func tearDown() {
        DropboxOAuthMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testAuthorizationUsesRFC7636S256OfflineAccessAndLeastPrivilegeFileScopes() throws {
        let configuration = try DropboxOAuthConfiguration(appKey: "public-app-key", redirectURI: "clearpocket://dropbox-oauth")
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let authorization = try DropboxOAuthCredential.authorization(
            configuration: configuration, verifier: verifier, state: "unpredictable-state"
        )
        let values = Dictionary(uniqueKeysWithValues: URLComponents(
            url: authorization.authorizationURL, resolvingAgainstBaseURL: false
        )!.queryItems!.map { ($0.name, $0.value!) })

        XCTAssertEqual(values["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["token_access_type"], "offline")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["client_id"], "public-app-key")
        XCTAssertEqual(values["redirect_uri"], "clearpocket://dropbox-oauth")
        XCTAssertEqual(Set(values["scope"]!.split(separator: " ").map(String.init)), Set(configuration.scopes))
    }

    func testCallbackRequiresExactRedirectAndState() throws {
        XCTAssertEqual(
            try DropboxOAuthCredential.authorizationCode(
                from: URL(string: "clearpocket://dropbox-oauth?code=code-1&state=state-1")!,
                expectedRedirectURI: "clearpocket://dropbox-oauth", expectedState: "state-1"
            ),
            "code-1"
        )
        XCTAssertThrowsError(try DropboxOAuthCredential.authorizationCode(
            from: URL(string: "clearpocket://dropbox-oauth?code=code-1&state=wrong")!,
            expectedRedirectURI: "clearpocket://dropbox-oauth", expectedState: "state-1"
        )) { XCTAssertEqual($0 as? DropboxOAuthError, .stateMismatch) }
        XCTAssertThrowsError(try DropboxOAuthCredential.authorizationCode(
            from: URL(string: "other://dropbox-oauth?code=code-1&state=state-1")!,
            expectedRedirectURI: "clearpocket://dropbox-oauth", expectedState: "state-1"
        )) { XCTAssertEqual($0 as? DropboxOAuthError, .invalidCallback) }
    }

    func testAuthorizationCodeStoresRefreshTokenAndNeverPersistsAccessToken() async throws {
        let store = MemoryDropboxRefreshStore()
        let recorder = OAuthRequestRecorder()
        DropboxOAuthMockURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(request, body:
                #"{"access_token":"access-A","expires_in":14400,"refresh_token":"refresh-A"}"#)
        }
        let credential = try makeCredential(store: store)

        let installed = try await credential.installAuthorizationCode("authorization-code", verifier: String(repeating: "v", count: 43))
        let current = try await credential.validAccessToken()

        XCTAssertEqual(installed, "access-A")
        XCTAssertEqual(current, "access-A")
        XCTAssertEqual(store.value(), "refresh-A")
        XCTAssertEqual(recorder.count(), 1)
        let form = try formValues(recorder.bodies()[0])
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code_verifier"], String(repeating: "v", count: 43))
        XCTAssertFalse(recorder.bodies()[0].contains(Data("access-A".utf8)))
    }

    func testRelaunchAndConcurrentCallersShareOneRefreshAndPersistRotation() async throws {
        let store = MemoryDropboxRefreshStore("refresh-old")
        let recorder = OAuthRequestRecorder()
        DropboxOAuthMockURLProtocol.handler = { request in
            recorder.append(request)
            Thread.sleep(forTimeInterval: 0.03)
            return Self.response(request, body:
                #"{"access_token":"access-new","expires_in":14400,"refresh_token":"refresh-new"}"#)
        }
        let credential = try makeCredential(store: store)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await credential.validAccessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(tokens), ["access-new"])
        XCTAssertEqual(recorder.count(), 1)
        XCTAssertEqual(store.value(), "refresh-new")
        let form = try formValues(recorder.bodies()[0])
        XCTAssertEqual(form["refresh_token"], "refresh-old")
        XCTAssertEqual(form["grant_type"], "refresh_token")
    }

    func testRejectedAccessTokenRefreshesAndDisconnectRemovesOnlyDropboxCredential() async throws {
        let store = MemoryDropboxRefreshStore("refresh-A")
        let recorder = OAuthRequestRecorder()
        DropboxOAuthMockURLProtocol.handler = { request in
            recorder.append(request)
            let suffix = recorder.count()
            return Self.response(request, body: "{\"access_token\":\"access-\(suffix)\",\"expires_in\":14400}")
        }
        let credential = try makeCredential(store: store)

        let first = try await credential.validAccessToken()
        await credential.rejectAccessToken(first)
        let second = try await credential.validAccessToken()
        await credential.disconnect()

        XCTAssertEqual(first, "access-1")
        XCTAssertEqual(second, "access-2")
        XCTAssertNil(store.value())
        let connected = await credential.isConnected()
        XCTAssertFalse(connected)
    }

    func testRevokeConfirmsRemoteGrantRemovalBeforeDeletingKeychainRefreshToken() async throws {
        let store = MemoryDropboxRefreshStore("refresh-A")
        let recorder = OAuthRequestRecorder()
        DropboxOAuthMockURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/2/auth/token/revoke" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-A")
                return Self.response(request, body: "")
            }
            return Self.response(request, body: #"{"access_token":"access-A","expires_in":14400}"#)
        }
        let credential = try makeCredential(store: store)

        try await credential.revoke()

        XCTAssertNil(store.value())
        XCTAssertEqual(recorder.count(), 2)
    }

    func testLateAuthorizationCannotReconnectAfterDisconnect() async throws {
        let store = MemoryDropboxRefreshStore("prior-account-refresh")
        let started = expectation(description: "Authorization exchange started")
        let release = DispatchSemaphore(value: 0)
        DropboxOAuthMockURLProtocol.handler = { request in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return Self.response(request, body:
                #"{"access_token":"late-access","expires_in":14400,"refresh_token":"late-refresh"}"#)
        }
        let credential = try makeCredential(store: store)
        let pending = Task { try await credential.installAuthorizationCode("old-code", verifier: String(repeating: "v", count: 43)) }
        await fulfillment(of: [started], timeout: 3)
        do { _ = try await credential.validAccessToken(); XCTFail("Pending sign-in must not refresh the prior account") }
        catch { XCTAssertEqual(error as? DropboxOAuthError, .authorizationInProgress) }
        await credential.disconnect()
        release.signal()
        do { _ = try await pending.value; XCTFail("A disconnected authorization must not publish credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.value())
        let connected = await credential.isConnected()
        XCTAssertFalse(connected)
        do { _ = try await credential.validAccessToken(); XCTFail("Disconnected credential must remain unavailable") }
        catch { XCTAssertEqual(error as? DropboxOAuthError, .missingRefreshToken) }
    }

    func testLateRefreshCannotRestoreCredentialAfterDisconnect() async throws {
        let store = MemoryDropboxRefreshStore("existing-refresh")
        let started = expectation(description: "Refresh exchange started")
        let release = DispatchSemaphore(value: 0)
        DropboxOAuthMockURLProtocol.handler = { request in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return Self.response(request, body:
                #"{"access_token":"late-access","expires_in":14400,"refresh_token":"late-refresh"}"#)
        }
        let credential = try makeCredential(store: store)
        let pending = Task { try await credential.validAccessToken() }
        await fulfillment(of: [started], timeout: 3)
        await credential.disconnect()
        release.signal()
        do { _ = try await pending.value; XCTFail("A disconnected refresh must not return credentials") }
        catch { /* Cancellation may be delivered by URLSession or by the revision guard. */ }
        XCTAssertNil(store.value())
        let connected = await credential.isConnected()
        XCTAssertFalse(connected)
    }

    private func makeCredential(store: MemoryDropboxRefreshStore) throws -> DropboxOAuthCredential {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DropboxOAuthMockURLProtocol.self]
        return DropboxOAuthCredential(
            configuration: try .init(appKey: "public-app-key", redirectURI: "clearpocket://dropbox-oauth"),
            store: store,
            session: URLSession(configuration: configuration),
            tokenURL: URL(string: "https://api.dropbox.test/oauth2/token")!,
            revokeURL: URL(string: "https://api.dropbox.test/2/auth/token/revoke")!,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func formValues(_ data: Data) throws -> [String: String] {
        var components = URLComponents(); components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func response(_ request: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private final class MemoryDropboxRefreshStore: DropboxRefreshTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String? = nil) { self.token = token }
    func loadRefreshToken() -> String? { lock.withLock { token } }
    func saveRefreshToken(_ value: String) { lock.withLock { token = value } }
    func deleteRefreshToken() { lock.withLock { token = nil } }
    func value() -> String? { loadRefreshToken() }
}

private final class OAuthRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodyValues: [Data] = []
    func append(_ request: URLRequest) {
        let body = request.httpBody ?? Self.read(request.httpBodyStream) ?? Data()
        lock.withLock { bodyValues.append(body) }
    }
    func count() -> Int { lock.withLock { bodyValues.count } }
    func bodies() -> [Data] { lock.withLock { bodyValues } }
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

private final class DropboxOAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
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
