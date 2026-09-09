import Foundation
import BudgetAPI

enum AppDataSourceMode: String, CaseIterable, Identifiable {
    case deterministic
    case liveServer
    var id: String { rawValue }
    var title: String { self == .deterministic ? "Deterministic Demo" : "Live Budget Server" }
}

enum AppComposition: Equatable { case deterministic, liveServer }

enum WorkspaceRouteContext: Equatable {
    case deterministic
    case live(budget: APIBudget, serverURL: URL, token: String)
    var identity: String {
        switch self { case .deterministic: "deterministic-workspace"; case let .live(budget, _, _): budget.id }
    }
}

enum ApplicationRoute: Equatable {
    case serverSetup
    case connecting
    case serverBootstrap
    case authentication
    case budgetSelection
    case workspace(WorkspaceRouteContext)
}

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
    static let production = AppSession()

    @Published private(set) var sourceMode: AppDataSourceMode
    @Published private(set) var connectionStatus: ServerConnectionStatus
    @Published private(set) var serverURL: URL?
    @Published private(set) var token: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var profile: APIProfile?
    @Published var budgets: [APIBudget] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published private(set) var activeBudgetID: String?

    var composition: AppComposition { sourceMode == .deterministic ? .deterministic : .liveServer }
    private let defaults: UserDefaults
    private let keychain: TokenStoring
    private let clientFactory: (URL) throws -> APIClient
    private let serverKey = "budget.serverURL"
    private let sourceModeKey = "budget.dataSourceMode"
    private let tokenAccount = "access-token"
    private let refreshTokenAccount = "refresh-token"
    private let activeBudgetKey = "budget.activeBudgetID"
    // Single-flight refresh: at most one `/auth/refresh` request is in flight per session; concurrent
    // callers await this shared task rather than each submitting the (now-rotated) refresh token.
    private var refreshTask: Task<APIAuthTokens, Error>?
    private var refreshOperationID: UUID?
    // Monotonic credential generation. A refresh result — success or failure — may only be applied
    // while the generation it started under is still current, so a stale attempt can never overwrite
    // or clear credentials installed by a newer refresh, sign-in, or sign-out.
    private var credentialGeneration = 0
    // Authoritative terminal latch. Once a current-generation refresh is rejected (401) — or the
    // session is otherwise torn down — the session is invalidated and NO further refresh may begin
    // until a successful login/bootstrap/invitation establishes a new refreshable generation. This
    // gates refresh eligibility so a caller arriving after the failed refresh (even one that already
    // passed earlier guards) cannot start a fresh refresh for an already-invalidated session.
    private var authInvalidated = false
    // Coalesces concurrent startup validations (RootView's `.task` and its `scenePhase == .active`
    // handler) so discovery and the authenticated load run once per activation, not once per entry.
    private var validateTask: Task<Void, Never>?
    private var activationValidated = false
    private let instanceID = String(UUID().uuidString.prefix(8))
    private let suppressLifecycleValidationForUITest: Bool

    init(defaults: UserDefaults = .standard,
         keychain: TokenStoring = KeychainStore(),
         clientFactory: @escaping (URL) throws -> APIClient = { try APIClient(baseURL: $0) },
         initialMode: AppDataSourceMode? = nil) {
        self.defaults = defaults; self.keychain = keychain; self.clientFactory = clientFactory
        #if DEBUG
        suppressLifecycleValidationForUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-authentication")
        #else
        suppressLifecycleValidationForUITest = false
        #endif
        serverURL = defaults.string(forKey: serverKey).flatMap(URL.init(string:))
        token = keychain.read(account: tokenAccount); refreshToken = keychain.read(account: refreshTokenAccount)
        activeBudgetID = defaults.string(forKey: activeBudgetKey)
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
        #if DEBUG
        if suppressLifecycleValidationForUITest {
            sourceMode = .liveServer
            serverURL = URL(string: "http://127.0.0.1:8000")
            token = nil; refreshToken = nil
            connectionStatus = .authenticationRequired
        }
        #endif
        debugLog("AUTH_DIAGNOSTICS build=\(Self.buildMarker) session=\(instanceID)")
        authLog("init", caller: "AppSession.init")
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
            } else if token == nil {
                connectionStatus = .authenticationRequired
            } else {
                // Stay `.connecting` until loadBudgets resolves. Publishing `.connected` here — before
                // the authenticated load has succeeded — renders the Budgets UI (and spawns its own
                // loader) during the not-yet-loaded window, which both showed stale content and let an
                // invalid session issue extra refreshes. loadBudgets sets `.connected` on success or
                // `.authenticationRequired` if the refresh token is invalid.
                await loadBudgets(caller: "configureServer")
            }
        } catch {
            let message = connectionMessage(error)
            connectionStatus = isConfigurationError(error) ? .invalidConfiguration(message) : .unreachable(message)
            debugLog("live connection failed: \(failureCategory(error))")
        }
    }

    func validateSelectedSource(caller: String = "unspecified") async {
        authLog("validate requested", caller: caller)
        // Single-flight: the `.task` modifier and the `scenePhase == .active` handler both call this at
        // launch. Coalescing them avoids duplicate discovery and duplicate authenticated loads.
        if let validateTask {
            authLog("validate joined", caller: caller)
            await validateTask.value
            return
        }
        let task = Task { await self.performValidateSelectedSource(caller: caller) }
        validateTask = task
        defer { validateTask = nil }
        await task.value
    }

    private func performValidateSelectedSource(caller: String) async {
        authLog("validate started", caller: caller)
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

    func loadBudgets(caller: String = "unspecified") async {
        guard sourceMode == .liveServer else { return }
        authLog("loadBudgets started", caller: caller)
        let startingGeneration = credentialGeneration
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await refreshIfNeeded(caller: "loadBudgets:\(caller)")
            guard let serverURL, let token else { connectionStatus = .authenticationRequired; return }
            let generation = credentialGeneration
            let client = try clientFactory(serverURL)
            async let loadedProfile = client.profile(token: token)
            async let loadedBudgets = client.budgets(token: token)
            let loaded = try await (loadedProfile, loadedBudgets)
            guard generation == credentialGeneration, !authInvalidated, self.token != nil else {
                authLog("discarded stale loadBudgets completion", caller: caller)
                return
            }
            (profile, budgets) = loaded
            reconcileActiveBudget()
            connectionStatus = .connected
        } catch {
            // A request started by an older authenticated generation is obsolete. In particular it
            // must not put an alert over Sign In after a different caller invalidated the session.
            guard startingGeneration == credentialGeneration, !authInvalidated else {
                authLog("discarded stale loadBudgets error", caller: caller)
                return
            }
            errorMessage = error.localizedDescription
            debugLog("API request failed: \(failureCategory(error))")
        }
    }

    func createBudget(name: String, currencyCode: String, householdID: String) async {
        guard sourceMode == .liveServer, let serverURL, let token else { return }
        await perform {
            let client = try self.clientFactory(serverURL)
            let created = try await client.createBudget(APIBudgetCreate(householdID: householdID, name: name, currencyCode: currencyCode), token: token)
            self.budgets = try await client.budgets(token: token)
            self.selectBudget(created.id)
        }
    }

    var activeBudget: APIBudget? { budgets.first { $0.id == activeBudgetID } }

    var route: ApplicationRoute {
        if composition == .deterministic { return .workspace(.deterministic) }
        guard serverURL != nil else { return .serverSetup }
        switch connectionStatus {
        case .unreachable, .invalidConfiguration: return .serverSetup
        case .connecting: return .connecting
        case .setupRequired: return .serverBootstrap
        case .authenticationRequired: return .authentication
        default: break
        }
        guard token != nil else { return .authentication }
        if let activeBudget, let serverURL, let token { return .workspace(.live(budget: activeBudget, serverURL: serverURL, token: token)) }
        return .budgetSelection
    }

    func activate(caller: String = "unspecified") async {
        guard !suppressLifecycleValidationForUITest else { return }
        guard !activationValidated else { authLog("activation ignored", caller: caller); return }
        activationValidated = true
        await validateSelectedSource(caller: caller)
    }

    func deactivate() { activationValidated = false }

    func selectBudget(_ id: String) {
        guard budgets.contains(where: { $0.id == id }) else { return }
        activeBudgetID = id
        defaults.set(id, forKey: activeBudgetKey)
    }

    private func reconcileActiveBudget() {
        if let activeBudgetID, budgets.contains(where: { $0.id == activeBudgetID }) { return }
        if budgets.count == 1 { selectBudget(budgets[0].id) }
        else { activeBudgetID = nil; defaults.removeObject(forKey: activeBudgetKey) }
    }

    func signOut() { clearCredentials(logoutFrom: serverURL) }
    func changeServer() {
        clearCredentials(logoutFrom: serverURL); defaults.removeObject(forKey: serverKey); serverURL = nil
        connectionStatus = .invalidConfiguration("Enter the address of your Budget Server.")
    }

    private func authenticate(_ operation: (APIClient) async throws -> APIAuthTokens) async {
        guard sourceMode == .liveServer, let serverURL else { return }
        let failureRoute = connectionStatus
        isWorking = true
        errorMessage = nil
        // Authentication is not complete when tokens arrive. Keep the application in a non-
        // authenticated route until the authoritative profile and budget collection have loaded and
        // the active-budget resolver has run. Publishing a token while still
        // `.authenticationRequired` used to expose BudgetSelectionView with an empty budget array.
        connectionStatus = .connecting
        defer { isWorking = false }
        do {
            let tokens = try await operation(self.clientFactory(serverURL)); try self.save(tokens)
            self.refreshTask = nil  // a brand-new session must not join a prior session's refresh task
            self.refreshOperationID = nil
            let client = try self.clientFactory(serverURL)
            async let profile = client.profile(token: tokens.accessToken); async let budgets = client.budgets(token: tokens.accessToken)
            (self.profile, self.budgets) = try await (profile, budgets)
            self.reconcileActiveBudget()
            self.connectionStatus = .connected
        } catch {
            // A failed post-token hydration must not expose a partially authenticated shell. Keep the
            // saved credentials for a retry, but return to the authentication/setup presentation and
            // surface the actual error.
            connectionStatus = failureRoute
            errorMessage = error.localizedDescription
            debugLog("API request failed: \(failureCategory(error))")
        }
    }

    func refreshIfNeeded(force: Bool = false, caller: String = "unspecified") async throws {
        authLog("refresh requested", caller: caller)
        // Eligibility is authoritative: a Live session with credentials that has NOT been invalidated.
        // `authInvalidated` makes a post-401 session terminal, so a caller arriving after the failed
        // refresh cannot start a new refresh cycle for the dead credential generation.
        guard sourceMode == .liveServer, !authInvalidated, token != nil, refreshToken != nil, let serverURL else { return }
        if !force, let token, Self.secondsUntilExpiration(token) > 90 { return }
        do {
            _ = try await sharedRefresh(serverURL: serverURL)
        } catch {
            if Self.isUnauthorized(error) {
                // A genuine invalid/expired refresh token already cleared the session to Sign In inside
                // sharedRefresh (generation-guarded). A refresh 401 is an authentication-state
                // transition, not an ordinary error: consume it here so no generic alert is shown over
                // the now-unauthenticated state. Other (network/server) errors still propagate.
                return
            }
            throw error
        }
    }

    // Concurrent callers converge on one network refresh. The first caller installs the shared task;
    // everyone arriving while it is in flight awaits the same task and receives the same rotated
    // tokens — no second caller ever submits the old refresh token. Because the check-and-set runs
    // synchronously on the main actor (no `await` between them), the single-flight guarantee holds.
    @discardableResult
    private func sharedRefresh(serverURL: URL) async throws -> APIAuthTokens {
        if let refreshTask {
            authLog("refresh joined", caller: "sharedRefresh")
            return try await refreshTask.value
        }
        guard let currentRefresh = refreshToken else {
            throw APIClientError.server(status: 401, message: "No refresh token available")
        }
        let generation = credentialGeneration
        let makeClient = clientFactory
        let operationID = UUID()
        let task = Task<APIAuthTokens, Error> { @MainActor in
            do {
                let rotated = try await makeClient(serverURL).refresh(currentRefresh)
                // The shared operation includes the state transition. Joiners cannot resume with
                // the old access token after the server has already rotated the refresh token.
                if generation == self.credentialGeneration { try self.save(rotated) }
                self.authLog("refresh completed", caller: "sharedRefresh")
                return rotated
            } catch where Self.isUnauthorized(error) {
                if generation == self.credentialGeneration { self.invalidateSessionToSignIn() }
                self.authLog("refresh failed unauthorized", caller: "sharedRefresh")
                throw error
            }
        }
        refreshTask = task
        refreshOperationID = operationID
        authLog("refresh created", caller: "sharedRefresh")
        defer {
            // A stale operation must not clear a newer refresh installed after re-authentication.
            if refreshOperationID == operationID {
                refreshTask = nil
                refreshOperationID = nil
            }
        }
        return try await task.value
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case APIClientError.server(401, _) = error { return true }
        return false
    }

    // Atomic logical replacement of the access + refresh token pair, advancing the credential
    // generation so any in-flight or stale refresh cannot apply over it.
    private func save(_ tokens: APIAuthTokens) throws {
        try keychain.save(tokens.accessToken, account: tokenAccount)
        do { try keychain.save(tokens.refreshToken, account: refreshTokenAccount) }
        catch { keychain.delete(account: tokenAccount); throw error }
        token = tokens.accessToken; refreshToken = tokens.refreshToken
        credentialGeneration += 1
        authInvalidated = false  // a successful sign-in/refresh re-establishes a refreshable session
    }

    // Clean transition to Sign In when the refresh token is genuinely invalid. Preserves the Live
    // Budget Server selection and configuration; never falls back to the deterministic demo. No
    // network logout is attempted because the token is already rejected. Clears the stale
    // authenticated content so RootView routes to Sign In rather than presenting old Budgets, and
    // latches the session invalid so no further refresh may begin until re-authentication.
    private func invalidateSessionToSignIn() {
        keychain.delete(account: tokenAccount); keychain.delete(account: refreshTokenAccount)
        token = nil; refreshToken = nil; budgets = []; profile = nil
        credentialGeneration += 1
        authInvalidated = true
        refreshTask = nil
        refreshOperationID = nil
        if sourceMode == .liveServer { connectionStatus = .authenticationRequired }
        debugLog("refresh token rejected; session cleared to sign in")
        authLog("session invalidated", caller: "invalidateSessionToSignIn")
    }

    private func clearCredentials(logoutFrom url: URL?) {
        if let url, let refreshToken { Task { try? await clientFactory(url).logout(refreshToken) } }
        keychain.delete(account: tokenAccount); keychain.delete(account: refreshTokenAccount)
        token = nil; refreshToken = nil; budgets = []; profile = nil
        credentialGeneration += 1
        authInvalidated = true
        refreshTask = nil
        refreshOperationID = nil
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

    private static var buildMarker: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "\(version)(\(build))"
    }

    private func authLog(_ event: String, caller: String) {
        debugLog("AUTH session=\(instanceID) caller=\(caller) event=\(event) status=\(connectionStatus.title) auth=\(token == nil ? "none" : "present") invalidated=\(authInvalidated) generation=\(credentialGeneration)")
    }
}

private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[BudgetApp] \(message())")
    #endif
}
