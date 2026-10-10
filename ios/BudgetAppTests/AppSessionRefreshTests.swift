import XCTest
import BudgetAPI
import SwiftUI
import UIKit
import CryptoKit
@testable import Budget_App

/// Regression coverage for authentication-refresh single-flight and session recovery.
///
/// The live human-acceptance bug: on relaunch, several independent session-initialization paths
/// each read the same stored refresh token and issued their own `POST /auth/refresh`. With rotation,
/// the first rotated R1→R2 (200) and the losers submitted the now-stale R1 (401), surfacing a
/// user-visible "Invalid or expired refresh token" alert even though the winning refresh had already
/// recovered the session. These tests lock in the single-flight fix and the clean sign-in transition.
final class AppSessionRefreshTests: XCTestCase {
    func testPendingTransactionDetailsRequireCurrentWholeResourceScope() {
        let operation = RecordTransactionOperation(accountID: "checking", categoryID: nil, amountMinor: -3,
            occurredOn: "2026-10-09", payeeName: "Private purchase", memo: "Sensitive", isCleared: false,
            splits: [.init(categoryID: "food", amountMinor: -1, memo: ""),
                     .init(categoryID: "hidden", amountMinor: -2, memo: "")],
            flag: nil, tags: [], attachmentMetadata: [])
        XCTAssertTrue(PendingTransactionVisibility.allows(operation, canView: true,
            accountIDs: ["checking"], categoryIDs: ["food", "hidden"]))
        XCTAssertFalse(PendingTransactionVisibility.allows(operation, canView: false,
            accountIDs: ["checking"], categoryIDs: ["food", "hidden"]))
        XCTAssertFalse(PendingTransactionVisibility.allows(operation, canView: true,
            accountIDs: [], categoryIDs: ["food", "hidden"]))
        XCTAssertFalse(PendingTransactionVisibility.allows(operation, canView: true,
            accountIDs: ["checking"], categoryIDs: ["food"]))
    }
    func testPairingPayloadRequiresVersionedHTTPSOrigin() throws {
        let valid = DevicePairingPayload(version: 1, serverURL: "https://budget.example.com", code: "secret")
        XCTAssertEqual(DevicePairingPayload.parse(try XCTUnwrap(valid.encoded)), valid)
        XCTAssertNil(DevicePairingPayload.parse(#"{"v":1,"server_url":"http://budget.example.com","code":"secret"}"#))
        XCTAssertNotNil(DevicePairingPayload.parse(#"{"v":1,"server_url":"http://127.0.0.1:8000","code":"secret"}"#))
        XCTAssertNil(DevicePairingPayload.parse(#"{"v":2,"server_url":"https://budget.example.com","code":"secret"}"#))
        XCTAssertNil(DevicePairingPayload.parse(#"{"v":1,"server_url":"https://user:pass@budget.example.com","code":"secret"}"#))
        XCTAssertNil(DevicePairingPayload.parse(#"{"v":1,"server_url":"https://budget.example.com/untrusted-path","code":"secret"}"#))
    }

    @MainActor
    func testPairingConfiguresServerStoresSessionAndHydratesCanonicalWorkspace() async throws {
        let paths = CredentialRequestRecorder()
        RefreshMockURLProtocol.handler = { request in
            paths.append(path: request.url!.path, authorization: request.value(forHTTPHeaderField: "Authorization") ?? "")
            switch request.url!.path {
            case "/api/v1/health": return Self.json(200, #"{"status":"ok"}"#)
            case "/api/v1/bootstrap/status": return Self.json(200, #"{"initialized":true,"authentication_required":true,"api_version":"v1"}"#)
            case "/api/v1/auth/pair":
                let body = try! JSONSerialization.jsonObject(with: Self.requestBody(request)) as! [String: Any]
                XCTAssertEqual(body["code"] as? String, "one-time-code")
                XCTAssertFalse((body["device_name"] as? String ?? "").isEmpty)
                return Self.json(200, #"{"access_token":"paired-access","refresh_token":"paired-refresh","token_type":"bearer"}"#)
            case "/api/v1/me": return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets": return Self.json(200, #"[{"id":"b1","household_id":"h1","name":"Home","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default: return Self.json(404, #"{"detail":"not found"}"#)
            }
        }
        let suite = "AppSessionPairingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let session = AppSession(
            defaults: defaults,
            keychain: InMemoryTokenStore([:]),
            clientFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [RefreshMockURLProtocol.self]
                return try APIClient(baseURL: $0, session: URLSession(configuration: configuration))
            },
            initialMode: .localDevice
        )

        await session.pairDevice(serverAddress: "https://budget.example.com", code: "one-time-code")

        XCTAssertEqual(session.token, "paired-access")
        XCTAssertEqual(session.refreshToken, "paired-refresh")
        XCTAssertEqual(session.activeBudget?.id, "b1")
        XCTAssertEqual(session.connectionStatus, .connected)
        if case let .workspace(.live(budget, serverURL, token)) = session.route {
            XCTAssertEqual(budget.id, "b1")
            XCTAssertEqual(serverURL.absoluteString, "https://budget.example.com")
            XCTAssertEqual(token, "paired-access")
        } else {
            XCTFail("Pairing must enter the canonical Live workspace")
        }
        XCTAssertEqual(Array(paths.paths.prefix(3)), ["/api/v1/health", "/api/v1/bootstrap/status", "/api/v1/auth/pair"])
        XCTAssertEqual(Set(paths.paths.dropFirst(3)), Set(["/api/v1/me", "/api/v1/budgets"]),
                       "post-pair identity and budget hydration may complete concurrently")
    }

    @MainActor
    func testForegroundValidationKeepsAuthenticatedWorkspaceDuringTransientOutage() async throws {
        let unavailable = Counter()
        RefreshMockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/api/v1/health":
                return unavailable.value == 0
                    ? Self.json(200, #"{"status":"ok"}"#)
                    : Self.json(503, #"{"detail":"Temporarily unavailable"}"#)
            case "/api/v1/bootstrap/status": return Self.json(200, #"{"initialized":true,"authentication_required":true,"api_version":"v1"}"#)
            case "/api/v1/auth/pair": return Self.json(200, #"{"access_token":"access","refresh_token":"refresh","token_type":"bearer"}"#)
            case "/api/v1/me": return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets": return Self.json(200, #"[{"id":"b1","household_id":"h1","name":"Home","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default: return Self.json(404, #"{"detail":"not found"}"#)
            }
        }
        let suite = "AppSessionForegroundTests.\(UUID().uuidString)"
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
            initialMode: .localDevice
        )
        await session.pairDevice(serverAddress: "https://budget.example.com", code: "one-time-code")
        guard case .workspace = session.route else { return XCTFail("Expected authenticated workspace") }

        _ = unavailable.increment()
        await session.validateSelectedSource(caller: "foreground-test")

        XCTAssertEqual(session.connectionStatus, .connected)
        guard case .workspace = session.route else {
            return XCTFail("A transient foreground validation must not replace the active workspace")
        }
        XCTAssertNil(session.errorMessage, "A routine reconnect miss must remain in the compact workspace sync status instead of interrupting the user")
    }

    private static func workspaceResponse(_ path: String) -> (Int, Data) {
        if path.contains("/months/") {
            return json(200, #"{"month":"2026-09-01","currency_code":"USD","ready_to_assign_minor":42,"total_assigned_minor":0,"total_overspent_minor":0,"allocation_version":0,"categories":[]}"#)
        }
        if path.hasSuffix("/accounts") {
            return json(200, #"[{"id":"private-account","budget_id":"b1","name":"Private account","account_type":"checking","is_on_budget":true,"is_closed":false}]"#)
        }
        if path.hasSuffix("/reports/summary") {
            return json(200, #"{"currency_code":"USD","net_cash_flow_minor":42,"net_worth_minor":42,"debt_minor":0,"recorded_interest_month_minor":0,"expected_margin_minor":0}"#)
        }
        return json(200, "[]")
    }

    @MainActor
    private func workspaceForRevocationTest() throws -> BudgetWorkspaceStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        return BudgetWorkspaceStore.production(context: .live(
            budget: APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD"),
            serverURL: URL(string: "https://budget.example.com")!, token: "current-token"),
            clientFactory: { try APIClient(baseURL: $0, session: transport) })
    }

    @MainActor
    func testLiveWorkspaceAccessDenialEvictsFinancialObservationsButTransientFailureDoesNot() async throws {
        for deniedStatus in [403, 404] {
            let phase = Counter()
            let requests = CredentialRequestRecorder()
            RefreshMockURLProtocol.handler = { request in
                requests.append(path: request.url!.path, authorization: "test")
                if phase.value == 1 { return Self.json(503, #"{"detail":"Temporarily unavailable"}"#) }
                if phase.value == 2 { return Self.json(deniedStatus, #"{"detail":"Budget not available"}"#) }
                return Self.workspaceResponse(request.url!.path)
            }
            let store = try workspaceForRevocationTest()
            await store.refresh(); await store.loadReports([.summary])
            XCTAssertEqual(store.accounts.first?.name, "Private account")
            XCTAssertEqual(store.summary?.readyToAssignMinor, 42)
            XCTAssertNotNil(store.insightsSummary)
            _ = phase.increment(); await store.refresh()
            XCTAssertEqual(store.summary?.readyToAssignMinor, 42, "Transient outage must not be treated as revocation")
            XCTAssertEqual(store.accounts.count, 1)
            _ = phase.increment(); await store.refresh()
            XCTAssertNil(store.summary, "Definitive authorization failure must evict prior financial observations")
            XCTAssertTrue(store.accounts.isEmpty)
            XCTAssertNil(store.insightsSummary)
            XCTAssertFalse(store.reportsReady([.summary]))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.workspaceAccessDenied)
            XCTAssertThrowsError(try store.pendingAttachmentBytes(id: "forbidden"), "Known revocation blocks private staged-byte access")
            let reportCount = requests.paths.filter { $0.contains("/reports/") }.count
            await store.loadReports([.summary], retry: true)
            do { _ = try await store.transactionAttachments(id: "forbidden"); XCTFail("Known denial must block repeated service calls") } catch {}
            XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, reportCount)
            XCTAssertFalse(requests.paths.contains { $0.contains("/forbidden/attachments") })
            XCTAssertTrue(store.usesLiveCredential("current-token"), "Budget denial does not invalidate the authenticated session")
            _ = phase.increment(); await store.refresh()
            XCTAssertEqual(store.accounts.count, 1)
            XCTAssertEqual(store.summary?.readyToAssignMinor, 42)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(store.workspaceAccessDenied)
        }
    }

    @MainActor
    func testLateDetailObservationsCannotReturnAfterLiveWorkspaceRevocation() async throws {
        for kind in ["category", "account", "attachments"] {
            for responseStatus in [200, 503] {
                let gate = Gate(), denied = Counter()
                defer { gate.releaseNow() }
                RefreshMockURLProtocol.handler = { request in
                    let path = request.url!.path
                    if path.contains("/private/") {
                        gate.signalArrived(); gate.waitForRelease()
                        return Self.json(responseStatus, responseStatus == 200 ? "[]" : #"{"detail":"Old request failed"}"#)
                    }
                    if denied.value > 0 && path.contains("/months/") {
                        return Self.json(403, #"{"detail":"Access removed"}"#)
                    }
                    return Self.workspaceResponse(path)
                }
                let store = try workspaceForRevocationTest()
                await store.refresh()
                let pending = Task { () throws -> Int in
                    switch kind {
                    case "category": return try await store.categoryHistory(categoryID: "private").count
                    case "account": return try await store.accountHistory(accountID: "private").count
                    default: return try await store.transactionAttachments(id: "private").count
                    }
                }
                await gate.awaitArrival()
                _ = denied.increment()
                await store.refresh()
                XCTAssertTrue(store.workspaceAccessDenied)
                gate.releaseNow()
                do {
                    _ = try await pending.value
                    XCTFail("Revoked detail response must not reach its view: \(kind)")
                } catch is CancellationError {} catch {
                    XCTFail("Obsolete responses must cancel, not surface stale errors: \(error)")
                }
                XCTAssertTrue(store.accounts.isEmpty)
            }
        }
    }

    @MainActor
    func testLivePermissionHydrationUpdatesExistingWorkspaceAndReportRepository() async throws {
        let requests = CredentialRequestRecorder()
        RefreshMockURLProtocol.handler = { request in
            requests.append(path: request.url!.path, authorization: "test")
            return Self.workspaceResponse(request.url!.path)
        }
        let store = try workspaceForRevocationTest()
        let identity = ObjectIdentifier(store)
        await store.refresh(); await store.loadReports([.summary])
        XCTAssertNotNil(store.insightsSummary)
        let renamed = APIBudget(id: "b1", householdID: "h1", name: "Renamed household budget", currencyCode: "USD")
        XCTAssertFalse(store.updateLiveBudgetAuthority(renamed))
        XCTAssertNotNil(store.summary, "Metadata-only hydration must not interrupt the workspace")
        let restricted = APIBudget(id: "b1", householdID: "h1", name: renamed.name, currencyCode: "USD",
                                   effectivePermission: .view,
                                   capabilities: ["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions"])
        XCTAssertTrue(store.updateLiveBudgetAuthority(restricted))
        XCTAssertEqual(ObjectIdentifier(store), identity)
        XCTAssertEqual(store.budget.name, renamed.name)
        XCTAssertFalse(store.budget.can("view_reports"))
        XCTAssertTrue(store.workspaceAccessDenied)
        XCTAssertNil(store.insightsSummary)
        XCTAssertTrue(store.accounts.isEmpty)
        await store.refresh()
        XCTAssertFalse(store.workspaceAccessDenied)
        let reportReads = requests.paths.filter { $0.contains("/reports/") }.count
        await store.loadReports([.summary], retry: true)
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, reportReads,
                       "The retained Live repository must use newly hydrated capabilities")
        XCTAssertNil(store.insightsSummary)
        XCTAssertEqual(ObjectIdentifier(store), identity)
        let different = APIBudget(id: "another-budget", householdID: "h1", name: "Other", currencyCode: "USD")
        XCTAssertFalse(store.updateLiveBudgetAuthority(different))
        XCTAssertEqual(store.budget.id, "b1")
        let scopeOnly = APIBudget(id: "b1", householdID: "h1", name: renamed.name,
                                  currencyCode: "USD", effectivePermission: restricted.effectivePermission,
                                  capabilities: restricted.capabilities, accessRevision: "narrowed-resource-scope")
        let previousAuthority = store.authorityRevision
        XCTAssertTrue(store.updateLiveBudgetAuthority(scopeOnly), "Identical capabilities/resources do not imply unchanged access")
        XCTAssertGreaterThan(store.authorityRevision, previousAuthority)
        XCTAssertTrue(store.workspaceAccessDenied)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(ObjectIdentifier(store), identity)
        XCTAssertFalse(store.updateLiveBudgetAuthority(scopeOnly), "An unchanged revision must not repeatedly evict state")
    }

    @MainActor
    func testChangingPlanMonthImmediatelyDropsPreviousMonthObservation() async throws {
        RefreshMockURLProtocol.handler = { request in Self.workspaceResponse(request.url!.path) }
        let store = try workspaceForRevocationTest()
        await store.refresh()
        XCTAssertNotNil(store.summary)
        let previous = store.planMonth
        store.planMonth = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: previous))
        XCTAssertNotNil(store.summary, "A same-month date change must not interrupt observations")
        store.planMonth = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: 1, to: previous))
        XCTAssertNil(store.summary, "A new month must not render the old month's amounts while awaiting refresh")
        XCTAssertNil(store.delegatedBudget)
    }

    @MainActor
    func testPlanningGuidanceEvictsLoadedAndLateSpendingAfterWorkspaceDenial() async throws {
        for deniedStatus in [403, 404] {
            let gate = Gate(), denied = Counter(), spendingReads = Counter()
            defer { gate.releaseNow() }
            RefreshMockURLProtocol.handler = { request in
                let path = request.url!.path
                if path.hasSuffix("/reports/spending") {
                    if spendingReads.increment() == 2 { gate.signalArrived(); gate.waitForRelease() }
                    return Self.json(200, #"{"start_date":"2026-07-01","end_date":"2026-09-30","currency_code":"USD","total_spending_minor":12345,"categories":[]}"#)
                }
                if denied.value > 0 && path.contains("/months/") {
                    return Self.json(deniedStatus, #"{"detail":"Access removed"}"#)
                }
                return Self.workspaceResponse(path)
            }
            let store = try workspaceForRevocationTest()
            await store.refresh(); await store.loadPlanningGuidance()
            XCTAssertEqual(store.planningSpendingReport?.totalSpendingMinor, 12345)
            let pending = Task { await store.loadPlanningGuidance() }
            await gate.awaitArrival()
            _ = denied.increment(); await store.refresh()
            XCTAssertTrue(store.workspaceAccessDenied)
            XCTAssertNil(store.planningSpendingReport, "Revocation must discard already-loaded planning aggregates")
            gate.releaseNow(); await pending.value
            XCTAssertNil(store.planningSpendingReport, "Late success must not restore private averages")
            await store.loadPlanningGuidance()
            XCTAssertEqual(spendingReads.value, 2, "Known denial must not trigger another report request")
            XCTAssertTrue(store.usesLiveCredential("current-token"))
        }
    }

    @MainActor
    func testSuccessfulScopeReductionInvalidatesLateHistoryAndPreservesReportDates() async throws {
        let gate = Gate(), reduced = Counter()
        defer { gate.releaseNow() }
        RefreshMockURLProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/private-account/history") {
                gate.signalArrived(); gate.waitForRelease(); return Self.json(200, "[]")
            }
            if reduced.value > 0 && path.hasSuffix("/accounts") { return Self.json(200, "[]") }
            return Self.workspaceResponse(path)
        }
        let store = try workspaceForRevocationTest()
        await store.refresh(); await store.loadReports([.summary])
        XCTAssertNotNil(store.insightsSummary)
        store.reportPeriod = "custom"
        XCTAssertTrue(store.historyResourceVisible(.budget))
        XCTAssertTrue(store.historyResourceVisible(.account("private-account")))
        XCTAssertFalse(store.historyResourceVisible(.account("missing-account")))
        XCTAssertFalse(store.historyResourceVisible(.category("missing-category")))
        XCTAssertFalse(store.historyResourceVisible(.group("missing-group")))
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = start.addingTimeInterval(86400)
        store.customReportStart = start; store.customReportEnd = end
        store.reportAccountID = "private-account"
        store.reportTag = "keep-this-filter"
        let pending = Task { try await store.accountHistory(accountID: "private-account") }
        await gate.awaitArrival()
        _ = reduced.increment(); await store.refresh()
        XCTAssertFalse(store.workspaceAccessDenied, "A narrower successful scope is not whole-budget denial")
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.insightsSummary)
        XCTAssertEqual(store.reportAccountID, "")
        XCTAssertTrue(store.historyResourceVisible(.budget))
        XCTAssertFalse(store.historyResourceVisible(.account("private-account")))
        XCTAssertEqual(store.reportPeriod, "custom")
        XCTAssertEqual(store.customReportStart, start); XCTAssertEqual(store.customReportEnd, end)
        XCTAssertEqual(store.reportTag, "keep-this-filter")
        gate.releaseNow()
        do { _ = try await pending.value; XCTFail("Old-scope history must cancel") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testScopeReductionDistinguishesOrderingAndExpansionFromRemoval() {
        XCTAssertFalse(BudgetWorkspaceStore.scopeShrank(previous: ["a", "b"], current: ["b", "a"]))
        XCTAssertFalse(BudgetWorkspaceStore.scopeShrank(previous: ["a"], current: ["a", "b"]))
        XCTAssertFalse(BudgetWorkspaceStore.scopeShrank(previous: [], current: ["a"]))
        XCTAssertTrue(BudgetWorkspaceStore.scopeShrank(previous: ["a", "b"], current: ["a"]))
        XCTAssertTrue(BudgetWorkspaceStore.scopeShrank(previous: ["a"], current: []))
    }

    @MainActor
    func testKnownWorkspaceDenialHidesEveryHistoryResource() async throws {
        RefreshMockURLProtocol.handler = { _ in Self.json(403, #"{"detail":"Access removed"}"#) }
        let store = try workspaceForRevocationTest()
        await store.refresh()
        for resource: WorkspaceHistoryResource in [.budget, .account("a"), .category("c"), .group("g")] {
            XCTAssertFalse(store.historyResourceVisible(resource))
        }
    }

    func testActivityAndAttachmentAuthorityGuardsAreWiredIntoProductionViews() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: path)
        let start = try XCTUnwrap(source.range(of: "private struct LiveActivityView:"))
        let end = try XCTUnwrap(source.range(of: "private struct TransactionBrowserFilter:"))
        let activity = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(activity.contains(".onChange(of: store.authorityRevision)"))
        XCTAssertTrue(activity.contains("recentTransactionChanges = []; recentReconciliations = []; reconciliationAccount = nil"))
        XCTAssertTrue(activity.contains("selectedIDs.removeAll(); selecting = false; showTagPrompt = false"))
        XCTAssertTrue(activity.contains("transactionChangesAuthority != revision"))
        XCTAssertTrue(activity.contains("reconciliationAuthority != revision"))
        XCTAssertTrue(activity.contains("guard requestedKey == queryKey, !Task.isCancelled"))
        XCTAssertTrue(source.contains("HistoryAuthorityBoundary(.account(transaction.accountID), unavailableTitle: \"Attachments unavailable\")"))
    }

    func testMissingMonthlyObservationHasProductionRecoveryInsteadOfZeroOrEmptyMutationSheet() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: path)
        let homeStart = try XCTUnwrap(source.range(of: "private struct LiveHomeView:"))
        let homeEnd = try XCTUnwrap(source.range(of: "private struct LivePlanView:"))
        let home = String(source[homeStart.lowerBound..<homeEnd.lowerBound])
        XCTAssertTrue(home.contains("home-budget-total-unavailable"))
        XCTAssertFalse(home.contains("store.summary?.readyToAssignMinor ?? 0"))
        let planEnd = try XCTUnwrap(source.range(of: "private struct LivePlanGroupDetailView:", range: homeEnd.lowerBound..<source.endIndex))
        let plan = String(source[homeEnd.lowerBound..<planEnd.lowerBound])
        XCTAssertTrue(plan.contains("plan-month-loading"))
        XCTAssertTrue(plan.contains("plan-month-unavailable"))
        XCTAssertTrue(plan.contains("Button(\"Retry\", systemImage: \"arrow.clockwise\")"))
        XCTAssertTrue(plan.contains(".disabled(store.summary == nil)"))
        XCTAssertTrue(plan.contains("if store.summary != nil && !activation.showsNormalPlan"))
    }

    func testStatementReviewAuthorityChangeClosesWithoutAutomaticMutation() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: path)
        let start = try XCTUnwrap(source.range(of: "private struct StatementImportFlowView:"))
        let content = try XCTUnwrap(source.range(of: "    private var editorContent:", range: start.lowerBound..<source.endIndex))
        let boundary = String(source[start.lowerBound..<content.lowerBound])
        XCTAssertTrue(boundary.contains("workspace.budget.can(\"reconcile_account\")"))
        XCTAssertTrue(boundary.contains(".onChange(of: workspace.authorityRevision)"))
        XCTAssertTrue(boundary.contains("accessChanged = true; staged = nil; postRows = []; categoryByRow = [:]"))
        XCTAssertFalse(boundary.contains("Task {"), "Scope change must not automatically stage or approve an import")
        XCTAssertTrue(source.contains("guard canUseCurrentAccess, revision == workspace.authorityRevision else { return }; staged = result"))
        XCTAssertTrue(source.contains("HistoryAuthorityBoundary(.account(account.id), unavailableTitle: \"Statement imports unavailable\")"))
        XCTAssertTrue(source.contains("HistoryAuthorityBoundary(.account(account.id), unavailableTitle: \"Debt terms unavailable\")"))
    }

    @MainActor
    func testLateSnapshotAndReportCannotRestoreWorkspaceAfterAccessDenial() async throws {
        let reads = Counter(), snapshotGate = Gate(), reportGate = Gate()
        defer { snapshotGate.releaseNow(); reportGate.releaseNow() }
        RefreshMockURLProtocol.handler = { request in
            let path = request.url!.path
            if path.contains("/months/") {
                let read = reads.increment()
                if read == 2 { snapshotGate.signalArrived(); snapshotGate.waitForRelease() }
                if read == 3 { return Self.json(403, #"{"detail":"Access removed"}"#) }
            }
            if path.hasSuffix("/reports/summary") { reportGate.signalArrived(); reportGate.waitForRelease() }
            return Self.workspaceResponse(path)
        }
        let store = try workspaceForRevocationTest()
        await store.refresh()
        XCTAssertNotNil(store.summary)
        let delayedReport = Task { await store.loadReports([.summary]) }
        await reportGate.awaitArrival()
        let delayedSnapshot = Task { await store.refresh() }
        await snapshotGate.awaitArrival()
        await store.refresh()
        snapshotGate.releaseNow(); reportGate.releaseNow()
        await delayedSnapshot.value; await delayedReport.value
        XCTAssertNil(store.summary)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.insightsSummary)
        XCTAssertFalse(store.reportsReady([.summary]))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

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
    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
    private static let rotated = #"{"access_token":"A2","refresh_token":"R2","token_type":"bearer"}"#

    private static func jwt(expiration: TimeInterval) -> String {
        func encode(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"none"}"#)).\(encode("{\"exp\":\(Int(expiration))}")).signature"
    }

    @MainActor
    func testDeterministicSourceUsesSharedWorkspaceRoute() {
        let session = AppSession(defaults: UserDefaults(suiteName: "DeterministicShell.\(UUID().uuidString)")!, keychain: InMemoryTokenStore([:]), initialMode: .deterministic)
        guard case let .workspace(context) = session.route else { return XCTFail("deterministic source must resolve the shared workspace route") }
        XCTAssertEqual(context, .deterministic)
    }

    @MainActor
    func testFreshInstallDefaultsDirectlyToDurableLocalWorkspace() {
        let suite = "LocalFirstShell.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let session = AppSession(defaults: defaults, keychain: InMemoryTokenStore([:]))

        XCTAssertEqual(session.sourceMode, .localDevice)
        XCTAssertEqual(session.connectionStatus, .localDevice)
        XCTAssertEqual(session.route, .workspace(.localDevice(revision: 0)))
        XCTAssertNil(session.serverURL)
        XCTAssertNil(session.token)
    }

    @MainActor
    func testProductionWorkspaceRebindsCommandsAfterAccessTokenRotation() {
        let budget = APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD")
        let serverURL = URL(string: "https://budget.example.com")!
        let store = BudgetWorkspaceStore.production(context: .live(budget: budget, serverURL: serverURL, token: "A1"))

        XCTAssertTrue(store.usesLiveCredential("A1"))
        store.updateLiveCredentials(serverURL: serverURL, token: "A2")
        XCTAssertFalse(store.usesLiveCredential("A1"))
        XCTAssertTrue(store.usesLiveCredential("A2"), "all subsequent commands, including schedule creation, must use the rotated access token")
    }

    @MainActor
    func testFocusedReportReadsRequestOnlySelectedPayloadAndCurrentCredential() async throws {
        let requests = CredentialRequestRecorder()
        RefreshMockURLProtocol.handler = { request in
            requests.append(path: request.url!.path, authorization: request.value(forHTTPHeaderField: "Authorization") ?? "")
            if request.url!.path.hasSuffix("/reports/debt-cost") {
                return Self.json(200, #"{"as_of":"2026-09-18","currency_code":"USD","model":"unchanged_balance_monthly_apr","accounts":[]}"#)
            }
            guard request.url!.path.hasSuffix("/reports/debt") else { return Self.json(500, "{}") }
            return Self.json(200, #"{"start_date":"2026-09-01","end_date":"2026-09-30","currency_code":"USD","opening_debt_minor":1000,"debt_minor":900,"principal_reduction_minor":100,"recorded_interest_range_minor":0,"recorded_interest_month_minor":0,"recorded_interest_ytd_minor":0,"recorded_interest_trailing_12_minor":0,"interest_tracking_started_on":null,"points":[],"accounts":[]}"#)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        let url = URL(string: "https://budget.example.com")!
        let store = BudgetWorkspaceStore.production(
            context: .live(budget: APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD"), serverURL: url, token: "A1"),
            clientFactory: { try APIClient(baseURL: $0, session: transport) }
        )
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: false)
        let empty = try await store.fetchReports(query: query, kinds: [])
        XCTAssertNil(empty.debt)
        XCTAssertEqual(requests.count, 0)
        let first = try await store.fetchReports(query: query, kinds: [.debt])
        XCTAssertEqual(first.debt?.debtMinor, 900)
        XCTAssertNil(first.spending)
        XCTAssertNil(first.netWorth)
        XCTAssertEqual(requests.count, 1)
        store.updateLiveCredentials(serverURL: url, token: "A2")
        _ = try await store.fetchReports(query: query, kinds: [.debt])
        XCTAssertEqual(requests.paths, Array(repeating: "/api/v1/budgets/b1/reports/debt", count: 2))
        XCTAssertEqual(requests.authorizations, ["Bearer A1", "Bearer A2"])
        _ = try await store.debtCost(accountIDs: [])
        store.updateLiveCredentials(serverURL: url, token: "A3")
        _ = try await store.debtCost(accountIDs: ["card"])
        XCTAssertEqual(Array(requests.paths.suffix(2)), Array(repeating: "/api/v1/budgets/b1/reports/debt-cost", count: 2))
        XCTAssertEqual(Array(requests.authorizations.suffix(2)), ["Bearer A2", "Bearer A3"])
    }

    @MainActor
    func testCoreHydrationSkipsReportsAndFocusedReportsCacheRetryAndInvalidate() async throws {
        let requests = CredentialRequestRecorder()
        RefreshMockURLProtocol.handler = { request in
            let path = request.url!.path
            requests.append(path: path, authorization: request.value(forHTTPHeaderField: "Authorization") ?? "")
            if path.contains("/months/") {
                return Self.json(200, #"{"month":"2026-09-01","currency_code":"USD","ready_to_assign_minor":0,"total_assigned_minor":0,"total_overspent_minor":0,"allocation_version":0,"categories":[]}"#)
            }
            if path.hasSuffix("/reports/debt") {
                if requests.paths.filter({ $0.hasSuffix("/reports/debt") }).count == 1 {
                    return Self.json(503, #"{"detail":"Report temporarily unavailable"}"#)
                }
                return Self.json(200, #"{"start_date":"2026-09-01","end_date":"2026-09-30","currency_code":"USD","opening_debt_minor":1000,"debt_minor":900,"principal_reduction_minor":100,"recorded_interest_range_minor":0,"recorded_interest_month_minor":0,"recorded_interest_ytd_minor":0,"recorded_interest_trailing_12_minor":0,"interest_tracking_started_on":null,"points":[],"accounts":[]}"#)
            }
            if path.hasSuffix("/reports/summary") {
                return Self.json(200, #"{"currency_code":"USD","net_cash_flow_minor":1000,"net_worth_minor":1000,"debt_minor":0,"recorded_interest_month_minor":0,"expected_margin_minor":0}"#)
            }
            if path.contains("/reports/") { return Self.json(500, "{}") }
            return Self.json(200, "[]")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        let url = URL(string: "https://budget.example.com")!
        let store = BudgetWorkspaceStore.production(
            context: .live(budget: APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD"), serverURL: url, token: "A1"),
            clientFactory: { try APIClient(baseURL: $0, session: transport) }
        )
        await store.refresh()
        XCTAssertNotNil(store.summary)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(requests.paths.contains { $0.contains("/reports/") })
        await store.loadReports([.debt])
        XCTAssertNotNil(store.reportErrors[.debt])
        XCTAssertNil(store.errorMessage, "Report failures must not fail workspace hydration")
        await store.loadReports([.debt])
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 1, "Do not loop on a known report failure")
        await store.loadReports([.debt], retry: true)
        XCTAssertTrue(store.reportsReady([.debt]))
        XCTAssertEqual(store.debtReport?.debtMinor, 900)
        await store.loadReports([.debt])
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 2)
        store.reportAccountID = "a1"
        XCTAssertFalse(store.reportsReady([.debt]))
        async let firstRead: Void = store.loadReports([.debt])
        async let secondRead: Void = store.loadReports([.debt])
        _ = await (firstRead, secondRead)
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 3)
        await store.refresh()
        XCTAssertFalse(store.reportsReady([.debt]))
        await store.loadReports([.debt])
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 4)
        store.updateLiveCredentials(serverURL: url, token: "A2")
        await store.loadReports([.debt])
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 5)
        XCTAssertEqual(requests.authorizations.last, "Bearer A2")
        XCTAssertTrue(requests.paths.filter { $0.contains("/reports/") }.allSatisfy { $0.hasSuffix("/reports/debt") })
        await store.loadReports([.summary])
        XCTAssertEqual(store.insightsSummary?.netCashFlowMinor, 1000)
        XCTAssertEqual(requests.paths.last, "/api/v1/budgets/b1/reports/summary")
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 6)
        await store.loadReports([.summary])
        XCTAssertEqual(requests.paths.filter { $0.contains("/reports/") }.count, 6)
        XCTAssertNil(store.incomeReport, "The hub must not fetch detailed report payloads")
        XCTAssertNil(store.netWorthReport)
    }

    @MainActor
    func testLiveWorkspaceAttachmentsAndCommandsUseRotatedCredentialWithoutReconstruction() async throws {
        let requests = CredentialRequestRecorder()
        RefreshMockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requests.append(path: request.url?.path ?? "", authorization: authorization)
            if authorization == "Bearer A1", requests.count > 1 {
                return Self.json(401, #"{"detail":"Invalid or expired credentials"}"#)
            }
            if request.url?.path.hasSuffix("/attachments") == true {
                return Self.json(200, "[]")
            }
            if request.url?.path.hasSuffix("/schedule") == true {
                return Self.json(201, #"{"id":"s1","budget_id":"b1","account_id":"a1","destination_account_id":null,"category_id":"c1","name":"Market","amount_minor":-1200,"next_date":"2026-10-15","recurrence_unit":"months","interval_count":1,"memo":"","is_active":true,"last_realized_on":null}"#)
            }
            if request.url?.path.hasSuffix("/target/snooze/2027-02-01") == true {
                return Self.json(200, #"{"category_id":"c1","month":"2027-02-01","is_snoozed":true}"#)
            }
            if request.url?.path.hasSuffix("/cash-rollover-policy") == true {
                return Self.json(200, #"{"current_month":"2026-09-01","current_policy":"carry_category_deficit","policy_version":1,"allocation_version":1,"pending":[{"effective_month":"2026-10-01","policy":"absorb_next_month","version":1}]}"#)
            }
            if request.url?.path.hasSuffix("/cash-rollover-policy/history") == true {
                return Self.json(200, #"{"items":[],"next_before_version":null}"#)
            }
            if request.url?.path.hasSuffix("/access/u2") == true {
                return Self.json(200, #"{"budget_id":"b1","user_id":"u2","capabilities":["view_budget"],"restrict_accounts":false,"account_ids":[],"restrict_categories":false,"category_ids":[],"grant_permission":"view","is_custom":false,"version":0,"updated_by_user_id":null,"updated_by_display_name":null,"updated_at":null}"#)
            }
            // A successful command triggers authoritative hydration. Model that healthy read path
            // rather than accidentally representing revoked access with blanket 404 responses.
            if request.httpMethod == "GET" { return Self.workspaceResponse(request.url!.path) }
            return Self.json(404, "{}")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let budget = APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD")
        let serverURL = URL(string: "https://budget.example.com")!
        let store = BudgetWorkspaceStore.production(
            context: .live(budget: budget, serverURL: serverURL, token: "A1"),
            clientFactory: { try APIClient(baseURL: $0, session: session) }
        )

        let beforeRotation = try await store.transactionAttachments(id: "t1")
        XCTAssertEqual(beforeRotation, [])
        store.updateLiveCredentials(serverURL: serverURL, token: "A2")
        XCTAssertEqual(store.liveCredentialRevision, 1)
        let afterRotation = try await store.transactionAttachments(id: "t1")
        XCTAssertEqual(afterRotation, [])
        let accessProfile = try await store.accessProfile(userID: "u2")
        XCTAssertEqual(accessProfile.version, 0)
        try await store.createScheduleFromTransaction(
            id: "t1",
            operation: .init(recurrenceUnit: "months", intervalCount: 1, nextDate: "2026-10-15", expectedRevision: "v1:" + String(repeating: "a", count: 64))
        )

        XCTAssertEqual(Array(requests.authorizations.prefix(4)), ["Bearer A1", "Bearer A2", "Bearer A2", "Bearer A2"])
        XCTAssertEqual(Array(requests.paths.prefix(4)), [
            "/api/v1/budgets/b1/transactions/t1/attachments",
            "/api/v1/budgets/b1/transactions/t1/attachments",
            "/api/v1/budgets/b1/access/u2",
            "/api/v1/budgets/b1/transactions/t1/schedule",
        ])
        XCTAssertTrue(requests.authorizations.dropFirst().allSatisfy { $0 == "Bearer A2" })
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.workspaceAccessDenied)
        try await store.setTargetSnoozed(categoryID: "c1", month: "2027-02-01", isSnoozed: true)
        XCTAssertEqual(requests.paths.filter { $0.hasSuffix("/target/snooze/2027-02-01") }.count, 1)
        let policy = try await store.cashRolloverPolicy()
        XCTAssertEqual(policy.currentPolicy, .carryCategoryDeficit)
        _ = try await store.selectCashRolloverPolicy(.init(policy: .absorbNextMonth, effectiveMonth: "2026-10-01", expectedPolicyVersion: 0, expectedAllocationVersion: 0))
        let history = try await store.cashRolloverPolicyHistory()
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertEqual(requests.paths.filter { $0.hasSuffix("/cash-rollover-policy") }.count, 2, "One read and exactly one mutation")
        XCTAssertEqual(requests.paths.filter { $0.hasSuffix("/cash-rollover-policy/history") }.count, 1)
        XCTAssertTrue(requests.authorizations.dropFirst().allSatisfy { $0 == "Bearer A2" })
    }

    @MainActor
    func testAttachmentPreviewDownloadsWithoutDetachAndConfirmedRemovalDetachesOnce() async throws {
        let requests = CredentialRequestRecorder()
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let attachmentJSON = "{\"id\":\"att1\",\"transaction_id\":\"t1\",\"filename\":\"receipt.jpg\",\"content_type\":\"image/jpeg\",\"byte_count\":4,\"sha256\":\"\(digest)\",\"created_at\":\"2026-10-09T00:00:00Z\"}"
        RefreshMockURLProtocol.handler = { request in
            requests.append(path: "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")", authorization: request.value(forHTTPHeaderField: "Authorization") ?? "")
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A2")
                XCTAssertNotNil(UUID(uuidString: request.value(forHTTPHeaderField: "X-Attachment-Operation-ID") ?? ""))
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                    [URLQueryItem(name: "expected_sha256", value: digest)])
                return Self.json(204, "")
            }
            if request.url?.path.hasSuffix("/attachments") == true { return Self.json(200, "[" + attachmentJSON + "]") }
            return (200, image)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let budget = APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD")
        let store = BudgetWorkspaceStore.production(
            context: .live(budget: budget, serverURL: URL(string: "https://budget.example.com")!, token: "A1"),
            clientFactory: { try APIClient(baseURL: $0, session: session) }
        )

        let data = try await store.downloadTransactionAttachment(transactionID: "t1", attachmentID: "att1")
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(requests.paths.filter { $0.hasPrefix("DELETE ") }.count, 0, "preview/download must never detach")

        store.updateLiveCredentials(serverURL: URL(string: "https://budget.example.com")!, token: "A2")
        let attachment = try JSONDecoder().decode(APITransactionAttachment.self, from: Data(attachmentJSON.utf8))
        try await store.detachTransactionAttachment(transactionID: "t1", attachment: attachment)
        XCTAssertEqual(requests.paths.filter { $0 == "DELETE /api/v1/budgets/b1/transactions/t1/attachments/att1" }.count, 1)
    }

    @MainActor
    func testLongLivedWorkspaceSearchRefreshesExpiredSessionAtRequestExecution() async throws {
        let requests = CredentialRequestRecorder()
        let expired = Self.jwt(expiration: Date().timeIntervalSince1970 - 60)
        let current = Self.jwt(expiration: Date().timeIntervalSince1970 + 3600)
        let session = makeSession(access: expired, refresh: "R1") { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requests.append(path: request.url?.path ?? "", authorization: authorization)
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                return Self.json(200, "{\"access_token\":\"\(current)\",\"refresh_token\":\"R2\",\"token_type\":\"bearer\"}")
            case "/api/v1/budgets/b1/transactions/search":
                return Self.json(200, #"{"items":[],"next_cursor":null,"total_count":0}"#)
            default:
                return Self.json(404, "{}")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let budget = APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD")
        let store = BudgetWorkspaceStore.production(
            context: .live(budget: budget, serverURL: URL(string: "https://budget.example.com")!, token: expired),
            clientFactory: { try APIClient(baseURL: $0, session: urlSession) }
        )
        store.bindLiveCredentialAuthority { [weak session] forceRefresh in
            guard let session else { throw APIClientError.server(status: 401, message: "Authentication required") }
            return try await session.currentLiveCredentials(forceRefresh: forceRefresh, caller: "test.transaction-search")
        }

        async let firstPage = store.browseTransactions(APITransactionQuery())
        async let reconstructedActivityPage = store.browseTransactions(APITransactionQuery())
        let (page, duplicatePage) = try await (firstPage, reconstructedActivityPage)

        XCTAssertEqual(page.totalCount, 0)
        XCTAssertEqual(duplicatePage.totalCount, 0)
        XCTAssertEqual(requests.paths, ["/api/v1/auth/refresh", "/api/v1/budgets/b1/transactions/search"])
        XCTAssertEqual(requests.authorizations.last, "Bearer \(current)")
        XCTAssertFalse(requests.authorizations.contains("Bearer \(expired)"), "the expired token must not reach transaction search")
        XCTAssertTrue(store.usesLiveCredential(current))
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

        // RootView.task is the production startup entry point under test. Do not also call
        // validateSelectedSource directly: on a fast runner the calls happen to overlap and join,
        // while on a slower runner they can become sequential and make the test itself submit a
        // second refresh that the application never requests. Wait for the rendered hierarchy's
        // lifecycle task to reach the authoritative sign-in state instead.
        // A hosted view receives scene activation automatically in an application test, but a
        // unit-test UIWindow is not guaranteed to transition its scene to active. Give the actual
        // modifier an opportunity to start, then invoke the same activation gateway as a fallback.
        // `activate` is latched, so this cannot start a second validation if SwiftUI already did.
        let lifecycleDeadline = ContinuousClock.now + .milliseconds(250)
        while refresh.value == 0,
              session.connectionStatus != .authenticationRequired,
              ContinuousClock.now < lifecycleDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if refresh.value == 0 {
            await session.activate(caller: "test.productionRoot.fallback")
        }
        // Hosted Xcode 15.4 runners can take several seconds to deliver a mocked URLProtocol
        // response after the request has already been observed. Keep the assertion bounded while
        // waiting for the authoritative transition, rather than treating runner scheduling as an
        // authentication failure.
        let deadline = ContinuousClock.now + .seconds(10)
        while session.connectionStatus != .authenticationRequired,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

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
        await session.createBudget(name: "First budget", currencyCode: "USD", householdID: "h1", cashRolloverPolicy: .absorbNextMonth)
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
    func testVerifiedTransferSchedulesColdLocalLaunchWithoutDiscardingServerCredentials() throws {
        let suite = "AppSessionTransferActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://budget.example.com", forKey: "budget.serverURL")
        defaults.set("liveServer", forKey: "budget.dataSourceMode")
        let keychain = InMemoryTokenStore([
            "access-token": "access-a", "refresh-token": "refresh-a",
        ])
        let active = AppSession(defaults: defaults, keychain: keychain)

        try active.scheduleLocalDeviceActivationAfterRestart()

        XCTAssertEqual(active.sourceMode, .liveServer)
        XCTAssertEqual(active.token, "access-a")
        XCTAssertEqual(active.refreshToken, "refresh-a")
        let relaunched = AppSession(defaults: defaults, keychain: keychain)
        XCTAssertEqual(relaunched.sourceMode, .localDevice)
        XCTAssertEqual(relaunched.token, "access-a", "Server access remains available for a later switch back")
        XCTAssertEqual(relaunched.refreshToken, "refresh-a")
    }

    @MainActor
    func testConnectedServerCannotBypassVerifiedTransferIntoEmptyLocalAuthority() {
        let suite = "AppSessionTransferBypassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://budget.example.com", forKey: "budget.serverURL")
        defaults.set("liveServer", forKey: "budget.dataSourceMode")
        let session = AppSession(
            defaults: defaults,
            keychain: InMemoryTokenStore(["access-token": "access-a", "refresh-token": "refresh-a"])
        )

        session.selectLocalDevice()

        XCTAssertEqual(session.sourceMode, .liveServer)
        XCTAssertEqual(session.token, "access-a")
        XCTAssertTrue(session.errorMessage?.contains("Backup & Recovery") == true)
    }

    @MainActor
    func testGuardedReturnToSavedServerVerifiesRefreshAndMatchingBudgetBeforeCutover() async {
        let requests = CredentialRequestRecorder()
        let session = makeLocalSessionWithRetainedServer { request in
            requests.append(
                path: request.url!.path,
                authorization: request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            switch request.url?.path {
            case "/api/v1/health":
                return Self.json(200, #"{"status":"ok"}"#)
            case "/api/v1/auth/refresh":
                return Self.json(200, #"{"access_token":"A2","refresh_token":"R2","token_type":"bearer"}"#)
            case "/api/v1/me":
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                return Self.json(200, #"[{"id":"b1","household_id":"h1","name":"Home","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default:
                return Self.json(404, #"{"detail":"not found"}"#)
            }
        }

        await session.returnToSavedServer(expectedBudgetID: "b1")

        XCTAssertEqual(session.sourceMode, .liveServer)
        XCTAssertEqual(session.connectionStatus, .connected)
        XCTAssertEqual(session.token, "A2")
        XCTAssertEqual(session.refreshToken, "R2")
        XCTAssertEqual(session.activeBudgetID, "b1")
        guard case let .workspace(.live(budget, _, token)) = session.route else {
            return XCTFail("A verified return must enter the canonical Live workspace")
        }
        XCTAssertEqual(budget.id, "b1")
        XCTAssertEqual(token, "A2")
        XCTAssertEqual(Set(requests.paths), Set([
            "/api/v1/health", "/api/v1/auth/refresh", "/api/v1/me", "/api/v1/budgets",
        ]))
        XCTAssertTrue(requests.authorizations.filter { !$0.isEmpty }.allSatisfy { $0 == "Bearer A2" })
    }

    @MainActor
    func testGuardedReturnFailureLeavesLocalAuthoritySelectedAndCredentialsRetryable() async {
        let session = makeLocalSessionWithRetainedServer { request in
            switch request.url?.path {
            case "/api/v1/health":
                return Self.json(503, #"{"detail":"offline"}"#)
            default:
                return Self.json(500, "{}")
            }
        }

        await session.returnToSavedServer(expectedBudgetID: "b1")

        XCTAssertEqual(session.sourceMode, .localDevice)
        XCTAssertEqual(session.connectionStatus, .localDevice)
        XCTAssertEqual(session.route, .workspace(.localDevice(revision: 0)))
        XCTAssertEqual(session.token, "A1")
        XCTAssertEqual(session.refreshToken, "R1")
        XCTAssertTrue(session.canReturnToSavedServer)
        XCTAssertNotNil(session.errorMessage)
    }

    @MainActor
    func testGuardedReturnRejectsDifferentServerBudgetWithoutPublishingLiveMode() async {
        let session = makeLocalSessionWithRetainedServer { request in
            switch request.url?.path {
            case "/api/v1/health":
                return Self.json(200, #"{"status":"ok"}"#)
            case "/api/v1/auth/refresh":
                return Self.json(200, #"{"access_token":"A2","refresh_token":"R2","token_type":"bearer"}"#)
            case "/api/v1/me":
                return Self.json(200, #"{"id":"u1","email":"owner@example.com","display_name":"Owner","households":[]}"#)
            case "/api/v1/budgets":
                return Self.json(200, #"[{"id":"other","household_id":"h2","name":"Different","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#)
            default:
                return Self.json(404, "{}")
            }
        }

        await session.returnToSavedServer(expectedBudgetID: "b1")

        XCTAssertEqual(session.sourceMode, .localDevice)
        XCTAssertEqual(session.route, .workspace(.localDevice(revision: 0)))
        XCTAssertEqual(session.token, "A2", "Rotated credentials must remain durable for a later retry")
        XCTAssertEqual(session.refreshToken, "R2")
        XCTAssertTrue(session.errorMessage?.contains("no longer exposes this budget") == true)
    }

    @MainActor
    private func makeLocalSessionWithRetainedServer(
        handler: @escaping (URLRequest) -> (Int, Data)
    ) -> AppSession {
        RefreshMockURLProtocol.handler = handler
        let suite = "SavedServerReturnTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("https://budget.example.com", forKey: "budget.serverURL")
        defaults.set("localDevice", forKey: "budget.dataSourceMode")
        return AppSession(
            defaults: defaults,
            keychain: InMemoryTokenStore(["access-token": "A1", "refresh-token": "R1"]),
            clientFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [RefreshMockURLProtocol.self]
                return try APIClient(baseURL: $0, session: URLSession(configuration: configuration))
            },
            initialMode: .localDevice
        )
    }

    @MainActor
    func testSignOutClearsPersistedActiveBudgetContext() {
        let session = makeSession(access: "A1", refresh: "R1") { request in
            request.url?.path == "/api/v1/auth/logout" ? Self.json(204, "") : Self.json(404, "{}")
        }
        session.budgets = [APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD")]
        session.selectBudget("b1")

        session.signOut()

        XCTAssertNil(session.activeBudgetID)
        XCTAssertNil(session.activeBudget)
        XCTAssertEqual(session.route, .authentication)
    }

    @MainActor
    func testRepositoryChangeInvalidatesPriorActiveBudgetContext() {
        let session = makeSession(access: "A1", refresh: "R1") { request in
            request.url?.path == "/api/v1/auth/logout" ? Self.json(204, "") : Self.json(404, "{}")
        }
        session.budgets = [APIBudget(id: "b1", householdID: "h1", name: "Home", currencyCode: "USD")]
        session.selectBudget("b1")

        session.changeServer()

        XCTAssertNil(session.activeBudgetID)
        XCTAssertNil(session.activeBudget)
        XCTAssertNil(session.serverURL)
        XCTAssertEqual(session.route, .serverSetup)
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
        let workspaceRefresh = Counter()
        let session = makeSession(access: "expired-access", refresh: "R1") { request in
            switch request.url?.path {
            case "/api/v1/auth/login":
                return Self.json(200, #"{"access_token":"A9","refresh_token":"R9","token_type":"bearer"}"#)
            case "/api/v1/auth/refresh":
                _ = workspaceRefresh.increment()
                return Self.json(200, Self.rotated)
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

        // Entering the real workspace intentionally starts its production reload. Wait for that
        // authenticated task to consume this test's handler before replacing the process-wide
        // URLProtocol handler in the next test. Without this drain, a slow hosted simulator can
        // let the old workspace request receive the next test's synthetic 401.
        let reloadDeadline = ContinuousClock.now + .seconds(10)
        while workspaceRefresh.value == 0, ContinuousClock.now < reloadDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspaceRefresh.value, 1)
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
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
    @MainActor
    func testLiveTransactionOutboxPersistsExactMoneyAndStableReplayIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let id = "5c0da385-5c73-40fc-8c4f-19e9c93ae5b6"
        let operation = RecordTransactionOperation(
            accountID: "checking", categoryID: "groceries", amountMinor: -12_345,
            occurredOn: "2026-10-03", payeeName: "Offline Market", memo: "No signal",
            isCleared: false,
            splits: [.init(categoryID: "groceries", amountMinor: -12_345, memo: "")],
            flag: "orange", tags: ["offline"], attachmentMetadata: [], clientOperationID: id
        )
        let first = LiveTransactionOutbox(fileURL: file)
        try first.enqueue(operation)
        try first.enqueue(operation)
        XCTAssertEqual(first.count, 1)

        let reopened = LiveTransactionOutbox(fileURL: file)
        XCTAssertEqual(reopened.entries.first?.operation?.amountMinor, -12_345)
        XCTAssertEqual(reopened.entries.first?.operation?.clientOperationID, id)
        let secondID = "9ad90c5c-ae8f-4dbc-9a87-10323c0b9376"
        let second = RecordTransactionOperation(
            accountID: "savings", categoryID: "goals", amountMinor: -500,
            occurredOn: "2026-10-04", payeeName: "Second queued item", memo: "Keep me",
            isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [],
            clientOperationID: secondID
        )
        try reopened.enqueue(second)
        try reopened.remove(id: id)
        let afterDiscard = LiveTransactionOutbox(fileURL: file)
        XCTAssertEqual(afterDiscard.count, 1)
        XCTAssertEqual(afterDiscard.entries.first?.id, secondID)
        XCTAssertEqual(afterDiscard.entries.first?.operation?.amountMinor, -500)
    }

    @MainActor
    func testLegacyOutboxRequiresExplicitServerReviewAndPreservesOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.json"), destination = root.appendingPathComponent("scoped.json")
        let operation = RecordTransactionOperation(accountID: "checking", categoryID: "groceries", amountMinor: -9007199254740993,
            occurredOn: "2026-10-09", payeeName: "Preserved", memo: "Legacy", isCleared: false, splits: [],
            flag: "orange", tags: ["qa"], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        let original = LiveTransactionOutbox(fileURL: legacy)
        try original.enqueue(operation)
        let bytes = try Data(contentsOf: legacy)
        let queue = LiveTransactionOutbox(fileURL: destination, legacyFileURL: legacy, scope: "server-a")
        XCTAssertTrue(queue.requiresLegacyReview)
        XCTAssertThrowsError(try queue.beginReplay())
        XCTAssertThrowsError(try queue.remove(id: operation.clientOperationID!))
        XCTAssertThrowsError(try queue.enqueue(operation))
        try queue.confirmLegacyServer()
        XCTAssertFalse(queue.requiresLegacyReview)
        XCTAssertEqual(queue.entries, original.entries)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let reopened = LiveTransactionOutbox(fileURL: destination, legacyFileURL: legacy, scope: "server-a")
        XCTAssertFalse(reopened.requiresLegacyReview)
        XCTAssertEqual(reopened.entries, queue.entries)
        let other = LiveTransactionOutbox(fileURL: root.appendingPathComponent("other.json"), legacyFileURL: legacy, scope: "server-b")
        XCTAssertEqual(other.count, 0)
        XCTAssertFalse(other.requiresLegacyReview)
    }

    func testLiveRouteIdentitySeparatesEndpointsWithoutResettingForTokenRotation() throws {
        let budget = APIBudget(id: "same-budget", householdID: "h", name: "Budget", currencyCode: "USD")
        let first = WorkspaceRouteContext.live(budget: budget, serverURL: try XCTUnwrap(URL(string: "https://server.example/family")), token: "old")
        let rotated = WorkspaceRouteContext.live(budget: budget, serverURL: try XCTUnwrap(URL(string: "https://server.example/family")), token: "new")
        let other = WorkspaceRouteContext.live(budget: budget, serverURL: try XCTUnwrap(URL(string: "https://server.example/friends")), token: "new")
        XCTAssertEqual(first.identity, rotated.identity)
        XCTAssertNotEqual(first.identity, other.identity)
    }

    @MainActor
    func testLiveOutboxFailedWritesPreserveInMemoryAndDurableEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("storage")
        let retained = root.appendingPathComponent("retained")
        let file = storage.appendingPathComponent("queue.json")
        let queue = LiveTransactionOutbox(fileURL: file)
        let operation = RecordTransactionOperation(accountID: "a", categoryID: nil, amountMinor: 9_007_199_254_740_993,
            occurredOn: "2026-10-09", payeeName: "Offline", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        try queue.enqueue(operation)
        let original = queue.entries
        try FileManager.default.moveItem(at: storage, to: retained)
        try Data("blocks writes".utf8).write(to: storage)
        var other = operation; other.clientOperationID = UUID().uuidString
        XCTAssertThrowsError(try queue.enqueue(other))
        XCTAssertEqual(queue.entries, original)
        XCTAssertThrowsError(try queue.remove(id: original[0].id))
        XCTAssertEqual(queue.entries, original)
        XCTAssertEqual(LiveTransactionOutbox(fileURL: retained.appendingPathComponent("queue.json")).entries, original)
    }

    @MainActor
    func testLiveOutboxUnreadableQueueIsPreservedAndCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("queue.json")
        let original = Data("unreadable saved queue".utf8)
        try original.write(to: file)
        let queue = LiveTransactionOutbox(fileURL: file)
        XCTAssertNotNil(queue.loadErrorMessage)
        let operation = RecordTransactionOperation(accountID: "a", categoryID: nil, amountMinor: 100,
            occurredOn: "2026-10-09", payeeName: "Offline", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        XCTAssertThrowsError(try queue.enqueue(operation))
        XCTAssertThrowsError(try queue.remove(id: operation.clientOperationID!))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(queue.entries.isEmpty)
    }

    @MainActor
    func testLiveOutboxRejectsChangedPayloadForExistingIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let queue = LiveTransactionOutbox(fileURL: file)
        let first = RecordTransactionOperation(accountID: "a", categoryID: nil, amountMinor: 100,
            occurredOn: "2026-10-09", payeeName: "Offline", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        try queue.enqueue(first)
        let changed = RecordTransactionOperation(accountID: "a", categoryID: nil, amountMinor: 100,
            occurredOn: "2026-10-09", payeeName: "Offline", memo: "Different intent", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [], clientOperationID: first.clientOperationID)
        XCTAssertThrowsError(try queue.enqueue(changed))
        XCTAssertEqual(queue.entries.first?.operation, first)
        XCTAssertEqual(LiveTransactionOutbox(fileURL: file).entries, queue.entries)
        let duplicate = try JSONEncoder().encode(queue.entries + queue.entries)
        try duplicate.write(to: file)
        let invalid = LiveTransactionOutbox(fileURL: file)
        XCTAssertNotNil(invalid.loadErrorMessage)
        XCTAssertThrowsError(try invalid.enqueue(first))
        XCTAssertEqual(try Data(contentsOf: file), duplicate)
    }

    @MainActor
    func testLiveOutboxReplayClaimBlocksDiscardAndPreservesNewEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let queue = LiveTransactionOutbox(fileURL: file)
        let first = RecordTransactionOperation(accountID: "a", categoryID: nil, amountMinor: 100,
            occurredOn: "2026-10-09", payeeName: "Offline", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        try queue.enqueue(first)
        XCTAssertThrowsError(try queue.acknowledgeReplay(id: first.clientOperationID!))
        XCTAssertTrue(try queue.beginReplay())
        XCTAssertFalse(try queue.beginReplay(), "A second refresh cannot claim the same replay")
        XCTAssertThrowsError(try queue.remove(id: first.clientOperationID!))
        XCTAssertEqual(queue.count, 1)
        var second = first; second.clientOperationID = UUID().uuidString
        try queue.enqueue(second)
        XCTAssertEqual(queue.count, 2)
        try queue.acknowledgeReplay(id: first.clientOperationID!)
        XCTAssertEqual(queue.entries.map(\.id), [second.clientOperationID!])
        XCTAssertThrowsError(try queue.remove(id: second.clientOperationID!))
        queue.finishReplay()
        XCTAssertFalse(queue.isReplaying)
        XCTAssertEqual(LiveTransactionOutbox(fileURL: file).entries, queue.entries)
        try queue.remove(id: second.clientOperationID!)
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(try queue.beginReplay(), "Completion releases the replay claim")
        queue.finishReplay()
    }

    @MainActor
    func testStaleOutboxOwnerCannotOverwriteOrAcknowledgeNewerQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-owners-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let stale = LiveTransactionOutbox(fileURL: file)
        let current = LiveTransactionOutbox(fileURL: file)
        let first = RecordTransactionOperation(accountID: "a", categoryID: "c", amountMinor: -1,
            occurredOn: "2026-10-09", payeeName: "First", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        var second = first; second.clientOperationID = UUID().uuidString
        try current.enqueue(first)
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try stale.enqueue(second))
        XCTAssertThrowsError(try stale.beginReplay())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        do {
            try await current.replay { _ in try LiveTransactionOutbox(fileURL: file).enqueue(second) }
            XCTFail("Stale acknowledgement must not erase another owner's saved changes")
        } catch {}
        XCTAssertFalse(current.isReplaying)
        let reopened = LiveTransactionOutbox(fileURL: file)
        XCTAssertEqual(reopened.entries.map(\.operation), [first, second])
        try await reopened.replay { _ in }
        XCTAssertEqual(LiveTransactionOutbox(fileURL: file).count, 0)
    }

    @MainActor
    func testOutboxSubmissionIsDurableBeforeFirstSendAndRetainsUncertainIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-submit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let queue = LiveTransactionOutbox(fileURL: file)
        let operation = RecordTransactionOperation(accountID: "a", categoryID: "c", amountMinor: -9007199254740993,
            occurredOn: "2026-10-09", payeeName: "Durable", memo: "Preserve", isCleared: false,
            splits: [], flag: "orange", tags: ["qa"], attachmentMetadata: [], clientOperationID: UUID().uuidString)
        var attempts = 0
        do {
            try await queue.submit(operation) { sent in
                attempts += 1
                XCTAssertEqual(LiveTransactionOutbox(fileURL: file).entries.first?.operation, sent)
                throw URLError(.timedOut)
            }
            XCTFail("Expected uncertain send")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(attempts, 1)
        let reopened = LiveTransactionOutbox(fileURL: file)
        XCTAssertEqual(reopened.entries.first?.operation, operation)
        try await reopened.replay { sent in XCTAssertEqual(sent, operation) }
        XCTAssertEqual(LiveTransactionOutbox(fileURL: file).count, 0)
    }

    @MainActor
    func testReviewedDuplicateSurvivesRelaunchWithoutPostingLocally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let command = DuplicateTransactionOperation(transactionID: "original", occurredOn: "2026-10-09",
            expectedRevision: "v1:" + String(repeating: "d", count: 64), mutationOperationID: UUID().uuidString.lowercased())
        let queue = LiveTransactionOutbox(fileURL: file)
        try queue.enqueueDuplicate(command)
        do { try await queue.replayCommands(shouldPause: { _ in false }) { _ in throw URLError(.networkConnectionLost) }; XCTFail("Expected lost response") } catch {}
        let reopened = LiveTransactionOutbox(fileURL: file)
        XCTAssertEqual(reopened.entries.first?.duplicateCommand, command)
        XCTAssertNil(reopened.entries.first?.operation, "No locally synthesized ledger posting")
        try await reopened.replayCommands { entry in XCTAssertEqual(entry.duplicateCommand, command) }
        XCTAssertEqual(LiveTransactionOutbox(fileURL: file).count, 0)
    }

    @MainActor
    func testLiveAttachmentListsSurviveReconstructionButNeverFallbackAfterDenial() async throws {
        let budget = APIBudget(id: UUID().uuidString, householdID: "h1", name: "Cache test", currencyCode: "USD", accessRevision: "a")
        let server = URL(string: "https://attachment-cache.example.com")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        func workspace() -> BudgetWorkspaceStore {
            BudgetWorkspaceStore.production(context: .live(budget: budget, serverURL: server, token: "A1"),
                clientFactory: { try APIClient(baseURL: $0, session: session) })
        }
        let original = workspace()
        RefreshMockURLProtocol.handler = { _ in
            Self.json(200, "[{\"id\":\"receipt\",\"transaction_id\":\"posted\",\"filename\":\"receipt.pdf\",\"content_type\":\"application/pdf\",\"byte_count\":10,\"sha256\":\"\(String(repeating: "a", count: 64))\",\"created_at\":\"2026-10-09T00:00:00Z\"}]")
        }
        let accepted = try await original.transactionAttachments(id: "posted")
        XCTAssertEqual(accepted.count, 1)
        let reopened = workspace()
        RefreshMockURLProtocol.handler = { _ in Self.json(503, "{\"detail\":\"Offline test\"}") }
        let cached = try await reopened.transactionAttachments(id: "posted")
        XCTAssertEqual(cached, accepted)
        RefreshMockURLProtocol.handler = { _ in Self.json(403, "{\"detail\":\"Access revoked\"}") }
        do { _ = try await reopened.transactionAttachments(id: "posted"); XCTFail("Access denial used cached metadata") }
        catch { }
        RefreshMockURLProtocol.handler = { _ in Self.json(503, "{\"detail\":\"Offline test\"}") }
        do { _ = try await reopened.transactionAttachments(id: "posted"); XCTFail("Denied metadata remained available") }
        catch { }
        _ = reopened.updateLiveBudgetAuthority(APIBudget(id: budget.id, householdID: "h1", name: "Cache test",
            currencyCode: "USD", accessRevision: "b"))
    }

    @MainActor
    func testLiveWorkspaceReadCacheSurvivesRelaunchWithoutInventingAuthority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LiveWorkspaceReadCache(fileURL: directory.appendingPathComponent("cache.json"))
        let snapshot = WorkspaceSnapshot(
            accounts: [], accountBalances: [:], categories: [], groups: [], transactions: [],
            summary: nil, requests: [], allowances: [], spending: nil, spendingTrends: nil,
            income: nil, netWorth: nil, debt: nil, planPerformance: nil, resilience: nil,
            delegated: nil, forecast: nil, members: [], delegatedBudgets: []
        )
        try cache.save(snapshot)
        let reopened = try LiveWorkspaceReadCache(fileURL: directory.appendingPathComponent("cache.json")).load()
        XCTAssertTrue(reopened.accounts.isEmpty)
        XCTAssertTrue(reopened.transactions.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(reopened.savedAt), 5)
        let revised = LiveWorkspaceReadCache(fileURL: directory.appendingPathComponent("cache.json"), accessRevision: "scope-a")
        XCTAssertThrowsError(try revised.load(), "Legacy cache cannot establish current revision authority")
        try revised.save(snapshot)
        XCTAssertEqual(try revised.load().accessRevision, "scope-a")
        XCTAssertNoThrow(try LiveWorkspaceReadCache(fileURL: directory.appendingPathComponent("cache.json"), accessRevision: "scope-a").load())
        XCTAssertThrowsError(try LiveWorkspaceReadCache(fileURL: directory.appendingPathComponent("cache.json"), accessRevision: "scope-b").load())
        revised.updateAccessRevision("scope-b")
        XCTAssertThrowsError(try revised.load(), "Even failed disk eviction must not expose earlier-scope data")
        try revised.save(snapshot)
        XCTAssertEqual(try revised.load().accessRevision, "scope-b")
        try revised.save(snapshot, planMonth: "2026-09-01")
        try revised.save(snapshot, planMonth: "2026-10-01")
        XCTAssertEqual(try revised.load(planMonth: "2026-09-01").planMonth, "2026-09-01")
        XCTAssertEqual(try revised.load(planMonth: "2026-10-01").planMonth, "2026-10-01")
        XCTAssertThrowsError(try revised.load(planMonth: "2026-11-01"), "Never substitute another month's plan")
        XCTAssertThrowsError(try revised.load(planMonth: "../../private"))
        XCTAssertThrowsError(try revised.save(snapshot, planMonth: "2026-13-01"))
        revised.updateAccessRevision("scope-c")
        XCTAssertThrowsError(try revised.load(planMonth: "2026-09-01"))
        revised.remove()
        XCTAssertThrowsError(try revised.load())
        XCTAssertThrowsError(try revised.load(planMonth: "2026-10-01"))
    }

    func testLiveReadNamespaceSeparatesServersButSurvivesCredentialRotation() throws {
        func token(_ subject: String, signature: String) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: ["sub": subject]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "header.\(payload).\(signature)"
        }
        let first = try token("member", signature: "old")
        let rotated = try token("member", signature: "new")
        let other = try token("another-member", signature: "new")
        let url = try XCTUnwrap(URL(string: "https://server.example/family"))
        let expected = liveServerStorageScope(budgetID: "budget", serverURL: url, token: first)
        XCTAssertEqual(expected.count, 64)
        XCTAssertEqual(expected, liveServerStorageScope(budgetID: "budget", serverURL: url, token: rotated))
        XCTAssertEqual(expected, liveServerStorageScope(budgetID: "budget", serverURL: try XCTUnwrap(URL(string: "https://SERVER.example:443/family/")), token: rotated))
        for address in ["https://server.example/friends", "http://server.example/family", "https://server.example:8443/family"] {
            XCTAssertNotEqual(expected, liveServerStorageScope(budgetID: "budget", serverURL: try XCTUnwrap(URL(string: address)), token: first))
        }
        XCTAssertNotEqual(expected, liveServerStorageScope(budgetID: "budget", serverURL: url, token: other))
        XCTAssertNotEqual(expected, liveServerStorageScope(budgetID: "another-budget", serverURL: url, token: first))
    }

    @MainActor
    func testCachedAuthorizedBudgetKeepsWorkspaceRouteDuringColdOfflineLaunch() async {
        let suite = "CachedLiveRoute.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://budget.example.com", forKey: "budget.serverURL")
        defaults.set("liveServer", forKey: "budget.dataSourceMode")
        defaults.set("b1", forKey: "budget.activeBudgetID")
        defaults.set(Data(#"[{"id":"b1","household_id":"h1","name":"Home","currency_code":"USD","effective_permission":"owner","allocation_version":0}]"#.utf8), forKey: "budget.authorizedBudgetCache")
        let token = Self.jwt(expiration: Date().timeIntervalSince1970 + 3_600)
        RefreshMockURLProtocol.handler = { _ in Self.json(503, #"{"detail":"offline"}"#) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let session = AppSession(
            defaults: defaults,
            keychain: InMemoryTokenStore(["access-token": token, "refresh-token": "refresh"]),
            clientFactory: { try APIClient(baseURL: $0, session: URLSession(configuration: configuration)) }
        )

        guard case .workspace(.live) = session.route else {
            return XCTFail("The saved authorized workspace must render before reachability completes")
        }
        await session.activate(caller: "offline-cold-launch-test")
        guard case .workspace(.live) = session.route else {
            return XCTFail("A transient outage must not replace the workspace route")
        }
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

private final class CredentialRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String)] = []
    func append(path: String, authorization: String) {
        lock.lock(); entries.append((path, authorization)); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.0) }
    var authorizations: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.1) }
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
