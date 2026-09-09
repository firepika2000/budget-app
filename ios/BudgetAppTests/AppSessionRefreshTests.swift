import XCTest
import BudgetAPI
import SwiftUI
import UIKit
@testable import Budget_App

/// Regression coverage for authentication-refresh single-flight and session recovery.
///
/// The live human-acceptance bug: on relaunch, several independent session-initialization paths
/// each read the same stored refresh token and issued their own `POST /auth/refresh`. With rotation,
/// the first rotated R1→R2 (200) and the losers submitted the now-stale R1 (401), surfacing a
/// user-visible "Invalid or expired refresh token" alert even though the winning refresh had already
/// recovered the session. These tests lock in the single-flight fix and the clean sign-in transition.
final class AppSessionRefreshTests: XCTestCase {
    override func tearDown() {
        RefreshMockURLProtocol.handler = nil
        super.tearDown()
    }

    // AppSession's private Keychain accounts; kept in sync intentionally so we can seed a session.
    private static let accessAccount = "access-token"
    private static let refreshAccount = "refresh-token"

    @MainActor
    private func makeSession(
        access: String,
        refresh: String,
        persistedActiveBudgetID: String? = nil,
        handler: @escaping (URLRequest) -> (Int, Data)
    ) -> AppSession {
        RefreshMockURLProtocol.handler = handler
        let suite = "AppSessionRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("https://budget.example.com", forKey: "budget.serverURL")
        defaults.set("liveServer", forKey: "budget.dataSourceMode")
        if let persistedActiveBudgetID { defaults.set(persistedActiveBudgetID, forKey: "budget.activeBudgetID") }

        let store = InMemoryTokenStore([
            Self.accessAccount: access,   // non-JWT string → treated as already expired (needs refresh)
            Self.refreshAccount: refresh,
        ])
        return AppSession(
            defaults: defaults,
            keychain: store,
            clientFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [RefreshMockURLProtocol.self]
                return try APIClient(baseURL: $0, session: URLSession(configuration: configuration))
            },
            initialMode: .liveServer
        )
    }

    private static func json(_ status: Int, _ body: String) -> (Int, Data) { (status, Data(body.utf8)) }
    private static let rotated = #"{"access_token":"A2","refresh_token":"R2","token_type":"bearer"}"#

    @MainActor
    func testDeterministicSourceUsesSharedWorkspaceRoute() {
        let session = AppSession(defaults: UserDefaults(suiteName: "DeterministicShell.\(UUID().uuidString)")!, keychain: InMemoryTokenStore([:]), initialMode: .deterministic)
        guard case let .workspace(context) = session.route else { return XCTFail("deterministic source must resolve the shared workspace route") }
        XCTAssertEqual(context, .deterministic)
    }

    // Concurrent refresh demand must collapse to exactly one network refresh, and the rotated
    // credentials (A2/R2) must be what remains — no losing caller re-submits the old token or clears
    // the newer credentials, and no user-facing error is produced.
    @MainActor
    func testConcurrentRefreshIsSingleFlightAndKeepsRotatedCredentials() async throws {
        let gate = Gate()
        let counter = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            guard request.url?.path == "/api/v1/auth/refresh" else { return Self.json(404, "{}") }
            let n = counter.increment()
            if n == 1 {
                gate.signalArrived()
                gate.waitForRelease()
                return Self.json(200, Self.rotated)
            }
            // A duplicate request would carry the now-rotated-away R1 → 401 (the original bug).
            return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
        }

        let callers = (0..<8).map { _ in Task { try? await session.refreshIfNeeded(force: true) } }
        await gate.awaitArrival()   // the single request is in flight; every other caller has joined it
        gate.releaseNow()
        for caller in callers { _ = await caller.value }

        XCTAssertEqual(counter.value, 1, "concurrent refresh demand must issue exactly one /auth/refresh")
        XCTAssertEqual(session.token, "A2")
        XCTAssertEqual(session.refreshToken, "R2")
        XCTAssertNil(session.errorMessage, "a recovered refresh must not surface a user-facing error")
    }

    // Concurrent loadBudgets() at startup (the real call graph) must also trigger only one refresh,
    // then hydrate /me and /budgets and land Connected.
    @MainActor
    func testConcurrentLoadBudgetsAtStartupIssuesOneRefresh() async throws {
        let gate = Gate()
        let counter = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                let n = counter.increment()
                if n == 1 { gate.signalArrived(); gate.waitForRelease(); return Self.json(200, Self.rotated) }
                return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
            case "/api/v1/me":
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                return Self.json(200, "[]")
            default:
                return Self.json(404, "{}")
            }
        }

        let loaders = (0..<5).map { _ in Task { await session.loadBudgets() } }
        await gate.awaitArrival()
        gate.releaseNow()
        for loader in loaders { _ = await loader.value }

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(session.token, "A2")
        XCTAssertEqual(session.connectionStatus, .connected)
        XCTAssertNil(session.errorMessage)
    }

    // A genuinely invalid/expired refresh token (no competing success) must clear credentials and
    // transition cleanly to Sign In, while preserving the Live Budget Server selection and never
    // falling back to the deterministic demo — and without a generic error alert.
    @MainActor
    func testGenuineInvalidRefreshTransitionsToSignInAndPreservesLiveServer() async throws {
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            guard request.url?.path == "/api/v1/auth/refresh" else { return Self.json(404, "{}") }
            return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
        }

        try await session.refreshIfNeeded(force: true)

        XCTAssertNil(session.token)
        XCTAssertNil(session.refreshToken)
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertEqual(session.route, .authentication)
        XCTAssertEqual(session.serverURL?.absoluteString, "https://budget.example.com")
        XCTAssertEqual(session.sourceMode, .liveServer, "must not downgrade to deterministic demo")
        XCTAssertNil(session.errorMessage, "clean sign-in transition, not a generic error alert")
    }

    // Generation safety: if the user signs out while a refresh is in flight, the later-arriving
    // success must NOT re-authenticate the session (a stale completion cannot install credentials
    // over a newer sign-out).
    @MainActor
    func testStaleRefreshSuccessAfterSignOutDoesNotReauthenticate() async throws {
        let gate = Gate()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                gate.signalArrived(); gate.waitForRelease(); return Self.json(200, Self.rotated)
            case "/api/v1/auth/logout":
                return Self.json(204, "")
            default:
                return Self.json(404, "{}")
            }
        }

        let refresh = Task { try? await session.refreshIfNeeded(force: true) }
        await gate.awaitArrival()   // refresh is in flight (blocked in transport)
        session.signOut()           // newer credential change: clears session, advances generation
        gate.releaseNow()           // the in-flight refresh now completes with 200 A2/R2 (stale)
        _ = await refresh.value

        XCTAssertNil(session.token, "a stale refresh success must not re-install credentials")
        XCTAssertNil(session.refreshToken)
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
    }

    // Terminal invalidation: after a genuine 401, independent production-style callers arriving LATER
    // (after the failed refresh Task has completed and cleared) must not start a new refresh. This is
    // the case the earlier single-flight test did not cover — it only collapsed simultaneous callers.
    @MainActor
    func testSequentialCallersAfterInvalidRefreshDoNotRetry() async throws {
        let refresh = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                _ = refresh.increment()
                return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
            case "/api/v1/me":
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                return Self.json(200, "[]")
            default:
                return Self.json(404, "{}")
            }
        }

        // First production-style load refreshes → 401 → session invalidated.
        await session.loadBudgets()
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertNil(session.token)

        // Two more independent loaders arrive after the failed refresh completed.
        await session.loadBudgets()
        await session.loadBudgets()

        XCTAssertEqual(refresh.value, 1, "an invalidated session must not start another refresh cycle")
        XCTAssertNil(session.token)
        XCTAssertNil(session.refreshToken)
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertTrue(session.budgets.isEmpty, "stale authenticated content must be cleared")
        XCTAssertNil(session.errorMessage, "a handled refresh 401 must not surface a generic error alert")
        XCTAssertEqual(session.serverURL?.absoluteString, "https://budget.example.com")
    }

    // Reproduces the real startup composition: two concurrent entry points (RootView.task +
    // scenePhase .active) both call validateSelectedSource, which runs discovery then the
    // authenticated load. Discovery and refresh must each happen once. This would fail on the prior
    // build, where validateSelectedSource was not coalesced (duplicate /health + /bootstrap/status).
    @MainActor
    func testConcurrentStartupValidationRunsDiscoveryAndRefreshOnce() async throws {
        let gate = Gate()
        let health = Counter(); let bootstrap = Counter(); let refresh = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/health":
                let n = health.increment()
                if n == 1 { gate.signalArrived(); gate.waitForRelease() }
                return Self.json(200, "{}")
            case "/api/v1/bootstrap/status":
                _ = bootstrap.increment()
                return Self.json(200, #"{"initialized":true,"authentication_required":true,"api_version":"0.4.0"}"#)
            case "/api/v1/auth/refresh":
                _ = refresh.increment()
                return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
            default:
                return Self.json(404, "{}")
            }
        }

        let first = Task { await session.validateSelectedSource() }
        let second = Task { await session.validateSelectedSource() }
        await gate.awaitArrival()   // the single coalesced discovery is in flight; the other entry joined
        gate.releaseNow()
        _ = await first.value; _ = await second.value

        XCTAssertEqual(health.value, 1, "startup discovery must run once, not once per entry point")
        XCTAssertEqual(bootstrap.value, 1)
        XCTAssertEqual(refresh.value, 1, "an invalid session must issue exactly one refresh at startup")
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertNil(session.token)
        XCTAssertTrue(session.budgets.isEmpty)
        XCTAssertNil(session.errorMessage)
    }

    // Hosts the actual RootView while startup discovery rejects the stored refresh token. This
    // catches presentation-owned loaders: the rendered production hierarchy must not issue another
    // refresh after AppSession transitions authoritatively to Sign In.
    @MainActor
    func testProductionRootInvalidRefreshClearsAuthenticatedShellWithOneRequest() async throws {
        let refresh = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/health": return Self.json(200, "{}")
            case "/api/v1/bootstrap/status": return Self.json(200, #"{"initialized":true,"authentication_required":true,"api_version":"0.4.0"}"#)
            case "/api/v1/auth/refresh": _ = refresh.increment(); return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
            default: return Self.json(404, "{}")
            }
        }
        let controller = UIHostingController(rootView: RootView().environmentObject(session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.loadViewIfNeeded(); controller.view.layoutIfNeeded()

        await session.validateSelectedSource(caller: "test.productionRoot")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(refresh.value, 1)
        XCTAssertNil(session.token)
        XCTAssertTrue(session.budgets.isEmpty)
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertNil(session.errorMessage)
        window.isHidden = true; window.rootViewController = nil
    }

    @MainActor
    func testAuthenticatedLoadResolvesAndSwitchesPersistentActiveBudget() async throws {
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh": return Self.json(200, Self.rotated)
            case "/api/v1/me": return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets": return Self.json(200, #"[{"id":"b1","household_id":"h1","name":"Home","currency_code":"USD","effective_permission":"owner","allocation_version":0},{"id":"b2","household_id":"h1","name":"Travel","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default: return Self.json(404, "{}")
            }
        }
        await session.loadBudgets(caller: "test.activeBudget")
        XCTAssertNil(session.activeBudget, "multiple budgets require an explicit first selection")
        XCTAssertEqual(session.route, .budgetSelection)
        session.selectBudget("b2")
        XCTAssertEqual(session.activeBudget?.name, "Travel")
        guard case .workspace = session.route else { return XCTFail("selected budget must enter the shared workspace route") }
        session.selectBudget("not-authorized")
        XCTAssertEqual(session.activeBudget?.id, "b2", "an unavailable budget cannot replace the active context")
    }

    @MainActor
    func testInvalidPersistedBudgetIsReplacedBySoleAccessibleBudget() async {
        let session = makeSession(access: "expired-access", refresh: "R1", persistedActiveBudgetID: "revoked-budget") { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh": return Self.json(200, Self.rotated)
            case "/api/v1/me": return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets": return Self.json(200, #"[{"id":"b1","household_id":"h1","name":"Test budget","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default: return Self.json(404, "{}")
            }
        }
        await session.loadBudgets(caller: "test.invalidPersistedSelection")
        XCTAssertEqual(session.activeBudgetID, "b1")
        guard case .workspace = session.route else { return XCTFail("sole accessible budget must enter the shared workspace route") }
    }

    @MainActor
    func testNewlyCreatedFirstBudgetImmediatelyBecomesWorkspaceContext() async {
        let created = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/auth/refresh"): return Self.json(200, Self.rotated)
            case ("GET", "/api/v1/me"): return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[{"id":"h1","name":"Home","role":"owner","is_active":true}]}"#)
            case ("POST", "/api/v1/budgets"):
                _ = created.increment()
                return Self.json(201, #"{"id":"b1","household_id":"h1","name":"First budget","currency_code":"USD","effective_permission":"owner","allocation_version":0}"#)
            case ("GET", "/api/v1/budgets"):
                return created.value == 0 ? Self.json(200, "[]") : Self.json(200, #"[{"id":"b1","household_id":"h1","name":"First budget","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default: return Self.json(404, "{}")
            }
        }
        await session.loadBudgets(caller: "test.firstBudget")
        XCTAssertEqual(session.route, .budgetSelection)
        await session.createBudget(name: "First budget", currencyCode: "USD", householdID: "h1")
        XCTAssertEqual(session.activeBudgetID, "b1")
        guard case .workspace = session.route else { return XCTFail("newly created first budget must immediately enter the shared shell") }
    }

    @MainActor
    func testActiveBudgetSelectionSurvivesSessionReconstruction() {
        let suite = "AppSessionActiveBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let budgets = [
            APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD"),
            APIBudget(id: "b2", householdID: "h1", name: "Travel", currencyCode: "USD")
        ]
        let first = AppSession(defaults: defaults, keychain: InMemoryTokenStore([:]), initialMode: .liveServer)
        first.budgets = budgets
        first.selectBudget("b2")

        let relaunched = AppSession(defaults: defaults, keychain: InMemoryTokenStore([:]), initialMode: .liveServer)
        relaunched.budgets = budgets
        XCTAssertEqual(relaunched.activeBudget?.id, "b2")
    }

    @MainActor
    func testProductionDemoToLiveAuthenticationFormRetainsContinuousInputAndFocus() async throws {
        let health = Counter()
        RefreshMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/health": _ = health.increment(); return Self.json(200, "{}")
            case "/api/v1/bootstrap/status": return Self.json(200, #"{"initialized":true,"authentication_required":true,"api_version":"0.4.0"}"#)
            default: return Self.json(404, "{}")
            }
        }
        let suite = "AuthFormProductionComposition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(
            defaults: defaults,
            keychain: InMemoryTokenStore([:]),
            clientFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [RefreshMockURLProtocol.self]
                return try APIClient(baseURL: $0, session: URLSession(configuration: configuration))
            },
            initialMode: .deterministic
        )
        let form = AuthenticationFormState()
        let controller = UIHostingController(rootView: RootView(authenticationForm: form).environmentObject(session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.loadViewIfNeeded(); controller.view.layoutIfNeeded()

        await session.configureServer("https://budget.example.com")
        try? await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)

        let formIdentity = ObjectIdentifier(form)
        for character in "owner@example.com" {
            form.email.append(character)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await Task.yield()
        }
        XCTAssertEqual(form.email, "owner@example.com")
        for character in "correct horse battery staple" {
            form.password.append(character)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await Task.yield()
        }
        XCTAssertEqual(form.password, "correct horse battery staple")
        XCTAssertEqual(ObjectIdentifier(form), formIdentity, "field edits must retain the root-owned form identity")
        XCTAssertEqual(session.connectionStatus, .authenticationRequired, "field edits must not replace the auth presentation")
        XCTAssertEqual(health.value, 1, "editing must not restart root source validation")
        window.isHidden = true; window.rootViewController = nil
    }

    // The terminal latch must not be permanent: a successful login re-establishes a refreshable
    // session, and a later legitimate refresh proceeds.
    @MainActor
    func testSuccessfulLoginAfterInvalidationRestoresRefreshableSession() async throws {
        let refresh = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                let n = refresh.increment()
                // First refresh (the invalid stored token) fails; a later refresh (post-login) rotates.
                return n == 1
                    ? Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
                    : Self.json(200, #"{"access_token":"A10","refresh_token":"R10","token_type":"bearer"}"#)
            case "/api/v1/auth/login":
                return Self.json(200, #"{"access_token":"A9","refresh_token":"R9","token_type":"bearer"}"#)
            case "/api/v1/me":
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                return Self.json(200, "[]")
            default:
                return Self.json(404, "{}")
            }
        }

        // Genuine 401 invalidates the session.
        try await session.refreshIfNeeded(force: true)
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertNil(session.token)

        // Re-authenticate — this must reset the invalidation latch.
        await session.login(email: "owner@example.com", password: "correct horse battery staple")
        XCTAssertEqual(session.token, "A9")
        XCTAssertEqual(session.refreshToken, "R9")
        XCTAssertEqual(session.connectionStatus, .connected)

        // A later legitimate refresh is eligible again and rotates successfully.
        try await session.refreshIfNeeded(force: true)
        XCTAssertEqual(refresh.value, 2, "the login path must reset the terminal latch so refresh works again")
        XCTAssertEqual(session.token, "A10")
        XCTAssertEqual(session.refreshToken, "R10")
        XCTAssertNil(session.errorMessage)
    }

    @MainActor
    func testProductionPostAuthenticationHydratesOneBudgetBeforeEnteringWorkspace() async throws {
        let budgetsGate = Gate()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/login":
                return Self.json(200, #"{"access_token":"A9","refresh_token":"R9","token_type":"bearer"}"#)
            case "/api/v1/me":
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                budgetsGate.signalArrived()
                budgetsGate.waitForRelease()
                return Self.json(200, #"[{"id":"b1","household_id":"h1","name":"Test budget","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default:
                return Self.json(404, "{}")
            }
        }

        // Match the real production composition, not an isolated budget picker.
        let controller = UIHostingController(rootView: RootView().environmentObject(session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()

        let login = Task { await session.login(email: "owner@example.com", password: "correct horse battery staple") }
        await budgetsGate.awaitArrival()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(session.route, .connecting, "tokens must not expose the Budgets browser before authoritative hydration")

        budgetsGate.releaseNow()
        await login.value
        controller.view.layoutIfNeeded()
        XCTAssertEqual(session.activeBudget?.id, "b1")
        guard case .workspace = session.route else { return XCTFail("post-authentication hydration must enter the shared workspace route") }
        XCTAssertEqual(session.activeBudgetID, "b1", "the sole authoritative budget must become persisted application context")
        window.isHidden = true
        window.rootViewController = nil
    }

    // A loader can already be suspended in authenticated endpoint calls when another caller learns
    // that the current refresh generation is invalid. Its later success is obsolete and must not
    // restore Connected or authenticated presentation state.
    @MainActor
    func testSuspendedAuthenticatedLoadCannotReviveInvalidatedSession() async throws {
        let endpoints = Gate()
        let session = makeSession(
            access: "eyJhbGciOiJub25lIn0.eyJleHAiOjQxMDI0NDQ4MDB9.x",
            refresh: "R1"
        ) { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                return Self.json(401, #"{"detail":"Invalid or expired refresh token"}"#)
            case "/api/v1/me":
                endpoints.signalArrived(); endpoints.waitForRelease()
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                endpoints.signalArrived(); endpoints.waitForRelease()
                return Self.json(200, "[]")
            default:
                return Self.json(404, "{}")
            }
        }

        let staleLoad = Task { await session.loadBudgets(caller: "test.staleLoad") }
        await endpoints.awaitArrival()

        try await session.refreshIfNeeded(force: true, caller: "test.invalidate")
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        endpoints.releaseNow(); endpoints.releaseNow()
        _ = await staleLoad.value

        XCTAssertNil(session.token)
        XCTAssertNil(session.profile)
        XCTAssertTrue(session.budgets.isEmpty)
        XCTAssertEqual(session.connectionStatus, .authenticationRequired)
        XCTAssertNil(session.errorMessage)
    }
}

// MARK: - Test doubles

private final class InMemoryTokenStore: TokenStoring {
    private let lock = NSLock()
    private var storage: [String: String]
    init(_ initial: [String: String]) { storage = initial }
    func save(_ value: String, account: String) throws { lock.lock(); storage[account] = value; lock.unlock() }
    func read(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return storage[account] }
    func delete(account: String) { lock.lock(); storage[account] = nil; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Deterministic barrier: lets a test hold the single in-flight refresh open until every concurrent
/// caller has converged on it, then release it — no sleeps, no timing assumptions. `waitForRelease`
/// blocks only the URLSession transport thread; `awaitArrival` suspends the test without blocking the
/// main actor, so the refresh can actually reach the transport.
private final class Gate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func signalArrived() { arrived.signal() }
    func waitForRelease() { released.wait() }
    func releaseNow() { released.signal() }
    func awaitArrival() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.arrived.wait(); continuation.resume() }
        }
    }
}

private final class RefreshMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Run the deterministic handler away from URLSession's protocol scheduling queue. Some tests
        // intentionally suspend one response while a second session performs invalidation.
        DispatchQueue.global().async { [self] in
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            let (status, data) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
