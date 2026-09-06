import Foundation
import BudgetAPI

enum AppDataSourceMode: String, CaseIterable, Identifiable {
    case deterministic
    case liveServer
    var id: String { rawValue }
    var title: String { self == .deterministic ? "Deterministic Demo" : "Live Budget Server" }
}

enum AppComposition: Equatable { case deterministic, liveServer }

enum ServerConnectionStatus: Equatable {
    case deterministic, connecting, connected, authenticationRequired, setupRequired
    case unreachable(String), invalidConfiguration(String)

    var title: String {
        switch self {
        case .deterministic: "Demo data — not authoritative"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .authenticationRequired: "Authentication required"
        case .setupRequired: "First-time setup required"
        case .unreachable: "Unreachable"
        case .invalidConfiguration: "Invalid configuration"
        }
    }
    var detail: String? {
        switch self {
        case let .unreachable(message), let .invalidConfiguration(message): message
        default: nil
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var sourceMode: AppDataSourceMode
    @Published private(set) var connectionStatus: ServerConnectionStatus
    @Published private(set) var serverURL: URL?
    @Published private(set) var token: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var profile: APIProfile?
    @Published var budgets: [APIBudget] = []
    @Published var isWorking = false
    @Published var errorMessage: String?

    var composition: AppComposition { sourceMode == .deterministic ? .deterministic : .liveServer }
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let clientFactory: (URL) throws -> APIClient
    private let serverKey = "budget.serverURL"
    private let sourceModeKey = "budget.dataSourceMode"
    private let tokenAccount = "access-token"
    private let refreshTokenAccount = "refresh-token"

    init(defaults: UserDefaults = .standard,
         keychain: KeychainStore = KeychainStore(),
         clientFactory: @escaping (URL) throws -> APIClient = { try APIClient(baseURL: $0) },
         initialMode: AppDataSourceMode? = nil) {
        self.defaults = defaults; self.keychain = keychain; self.clientFactory = clientFactory
        serverURL = defaults.string(forKey: serverKey).flatMap(URL.init(string:))
        token = keychain.read(account: tokenAccount); refreshToken = keychain.read(account: refreshTokenAccount)
        let stored = defaults.string(forKey: sourceModeKey).flatMap(AppDataSourceMode.init(rawValue:))
        #if DEBUG
        let argumentMode: AppDataSourceMode? = ProcessInfo.processInfo.arguments.contains("--live") ? .liveServer : (ProcessInfo.processInfo.arguments.contains("--demo") ? .deterministic : nil)
        let fallback: AppDataSourceMode = .deterministic
        #else
        let argumentMode: AppDataSourceMode? = nil
        let fallback: AppDataSourceMode = .liveServer
        #endif
        let resolvedMode = initialMode ?? argumentMode ?? stored ?? fallback
        sourceMode = resolvedMode
        connectionStatus = resolvedMode == .deterministic ? .deterministic : .connecting
        debugLog("selected data source: \(resolvedMode.rawValue)")
        if let serverURL { debugLog("configured server: \(serverURL.absoluteString)") }
    }

    func selectDeterministic() {
        defaults.set(AppDataSourceMode.deterministic.rawValue, forKey: sourceModeKey)
        sourceMode = .deterministic; connectionStatus = .deterministic; errorMessage = nil
        debugLog("selected data source: deterministic")
    }

    func configureServer(_ rawValue: String) async {
        isWorking = true; errorMessage = nil; defer { isWorking = false }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { selectLiveWithInvalidConfiguration("Enter a valid server address."); return }
        let client: APIClient
        do { client = try clientFactory(url) }
        catch {
            selectLiveWithInvalidConfiguration(connectionMessage(error))
            return
        }
        if serverURL != nil && serverURL != url { clearCredentials(logoutFrom: serverURL) }
        serverURL = url; defaults.set(url.absoluteString, forKey: serverKey)
        defaults.set(AppDataSourceMode.liveServer.rawValue, forKey: sourceModeKey)
        sourceMode = .liveServer; connectionStatus = .connecting
        debugLog("selected data source: liveServer")
        debugLog("initializing live repository for: \(url.absoluteString)")
        do {
            try await client.health()
            debugLog("live server health check succeeded")
            // Discover whether the server still needs first-run setup, so a fresh install shows
            // First-Time Setup instead of a Sign In prompt the tester can't satisfy. A server that
            // predates this endpoint fails the call and falls back to the existing behavior.
            let status = try? await client.bootstrapStatus()
            if let status, !status.initialized {
                connectionStatus = .setupRequired
                debugLog("live server reports uninitialized: first-run setup required")
            } else {
                connectionStatus = token == nil ? .authenticationRequired : .connected
                if token != nil { await loadBudgets() }
            }
        } catch {
            let message = connectionMessage(error)
            connectionStatus = isConfigurationError(error) ? .invalidConfiguration(message) : .unreachable(message)
            debugLog("live connection failed: \(failureCategory(error))")
        }
    }

    func validateSelectedSource() async {
        guard sourceMode == .liveServer else { connectionStatus = .deterministic; return }
        guard let serverURL else { connectionStatus = .invalidConfiguration("Enter the address of your Budget Server."); return }
        await configureServer(serverURL.absoluteString)
    }

    func login(email: String, password: String) async { await authenticate { try await $0.login(email: email, password: password) } }
    func bootstrap(email: String, password: String, displayName: String, householdName: String) async {
        await authenticate { try await $0.bootstrap(BootstrapRequest(email: email, password: password, displayName: displayName, householdName: householdName)) }
    }
    func acceptInvitation(token invitationToken: String, password: String, displayName: String) async {
        await authenticate { try await $0.acceptInvitation(APIInvitationAccept(invitationToken: invitationToken, password: password, displayName: displayName)) }
    }

    func loadBudgets() async {
        guard sourceMode == .liveServer else { return }
        await perform {
            try await self.refreshIfNeeded()
            guard let serverURL = self.serverURL, let token = self.token else { self.connectionStatus = .authenticationRequired; return }
            let client = try self.clientFactory(serverURL)
            async let profile = client.profile(token: token); async let budgets = client.budgets(token: token)
            (self.profile, self.budgets) = try await (profile, budgets); self.connectionStatus = .connected
        }
    }

    func createBudget(name: String, currencyCode: String, householdID: String) async {
        guard sourceMode == .liveServer, let serverURL, let token else { return }
        await perform {
            let client = try self.clientFactory(serverURL)
            _ = try await client.createBudget(APIBudgetCreate(householdID: householdID, name: name, currencyCode: currencyCode), token: token)
            self.budgets = try await client.budgets(token: token)
        }
    }

    func signOut() { clearCredentials(logoutFrom: serverURL) }
    func changeServer() {
        clearCredentials(logoutFrom: serverURL); defaults.removeObject(forKey: serverKey); serverURL = nil
        connectionStatus = .invalidConfiguration("Enter the address of your Budget Server.")
    }

    private func authenticate(_ operation: (APIClient) async throws -> APIAuthTokens) async {
        guard sourceMode == .liveServer, let serverURL else { return }
        await perform {
            let tokens = try await operation(self.clientFactory(serverURL)); try self.save(tokens)
            let client = try self.clientFactory(serverURL)
            async let profile = client.profile(token: tokens.accessToken); async let budgets = client.budgets(token: tokens.accessToken)
            (self.profile, self.budgets) = try await (profile, budgets); self.connectionStatus = .connected
        }
    }

    func refreshIfNeeded(force: Bool = false) async throws {
        guard sourceMode == .liveServer, let serverURL, let refreshToken else { return }
        if !force, let token, Self.secondsUntilExpiration(token) > 90 { return }
        try save(try await clientFactory(serverURL).refresh(refreshToken))
    }

    private func save(_ tokens: APIAuthTokens) throws {
        try keychain.save(tokens.accessToken, account: tokenAccount)
        do { try keychain.save(tokens.refreshToken, account: refreshTokenAccount) }
        catch { keychain.delete(account: tokenAccount); throw error }
        token = tokens.accessToken; refreshToken = tokens.refreshToken
    }

    private func clearCredentials(logoutFrom url: URL?) {
        if let url, let refreshToken { Task { try? await clientFactory(url).logout(refreshToken) } }
        keychain.delete(account: tokenAccount); keychain.delete(account: refreshTokenAccount)
        token = nil; refreshToken = nil; budgets = []; profile = nil
        if sourceMode == .liveServer { connectionStatus = .authenticationRequired }
    }

    private func selectLiveWithInvalidConfiguration(_ message: String) {
        clearCredentials(logoutFrom: serverURL)
        defaults.set(AppDataSourceMode.liveServer.rawValue, forKey: sourceModeKey)
        defaults.removeObject(forKey: serverKey); sourceMode = .liveServer; serverURL = nil
        connectionStatus = .invalidConfiguration(message)
        debugLog("live connection failed: invalid configuration")
    }

    private static func secondsUntilExpiration(_ token: String) -> TimeInterval {
        let parts = token.split(separator: "."); guard parts.count == 3 else { return 0 }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let expiration = object["exp"] as? TimeInterval else { return 0 }
        return expiration - Date().timeIntervalSince1970
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true; errorMessage = nil; defer { isWorking = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription; debugLog("API request failed: \(failureCategory(error))") }
    }
    private func connectionMessage(_ error: Error) -> String {
        if isConfigurationError(error), let description = (error as? LocalizedError)?.errorDescription { return description }
        if error is URLError { return "Budget Server could not be reached. Check that it is running and the address is correct." }
        return "Budget Server could not be reached. Check the server and try again."
    }
    private func isConfigurationError(_ error: Error) -> Bool {
        guard let error = error as? APIClientError else { return false }
        return error == .invalidServerURL || error == .insecureRemoteServer
    }
    private func failureCategory(_ error: Error) -> String {
        if let error = error as? APIClientError {
            switch error {
            case .invalidServerURL, .insecureRemoteServer: return "configuration"
            case .invalidResponse: return "invalid-response"
            case let .server(status, _): return "http-\(status)"
            }
        }
        if let error = error as? URLError { return "network-\(error.code.rawValue)" }
        return String(describing: type(of: error))
    }
}

private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[BudgetApp] \(message())")
    #endif
}
