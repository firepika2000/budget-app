import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DropboxOAuthConfiguration: Equatable, Sendable {
    public let appKey: String
    public let redirectURI: String
    public let scopes: [String]

    public init(
        appKey: String,
        redirectURI: String,
        scopes: [String] = [
            "files.content.read", "files.content.write", "files.metadata.read", "files.metadata.write"
        ]
    ) throws {
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let redirect = URL(string: redirectURI), redirect.scheme != nil,
              !scopes.isEmpty, scopes.allSatisfy({ !$0.isEmpty }) else {
            throw DropboxOAuthError.invalidConfiguration
        }
        self.appKey = key
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

public struct DropboxPKCEAuthorization: Equatable, Sendable {
    public let authorizationURL: URL
    public let verifier: String
    public let state: String
}

public protocol DropboxRefreshTokenStoring: Sendable {
    func loadRefreshToken() throws -> String?
    func saveRefreshToken(_ value: String) throws
    func deleteRefreshToken()
}

public enum DropboxOAuthError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidCallback
    case stateMismatch
    case authorizationDenied(String)
    case missingAuthorizationCode
    case missingRefreshToken
    case invalidResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Dropbox is not configured for this build."
        case .invalidCallback: "Dropbox returned an invalid authorization callback."
        case .stateMismatch: "Dropbox authorization could not be verified. Please try again."
        case let .authorizationDenied(message): "Dropbox authorization was not completed: \(message)"
        case .missingAuthorizationCode: "Dropbox did not return an authorization code."
        case .missingRefreshToken: "Reconnect Dropbox to permit future encrypted backups."
        case .invalidResponse: "Dropbox returned an invalid OAuth response."
        case let .httpStatus(status, message): "Dropbox authorization failed (\(status)): \(message)"
        }
    }
}

public actor DropboxOAuthCredential: DropboxAccessTokenProviding {
    private struct AccessToken: Sendable {
        let value: String
        let expiresAt: Date
    }

    private let configuration: DropboxOAuthConfiguration
    private let store: DropboxRefreshTokenStoring
    private let session: URLSession
    private let tokenURL: URL
    private let now: @Sendable () -> Date
    private var accessToken: AccessToken?
    private var refreshTask: Task<TokenResponse, Error>?
    private var refreshID: UUID?

    public init(
        configuration: DropboxOAuthConfiguration,
        store: DropboxRefreshTokenStoring,
        session: URLSession = .shared,
        tokenURL: URL = URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store
        self.session = session
        self.tokenURL = tokenURL
        self.now = now
    }

    public nonisolated func beginAuthorization() throws -> DropboxPKCEAuthorization {
        try Self.authorization(configuration: configuration)
    }

    public nonisolated static func authorization(
        configuration: DropboxOAuthConfiguration,
        verifier: String? = nil,
        state: String? = nil
    ) throws -> DropboxPKCEAuthorization {
        let verifier = verifier ?? randomURLSafe(count: 32)
        let state = state ?? randomURLSafe(count: 32)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard (43...128).contains(verifier.count), !state.isEmpty,
              verifier.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DropboxOAuthError.invalidConfiguration
        }
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: configuration.appKey),
            .init(name: "redirect_uri", value: configuration.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "token_access_type", value: "offline"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
        ]
        guard let url = components.url else { throw DropboxOAuthError.invalidConfiguration }
        return .init(authorizationURL: url, verifier: verifier, state: state)
    }

    public nonisolated static func authorizationCode(
        from callback: URL,
        expectedRedirectURI: String,
        expectedState: String
    ) throws -> String {
        guard let expected = URLComponents(string: expectedRedirectURI),
              let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host,
              actual.path == expected.path else { throw DropboxOAuthError.invalidCallback }
        var items: [String: String] = [:]
        for item in actual.queryItems ?? [] {
            guard items[item.name] == nil else { throw DropboxOAuthError.invalidCallback }
            items[item.name] = item.value ?? ""
        }
        guard items["state"] == expectedState else { throw DropboxOAuthError.stateMismatch }
        if let error = items["error"] {
            throw DropboxOAuthError.authorizationDenied(items["error_description"] ?? error)
        }
        guard let code = items["code"], !code.isEmpty else { throw DropboxOAuthError.missingAuthorizationCode }
        return code
    }

    @discardableResult
    public func installAuthorizationCode(_ code: String, verifier: String) async throws -> String {
        let response = try await exchange([
            "code": code,
            "grant_type": "authorization_code",
            "client_id": configuration.appKey,
            "redirect_uri": configuration.redirectURI,
            "code_verifier": verifier,
        ])
        guard let refresh = response.refreshToken, !refresh.isEmpty else {
            throw DropboxOAuthError.missingRefreshToken
        }
        try store.saveRefreshToken(refresh)
        accessToken = token(response)
        return response.accessToken
    }

    public func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expiresAt.timeIntervalSince(now()) > 60 { return accessToken.value }
        if let refreshTask { return try await finish(refreshTask, id: refreshID).accessToken }
        guard let refresh = try store.loadRefreshToken(), !refresh.isEmpty else {
            throw DropboxOAuthError.missingRefreshToken
        }
        let id = UUID()
        let configuration = configuration, session = session, tokenURL = tokenURL
        let task = Task {
            try await Self.exchange(
                ["refresh_token": refresh, "grant_type": "refresh_token", "client_id": configuration.appKey],
                session: session,
                tokenURL: tokenURL
            )
        }
        refreshTask = task; refreshID = id
        return try await finish(task, id: id).accessToken
    }

    public func rejectAccessToken(_ token: String) {
        if accessToken?.value == token { accessToken = nil }
    }

    public func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil; refreshID = nil; accessToken = nil
        store.deleteRefreshToken()
    }

    public func isConnected() -> Bool { (try? store.loadRefreshToken())?.isEmpty == false }

    private func finish(_ task: Task<TokenResponse, Error>, id: UUID?) async throws -> TokenResponse {
        do {
            let response = try await task.value
            if refreshID == id {
                if let rotated = response.refreshToken, !rotated.isEmpty { try store.saveRefreshToken(rotated) }
                accessToken = token(response)
                refreshTask = nil; refreshID = nil
            }
            return response
        } catch {
            if refreshID == id { refreshTask = nil; refreshID = nil }
            throw error
        }
    }

    private func token(_ response: TokenResponse) -> AccessToken {
        .init(value: response.accessToken, expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)))
    }

    private func exchange(_ parameters: [String: String]) async throws -> TokenResponse {
        try await Self.exchange(parameters, session: session, tokenURL: tokenURL)
    }

    private nonisolated static func exchange(
        _ parameters: [String: String], session: URLSession, tokenURL: URL
    ) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw DropboxOAuthError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode(OAuthFailure.self, from: data).errorDescription)
                ?? String(data: data.prefix(2_048), encoding: .utf8) ?? "Unknown error"
            throw DropboxOAuthError.httpStatus(response.statusCode, detail)
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw DropboxOAuthError.invalidResponse }
    }

    private nonisolated static func randomURLSafe(count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token"
        }
    }

    private struct OAuthFailure: Decodable {
        let errorDescription: String
        enum CodingKeys: String, CodingKey { case errorDescription = "error_description" }
    }
}
