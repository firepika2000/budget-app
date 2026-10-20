import XCTest
import SwiftUI
import UIKit
import BudgetAPI
import BudgetCore
import BudgetStorage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import UserNotifications
@testable import Budget_App

final class DemoStoreTests: XCTestCase {
    func testEditingSaveHandlersClaimSubmissionBeforeFirstSuspension() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp")
        let editor = try String(contentsOf: directory.appendingPathComponent("EditingViews.swift"))
        let handlers = editor.components(separatedBy: "private func save() async {").dropFirst()
        XCTAssertEqual(handlers.count, 8)
        for handler in handlers {
            let prefix = String(handler.prefix(350))
            let guardPosition = try XCTUnwrap(prefix.range(of: "!isSaving"))
            let claimPosition = try XCTUnwrap(prefix.range(of: "isSaving = true"))
            XCTAssertLessThan(guardPosition.lowerBound, claimPosition.lowerBound)
            if let suspension = prefix.range(of: "await ") { XCTAssertLessThan(claimPosition.lowerBound, suspension.lowerBound) }
            XCTAssertTrue(prefix.contains("defer { isSaving = false }"))
        }
        let source = try String(contentsOf: directory.appendingPathComponent("BudgetWorkspaceView.swift"))
        let start = try XCTUnwrap(source.range(of: "private struct AllowanceCreateView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct HouseholdMemberLifecycleView: View"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("@State private var initialized = false"))
        XCTAssertTrue(view.contains("guard !initialized else { return }"))
        XCTAssertTrue(view.contains("guard !isSaving, let parsed else"))
    }
    @MainActor
    func testHistoryRefreshRetainsDepthAndStopsAtShortOrEmptyPage() async throws {
        struct Row: Identifiable, Sendable { let id: Int }
        var offsets: [Int] = []
        let rows = try await HistoryRefreshReader.read(retainingCount: 5, pageSize: 2) { limit, offset in
            XCTAssertEqual(limit, 2); offsets.append(offset)
            return (offset..<min(offset + 2, 5)).map { Row(id: $0) }
        }
        XCTAssertEqual(offsets, [0, 2, 4]); XCTAssertEqual(rows.map(\.id), [0, 1, 2, 3, 4])
        let empty: [Row] = try await HistoryRefreshReader.read(retainingCount: 100, pageSize: 50) { _, offset in
            XCTAssertEqual(offset, 0); return []
        }
        XCTAssertTrue(empty.isEmpty)
        var clamped = 0
        let _: [Row] = try await HistoryRefreshReader.read(retainingCount: 0, pageSize: 1000) { limit, _ in
            clamped = limit; return []
        }
        XCTAssertEqual(clamped, 100)
    }

    @MainActor
    func testHistoryRefreshRejectsOverlapFailureAndCancellationWithoutPartialReturn() async throws {
        struct Row: Identifiable, Sendable { let id: Int }
        do {
            let _: [Row] = try await HistoryRefreshReader.read(retainingCount: 3, pageSize: 2) { _, offset in
                offset == 0 ? [Row(id: 1), Row(id: 2)] : [Row(id: 2)]
            }
            XCTFail("Overlapping authoritative pages must not publish")
        } catch { XCTAssertEqual((error as NSError).domain, "HistoryRefresh") }
        do {
            let _: [Row] = try await HistoryRefreshReader.read(retainingCount: 3, pageSize: 2) { _, offset in
                if offset > 0 { throw URLError(.timedOut) }; return [Row(id: 1), Row(id: 2)]
            }
            XCTFail("A failed later page must not return a partial replacement")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        do {
            let _: [Row] = try await HistoryRefreshReader.read(retainingCount: 3, pageSize: 2) { _, _ in throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor
    func testReportFilterDraftOnlyChangesCanonicalSelectionOnApply() async throws {
        let store = BudgetWorkspaceStore.demo(); await store.refresh()
        let original = store.reportFilters, context = store.reportContext
        let summary = store.summary, transactions = store.transactions
        var draft = original
        draft.accountID = "checking"; draft.categoryID = "groceries"; draft.categoryGroup = "Essentials"
        draft.payee = "Existing payee"; draft.memberID = "rey"; draft.transactionType = "spending"
        draft.cleared = "cleared"; draft.flag = "orange"; draft.tag = "qa"; draft.includeTracking = true
        XCTAssertTrue(draft.isActive); XCTAssertEqual(store.reportFilters, original); XCTAssertEqual(store.reportContext, context)
        store.applyReportFilters(draft)
        XCTAssertEqual(store.reportFilters, draft); XCTAssertNotEqual(store.reportContext, context)
        draft = .init()
        XCTAssertFalse(draft.isActive); XCTAssertTrue(store.reportFilters.isActive, "Reset is draft-only until Apply")
        store.applyReportFilters(draft)
        XCTAssertEqual(store.reportFilters, original); XCTAssertEqual(store.summary, summary)
        XCTAssertEqual(store.transactions, transactions)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct ReportFilterEditor: View"))
        let end = try XCTUnwrap(source.range(of: "private struct ReportPeriodControls: View"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(view.contains("selection: $store.")); XCTAssertFalse(view.contains("text: $store."))
        XCTAssertTrue(view.contains("guard authority == store.authorityRevision"))
        XCTAssertTrue(view.contains("PayeeSearchSelectionView")); XCTAssertTrue(view.contains("store.applyReportFilters(draft)"))
    }
    func testReportDateDraftPreservesPendingDatesAndValidatesBeforeApply() throws {
        let start = BudgetWorkspaceStore.parseDate("2026-09-01"), end = BudgetWorkspaceStore.parseDate("2026-09-30")
        var draft = ReportDateRangeDraft()
        draft.prepare(scope: "owner|budget", start: start, end: end)
        draft.start = BudgetWorkspaceStore.parseDate("2026-08-01")
        draft.prepare(scope: "owner|budget", start: start, end: end)
        XCTAssertEqual(draft.start, BudgetWorkspaceStore.parseDate("2026-08-01")); XCTAssertTrue(draft.hasChanges)
        draft.end = BudgetWorkspaceStore.parseDate("2026-07-31")
        XCTAssertFalse(draft.isValid); XCTAssertNil(draft.apply())
        draft.end = draft.start
        let applied = try XCTUnwrap(draft.apply())
        XCTAssertEqual(applied.start, applied.end); XCTAssertFalse(draft.hasChanges)
        draft.prepare(scope: "owner|budget", start: start, end: end)
        XCTAssertEqual(draft.start, start, "Pristine drafts follow externally applied ranges")
        draft.start = BudgetWorkspaceStore.parseDate("2026-07-01")
        draft.prepare(scope: "other-owner|budget", start: start, end: end)
        XCTAssertEqual(draft.start, start); XCTAssertFalse(draft.hasChanges)
    }

    @MainActor
    func testReportDateDraftDoesNotMutateReportUntilExplicitApply() async throws {
        let store = BudgetWorkspaceStore.demo(); await store.refresh()
        let original = store.customReportStart
        var draft = ReportDateRangeDraft()
        draft.prepare(scope: "owner|budget", start: original, end: store.customReportEnd)
        draft.start = BudgetWorkspaceStore.parseDate("2026-01-01")
        XCTAssertEqual(store.customReportStart, original)
        draft.prepare(scope: "owner|budget", start: store.customReportStart, end: store.customReportEnd, replacing: true)
        XCTAssertEqual(draft.start, original); XCTAssertFalse(draft.hasChanges)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct ReportPeriodControls: View"))
        let end = try XCTUnwrap(source.range(of: "private struct SpendingIncomeReportView: View"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("ReportDateRangeDraft()")); XCTAssertTrue(view.contains("guard let range = draft.apply()"))
        XCTAssertTrue(view.contains("report-range-validation")); XCTAssertTrue(view.contains("reset-report-range"))
    }
    private func directoryProfile(_ id: String, version: Int = 1) throws -> APIAccessProfile {
        try JSONDecoder().decode(APIAccessProfile.self, from: Data("""
        {"budget_id":"budget","user_id":"\(id)","capabilities":["view_budget"],"restrict_accounts":false,"account_ids":[],"restrict_categories":false,"category_ids":[],"grant_permission":"view","is_custom":false,"version":\(version)}
        """.utf8))
    }

    @MainActor
    func testHouseholdDirectoryBoundsRequestsAndRecoversPartialFailures() async throws {
        let directory = HouseholdDirectoryObservation()
        directory.prepare(scope: "owner|budget")
        var active = 0, maximum = 0, calls: [String] = []
        let profiles = try Dictionary(uniqueKeysWithValues: (0..<9).map { (String($0), try directoryProfile(String($0))) })
        await directory.load(memberIDs: Array(profiles.keys) + ["0"], invitations: { [] }) { id in
            active += 1; maximum = max(maximum, active); calls.append(id)
            await Task.yield(); active -= 1
            return try XCTUnwrap(profiles[id])
        }
        XCTAssertEqual(calls.count, 9); XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertEqual(directory.profiles.count, 9); XCTAssertFalse(directory.loading)
        await directory.load(memberIDs: ["0", "1"], invitations: { throw URLError(.timedOut) }) { id in
            if id == "0" { throw URLError(.notConnectedToInternet) }
            throw APIClientError.server(status: 403, message: "Denied")
        }
        XCTAssertEqual(Set(directory.profiles.keys), ["0"])
        XCTAssertEqual(directory.failedMembers, ["0", "1"]); XCTAssertNotNil(directory.invitationError)
        await directory.load(memberIDs: ["0", "1"], invitations: { [] }) { id in try XCTUnwrap(profiles[id]) }
        XCTAssertEqual(directory.profiles.count, 2); XCTAssertTrue(directory.failedMembers.isEmpty)
        XCTAssertNil(directory.invitationError)
    }

    @MainActor
    func testHouseholdDirectoryDoesNotOverwriteSavedProfileOrChangedScope() async throws {
        let old = try directoryProfile("member"), saved = try directoryProfile("member", version: 2)
        let directory = HouseholdDirectoryObservation()
        directory.prepare(scope: "owner|budget")
        await directory.load(memberIDs: ["member"], invitations: { [] }) { _ in
            directory.record(saved); return old
        }
        XCTAssertEqual(directory.profiles["member"]?.version, 2)
        await directory.load(memberIDs: ["member"], invitations: { [] }) { _ in
            directory.prepare(scope: "different-owner|budget"); return old
        }
        XCTAssertTrue(directory.profiles.isEmpty); XCTAssertFalse(directory.loading)
        await directory.load(memberIDs: ["different-member"], invitations: { [] }) { _ in old }
        XCTAssertTrue(directory.profiles.isEmpty); XCTAssertEqual(directory.failedMembers, ["different-member"])
    }
    @MainActor
    func testMemberAccessReadRetryScopeAndDenial() async throws {
        let profile = try JSONDecoder().decode(APIAccessProfile.self, from: Data(#"{"budget_id":"budget","user_id":"member","capabilities":["view_budget"],"restrict_accounts":false,"account_ids":[],"restrict_categories":false,"category_ids":[],"grant_permission":"view","is_custom":false,"version":4}"#.utf8))
        let observation = MemberAccessProfileObservation()
        observation.prepare(scope: "owner|budget|member")
        let failed = await observation.load { throw URLError(.timedOut) }
        XCTAssertNil(failed); XCTAssertNil(observation.value); XCTAssertNotNil(observation.errorMessage)
        let retried = await observation.load { profile }
        XCTAssertEqual(retried, profile); XCTAssertEqual(observation.value?.version, 4)
        XCTAssertNil(observation.errorMessage); XCTAssertFalse(observation.loading)
        _ = await observation.load { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(observation.value, profile, "Transient failure retains reviewed version and draft")
        _ = await observation.load {
            observation.prepare(scope: "other-owner|budget|member"); return profile
        }
        XCTAssertNil(observation.value, "Late result must not repopulate a changed authority scope")
        _ = await observation.load { profile }
        observation.reject(APIClientError.server(status: 403, message: "Denied"))
        XCTAssertNil(observation.value)
        _ = await observation.load { profile }
        _ = await observation.load { observation.invalidate(); return profile }
        XCTAssertFalse(observation.loading); XCTAssertEqual(observation.value, profile)
    }

    func testMemberAccessProductionRetryAndSaveUseScopedObservation() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveMemberAccessView: View"))
        let end = try XCTUnwrap(source.range(of: "struct LiveDelegatedPolicyView: View"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("MemberAccessProfileObservation()"))
        XCTAssertTrue(view.contains("member-access-retry"))
        XCTAssertTrue(view.contains(".task(id: accessScope)"))
        XCTAssertTrue(view.contains("guard !isSaving, !isLoading, let profile else"))
        XCTAssertTrue(view.contains("expectedVersion: profile.version"))
        XCTAssertTrue(view.contains("Button(\"Reload Latest\")"))
        XCTAssertTrue(view.contains("observation.reject(error)"))
    }
    func testDelegatedEditorPreservesDraftRulesAndReviewedVersionAcrossReappearance() throws {
        let policy = try JSONDecoder().decode(APIDelegatedBudget.self, from: Data(#"{"id":"policy","budget_id":"budget","user_id":"member","pool_category_id":"pool","authority_minor":9007199254740993,"assigned_minor":0,"available_to_assign_minor":9007199254740993,"allow_category_creation":false,"allow_reallocation":true,"rules":[{"id":"rule","category_id":"private-category","rule_kind":"hard_limit","minimum_minor":1,"maximum_minor":12345}]}"#.utf8))
        var draft = DelegatedPolicyEditorDraft()
        draft.prepare(scope: "owner|budget|member", policy: policy, fallbackCategoryID: nil,
                      currencyCode: "USD", allocationVersion: 7)
        XCTAssertEqual(try XCTUnwrap(draft.mutation(userID: "member", currencyCode: "USD")).authorityMinor, 9_007_199_254_740_993)
        draft.authority = "23.45"; draft.allowCreation = true; draft.allowReallocation = false
        draft.prepare(scope: "owner|budget|member", policy: policy, fallbackCategoryID: nil,
                      currencyCode: "USD", allocationVersion: 8)
        let value = try XCTUnwrap(draft.mutation(userID: "member", currencyCode: "USD"))
        XCTAssertEqual(value.authorityMinor, 2345); XCTAssertEqual(value.expectedAllocationVersion, 7)
        XCTAssertTrue(value.allowCategoryCreation); XCTAssertFalse(value.allowReallocation)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        let rules = try XCTUnwrap(json["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1); XCTAssertEqual(rules[0]["category_id"] as? String, "private-category")
        XCTAssertEqual(rules[0]["maximum_minor"] as? Int, 12345)
        draft.prepare(scope: "owner|budget|member", policy: policy, fallbackCategoryID: nil,
                      currencyCode: "USD", allocationVersion: 9, replacing: true)
        XCTAssertEqual(draft.expectedAllocationVersion, 9); XCTAssertFalse(draft.allowCreation)
        draft.prepare(scope: "other-owner|budget|member", policy: nil, fallbackCategoryID: "other-pool",
                      currencyCode: "USD", allocationVersion: 10)
        XCTAssertEqual(draft.poolCategoryID, "other-pool"); XCTAssertTrue(draft.rules.isEmpty)
        XCTAssertEqual(draft.authority, "0.00")
    }

    func testDelegatedEditorRejectsMissingVersionInvalidAndNegativeMoney() throws {
        var draft = DelegatedPolicyEditorDraft()
        draft.prepare(scope: "owner", policy: nil, fallbackCategoryID: "pool", currencyCode: "USD", allocationVersion: nil)
        XCTAssertNil(draft.mutation(userID: "member", currencyCode: "USD"))
        draft.prepare(scope: "owner", policy: nil, fallbackCategoryID: "pool", currencyCode: "USD", allocationVersion: 1, replacing: true)
        XCTAssertEqual(draft.mutation(userID: "member", currencyCode: "USD")?.authorityMinor, 0)
        draft.authority = "-1.00"; XCTAssertNil(draft.mutation(userID: "member", currencyCode: "USD"))
        draft.authority = "not money"; XCTAssertNil(draft.mutation(userID: "member", currencyCode: "USD"))
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "struct LiveDelegatedPolicyView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct DelegatedPolicyHistoryView:"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("@State private var draft = DelegatedPolicyEditorDraft()"))
        XCTAssertTrue(view.contains(".onAppear { prepareDraft() }"))
        XCTAssertTrue(view.contains("guard !isSaving, let mutation else"))
        XCTAssertFalse(view.contains("APIDelegatedBudgetUpsert("))
    }
    @MainActor
    func testHouseholdAccessHistoryRefreshDepthDenialAndLateResponse() async throws {
        func event(_ id: String) throws -> APIHouseholdAccessEvent {
            try JSONDecoder().decode(APIHouseholdAccessEvent.self, from: Data("""
            {"id":"\(id)","event_type":"member_removed","actor_display_name":"Owner","created_at":"2026-10-20"}
            """.utf8))
        }
        let first = try event("first"), second = try event("second")
        let pager = DecisionHistoryPager<APIHouseholdAccessEvent>(pageSize: 1)
        pager.prepare(scope: "owner|household")
        await pager.load(reset: true) { _, _ in [first] }
        await pager.load(reset: false) { _, offset in XCTAssertEqual(offset, 1); return [second] }
        var offsets: [Int] = []
        await pager.load(reset: true) { _, offset in
            offsets.append(offset); return offset == 0 ? [first] : [second]
        }
        XCTAssertEqual(offsets, [0, 1]); XCTAssertEqual(pager.rows.map(\.id), ["first", "second"])
        await pager.load(reset: false) { _, _ in throw URLError(.timedOut) }
        XCTAssertEqual(pager.retryIntent, .older); XCTAssertEqual(pager.rows.count, 2)
        await pager.load(reset: false) { _, _ in throw APIClientError.server(status: 403, message: "Denied") }
        XCTAssertTrue(pager.rows.isEmpty)
        await pager.load(reset: true) { _, _ in
            pager.prepare(scope: "another-member|household"); return [first]
        }
        XCTAssertTrue(pager.rows.isEmpty)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct HouseholdMemberLifecycleView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct HouseholdInvitationDraft:"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("DecisionHistoryPager<APIHouseholdAccessEvent>(pageSize: 50)"))
        XCTAssertTrue(view.contains(".task(id: historyContext)"))
        XCTAssertTrue(view.contains(".onDisappear { requestID = UUID(); history.invalidate() }"))
        XCTAssertTrue(view.contains("historyScope == scope"))
    }
    @MainActor
    func testWhatIfScenarioRebasesAfterScheduleRefreshWithoutChangingMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let balances = store.accountBalances, transactions = store.transactions, ready = store.summary?.readyToAssignMinor
        let assumptions = ForecastScenarioAssumptions(monthlyIncomeChangeMinor: -1_000,
            monthlyCostChangeMinor: 200, activeMonths: 12, majorPurchaseMinor: 300)
        let observation = ForecastObservation()
        observation.prepare(scope: "owner|budget|365")
        await observation.load { try await store.forecastObservation(days: 365) }
        let before = try ForecastScenarioCalculator.project(
            baselineProjectedMinor: XCTUnwrap(observation.value).projectedTotalOnBudgetMinor,
            currencyCode: "USD", assumptions: assumptions)
        try await store.createSchedule(.init(accountID: account.id, categoryID: nil, name: "Future-only scenario income",
            amountMinor: 5_000, nextDate: "2027-03-15", recurrenceUnit: "once", memo: ""))
        observation.prepare(scope: "owner|budget|365")
        await observation.load { try await store.forecastObservation(days: 365) }
        let after = try ForecastScenarioCalculator.project(
            baselineProjectedMinor: XCTUnwrap(observation.value).projectedTotalOnBudgetMinor,
            currencyCode: "USD", assumptions: assumptions)
        XCTAssertEqual(after.scenarioProjectedMinor - before.scenarioProjectedMinor, 5_000)
        XCTAssertEqual(after.differenceMinor, before.differenceMinor)
        XCTAssertEqual(store.accountBalances, balances); XCTAssertEqual(store.transactions, transactions)
        XCTAssertEqual(store.summary?.readyToAssignMinor, ready)
    }

    func testProductionWhatIfScenarioObservesBaselineAndPreservesOrdinaryDrafts() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct ForecastScenarioView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct LiveRequestsView: View"))
        let view = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(view.contains("let forecast: APIForecast"))
        XCTAssertFalse(view.contains(".onAppear { activeMonths"))
        XCTAssertTrue(view.contains("_activeMonths = State(initialValue:"))
        XCTAssertTrue(view.contains(".task(id: forecastContext)")); XCTAssertTrue(view.contains("store.reportRevision"))
        XCTAssertTrue(view.contains("observation.currentValue(scope: forecastScope)"))
        XCTAssertTrue(view.contains(".onChange(of: store.authorityRevision)"))
        XCTAssertTrue(view.contains("Retry Baseline"))
    }

    @MainActor
    func testForecastObservationKeepsOnlyCurrentPeriodAndRejectsSupersededResponses() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let short = try await store.forecastObservation(days: 30)
        let annual = try await store.forecastObservation(days: 365)
        let observation = ForecastObservation()
        observation.prepare(scope: "owner|budget|30")
        await observation.load { short }
        XCTAssertNil(observation.currentValue(scope: "owner|budget|365"), "A changed picker must not expose the old period even before its task runs")
        await observation.load { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(observation.value, short); XCTAssertNotNil(observation.errorMessage)
        observation.prepare(scope: "owner|budget|365")
        XCTAssertNil(observation.value, "A new period must not display the previous period's numbers")
        await observation.load {
            observation.prepare(scope: "current|budget|365")
            await observation.load { annual }
            return short
        }
        XCTAssertEqual(observation.value, annual); XCTAssertFalse(observation.loading)
        await observation.load { throw APIClientError.server(status: 403, message: "Denied") }
        XCTAssertNil(observation.value)
    }

    @MainActor
    func testForecastReadRejectsResultFromBeforeWorkspaceRefresh() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let original = try XCTUnwrap(store.forecast)
        do {
            _ = try await store.forecastObservation(days: 365, fetch: { days in
                XCTAssertEqual(days, 365)
                await store.refresh()
                return original
            })
            XCTFail("An earlier workspace observation must not become the current forecast")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.forecast, original)
    }

    func testProductionForecastOwnsHorizonAndObservesWorkspaceRevision() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveForecastView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct ForecastScenarioView: View"))
        let view = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(view.contains("if let forecast = displayedForecast"))
        XCTAssertTrue(view.contains("observation.currentValue(scope: forecastScope)"))
        XCTAssertFalse(view.contains("store.forecast {"))
        XCTAssertTrue(view.contains("store.reportRevision")); XCTAssertTrue(view.contains("store.authorityRevision"))
        XCTAssertTrue(view.contains(".task(id: forecastContext)")); XCTAssertTrue(view.contains("Retry Forecast"))
        XCTAssertFalse(source.contains("func loadForecast(days:"))
    }

    @MainActor
    func testStatementHeaderCacheSurvivesNavigationWithoutResettingUserMapping() async {
        let observation = StatementHeaderObservation()
        var reads = 0, mapping = ""
        let initial = await observation.load(scope: "file-a|;") { reads += 1; return ["Posted", "Amount", "Merchant"] }
        if initial { mapping = "Automatic selection" }
        mapping = "User-selected date column"
        observation.cancel() // A column-selection destination temporarily hides the form.
        let rediscovered = await observation.load(scope: "file-a|;") {
            XCTFail("Returning to unchanged input must reuse its completed header read")
            return []
        }
        if rediscovered { mapping = "Automatic selection" }
        XCTAssertEqual(mapping, "User-selected date column")
        XCTAssertEqual(observation.headers, ["Posted", "Amount", "Merchant"])
        XCTAssertEqual(reads, 1); XCTAssertFalse(observation.loading)
        let newFile = await observation.load(scope: "file-b|;") { reads += 1; return ["New date"] }
        XCTAssertTrue(newFile); XCTAssertEqual(observation.headers, ["New date"])
        observation.invalidate() // Revocation must still discard the completed observation.
        XCTAssertTrue(observation.headers.isEmpty)
        let afterInvalidation = await observation.load(scope: "file-b|;") { reads += 1; return ["Authorized date"] }
        XCTAssertTrue(afterInvalidation); XCTAssertEqual(reads, 3)
    }

    func testStatementHeaderDiscoveryStopsAtFirstRecordButPreviewStillRejectsInvalidTail() throws {
        let rows = (0..<10_000).map { "2026-09-15,-1.23,Merchant \($0)" }
        let data = Data((["Date,Amount,Payee"] + rows + ["\"unfinished private value"]).joined(separator: "\n").utf8)
        XCTAssertEqual(LocalDelimitedStatementParser.headers(data: data, delimiter: ","), ["Date", "Amount", "Payee"])
        XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(data: data, mapping: .init(
            sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount",
            payeeColumn: "Payee", dateOrder: "ymd")))
        let quoted = Data("\n\"Posted\nDate\",\"Amount\",\"Payee\"\r\nignored".utf8)
        XCTAssertEqual(LocalDelimitedStatementParser.headers(data: quoted, delimiter: ","), ["Posted\nDate", "Amount", "Payee"])
    }

    @MainActor
    func testStatementHeaderObservationRejectsSupersededAndInvalidatedResults() async {
        let observation = StatementHeaderObservation()
        await observation.load(scope: "old") { ["Old"] }
        XCTAssertEqual(observation.headers, ["Old"])
        await observation.load(scope: "pending") {
            XCTAssertTrue(observation.headers.isEmpty); XCTAssertTrue(observation.loading)
            await observation.load(scope: "new") { ["New"] }
            return ["Stale"]
        }
        XCTAssertEqual(observation.headers, ["New"]); XCTAssertFalse(observation.loading)
        await observation.load(scope: "invalidated") { observation.invalidate(); return ["Revoked"] }
        XCTAssertTrue(observation.headers.isEmpty); XCTAssertFalse(observation.loading)
        await observation.load(scope: "cancelled") { throw URLError(.cancelled) }
        XCTAssertTrue(observation.headers.isEmpty); XCTAssertFalse(observation.loading)
    }

    func testProductionStatementMappingUsesCachedWorkerHeaders() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct StatementImportFlowView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct ReportLoadModifier:"))
        let view = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(view.contains("private var headers: [String] { headerObservation.headers }"))
        XCTAssertTrue(view.contains(".task(id: headerContext) { await loadHeaders() }"))
        XCTAssertTrue(view.contains("_delimiter = State(initialValue: file.suggestedDelimiter)"))
        XCTAssertTrue(view.contains(".onDisappear { headerObservation.cancel() }"))
        XCTAssertTrue(view.contains("guard changed, !Task.isCancelled"))
        XCTAssertFalse(view.contains(".onAppear { if let file { delimiter ="))
        XCTAssertTrue(view.contains("NativeStatementParsing.run { LocalDelimitedStatementParser.headers"))
        XCTAssertTrue(view.contains("headerObservation.invalidate()"))
        XCTAssertTrue(view.contains("Reading statement columns…"))
        XCTAssertFalse(view.contains("Self.csvHeaders"))
    }

    @MainActor
    func testStatementParsingWorkerRunsOffMainAndPreservesExactParserResults() async throws {
        let onMain = try await NativeStatementParsing.run { Thread.isMainThread }
        XCTAssertFalse(onMain)
        let mapping = APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
            amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        let rows = (0..<2_000).map { "2026-09-15,-1.23,Merchant \($0)" }
        let data = Data((["Date,Amount,Payee", "2026-09-15,90071992547409.93,Exact"] + rows).joined(separator: "\n").utf8)
        let parsed = try await NativeStatementParsing.parse(data, mapping)
        XCTAssertEqual(parsed, try LocalDelimitedStatementParser.parse(data: data, mapping: mapping))
        XCTAssertEqual(parsed.first?.amountMinor, 9_007_199_254_740_993)
        XCTAssertEqual(parsed.count, 2_001)
    }

    @MainActor
    func testCanceledStatementParsingDoesNotReturnWorkerResult() async {
        let task = Task { try await NativeStatementParsing.run { 42 } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled parsing must not return a review") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testStatementStagingRechecksActorAndPermissionsAfterParsingBeforePublishing() async throws {
        for switchActor in [false, true] {
            let source = DemoWorkspaceDataSource()
            _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
                capabilities: ["view_budget", "view_transactions", "create_transaction"],
                restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: nil))
            source.demo.persona = .partner
            let account = try XCTUnwrap(source.demo.visibleAccounts.first)
            let before = source.demo.transactions
            let mapping = APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
            do {
                _ = try await source.stageStatementImport(accountID: account.id, data: Data(), mapping: mapping, parse: { _, _ in
                    source.demo.persona = .rey
                    if !switchActor {
                        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
                            capabilities: ["view_budget"], restrictAccounts: false, accountIDs: [],
                            restrictCategories: false, categoryIDs: [], expectedVersion: nil))
                        source.demo.persona = .partner
                    }
                    return [.init(sourceRow: 2, occurredOn: "2026-09-15", amountMinor: 100, payee: "Private row", memo: "")]
                })
                XCTFail("An old parsing request must not publish under changed access")
            } catch let APIClientError.server(status, _) { XCTAssertEqual(status, 403) }
            source.demo.persona = .rey
            let history = try await source.statementImports(accountID: account.id, limit: 25, offset: 0)
            XCTAssertTrue(history.items.isEmpty)
            XCTAssertEqual(source.demo.transactions, before)
        }
    }

    func testNativeImportReaderHandlesShortReadsAndExactLimitWithoutTruncation() throws {
        let expected = Data("abcde".utf8)
        var offset = 0, requests: [Int] = []
        let result = try NativeImportFileReader.boundedData(maximumBytes: 5, oversizedMessage: "Too large") { count in
            requests.append(count)
            guard offset < expected.count else { return nil }
            let end = min(offset + 2, expected.count)
            defer { offset = end }
            return expected.subdata(in: offset..<end)
        }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(requests, [6, 4, 2, 1])
    }

    func testNativeImportReaderStopsAtLimitPlusOneAndPreservesReadErrors() {
        var requested = 0, calls = 0
        XCTAssertThrowsError(try NativeImportFileReader.boundedData(maximumBytes: 100_000, oversizedMessage: "Too large") { count in
            calls += 1; requested += count
            XCTAssertLessThanOrEqual(count, 64 * 1024)
            return Data(repeating: 1, count: count)
        }) { error in XCTAssertEqual(error.localizedDescription, "Too large") }
        XCTAssertEqual(requested, 100_001); XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try NativeImportFileReader.boundedData(maximumBytes: 10, oversizedMessage: "Too large") { _ in
            throw CocoaError(.fileReadNoPermission)
        }) { error in XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue) }
    }

    func testNativeImportReaderChecksActualFileSizeAndBothProductionPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("statement.csv")
        let expected = Data("date,amount\n2026-10-20,1.00\n".utf8)
        try expected.write(to: file)
        XCTAssertEqual(try NativeImportFileReader.read(file, oversizedMessage: "Too large"), expected)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(NativeImportFileReader.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try NativeImportFileReader.read(file, oversizedMessage: "Too large")) {
            XCTAssertEqual($0.localizedDescription, "Too large")
        }
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL)
        XCTAssertEqual(source.components(separatedBy: "NativeImportFileReader.read(url, oversizedMessage:").count - 1, 2)
    }

    func testNativeFileSelectionCancellationPreservesDraftAndRealFailuresRemainErrors() throws {
        let chosen = URL(fileURLWithPath: "/private/tmp/selected-receipt.pdf")
        XCTAssertEqual(try UserFileSelection.url(from: .success(chosen)), chosen)
        XCTAssertNil(try UserFileSelection.url(from: .failure(CocoaError(.userCancelled))))
        XCTAssertNil(try UserFileSelection.url(from: .failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))))
        for error in [CocoaError(.fileReadNoPermission) as Error, URLError(.notConnectedToInternet),
                      NSError(domain: "OtherProvider", code: NSUserCancelledError)] {
            XCTAssertThrowsError(try UserFileSelection.url(from: .failure(error))) { observed in
                XCTAssertEqual((observed as NSError).domain, (error as NSError).domain)
                XCTAssertEqual((observed as NSError).code, (error as NSError).code)
            }
        }
    }

    func testProductionFilePickersShareCancellationPolicyAndCameraUploadsAfterDismissal() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        XCTAssertEqual(source.components(separatedBy: "UserFileSelection.url(from: result)").count - 1, 3)
        XCTAssertTrue(source.contains(".sheet(isPresented: $showingCamera, onDismiss:"))
        XCTAssertTrue(source.contains("guard let image = capturedAttachmentImage else { return }"))
        XCTAssertTrue(source.contains("AttachmentCameraPicker { capturedAttachmentImage = $0 }"))
        XCTAssertFalse(source.contains("AttachmentCameraPicker { image in Task { await importCameraImage(image) } }"))
    }

    func testProductionAttachmentSourceUsesDismissalCompletionInsteadOfTimer() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct TransactionAttachmentsView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AttachmentPreviewScreen: View"))
        let view = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(view.contains(".sheet(isPresented: $showingSources, onDismiss: presentQueuedSourceAfterDismissal)"))
        XCTAssertTrue(view.contains("guard !showingSources, let source = pendingSource"))
        XCTAssertFalse(view.contains("Task.sleep"))
        XCTAssertFalse(view.contains(".onChange(of: showingSources)"))
    }

    func testLocalTransactionHistoryProjectsExactValuesAndRedactsHistoricalScope() throws {
        let before = #"{"account_id":"a","category_id":"hidden","amount_minor":9007199254740993,"memo":"private old memo","is_cleared":false,"tags":["private"],"transfer_id":"internal-old"}"#
        let after = #"{"account_id":"a","category_id":"food","amount_minor":9007199254740995,"memo":"visible memo","is_cleared":true,"tags":["qa"],"transfer_id":"internal-new"}"#
        let record = LocalTransactionChangeRecord(id: "change", budgetID: "budget", transactionID: "t", actorUserID: "u",
            action: "updated", beforeJSON: before, afterJSON: after, createdAt: "2026-10-20T00:00:00Z")
        let rows = LocalTransactionHistoryProjection.changes(record, accounts: ["a": "Checking"],
            categories: ["food": "Everyday · Food"], payees: [:])
        let amount = try XCTUnwrap(rows.first { $0["field"] as? String == "amount_minor" })
        XCTAssertEqual(amount["before_value"] as? String, "Private or unavailable")
        XCTAssertEqual(amount["after_value"] as? String, "9007199254740995")
        XCTAssertEqual(amount["value_kind"] as? String, "restricted")
        let encoded = try JSONSerialization.data(withJSONObject: rows)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for secret in ["private old memo", "internal-old", "internal-new", "9007199254740993"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertFalse(rows.contains { $0["field"] as? String == "transfer_id" })
        let visible = LocalTransactionHistoryProjection.changes(record, accounts: ["a": "Checking"],
            categories: ["food": "Everyday · Food", "hidden": "Old · Category"], payees: [:])
        let exact = try XCTUnwrap(visible.first { $0["field"] as? String == "amount_minor" })
        XCTAssertEqual(exact["before_value"] as? String, "9007199254740993")
        XCTAssertEqual(exact["value_kind"] as? String, "money_minor")
        let clearing = try XCTUnwrap(visible.first { $0["field"] as? String == "is_cleared" })
        XCTAssertEqual(clearing["before_value"] as? String, "Uncleared")
        XCTAssertEqual(clearing["after_value"] as? String, "Cleared")
        XCTAssertEqual(visible.first { $0["field"] as? String == "tags" }?["after_value"] as? String, "#qa")
    }

    func testLocalTransactionHistoryDoesNotExposeMalformedOrCreationSnapshots() {
        for raw in [nil, "[]", "not json", "{}"] as [String?] {
            let record = LocalTransactionChangeRecord(id: "change", budgetID: "b", transactionID: "t", actorUserID: "u",
                action: "created", beforeJSON: raw, afterJSON: #"{"memo":"secret"}"#, createdAt: "now")
            XCTAssertTrue(LocalTransactionHistoryProjection.changes(record, accounts: [:], categories: [:], payees: [:]).isEmpty)
        }
    }

    func testLocalTransactionHistoryRedactsHiddenAccountsAndSplitCategories() {
        let after = #"{"account_id":"a","memo":"current","splits":[]}"#
        for before in [
            #"{"account_id":"private-account","memo":"secret","splits":[]}"#,
            #"{"account_id":"a","memo":"secret","splits":[{"category_id":"private-category","amount_minor":-1}]}"#,
            #"{"account_id":"a","memo":"secret","splits":[{"amount_minor":-1}]}"#
        ] {
            let record = LocalTransactionChangeRecord(id: "c", budgetID: "b", transactionID: "t", actorUserID: "u",
                action: "updated", beforeJSON: before, afterJSON: after, createdAt: "now")
            let changes = LocalTransactionHistoryProjection.changes(record, accounts: ["a": "Checking"], categories: [:], payees: [:])
            let memo = changes.first { $0["field"] as? String == "memo" }
            XCTAssertEqual(memo?["before_value"] as? String, "Private or unavailable")
            XCTAssertEqual(memo?["after_value"] as? String, "current")
            XCTAssertEqual(memo?["value_kind"] as? String, "restricted")
        }
    }

    @MainActor
    func testCanonicalClearingAndReconciliationRefreshSharedAuditHistories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = LocalDeviceKeyManager(store: InMemorySecretDataStore())
        let store = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keys)
        await store.refresh()
        try await store.createAccount(.init(name: "Audit Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 10_000))
        let account = try XCTUnwrap(store.accounts.first)
        try await store.createTransaction(.init(accountID: account.id, categoryID: nil, amountMinor: 200,
            occurredOn: "2026-09-30", payeeName: "Audit income", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let transaction = try XCTUnwrap(store.transactions.first { $0.payeeName == "Audit income" })
        let working = store.balance(for: account), ready = store.summary?.readyToAssignMinor
        let changes = DecisionHistoryPager<APITransactionChange>()
        let reconciliations = DecisionHistoryPager<APIReconciliationHistory>()
        changes.prepare(scope: "transaction|\(transaction.id)")
        reconciliations.prepare(scope: "account|\(account.id)")
        await changes.load(reset: true) { limit, offset in
            try await store.transactionHistory(id: transaction.id, limit: limit, offset: offset)
        }
        let oldChanges = changes.rows.count, revision = store.reportRevision
        try await store.setTransactionCleared(id: transaction.id, cleared: !transaction.isCleared)
        XCTAssertGreaterThan(store.reportRevision, revision)
        await changes.load(reset: true) { limit, offset in
            try await store.transactionHistory(id: transaction.id, limit: limit, offset: offset)
        }
        XCTAssertGreaterThan(changes.rows.count, oldChanges)
        // Reconciliation includes cleared rows, independent of the fixture's initial state.
        try await store.setTransactionCleared(id: transaction.id, cleared: true)
        await reconciliations.load(reset: true) { limit, offset in
            try await store.reconciliationHistory(accountID: account.id, limit: limit, offset: offset)
        }
        let oldReconciliations = reconciliations.rows.count
        try await store.reconcile(accountID: account.id, statementBalance: store.clearedBalance(for: account),
            throughDate: "2099-12-31", createAdjustment: false, reason: "")
        await reconciliations.load(reset: true) { limit, offset in
            try await store.reconciliationHistory(accountID: account.id, limit: limit, offset: offset)
        }
        XCTAssertEqual(reconciliations.rows.count, oldReconciliations + 1)
        XCTAssertNil(changes.errorMessage); XCTAssertNil(reconciliations.errorMessage)
        XCTAssertEqual(store.balance(for: account), working)
        XCTAssertEqual(store.summary?.readyToAssignMinor, ready)
        let reopened = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keys)
        await reopened.refresh()
        let persisted = try await reopened.transactionHistory(id: transaction.id)
        XCTAssertGreaterThan(persisted.count, oldChanges)
        let clearingDetails = persisted.flatMap { $0.changes ?? [] }.filter { $0.field == "is_cleared" }
        XCTAssertTrue(clearingDetails.contains { $0.beforeValue == "Uncleared" && $0.afterValue == "Cleared" })
        let recent = try await reopened.recentTransactionChanges(limit: 25)
        let recentDetails: [APITransactionFieldChange] = recent.flatMap { $0.changes ?? [] }
        XCTAssertTrue(recentDetails.contains { $0.field == "is_reconciled" && $0.afterValue == "Reconciled" })
        let persistedReconciliations = try await reopened.reconciliationHistory(accountID: account.id)
        XCTAssertEqual(persistedReconciliations.count, reconciliations.rows.count)
    }

    func testProductionAttachmentReadFailuresAreInlineAndObserveWorkspaceRefresh() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct TransactionAttachmentsView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AttachmentPreviewScreen: View"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains(".task(id: attachmentObservationContext)"))
        XCTAssertTrue(view.contains("store.reportRevision")); XCTAssertTrue(view.contains("store.liveCredentialRevision"))
        XCTAssertTrue(view.contains("attachmentList.prepare(scope: attachmentScope)"))
        XCTAssertTrue(view.contains("Retry Attachment List"))
        XCTAssertTrue(view.contains("Showing the last loaded attachment list"))
        let loadStart = try XCTUnwrap(view.range(of: "private func load() async"))
        let loadEnd = try XCTUnwrap(view.range(of: "private func importFile"))
        let read = view[loadStart.lowerBound..<loadEnd.lowerBound]
        XCTAssertTrue(read.contains("attachmentList.load(transactionID:"))
        XCTAssertFalse(read.contains("self.error ="), "Background reads must not trigger the command-error alert")
    }

    @MainActor
    func testAttachmentListPreservesTransientMetadataButClearsDeniedScope() async throws {
        let row = try attachmentListFixture(id: "a")
        let observation = AttachmentListObservation()
        observation.prepare(scope: "owner|budget|t")
        await observation.load(transactionID: "t") { [row] }
        XCTAssertEqual(observation.rows, [row])
        await observation.load(transactionID: "t") { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(observation.rows, [row]); XCTAssertNotNil(observation.errorMessage)
        await observation.load(transactionID: "t") { [] }
        XCTAssertTrue(observation.rows.isEmpty); XCTAssertNil(observation.errorMessage)
        await observation.load(transactionID: "t") { [row] }
        await observation.load(transactionID: "t") { throw BudgetApplicationError.permissionDenied("Scope changed") }
        XCTAssertTrue(observation.rows.isEmpty)
        observation.prepare(scope: "new-member|budget|t")
        XCTAssertTrue(observation.rows.isEmpty)
    }

    @MainActor
    func testAttachmentListRejectsSupersededDuplicateAndWrongTransactionResponses() async throws {
        let row = try attachmentListFixture(id: "a"), foreign = try attachmentListFixture(id: "b", transactionID: "other")
        let observation = AttachmentListObservation()
        observation.prepare(scope: "a")
        await observation.load(transactionID: "t") { [row] }
        await observation.load(transactionID: "t") { [row, row] }
        XCTAssertEqual(observation.rows, [row]); XCTAssertNotNil(observation.errorMessage)
        await observation.load(transactionID: "t") { [foreign] }
        XCTAssertEqual(observation.rows, [row])
        await observation.load(transactionID: "t") { observation.prepare(scope: "b"); return [row] }
        XCTAssertTrue(observation.rows.isEmpty); XCTAssertFalse(observation.loading)
        await observation.load(transactionID: "t") { [row] }
        XCTAssertEqual(observation.rows, [row]); XCTAssertNil(observation.errorMessage)
    }

    private func attachmentListFixture(id: String, transactionID: String = "t") throws -> APITransactionAttachment {
        try JSONDecoder().decode(APITransactionAttachment.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "transaction_id": transactionID, "filename": "receipt.jpg", "content_type": "image/jpeg",
            "byte_count": 4, "sha256": String(repeating: "a", count: 64), "created_at": "2026-10-20T00:00:00Z"
        ]))
    }

    @MainActor
    func testAccountHistorySharedPagerRefreshesCanonicalRenameWithoutChangingMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let balances = store.accountBalances, transactions = store.transactions
        let revision = store.reportRevision, authority = store.authorityRevision
        let history = DecisionHistoryPager<APIAccountRevision>(pageSize: 25)
        let scope = "\(authority)|\(store.budget.id)|account|\(account.id)"
        history.prepare(scope: scope)
        await history.load(reset: true) { limit, offset in
            XCTAssertEqual(limit, 25)
            return try await store.accountHistory(accountID: account.id, limit: limit, offset: offset)
        }
        let beforeCount = history.rows.count
        try await store.updateAccount(.init(accountID: account.id, name: "Renamed checking", currentKind: "checking",
            kind: "checking", isOnBudget: account.isOnBudget, isClosed: false))
        XCTAssertGreaterThan(store.reportRevision, revision); XCTAssertEqual(store.authorityRevision, authority)
        history.prepare(scope: scope)
        await history.load(reset: true) { limit, offset in
            try await store.accountHistory(accountID: account.id, limit: limit, offset: offset)
        }
        XCTAssertEqual(history.rows.count, beforeCount + 1)
        XCTAssertEqual(history.rows.first?.afterSnapshot.name, "Renamed checking")
        XCTAssertEqual(store.accountBalances, balances); XCTAssertEqual(store.transactions, transactions)
    }

    @MainActor
    func testDecisionHistoryRefreshPreservesDepthAtomicallyAndRetryIntent() async {
        struct Row: Identifiable, Sendable, Equatable { let id: Int; var value = "old" }
        let history = DecisionHistoryPager<Row>(pageSize: 2)
        history.prepare(scope: "owner|target")
        await history.load(reset: true) { limit, offset in
            XCTAssertEqual(limit, 2); XCTAssertEqual(offset, 0)
            return [Row(id: 1), Row(id: 2)]
        }
        await history.load(reset: false) { _, offset in
            XCTAssertEqual(offset, 2); return [Row(id: 3), Row(id: 4)]
        }
        let previous = history.rows
        history.prepare(scope: "owner|target")
        await history.load(reset: true) { _, offset in
            XCTAssertEqual(history.rows, previous, "No partial refresh publication")
            if offset == 0 { return [Row(id: 1, value: "new"), Row(id: 2)] }
            throw URLError(.timedOut)
        }
        XCTAssertEqual(history.rows, previous); XCTAssertEqual(history.retryIntent, .refresh)
        await history.load(reset: true) { _, offset in
            offset == 0 ? [Row(id: 1, value: "new"), Row(id: 2)] : [Row(id: 3)]
        }
        XCTAssertEqual(history.rows.map(\.id), [1, 2, 3]); XCTAssertEqual(history.rows.first?.value, "new")
        XCTAssertFalse(history.canLoadOlder); XCTAssertNil(history.errorMessage)
        await history.load(reset: false) { _, _ in XCTFail("Final page must not repeat"); return [] }
        history.prepare(scope: "different-member|target")
        XCTAssertTrue(history.rows.isEmpty)
    }

    @MainActor
    func testDecisionHistoryRejectsDuplicateDeniedAndSupersededPages() async {
        struct Row: Identifiable, Sendable { let id: Int }
        let history = DecisionHistoryPager<Row>(pageSize: 1)
        history.prepare(scope: "a")
        await history.load(reset: true) { _, _ in [Row(id: 1)] }
        await history.load(reset: false) { _, _ in [Row(id: 1)] }
        XCTAssertEqual(history.rows.map(\.id), [1]); XCTAssertEqual(history.retryIntent, .older)
        XCTAssertNotNil(history.errorMessage)
        await history.load(reset: false) { _, _ in throw APIClientError.server(status: 403, message: "Denied") }
        XCTAssertTrue(history.rows.isEmpty); XCTAssertFalse(history.canLoadOlder)
        await history.load(reset: true) { _, _ in
            history.prepare(scope: "b")
            return [Row(id: 2)]
        }
        XCTAssertTrue(history.rows.isEmpty); XCTAssertFalse(history.loading)
        await history.load(reset: true) { _, _ in [Row(id: 3)] }
        XCTAssertEqual(history.rows.map(\.id), [3])
    }

    func testReconciliationHistoryInitialLoadAndRecoveryAreReachable() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct ReconciliationHistoryView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct TransferPresentation:"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("DecisionHistoryPager<APIReconciliationHistory>()"))
        XCTAssertTrue(view.contains("if loading && rows.isEmpty"))
        XCTAssertTrue(view.contains("rows.isEmpty && errorMessage == nil"))
        XCTAssertTrue(view.contains("retryIntent.shouldReset(hasLoadedRows: !rows.isEmpty)"))
        XCTAssertTrue(view.contains(".task(id: historyContext)"))
        XCTAssertTrue(view.contains("history.prepare(scope: historyScope)"))
        XCTAssertTrue(view.contains("history.invalidate()"))
        XCTAssertTrue(view.contains("store.authorityRevision")); XCTAssertTrue(view.contains("store.reportRevision"))
        XCTAssertTrue(view.contains("reconciliation-history-row-"))
    }

    @MainActor
    func testCurrentCoalescedBrowserPublishesWhenOriginalWaiterCancels() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let transaction = try XCTUnwrap(store.transactions.first)
        store.transactions.removeAll { $0.id == transaction.id }
        let query = APITransactionQuery(transactionIDs: [transaction.id], limit: 1)
        var continuation: CheckedContinuation<APITransactionPage, Never>?
        let started = expectation(description: "Shared request started")
        let original = Task {
            try await store.browseTransactions(query, fetch: { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 2)
        let waiting = expectation(description: "Second waiter attached")
        let current = Task {
            waiting.fulfill()
            return try await store.browseTransactions(query, fetch: { _ in
                XCTFail("Identical current queries should coalesce")
                return .init(items: [], nextCursor: nil, totalCount: 0)
            })
        }
        await fulfillment(of: [waiting], timeout: 2)
        original.cancel()
        let response = try XCTUnwrap(continuation)
        response.resume(returning: .init(items: [transaction], nextCursor: nil, totalCount: 1))
        do { _ = try await original.value; XCTFail("Cancelled waiter must not publish") }
        catch is CancellationError { }
        let page = try await current.value
        XCTAssertEqual(page.items, [transaction])
        XCTAssertEqual(store.transactions.first { $0.id == transaction.id }, transaction)
    }

    @MainActor
    func testWorkspaceBrowserCannotReuseOrPublishPreRefreshTransactions() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        try await store.createTransaction(.init(accountID: account.id, categoryID: nil, amountMinor: -123,
            occurredOn: "2026-09-05", payeeName: "Revision race", memo: "Keep metadata", isCleared: false,
            splits: [], flag: "orange", tags: ["keep"], attachmentMetadata: []))
        let original = try XCTUnwrap(store.transactions.first { $0.payeeName == "Revision race" })
        let beforeBalance = store.balance(for: account)
        let query = APITransactionQuery(transactionIDs: [original.id], limit: 1)
        var continuation: CheckedContinuation<APITransactionPage, Never>?
        let started = expectation(description: "Old browser request started")
        let oldRequest = Task {
            try await store.browseTransactions(query, fetch: { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 2)
        let previousRevision = store.reportRevision
        try await store.setTransactionCleared(id: original.id, cleared: true)
        XCTAssertGreaterThan(store.reportRevision, previousRevision)
        let current = try XCTUnwrap(store.transactions.first { $0.id == original.id })
        XCTAssertTrue(current.isCleared)
        var fetchedCurrent = false
        let newRequest = Task {
            try await store.browseTransactions(query, fetch: { _ in
                fetchedCurrent = true
                return .init(items: [current], nextCursor: nil, totalCount: 1)
            })
        }
        for _ in 0..<100 where !fetchedCurrent { await Task.yield() }
        XCTAssertTrue(fetchedCurrent, "New revision must not reuse the old in-flight request")
        let oldContinuation = try XCTUnwrap(continuation)
        oldContinuation.resume(returning: .init(items: [original], nextCursor: nil, totalCount: 1))
        do { _ = try await oldRequest.value; XCTFail("Old revision must be cancelled before publication") }
        catch is CancellationError { }
        let page = try await newRequest.value
        XCTAssertEqual(page.items, [current])
        XCTAssertEqual(store.transactions.first { $0.id == current.id }, current)
        XCTAssertEqual(store.balance(for: account), beforeBalance)
        XCTAssertEqual(current.memo, "Keep metadata"); XCTAssertEqual(current.tags, ["keep"])
    }

    @MainActor
    func testScheduledRemindersDisableSupersedesPendingAuthorization() async throws {
        let suite = "Reminders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ReminderNotificationFixture()
        client.holdAuthorization = true
        let started = expectation(description: "Authorization started")
        client.onAuthorize = { started.fulfill() }
        let settings = ScheduledReminderSettings(budgetID: "b", defaults: defaults, notifications: client)
        let enable = Task { await settings.setEnabled(true, schedules: []) }
        await fulfillment(of: [started], timeout: 2)
        await settings.setEnabled(false, schedules: [])
        let continuation = try XCTUnwrap(client.authorization)
        client.authorization = nil; continuation.resume(returning: true)
        await enable.value
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "clearpocket.scheduled-reminders.b"))
        XCTAssertTrue(client.requests.isEmpty)
    }

    @MainActor
    func testScheduledRemindersDisableCleansLateAddsAndPreservesOtherRequests() async throws {
        let suite = "Reminders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ReminderNotificationFixture()
        client.holdAdd = true
        client.requests["another-app-feature"] = UNNotificationRequest(identifier: "another-app-feature",
            content: UNMutableNotificationContent(), trigger: nil)
        let started = expectation(description: "Add started")
        client.onAdd = { started.fulfill() }
        let schedule = try makeReminderSchedule(id: "one")
        let settings = ScheduledReminderSettings(budgetID: "b", defaults: defaults, notifications: client)
        let enable = Task { await settings.setEnabled(true, schedules: [schedule]) }
        await fulfillment(of: [started], timeout: 2)
        let disable = Task { await settings.setEnabled(false, schedules: []) }
        for _ in 0..<100 where settings.isEnabled { await Task.yield() }
        XCTAssertFalse(settings.isEnabled)
        let continuation = try XCTUnwrap(client.addition)
        client.addition = nil; continuation.resume()
        await enable.value; await disable.value
        XCTAssertEqual(Set(client.requests.keys), ["another-app-feature"])
        XCTAssertEqual(client.addCount, 1)
    }

    @MainActor
    func testScheduledRemindersRemainBoundedPrivateAndReportAddFailures() async throws {
        let suite = "Reminders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ReminderNotificationFixture()
        let settings = ScheduledReminderSettings(budgetID: "b", defaults: defaults, notifications: client)
        var schedules = try (0..<70).map { try makeReminderSchedule(id: String(format: "s%03d", $0)) }
        schedules.append(try makeReminderSchedule(id: "paused", active: false))
        schedules.append(try makeReminderSchedule(id: "foreign", budget: "private"))
        await settings.setEnabled(true, schedules: schedules)
        XCTAssertEqual(client.requests.count, 50)
        XCTAssertNil(client.requests["clearpocket.schedule.b.paused"])
        XCTAssertNil(client.requests["clearpocket.schedule.b.foreign"])
        for request in client.requests.values {
            XCTAssertEqual(request.content.title, "ClearPocket reminder")
            XCTAssertEqual(request.content.body, "A scheduled budget item is due today.")
            XCTAssertTrue(request.content.userInfo.isEmpty)
        }
        client.failAdd = true
        await settings.synchronize([try makeReminderSchedule(id: "failure")])
        XCTAssertNotNil(settings.errorMessage)
        client.failAdd = false
        await settings.synchronize([try makeReminderSchedule(id: "retry")])
        XCTAssertNil(settings.errorMessage)
        XCTAssertEqual(Set(client.requests.keys), ["clearpocket.schedule.b.retry"])
    }

    private func makeReminderSchedule(id: String, budget: String = "b", active: Bool = true) throws -> APIScheduledTransaction {
        let date = BudgetWorkspaceStore.dateString(Date().addingTimeInterval(86_400))
        return try JSONDecoder().decode(APIScheduledTransaction.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "budget_id": budget, "account_id": "private-account", "name": "Private merchant",
            "amount_minor": -123, "next_date": date, "recurrence_unit": "months", "interval_count": 1,
            "memo": "Private memo", "is_active": active
        ]))
    }

    @MainActor
    func testIndexedStatementMatchesEqualExhaustiveReviewAcrossLargeHistory() {
        let base = BudgetWorkspaceStore.parseDate("2026-09-01")
        let largeAmount: Int64 = -9_007_199_254_740_993
        let observations: [StatementMatchIndex.Observation] = (0..<2_001).map { index in
            let date = base.addingTimeInterval(Double(index % 25) * 86_400 + Double(index % 3) * 3_600)
            return .init(id: String(format: "t%05d", index), date: date,
                day: BudgetWorkspaceStore.dateString(date), amount: index % 5 == 0 ? largeAmount : -100,
                payeeKeys: ["merchant-\(index % 13)", "alias-\(index % 7)"])
        }
        var indexed = StatementMatchIndex(observations: observations.reversed())
        for offset in 0..<25 {
            let date = base.addingTimeInterval(Double(offset) * 86_400)
            let day = BudgetWorkspaceStore.dateString(date)
            for amount in [Int64(-100), largeAmount, Int64(0)] {
                for key in ["merchant-3", "alias-2", "missing"] {
                    let exact = observations.filter { $0.day == day && $0.amount == amount && $0.payeeKeys.contains(key) }
                        .map(\.id).sorted()
                    let ids = Set(exact)
                    let possible = observations.filter {
                        $0.amount == amount && abs($0.date.timeIntervalSince(date)) <= 2 * 86_400 && !ids.contains($0.id)
                    }.sorted {
                        let left = abs($0.date.timeIntervalSince(date)), right = abs($1.date.timeIntervalSince(date))
                        return left == right ? $0.id < $1.id : left < right
                    }.map(\.id)
                    let expected = StatementMatchIndex.Result(exact: Array(exact.prefix(20)), possible: Array(possible.prefix(20)),
                        truncated: exact.count > 20 || possible.count > 20)
                    XCTAssertEqual(indexed.match(day: day, date: date, amount: amount, payeeKey: key), expected)
                    XCTAssertEqual(indexed.match(day: day, date: date, amount: amount, payeeKey: key), expected,
                                   "Repeated rows share immutable match results, not consumed matches")
                }
            }
        }
    }

    @MainActor
    func testDownloadedBackupCustodyDefersCleanupUntilVerificationFinishes() throws {
        var removed: [URL] = []
        var failRemoval = false
        let custody = BackupDownloadCustody { url in
            if failRemoval { throw URLError(.cannotRemoveFile) }
            removed.append(url)
        }
        let first = URL(fileURLWithPath: "/private/tmp/download-one", isDirectory: true)
        let second = URL(fileURLWithPath: "/private/tmp/download-two", isDirectory: true)
        try custody.retain(first)
        try custody.retain(first)
        XCTAssertTrue(removed.isEmpty, "Reobserving the same package must not unlink it")
        XCTAssertTrue(custody.beginReading(first))
        XCTAssertFalse(custody.beginReading(first))
        XCTAssertThrowsError(try custody.retain(second))
        try custody.discard(); try custody.discard()
        XCTAssertEqual(custody.packageURL, first); XCTAssertTrue(removed.isEmpty)
        custody.finishReading()
        XCTAssertNil(custody.packageURL); XCTAssertEqual(removed, [first])
        custody.finishReading(); try custody.discard()
        XCTAssertEqual(removed, [first], "Cleanup executes exactly once")
        try custody.retain(second); XCTAssertTrue(custody.beginReading(second))
        try custody.discard(); failRemoval = true; custody.finishReading()
        XCTAssertEqual(custody.packageURL, second, "Failed cleanup must retain custody for retry")
        failRemoval = false; try custody.discard()
        XCTAssertNil(custody.packageURL); XCTAssertEqual(removed, [first, second])
    }

    func testProductionDropboxRestoreClaimsOperationAndRetainsActiveReadSource() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LocalDeviceBackupRecoveryView"))
        let end = try XCTUnwrap(source.range(of: "private struct BackupRecoverySettingsView"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("@StateObject private var downloadCustody = BackupDownloadCustody()"))
        XCTAssertTrue(view.contains("downloadCustody.beginReading(restorePackage)"))
        XCTAssertTrue(view.contains("defer { if isDownloaded { downloadCustody.finishReading() } }"))
        XCTAssertTrue(view.contains("guard recoveryVisible else"))
        XCTAssertTrue(view.contains("let restorePackage, dropbox.claimManualTransfer()"))
        XCTAssertTrue(view.contains("try? downloadCustody.discard()"))
    }

    @MainActor
    func testStatementImportPagerRetriesPreservesRowsAndRejectsInvalidPages() async throws {
        func row(_ id: String, account: String = "a") -> APIStatementImportSummary {
            .init(id: id, budgetID: "b", accountID: account, status: "review", version: 1,
                  sourceFormat: "csv", candidateCount: 2, createdAt: "2026-10-20")
        }
        let pager = StatementImportHistoryPager()
        await pager.load(budgetID: "b", accountID: "a", reset: true) { limit, offset in
            XCTAssertEqual(limit, 25); XCTAssertEqual(offset, 0)
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertNotNil(pager.errorMessage); XCTAssertTrue(pager.rows.isEmpty)
        XCTAssertEqual(pager.retryIntent, .refresh)
        await pager.load(budgetID: "b", accountID: "a", reset: true) { _, _ in
            .init(items: [row("1")], hasMore: true, nextOffset: 1)
        }
        await pager.load(budgetID: "b", accountID: "a", reset: false) { _, offset in
            XCTAssertEqual(offset, 1); throw URLError(.timedOut)
        }
        XCTAssertEqual(pager.rows.map(\.id), ["1"]); XCTAssertEqual(pager.retryIntent, .older)
        await pager.load(budgetID: "b", accountID: "a", reset: false) { _, _ in
            .init(items: [row("1")], hasMore: false, nextOffset: nil)
        }
        XCTAssertEqual(pager.rows.map(\.id), ["1"]); XCTAssertNotNil(pager.errorMessage)
        await pager.load(budgetID: "b", accountID: "a", reset: false) { _, _ in
            .init(items: [row("2", account: "private")], hasMore: false, nextOffset: nil)
        }
        XCTAssertEqual(pager.rows.map(\.id), ["1"])
        await pager.load(budgetID: "b", accountID: "a", reset: false) { _, _ in
            .init(items: [row("2")], hasMore: false, nextOffset: nil)
        }
        XCTAssertEqual(pager.rows.map(\.id), ["1", "2"]); XCTAssertNil(pager.errorMessage)
        await pager.load(budgetID: "b", accountID: "a", reset: false) { _, _ in
            XCTFail("Final page must not refetch"); return .init(items: [], hasMore: false, nextOffset: nil)
        }
        await pager.load(budgetID: "b", accountID: "a", reset: true) { _, _ in
            throw APIClientError.server(status: 403, message: "Denied")
        }
        XCTAssertTrue(pager.rows.isEmpty); XCTAssertNil(pager.nextOffset)
    }

    @MainActor
    func testStatementImportPagerDiscardsSupersededResponsesAndProductionWiring() async throws {
        let pager = StatementImportHistoryPager()
        await pager.load(budgetID: "b", accountID: "a", reset: true) { _, _ in
            pager.clear()
            return .init(items: [.init(id: "old", budgetID: "b", accountID: "a", status: "review",
                version: 1, sourceFormat: "csv", candidateCount: 1, createdAt: "2026-10-20")], hasMore: false, nextOffset: nil)
        }
        XCTAssertTrue(pager.rows.isEmpty); XCTAssertFalse(pager.loading)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct StatementImportHistoryView:"))
        let end = try XCTUnwrap(source.range(of: "private struct StatementImportFile:"))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("@StateObject private var pager = StatementImportHistoryPager()"))
        XCTAssertTrue(view.contains("pager.rows.isEmpty && pager.errorMessage == nil"))
        XCTAssertTrue(view.contains("pager.retryIntent.shouldReset"))
        XCTAssertTrue(view.contains("openRequestID == requestID"))
    }

    @MainActor
    func testNetWorthContributorsKeepFullHistoryAndAccountScope() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        await store.loadReports([.netWorth])
        let report = try XCTUnwrap(store.netWorthReport)
        let summary = store.summary, balances = store.accountBalances
        let query = store.reportContext.query.selectingCategory("ignored-category")
            .netWorthHistory(end: BudgetWorkspaceStore.parseDate(report.endDate))
        XCTAssertEqual(query.categoryID, ""); XCTAssertEqual(query.payee, "")
        XCTAssertEqual(query.cleared, "all"); XCTAssertEqual(query.memberID, "")
        var cursor: String?, found = Set<String>()
        repeat {
            let page = try await store.reportContributors(query: query, kind: .netWorth, cursor: cursor)
            XCTAssertTrue(found.isDisjoint(with: page.items.map(\.id)))
            XCTAssertTrue(page.items.allSatisfy { $0.occurredOn <= report.endDate })
            found.formUnion(page.items.map(\.id)); cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(found, Set(report.accounts.flatMap(\.transactionIDs)))
        XCTAssertEqual(store.summary, summary); XCTAssertEqual(store.accountBalances, balances)
    }

    @MainActor
    func testTrendContributorsPreserveCanonicalDimensionAndSelectedPeriod() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let summary = store.summary, balances = store.accountBalances
        for dimension in ["category", "group", "payee"] {
            store.spendingTrendDimension = dimension
            await store.loadReports([.spendingTrends])
            let report = try XCTUnwrap(store.spendingTrendsReport)
            for series in report.series {
                for point in series.points {
                    let context = store.reportContext.query
                    let query = context.selectingTrend(dimension: dimension, id: series.dimensionID,
                        start: point.periodStart, end: point.periodEnd)
                    XCTAssertEqual(query.start, context.start); XCTAssertEqual(query.end, context.end)
                    XCTAssertEqual(query.contributorStart, point.periodStart)
                    XCTAssertEqual(query.contributorEnd, point.periodEnd)
                    var cursor: String?, found = Set<String>()
                    repeat {
                        let page = try await store.reportContributors(query: query, kind: .categorySpending, cursor: cursor)
                        XCTAssertTrue(found.isDisjoint(with: page.items.map(\.id)))
                        XCTAssertTrue(page.items.allSatisfy { $0.occurredOn >= point.periodStart && $0.occurredOn <= point.periodEnd })
                        found.formUnion(page.items.map(\.id)); cursor = page.nextCursor
                    } while cursor != nil
                    XCTAssertEqual(found, Set(point.transactionIDs))
                }
            }
        }
        XCTAssertEqual(store.summary, summary); XCTAssertEqual(store.accountBalances, balances)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift"))
        XCTAssertTrue(source.contains("reportDimensionID: change.id"))
        XCTAssertTrue(source.contains("reportEnd: change.latestPeriodEnd"))
    }

    @MainActor
    func testIncomeSpendingContributorsKeepPeriodAndReportFilterSemantics() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        await store.loadReports([.income])
        let report = try XCTUnwrap(store.incomeReport)
        let period = try XCTUnwrap(report.periods.first)
        let query = store.reportContext.query.selectingCategory("not-an-income-report-filter")
            .incomeSpendingPeriod(start: BudgetWorkspaceStore.parseDate(period.periodStart), end: BudgetWorkspaceStore.parseDate(period.periodEnd))
        XCTAssertEqual(query.categoryID, ""); XCTAssertEqual(query.categoryGroup, ""); XCTAssertEqual(query.transactionType, "")
        XCTAssertEqual(BudgetWorkspaceStore.dateString(query.start), period.periodStart)
        XCTAssertEqual(BudgetWorkspaceStore.dateString(query.end), period.periodEnd)
        let summary = store.summary, balances = store.accountBalances
        for (kind, expected) in [(APIReportContributorKind.income, period.incomeTransactionIDs), (.spending, period.spendingTransactionIDs)] {
            var cursor: String?, found = Set<String>()
            repeat {
                let page = try await store.reportContributors(query: query, kind: kind, cursor: cursor)
                XCTAssertTrue(found.isDisjoint(with: page.items.map(\.id)))
                found.formUnion(page.items.map(\.id)); cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(found, Set(expected))
        }
        XCTAssertEqual(store.summary, summary); XCTAssertEqual(store.accountBalances, balances)
    }

    @MainActor
    func testFullCategoryContributorsUseCanonicalReportAndSharedDetail() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        await store.loadReports([.spending])
        let category = try XCTUnwrap(store.spendingReport?.categories.first)
        let query = store.reportContext.query.selectingCategory(category.categoryID)
        let summary = store.summary, balances = store.accountBalances
        let expected = Set(category.transactionIDs)
        store.transactions.removeAll { expected.contains($0.id) }
        var cursor: String?, found = Set<String>()
        repeat {
            let page = try await store.reportContributors(query: query, kind: .categorySpending, cursor: cursor)
            XCTAssertLessThanOrEqual(page.items.count, 50)
            XCTAssertTrue(found.isDisjoint(with: page.items.map(\.id)))
            found.formUnion(page.items.map(\.id)); cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(found, expected)
        XCTAssertTrue(expected.isSubset(of: Set(store.transactions.map(\.id))))
        XCTAssertEqual(store.summary, summary); XCTAssertEqual(store.accountBalances, balances)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift"))
        XCTAssertTrue(source.contains("reportCategoryID: category.categoryID"))
        XCTAssertTrue(source.contains("context.query.selectingCategory(reportCategoryID)"))
        XCTAssertTrue(source.contains("context == store.reportContext"))
    }

    @MainActor
    func testContributorIdentitySearchHydratesSharedDetailWithoutFinancialMutation() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let transaction = try XCTUnwrap(store.transactions.first)
        let summary = store.summary
        let balances = store.accountBalances
        store.transactions.removeAll { $0.id == transaction.id }
        let page = try await store.browseTransactions(.init(transactionIDs: [transaction.id, "missing"], limit: 1))
        XCTAssertEqual(page.items.map(\.id), [transaction.id])
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(store.transactions.first { $0.id == transaction.id }, transaction)
        XCTAssertEqual(store.summary, summary)
        XCTAssertEqual(store.accountBalances, balances)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift"))
        XCTAssertTrue(source.contains("report-contributors-load-more"))
        XCTAssertFalse(source.contains("outside the currently hydrated authorized activity page"))
    }

    @MainActor
    func testTransactionDetailCanHydrateOneMissingObservationWithoutFullLedger() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let expected = try XCTUnwrap(store.transactions.first)
        let summary = store.summary, balances = store.accountBalances
        store.transactions.removeAll()
        let page = try await store.browseTransactions(.init(transactionIDs: [expected.id], limit: 1))
        XCTAssertEqual(page.items, [expected])
        XCTAssertEqual(store.transactions, [expected], "Identity lookup must not rehydrate the complete ledger")
        XCTAssertEqual(store.summary, summary)
        XCTAssertEqual(store.accountBalances, balances)
        let missing = try await store.browseTransactions(.init(transactionIDs: ["not-authorized-or-missing"], limit: 1))
        XCTAssertTrue(missing.items.isEmpty)
        XCTAssertEqual(store.transactions, [expected])
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveTransactionDetailView: View"))
        let end = source.range(of: "\nprivate struct ", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let detail = String(source[start.lowerBound..<end])
        XCTAssertTrue(detail.contains("transactionIDs: [transactionID], limit: 1"))
        XCTAssertTrue(detail.contains("await loadMissingTransaction()"))
        XCTAssertTrue(detail.contains("transaction-detail-loading"))
        XCTAssertTrue(detail.contains("transaction-detail-retry"))
        XCTAssertTrue(detail.contains("TransactionAttachmentsView(transaction: transaction)"))
        XCTAssertTrue(detail.contains("LiveTransactionEditView(budget: store.budget, transaction: transaction"))
    }

    @MainActor
    func testSparseTransferLookupHydratesOnlyAuthorizedPairWithoutMoneyMutation() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        try await store.createTransfer(.init(sourceAccountID: "checking", destinationAccountID: "savings", amountMinor: 123,
            occurredOn: "2026-09-05", memo: "Sparse pair", isCleared: false))
        let row = try XCTUnwrap(store.transactions.first { $0.memo == "Sparse pair" })
        let pair = try XCTUnwrap(row.transferID)
        let balances = store.accountBalances, summary = store.summary
        store.transactions = [row]
        let page = try await store.browseTransactions(.init(transferIDs: [pair], limit: 2))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.items.allSatisfy { $0.transferID == pair })
        XCTAssertEqual(page.items.reduce(Int64(0)) { $0 + $1.amountMinor }, 0)
        XCTAssertEqual(store.transactions.count, 2)
        XCTAssertEqual(store.accountBalances, balances)
        XCTAssertEqual(store.summary, summary)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        XCTAssertTrue(source.contains("transferIDs: [transferID], limit: 2"))
    }

    func testStatementReviewSearchCombinesFocusWithoutChangingDecisions() {
        func includes(_ filter: StatementImportReviewFilter, selected: Bool = true, duplicate: Bool = false, query: String = "") -> Bool {
            filter.includes(selected: selected, duplicate: duplicate, query: query, payee: "Café Market", memo: "Receipt", date: "2026-09-15")
        }
        XCTAssertTrue(includes(.all, query: " cafe "))
        XCTAssertTrue(includes(.all, query: "2026-09"))
        XCTAssertTrue(includes(.selected, query: "receipt"))
        XCTAssertFalse(includes(.selected, selected: false))
        XCTAssertTrue(includes(.skipped, selected: false))
        XCTAssertFalse(includes(.skipped))
        XCTAssertTrue(includes(.duplicates, duplicate: true))
        XCTAssertFalse(includes(.duplicates, duplicate: false))
        XCTAssertFalse(includes(.all, query: "not present"))
    }
    func testStatementReviewPostingRetainsWholeBatchWhenRowsAreFiltered() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct StatementImportFlowView:"))
        let end = try XCTUnwrap(source.range(of: "private struct ReportLoadModifier:", range: start.upperBound..<source.endIndex))
        let flow = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(flow.contains("let visibleRows = visibleCandidates(batch)"))
        XCTAssertTrue(flow.contains("ForEach(visibleRows)"))
        XCTAssertTrue(flow.contains("let items = batch.candidates.map"))
        XCTAssertFalse(flow.contains("let items = visibleCandidates(batch).map"))
        XCTAssertTrue(flow.contains("StatementImportSearchModifier(enabled: staged != nil"))
        XCTAssertTrue(flow.contains("transactionIDs: row.exactTransactionIDs, purpose: \"matching\""))
        XCTAssertTrue(flow.contains("transactionIDs: row.possibleTransactionIDs, purpose: \"matching\""))
        XCTAssertTrue(flow.contains(".environmentObject(workspace)"), "match drill-through must share the active production store")
        XCTAssertTrue(flow.contains("statement-exact-matches-"))
        XCTAssertTrue(flow.contains("statement-possible-matches-"))
    }
    @MainActor
    func testMetadataOnlyCardEditDoesNotReclassifyFundedPurchaseAfterLaterSpending() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Cash", type: "checking", isOnBudget: true, startingBalance: 50000))
        XCTAssertTrue(source.demo.createAccount(name: "Card", type: "credit", isOnBudget: true))
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Plan"))
        let category = source.demo.categories[0].id, card = source.demo.accounts[1].id
        try await source.assignMoney(.init(categoryID: category, month: "2026-09-01", assignedMinor: 10000, expectedVersion: 0))
        let operation = RecordTransactionOperation(accountID: card, categoryID: category, amountMinor: -10000, occurredOn: "2026-09-01", payeeName: "Market", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await source.recordTransaction(operation)
        let id = try XCTUnwrap(source.demo.transactions.first?.id)
        try await source.recordTransaction(operation)
        let before = source.demo.accounts[1]
        XCTAssertEqual(before.paymentReserved, 10000)
        try await source.updateTransaction(id: id, operation: operation)
        XCTAssertEqual(source.demo.accounts[1].paymentReserved, before.paymentReserved)
        try await source.updateTransaction(id: id, operation: .init(accountID: card, categoryID: category, amountMinor: -10000, occurredOn: "2026-09-01", payeeName: "Market", memo: "Receipt saved", isCleared: true, splits: [], flag: "orange", tags: ["reviewed"], attachmentMetadata: []))
        let after = source.demo.accounts[1]
        XCTAssertEqual(after.paymentReserved, before.paymentReserved)
        XCTAssertEqual(after.balance, before.balance)
        XCTAssertEqual(after.cleared, before.cleared - 10000)
        XCTAssertEqual(source.demo.transactions.first { $0.id == id }?.memo, "Receipt saved")
    }
    @MainActor
    func testBulkTagsRejectOverflowAtomicallyAndPreserveOrderedNormalizedTags() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Cash", type: "checking", isOnBudget: true))
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Plan"))
        let account = source.demo.accounts[0].id
        let category = source.demo.categories[0].id
        for tags in [["existing"], (0..<20).map { "tag-\($0)" }] {
            try await source.recordTransaction(.init(accountID: account, categoryID: category, amountMinor: -100, occurredOn: "2026-09-01", payeeName: "Tags", memo: "Keep", isCleared: false, splits: [], flag: "orange", tags: tags, attachmentMetadata: []))
        }
        let before = source.demo.transactions
        let ids = before.map(\.id)
        do {
            try await source.bulkUpdateTransactions(.init(transactionIDs: ids, action: "add_tags", tags: ["new"]))
            XCTFail("An overflowing batch must fail rather than drop a requested tag")
        } catch { }
        XCTAssertEqual(source.demo.transactions, before)
        let full = try XCTUnwrap(before.first { $0.tags.count == 20 })
        try await source.bulkUpdateTransactions(.init(transactionIDs: [full.id], action: "add_tags", tags: [" TAG-0 ", "tag-0"]))
        XCTAssertEqual(source.demo.transactions, before)
        let ordinary = try XCTUnwrap(before.first { $0.tags == ["existing"] })
        try await source.bulkUpdateTransactions(.init(transactionIDs: [ordinary.id], action: "add_tags", tags: [" Review ", "review"]))
        XCTAssertEqual(source.demo.transactions.first { $0.id == ordinary.id }?.tags, ["existing", "review"])
        try await source.bulkUpdateTransactions(.init(transactionIDs: [ordinary.id], action: "remove_tags", tags: [" REVIEW "]))
        XCTAssertEqual(source.demo.transactions, before)
    }
    func testFundingRequestDetailUsesAuthorizedNamesWithoutRawIdentityFallback() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveRequestDetailView"))
        let end = try XCTUnwrap(source.range(of: "private struct MoveMoneyPresentation", range: start.upperBound..<source.endIndex))
        let detail = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(detail.contains("request.requesterDisplayName ?? requesterName"))
        XCTAssertTrue(detail.contains("action.actorDisplayName ?? action.actorUserID.flatMap(requesterName)"))
        XCTAssertTrue(detail.contains("map(store.categoryDisplayName)"))
        XCTAssertFalse(detail.contains("id.capitalized"))
        XCTAssertTrue(source.contains("item.action.actorDisplayName ?? requestActorName"))
    }
    func testDropboxReadResponsesCannotOverwriteNewerOperations() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/DropboxBackupCoordinator.swift")
        let source = try String(contentsOf: file)
        for signature in ["func connect()", "func upload(packageURL:", "func download(_ generation:", "func delete(_ generation:", "func revoke()"] {
            let start = try XCTUnwrap(source.range(of: signature))
            let tail = source[start.upperBound...]
            let invalidation = try XCTUnwrap(tail.range(of: "observationRevision = UUID()"))
            let busy = try XCTUnwrap(tail.range(of: "isWorking = true"))
            XCTAssertLessThan(invalidation.lowerBound, busy.lowerBound)
        }
        let listStart = try XCTUnwrap(source.range(of: "private func refreshGenerations(revision: UUID)"))
        let listEnd = try XCTUnwrap(source.range(of: "func recordSuccessfulBackup", range: listStart.upperBound..<source.endIndex))
        let list = source[listStart.upperBound..<listEnd.lowerBound]
        XCTAssertEqual(list.components(separatedBy: "guard observationRevision == revision else { return }").count - 1, 2)
        XCTAssertTrue(list.contains("let refreshed = try await destination.generations()"))
        XCTAssertTrue(source.contains("guard !isWorking else { return }"))
        XCTAssertFalse(source.contains("isConnected = await credential.isConnected()"))
        XCTAssertTrue(source.contains("guard isWorking, observationRevision == revision else { return }"), "Late progress must not replace a newer operation")
        XCTAssertEqual(source.components(separatedBy: "defer { isWorking = false; transferProgress = nil }").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "await self?.receiveTransferProgress(value, revision: revision)").count - 1, 2)
        let workspace = try String(contentsOf: file.deletingLastPathComponent().appendingPathComponent("BudgetWorkspaceView.swift"))
        XCTAssertTrue(workspace.contains("dropbox-transfer-progress"))
        XCTAssertTrue(workspace.contains("Finalizing encrypted transfer"))
    }
    func testFundingRequestHistoryExplainsRecordedAmountsAndDates() throws {
        for action in ["approved", "partially_approved"] {
            XCTAssertEqual(FundingRequestHistoryPresentation.amountLabel(for: action), "Approved amount")
        }
        for action in ["submitted", "revised"] {
            XCTAssertEqual(FundingRequestHistoryPresentation.amountLabel(for: action), "Requested amount")
        }
        XCTAssertEqual(FundingRequestHistoryPresentation.amountLabel(for: "future_action"), "Recorded amount")
        XCTAssertEqual(FundingRequestHistoryPresentation.timestamp("legacy timestamp"), "legacy timestamp")
        XCTAssertEqual(FundingRequestHistoryPresentation.timestamp("2026-10-09T12:00:00Z"),
                       FundingRequestHistoryPresentation.timestamp("2026-10-09T12:00:00.000000Z"))
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveRequestDetailView"))
        let detail = source[start.upperBound...].prefix(10000)
        XCTAssertTrue(detail.contains("if let amount = action.amountMinor"))
        XCTAssertTrue(detail.contains("value: store.format(amount)"))
        XCTAssertTrue(detail.contains("timestamp(action.createdAt)"))
    }
    func testDropboxTransfersGuardBeforeDestinationAndBusyStateMutation() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/DropboxBackupCoordinator.swift")
        let source = try String(contentsOf: file)
        for signature in ["func upload(packageURL:", "func download(_ generation:", "func delete(_ generation:"] {
            let start = try XCTUnwrap(source.range(of: signature))
            let tail = source[start.upperBound...]
            let guardRange = try XCTUnwrap(tail.range(of: "guard !isWorking else { throw DropboxBackupOperationError.alreadyWorking }"))
            let destinationRange = try XCTUnwrap(tail.range(of: "let destination = try destination()"))
            XCTAssertLessThan(guardRange.lowerBound, destinationRange.lowerBound, signature)
        }
    }
    func testCashRolloverClearsDeniedScopeAndKeepsPostSaveReloadInsideLock() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct CashRolloverSettingsView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AppearanceSettingsView: View", range: start.upperBound..<source.endIndex))
        let view = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("observation = nil; history = []; nextBeforeVersion = nil; effectiveMonth = \"\"; confirm = false"))
        XCTAssertEqual(view.components(separatedBy: "await fetchPolicyObservations()").count - 1, 2)
        XCTAssertEqual(view.components(separatedBy: "guard !store.workspaceAccessDenied else { discardPolicyObservations(); return }").count - 1, 2)
        XCTAssertTrue(view.contains(".onChange(of: store.workspaceAccessDenied)"))
        XCTAssertTrue(view.contains("if HistoryObservationPolicy.mustDiscard(after: failure) { discardPolicyObservations() }"))
    }
    func testDebtTermsEditorDiscardsDeniedDraftAndGuardsCommands() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/EditingViews.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "struct DebtTermsEditorView: View"))
        let end = try XCTUnwrap(source.range(of: "struct CategoryCreationView: View", range: start.upperBound..<source.endIndex))
        let editor = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(editor.contains("ContentUnavailableView(\"Debt terms unavailable\""))
        XCTAssertTrue(editor.contains("accessDenied = true; history = []; hasMoreHistory = false; hasStoredTerms = false"))
        XCTAssertTrue(editor.contains("originalPrincipal = \"\"; originalTerm = \"\"; remainingTerm = \"\"; promoRate = \"\"; promoEnd = \"\""))
        XCTAssertTrue(editor.contains("guard !accessDenied, !isLoading, !isLoadingHistory, !isSaving, inputsValid else { return }"))
        XCTAssertEqual(editor.components(separatedBy: "catch { handleDebtTermsError(error) }").count - 1, 4)
    }
    func testLedgerImportAndHouseholdHistoryApplyDefinitiveDenialPolicy() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        XCTAssertTrue(source.contains("allocationOperations = []; allocationHistoryNextCursor = nil"))
        XCTAssertTrue(source.contains("guard authorityRevision == revision, !workspaceAccessDenied else { return }"))
        for name in ["ReconciliationHistoryView", "StatementImportHistoryView", "HouseholdMemberLifecycleView"] {
            let start = try XCTUnwrap(source.range(of: "private struct \(name): View"))
            let end = source.range(of: "\nprivate struct ", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
            let view = source[start.lowerBound..<end]
            if name == "ReconciliationHistoryView" {
                XCTAssertTrue(view.contains("DecisionHistoryPager<APIReconciliationHistory>()"))
            } else {
                XCTAssertTrue(view.contains("HistoryObservationPolicy.mustDiscard(after: error)"), name)
            }
        }
        XCTAssertTrue(source.contains("pager.clear(); selected = nil"))
        XCTAssertTrue(source.contains("invitations = []; history.prepare(scope: \"denied\")"))
    }
    func testProductionTransactionBrowsersDiscardDeniedIndependentObservations() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let activityStart = try XCTUnwrap(source.range(of: "private struct LiveActivityView: View"))
        let activityEnd = try XCTUnwrap(source.range(of: "private struct TransactionBrowserFilter:"))
        let activity = String(source[activityStart.lowerBound..<activityEnd.lowerBound])
        XCTAssertEqual(activity.components(separatedBy: "HistoryObservationPolicy.mustDiscard(after: error)").count - 1, 3)
        XCTAssertTrue(activity.contains("history.clear(); commandError = nil"))
        XCTAssertTrue(activity.contains("transactionSelection.removeAll(); selecting = false; showTagPrompt = false"))
        XCTAssertTrue(activity.contains("recentTransactionChanges = []"))
        XCTAssertTrue(activity.contains("recentReconciliations = []; reconciliationAccount = nil"))
        XCTAssertTrue(activity.contains(".task(id: activityObservationKey)"))
        XCTAssertTrue(activity.contains("private var activityObservationKey: String { \"\\(store.authorityRevision)|\\(store.reportRevision)\" }"))
        XCTAssertEqual(activity.components(separatedBy: "let revision = activityObservationKey").count - 1, 2)
        XCTAssertEqual(activity.components(separatedBy: "guard revision == activityObservationKey").count - 1, 4)
        let scopedStart = try XCTUnwrap(source.range(of: "private struct ScopedTransactionHistoryView: View"))
        let scopedEnd = try XCTUnwrap(source.range(of: "private struct TransactionFilterView: View"))
        let scoped = String(source[scopedStart.lowerBound..<scopedEnd.lowerBound])
        XCTAssertTrue(scoped.contains("@StateObject private var history = TransactionHistoryPager()"))
        XCTAssertTrue(scoped.contains("history.clear()"))
        XCTAssertTrue(scoped.contains("history.load(query:"))
        XCTAssertTrue(scoped.contains("history.retryIntent.shouldReset(hasLoadedRows: !history.rows.isEmpty)"))
        XCTAssertTrue(activity.contains("history.load(query:"))
        XCTAssertTrue(activity.contains("preserveDepth: true"))
    }

    @MainActor
    func testSharedTransactionPagerRetriesOlderPageAndPurgesDeniedHistory() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let rows = Array(store.transactions.prefix(2))
        XCTAssertEqual(rows.count, 2)
        let pager = TransactionHistoryPager()
        let query = APITransactionQuery(limit: 1)
        await pager.load(query: query, reset: true) { request in
            XCTAssertNil(request.cursor)
            return .init(items: [rows[0]], nextCursor: "next", totalCount: 2)
        }
        await pager.load(query: query, reset: false) { request in
            XCTAssertEqual(request.cursor, "next")
            throw URLError(.networkConnectionLost)
        }
        XCTAssertEqual(pager.rows, [rows[0]])
        XCTAssertEqual(pager.retryIntent, .older)
        await pager.load(query: query, reset: false) { request in
            XCTAssertEqual(request.cursor, "next")
            return .init(items: [rows[1]], nextCursor: nil, totalCount: 2)
        }
        XCTAssertEqual(pager.rows, rows)
        XCTAssertNil(pager.errorMessage)
        await pager.load(query: query, reset: false) { _ in XCTFail("Final page must not repeat"); return .init(items: [], nextCursor: nil, totalCount: 0) }
        await pager.load(query: query, reset: true) { _ in throw APIClientError.server(status: 403, message: "Denied") }
        XCTAssertTrue(pager.rows.isEmpty)
        XCTAssertNil(pager.nextCursor)
        XCTAssertFalse(pager.loading)
    }

    @MainActor
    func testPayeePagerRefreshIsBoundedAtomicAndKeepsRetryIntent() async throws {
        func payee(_ id: String, _ name: String) throws -> APIPayee {
            try JSONDecoder().decode(APIPayee.self, from: Data("{\"id\":\"\(id)\",\"household_id\":\"h\",\"display_name\":\"\(name)\",\"is_archived\":false,\"transaction_count\":1,\"net_amount_minor\":-100,\"aliases\":[]}".utf8))
        }
        let first = try payee("a", "Before"), second = try payee("b", "Other"), renamed = try payee("a", "Renamed")
        let pager = PayeeSearchPager()
        pager.prepare(query: "", authority: 1, includeArchived: true)
        await pager.load(reset: true) { _ in .init(items: [first], nextCursor: "second") }
        await pager.load(reset: false) { cursor in
            XCTAssertEqual(cursor, "second")
            return .init(items: [second], nextCursor: "third")
        }
        pager.prepare(query: "", authority: 1, includeArchived: true)
        var requests = 0
        await pager.load(reset: true) { cursor in
            requests += 1
            XCTAssertEqual(pager.rows, [first, second], "No intermediate replacement page")
            return cursor == nil ? .init(items: [renamed], nextCursor: "second") : .init(items: [second], nextCursor: "third")
        }
        XCTAssertEqual(requests, 2, "Do not load unopened directory pages")
        XCTAssertEqual(pager.rows, [renamed, second])
        await pager.load(reset: true) { cursor in
            if cursor != nil { throw URLError(.notConnectedToInternet) }
            return .init(items: [first], nextCursor: "second")
        }
        XCTAssertEqual(pager.rows, [renamed, second])
        XCTAssertEqual(pager.retryIntent, .refresh)
        await pager.load(reset: false) { _ in .init(items: [second], nextCursor: "third") }
        XCTAssertEqual(pager.rows, [renamed, second], "Duplicate or non-advancing pages cannot publish")
        XCTAssertEqual(pager.retryIntent, .older)
        await pager.load(reset: true) { _ in throw APIClientError.server(status: 403, message: "Denied") }
        XCTAssertTrue(pager.rows.isEmpty)
        pager.prepare(query: "other", authority: 2, includeArchived: false)
        await pager.load(reset: true) { _ in
            pager.prepare(query: "newer", authority: 3, includeArchived: false)
            return .init(items: [first], nextCursor: nil)
        }
        XCTAssertTrue(pager.rows.isEmpty, "An older authority/query response cannot repopulate search")
        pager.invalidate()
    }

    @MainActor
    func testActivityAuditObservationsAdvanceWithoutPermissionChange() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let authority = store.authorityRevision
        let revision = store.reportRevision
        let date = BudgetWorkspaceStore.dateString(Date.demo(monthsAgo: 0, day: 15))
        try await store.createTransaction(.init(accountID: "checking", categoryID: "groceries", amountMinor: -100,
            occurredOn: date, payeeName: "Audit refresh merchant", memo: "", isCleared: true,
            splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let transaction = try XCTUnwrap(store.transactions.first { $0.payeeName == "Audit refresh merchant" })
        XCTAssertEqual(store.authorityRevision, authority)
        XCTAssertGreaterThan(store.reportRevision, revision)
        let changes = try await store.recentTransactionChanges()
        XCTAssertTrue(changes.contains { $0.transactionID == transaction.id })
        let beforeReconciliation = store.reportRevision
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let balance = store.clearedBalance(for: account)
        try await store.reconcile(accountID: account.id, statementBalance: balance, throughDate: date,
            createAdjustment: false, reason: "")
        XCTAssertEqual(store.authorityRevision, authority)
        XCTAssertGreaterThan(store.reportRevision, beforeReconciliation)
        let reconciliations = try await store.recentReconciliationHistory()
        XCTAssertTrue(reconciliations.contains { $0.accountID == account.id && $0.statementBalanceMinor == balance })
    }

    @MainActor
    func testScopedHistoryRefreshDropsEditedFilterMismatchWithoutChangingMoney() async throws {
        let source = DemoWorkspaceDataSource()
        let operation = RecordTransactionOperation(accountID: "checking", categoryID: "groceries", amountMinor: -100,
            occurredOn: "2026-09-15", payeeName: "Unique refresh merchant", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await source.recordTransaction(operation)
        let query = APITransactionQuery(search: "Unique refresh merchant", limit: 50)
        let pager = TransactionHistoryPager()
        await pager.load(query: query, reset: true) { try await source.browseTransactions(query: $0) }
        let row = try XCTUnwrap(pager.rows.first)
        XCTAssertEqual(pager.totalCount, 1)
        let accounts = source.demo.accounts
        let edited = RecordTransactionOperation(accountID: "checking", categoryID: "groceries", amountMinor: -100,
            occurredOn: "2026-09-15", payeeName: "Unique refresh merchant", memo: "Updated in shared editor", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await source.updateTransaction(id: row.id, operation: edited)
        await pager.load(query: query, reset: true, preserveDepth: true) { try await source.browseTransactions(query: $0) }
        XCTAssertEqual(pager.rows.first?.memo, "Updated in shared editor")
        let renamed = RecordTransactionOperation(accountID: "checking", categoryID: "groceries", amountMinor: -100,
            occurredOn: "2026-09-15", payeeName: "Different merchant", memo: "Updated in shared editor", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await source.updateTransaction(id: row.id, operation: renamed)
        await pager.load(query: query, reset: true, preserveDepth: true) { try await source.browseTransactions(query: $0) }
        XCTAssertTrue(pager.rows.isEmpty)
        XCTAssertEqual(pager.totalCount, 0)
        XCTAssertEqual(source.demo.accounts, accounts)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let text = try String(contentsOf: file)
        let start = try XCTUnwrap(text.range(of: "private struct ScopedTransactionHistoryView: View"))
        let end = try XCTUnwrap(text.range(of: "private struct TransactionHistoryRows: View"))
        let view = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(view.contains("\\(filter.description)|\\(store.reportRevision)"))
        XCTAssertTrue(view.contains("preserveDepth: true"))
        XCTAssertTrue(view.contains("if loadedFilter != filter.description"))
    }

    @MainActor
    func testRegisterRefreshPreservesOpenedDepthAndPublishesAtomically() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let rows = Array(store.transactions.prefix(3))
        XCTAssertEqual(rows.count, 3)
        let pager = TransactionHistoryPager()
        let query = APITransactionQuery(limit: 1)
        let fetch: (APITransactionQuery) async throws -> APITransactionPage = { request in
            let index = Int(request.cursor ?? "0")!
            return .init(items: [rows[index]], nextCursor: index < 2 ? String(index + 1) : nil, totalCount: 3)
        }
        await pager.load(query: query, reset: true, fetch: fetch)
        await pager.load(query: query, reset: false, fetch: fetch)
        XCTAssertEqual(pager.rows, Array(rows.prefix(2)))
        var calls = 0
        await pager.load(query: query, reset: true, preserveDepth: true) { request in
            calls += 1
            XCTAssertEqual(pager.rows, Array(rows.prefix(2)), "Do not publish an intermediate first page")
            return try await fetch(request)
        }
        XCTAssertEqual(calls, 2, "Do not fetch unopened history")
        XCTAssertEqual(pager.rows, Array(rows.prefix(2)))
        XCTAssertEqual(pager.nextCursor, "2")
        await pager.load(query: query, reset: true, preserveDepth: true) { request in
            if request.cursor != nil { throw URLError(.notConnectedToInternet) }
            return try await fetch(request)
        }
        XCTAssertEqual(pager.rows, Array(rows.prefix(2)))
        XCTAssertEqual(pager.nextCursor, "2")
        XCTAssertNotNil(pager.errorMessage)
        await pager.load(query: query, reset: true, preserveDepth: true) { _ in
            .init(items: [rows[0]], nextCursor: nil, totalCount: 1)
        }
        XCTAssertEqual(pager.rows, [rows[0]], "A shorter authoritative history can shrink the list")
        XCTAssertEqual(pager.totalCount, 1)
        await pager.load(query: query, reset: true, preserveDepth: true) { _ in throw APIClientError.server(status: 403, message: "Denied") }
        XCTAssertTrue(pager.rows.isEmpty)
    }

    @MainActor
    func testAccountRegisterUsesBoundedSharedPagerWithoutFinancialMutation() async throws {
        let source = DemoWorkspaceDataSource()
        let operations = (0..<75).map { index in RecordTransactionOperation(accountID: "checking", categoryID: nil,
            amountMinor: 1, occurredOn: "2026-09-15", payeeName: "Paged merchant \(index)", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []) }
        XCTAssertNotNil(source.demo.recordCanonicalTransactionBatch(operations))
        let accounts = source.demo.accounts, available = source.demo.unassignedMinor
        let pager = TransactionHistoryPager()
        let query = APITransactionQuery(accountIDs: ["checking"], limit: 50)
        await pager.load(query: query, reset: true) { try await source.browseTransactions(query: $0) }
        XCTAssertEqual(pager.rows.count, 50)
        XCTAssertNotNil(pager.nextCursor)
        while pager.nextCursor != nil {
            await pager.load(query: query, reset: false) { try await source.browseTransactions(query: $0) }
            XCTAssertNil(pager.errorMessage)
            if pager.errorMessage != nil { break }
        }
        XCTAssertEqual(pager.rows.count, pager.totalCount)
        XCTAssertGreaterThanOrEqual(pager.totalCount, 75)
        XCTAssertTrue(pager.rows.allSatisfy { $0.accountID == "checking" })
        XCTAssertEqual(Set(pager.rows.map(\.id)).count, pager.rows.count)
        XCTAssertEqual(source.demo.accounts, accounts)
        XCTAssertEqual(source.demo.unassignedMinor, available)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let text = try String(contentsOf: file)
        let start = try XCTUnwrap(text.range(of: "struct LiveAccountRegisterView: View"))
        let end = try XCTUnwrap(text.range(of: "private struct ReconciliationHistoryView: View"))
        let register = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(register.contains("TransactionHistoryRows(history: history, showsRegisterBadges: true"))
        XCTAssertTrue(register.contains("accountIDs: [account.id], limit: 50"))
        XCTAssertFalse(register.contains("store.transactions(for: account)"))
    }

    @MainActor
    func testCategoryAndPayeePreviewsUseBoundedCanonicalQueriesIncludingSplits() async throws {
        let source = DemoWorkspaceDataSource()
        try await source.recordTransaction(.init(accountID: "checking", categoryID: nil, amountMinor: 1,
            occurredOn: "2026-09-15", payeeName: "Preview merchant", memo: "", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let all = try await source.browseTransactions(query: .init(limit: 200))
        let split = try XCTUnwrap(all.items.first { !$0.splits.isEmpty })
        let categoryID = try XCTUnwrap(split.splits.first?.categoryID)
        let payeeID = try XCTUnwrap(all.items.first { $0.payeeName == "Preview merchant" }?.payeeID)
        let accounts = source.demo.accounts, available = source.demo.unassignedMinor
        let category = TransactionHistoryPager()
        await category.load(query: .init(categoryIDs: [categoryID], limit: 20), reset: true) { query in
            XCTAssertEqual(query.limit, 20)
            return try await source.browseTransactions(query: query)
        }
        XCTAssertNil(category.errorMessage)
        XCTAssertTrue(category.rows.contains { $0.id == split.id })
        XCTAssertTrue(category.rows.allSatisfy { $0.categoryID == categoryID || $0.splits.contains { $0.categoryID == categoryID } })
        let payee = TransactionHistoryPager()
        await payee.load(query: .init(payeeIDs: [payeeID], limit: 10), reset: true) { query in
            XCTAssertEqual(query.limit, 10)
            return try await source.browseTransactions(query: query)
        }
        XCTAssertNil(payee.errorMessage)
        XCTAssertFalse(payee.rows.isEmpty)
        XCTAssertTrue(payee.rows.allSatisfy { $0.payeeID == payeeID })
        XCTAssertEqual(source.demo.accounts, accounts)
        XCTAssertEqual(source.demo.unassignedMinor, available)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let text = try String(contentsOf: file)
        for name in ["PayeeEditorView", "LivePlanCategoryDetailView"] {
            let start = try XCTUnwrap(text.range(of: "private struct \(name): View"))
            let end = text.range(of: "\nprivate struct ", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
            let view = String(text[start.lowerBound..<end])
            XCTAssertTrue(view.contains("previewOnly: true, allowsQuickClearing: false"))
            XCTAssertTrue(view.contains("View All Transactions"))
            XCTAssertFalse(view.contains("store.transactions.filter"))
            XCTAssertTrue(view.contains("recentHistory.clear()"))
        }
    }

    @MainActor
    func testAccountBalancePresentationRequiresExplicitCapabilityDespiteCachedLedger() async throws {
        let owner = BudgetWorkspaceStore.demo()
        await owner.refresh()
        XCTAssertTrue(owner.canViewAccountBalances)
        let budget = APIBudget(id: owner.budget.id, householdID: owner.budget.householdID, name: "Restricted",
            currencyCode: "USD", effectivePermission: .view, capabilities: ["view_budget", "view_accounts", "view_transactions"])
        let restricted = BudgetWorkspaceStore(budget: budget)
        restricted.accounts = owner.accounts
        restricted.transactions = owner.transactions
        restricted.accountBalances = owner.accountBalances
        XCTAssertTrue(restricted.budget.can("view_accounts"))
        XCTAssertTrue(restricted.budget.can("view_transactions"))
        XCTAssertFalse(restricted.canViewAccountBalances, "Neither visible transactions nor old balance observations grant balance authority")
        restricted.accountBalances = [:]
        XCTAssertFalse(restricted.canViewAccountBalances, "Missing server observations must not enable a local aggregate fallback")
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let text = try String(contentsOf: file)
        let start = try XCTUnwrap(text.range(of: "private struct LiveAccountsView: View"))
        let end = try XCTUnwrap(text.range(of: "private struct ReconciliationHistoryView: View"))
        let accounts = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertGreaterThanOrEqual(accounts.components(separatedBy: "if store.canViewAccountBalances").count - 1, 3)
        XCTAssertTrue(accounts.contains("if store.canViewAccountBalances && store.budget.can(\"reconcile_account\")"))
        XCTAssertTrue(accounts.contains("if !allowed { showReconcile = false; showReconciliationHistory = false }"))
        XCTAssertTrue(accounts.contains("TransactionHistoryRows(history: history"), "Granted transaction visibility remains usable")
    }

    @MainActor
    func testActivityOnlyPublishesAndFinishesLatestRefresh() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveActivityView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct TransactionBrowserFilter:"))
        let activity = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(activity.contains("@StateObject private var history = TransactionHistoryPager()"))
        XCTAssertTrue(activity.contains("\\(selectionKey)|\\(store.reportRevision)"))
        XCTAssertTrue(activity.contains("if loadedQuery != selectionKey"))
        XCTAssertTrue(activity.contains("preserveDepth: true"))
        XCTAssertTrue(activity.contains("\\(store.authorityRevision)|\\(search)|\\(filter)"))
        XCTAssertFalse(activity.contains("await load(reset: true); errorMessage = nil"), "Bulk success must not hide a failed authoritative refresh")
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let rows = Array(store.transactions.prefix(2))
        XCTAssertEqual(rows.count, 2)
        let pager = TransactionHistoryPager()
        await pager.load(query: .init(limit: 1), reset: true) { _ in
            await pager.load(query: .init(limit: 1), reset: true) { _ in
                .init(items: [rows[1]], nextCursor: nil, totalCount: 1)
            }
            return .init(items: [rows[0]], nextCursor: nil, totalCount: 1)
        }
        XCTAssertEqual(pager.rows, [rows[1]], "An earlier request cannot replace a newer observation")
        XCTAssertFalse(pager.loading)
        await pager.load(query: .init(limit: 1), reset: true) { _ in
            pager.clear()
            return .init(items: [rows[0]], nextCursor: nil, totalCount: 1)
        }
        XCTAssertTrue(pager.rows.isEmpty, "Authority clearing invalidates an in-flight observation")
    }
    func testReportHistoryRefreshPublishesReplacementOnlyAfterCurrentResponse() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift"))
        let start = try XCTUnwrap(source.range(of: "private struct LiveReportTransactionsView:"))
        let end = try XCTUnwrap(source.range(of: "private struct LiveReportCategoryView:", range: start.upperBound..<source.endIndex))
        let section = String(source[start.lowerBound..<end.lowerBound])
        let loadStart = try XCTUnwrap(section.range(of: "private func load(reset:"))
        let load = String(section[loadStart.lowerBound...])
        let scopeGuard = try XCTUnwrap(load.range(of: "guard !Task.isCancelled"))
        let replacement = try XCTUnwrap(load.range(of: "if reset { rows = []; batchIndex = 0 }"))
        XCTAssertGreaterThan(replacement.lowerBound, scopeGuard.lowerBound)
        XCTAssertFalse(load.contains("if reset { batchIndex = 0; nextCursor = nil; rows = [] }"))
        XCTAssertTrue(load.contains("let requestCursor = reset ? nil : nextCursor"))
        XCTAssertTrue(load.contains("retryFromStart = reset"))
        XCTAssertTrue(section.contains("retryFromStart || rows.isEmpty"))
        XCTAssertTrue(load.contains("if HistoryObservationPolicy.mustDiscard(after: error) { rows = []; nextCursor = nil; batchIndex = 0 }"))
    }

    func testHistoryRetryPreservesFailedRequestIntentAndRestartsAfterEviction() throws {
        XCTAssertTrue(HistoryRetryIntent.refresh.shouldReset(hasLoadedRows: true))
        XCTAssertTrue(HistoryRetryIntent.refresh.shouldReset(hasLoadedRows: false))
        XCTAssertFalse(HistoryRetryIntent.older.shouldReset(hasLoadedRows: true))
        XCTAssertTrue(HistoryRetryIntent.older.shouldReset(hasLoadedRows: false))
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL)
        for name in ["BudgetStructureHistoryView", "PayeeHistoryView", "TargetHistoryView", "ScheduledTransactionHistoryView", "DelegatedPolicyHistoryView", "DebtPayoffPlanHistoryView"] {
            let start = try XCTUnwrap(source.range(of: "private struct \(name): View"))
            let end = source.range(of: "\nprivate struct ", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
            let view = source[start.lowerBound..<end]
            XCTAssertTrue(view.contains("retryIntent.shouldReset(hasLoadedRows: !rows.isEmpty)"), name)
            XCTAssertTrue(view.contains("DecisionHistoryPager<"), name)
            XCTAssertTrue(view.contains("history.prepare(scope: historyScope)"), name)
            XCTAssertTrue(view.contains(".task(id: historyContext)"), name)
            XCTAssertTrue(view.contains("history.invalidate()"), name)
        }
        let start = try XCTUnwrap(source.range(of: "private struct TransactionChangeHistoryView: View"))
        let end = source.range(of: "\nprivate struct ", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let transactionHistory = source[start.lowerBound..<end]
        XCTAssertTrue(transactionHistory.contains("if loading && changes.isEmpty"))
        XCTAssertTrue(transactionHistory.contains("DecisionHistoryPager<APITransactionChange>()"))
        XCTAssertTrue(transactionHistory.contains(".task(id: historyContext)"))
        XCTAssertTrue(transactionHistory.contains("history.prepare(scope: historyScope)"))
        XCTAssertTrue(transactionHistory.contains("history.invalidate()"))
        XCTAssertTrue(transactionHistory.contains("load(append: !retryIntent.shouldReset(hasLoadedRows: !changes.isEmpty))"))
        XCTAssertTrue(transactionHistory.contains("History could not be refreshed."))
    }

    func testHistoryDiscardsDefinitiveDenialsButRetainsTemporaryFailures() {
        for status in [401, 403, 404] {
            // Classification follows the HTTP contract, not English wording.
            XCTAssertTrue(HistoryObservationPolicy.mustDiscard(after: APIClientError.server(status: status, message: "Scope changed")))
        }
        for status in [409, 422, 429, 500, 503] {
            XCTAssertFalse(HistoryObservationPolicy.mustDiscard(after: APIClientError.server(status: status, message: "Request failed")))
        }
        XCTAssertTrue(HistoryObservationPolicy.mustDiscard(after: BudgetApplicationError.permissionDenied("Denied")))
        XCTAssertTrue(HistoryObservationPolicy.mustDiscard(after: BudgetApplicationError.notFound("Unavailable")))
        XCTAssertFalse(HistoryObservationPolicy.mustDiscard(after: URLError(.notConnectedToInternet)))
        XCTAssertEqual(BudgetApplicationError.map(APIClientError.server(status: 403, message: "Scope changed")), .permissionDenied("Scope changed"))
    }
    func testProductionAccountAndTransactionHistoriesApplyDenialEviction() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp")
        let account = try String(contentsOf: directory.appendingPathComponent("EditingViews.swift"))
        let transaction = try String(contentsOf: directory.appendingPathComponent("BudgetWorkspaceView.swift"))
        XCTAssertTrue(account.contains("DecisionHistoryPager<APIAccountRevision>(pageSize: 25)"))
        XCTAssertTrue(account.contains(".task(id: historyContext)"))
        XCTAssertTrue(account.contains("workspace.authorityRevision"))
        XCTAssertTrue(account.contains("history.retryIntent.shouldReset(hasLoadedRows: !items.isEmpty)"))
        XCTAssertTrue(account.contains("history.invalidate()"))
        XCTAssertTrue(transaction.contains("DecisionHistoryPager<APITransactionChange>()"))
        XCTAssertTrue(transaction.contains("history.load(reset: !append)"))
    }
    func testIndependentDecisionHistoriesDiscardDeniedObservations() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let names = ["BudgetStructureHistoryView", "PayeeHistoryView", "TargetHistoryView", "ScheduledTransactionHistoryView", "DebtPayoffPlanHistoryView", "AllowanceDetailView", "DelegatedPolicyHistoryView"]
        for name in names {
            let start = try XCTUnwrap(source.range(of: "private struct \(name): View"))
            let end = source.range(of: "\nprivate struct ", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
            let view = String(source[start.lowerBound..<end])
            if name != "AllowanceDetailView" {
                XCTAssertTrue(view.contains("DecisionHistoryPager<"), name)
                XCTAssertTrue(view.contains("store.authorityRevision"), name)
                continue
            }
            XCTAssertTrue(view.contains("HistoryObservationPolicy.mustDiscard(after: error)"), name)
            if name == "AllowanceDetailView" {
                XCTAssertTrue(view.contains("history = []; policyHistory = []; hasOlderIssuances = false; hasOlderPolicy = false"), name)
            } else {
                XCTAssertTrue(view.contains("rows = [];"), name)
            }
        }
    }
    func testAccountHistoryExplainsAllFieldsAndResolvesOnlyAuthorizedNames() {
        let before = APIAccountRevisionSnapshot(name: "Old", accountType: "checking", isOnBudget: true, isClosed: false, paymentCategoryID: "hidden-old")
        let after = APIAccountRevisionSnapshot(name: "New", accountType: "tracking", isOnBudget: false, isClosed: true, paymentCategoryID: "hidden-new")
        func revision(_ old: APIAccountRevisionSnapshot?) -> APIAccountRevision {
            .init(id: "r", accountID: "a", action: "updated", actorUserID: "owner", actorDisplayName: "Owner", beforeSnapshot: old, afterSnapshot: after, createdAt: "2026-10-09")
        }
        let changes = AccountHistoryPresentation.changes(revision(before), categoryName: { _ in "Category no longer available" })
        XCTAssertEqual(changes.map(\.id), ["name", "type", "budget", "closed", "payment"])
        XCTAssertEqual(changes.first(where: { $0.id == "budget" })?.after, "Tracking")
        XCTAssertEqual(changes.last?.before, changes.last?.after)
        XCTAssertFalse(String(describing: changes).contains("hidden-"))
        XCTAssertTrue(AccountHistoryPresentation.changes(revision(after), categoryName: { $0 }).isEmpty)
        XCTAssertTrue(AccountHistoryPresentation.changes(revision(nil), categoryName: { _ in "Cards · Payment" }).allSatisfy { $0.before == nil })
    }
    func testAllowanceHistoryAndMutationsCannotOverlapInProductionComposition() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL)
        let start = try XCTUnwrap(source.range(of: "private struct AllowanceDetailView: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AllowanceCreateView: View", range: start.upperBound..<source.endIndex))
        let detail = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(detail.contains("private var historyBusy: Bool { loadingHistory || loadingOlderPolicy || loadingOlderIssuances }"))
        XCTAssertTrue(detail.contains("guard !isSaving, !historyBusy, hasOlderPolicy"))
        XCTAssertTrue(detail.contains("guard !isSaving, !historyBusy, hasOlderIssuances"))
        XCTAssertTrue(detail.contains("guard !isSaving, !historyBusy, let version"))
        XCTAssertTrue(detail.contains("guard !isSaving, !historyBusy else { return }; isSaving = true"))
        XCTAssertEqual(detail.components(separatedBy: "await loadHistory() } catch").count - 1, 2)
        // Post-save/background refresh supersedes stale reads without unlocking the command.
        XCTAssertTrue(detail.contains(".task(id: historyContext)"))
        XCTAssertTrue(detail.contains("historyRequestID == id, context == historyContext"))
        let pair = try XCTUnwrap(detail.range(of: "let (issuanceRows, policyRows) = try await (issuances, changes)"))
        let firstPublication = try XCTUnwrap(detail.range(of: "history = issuanceRows"))
        XCTAssertLessThan(pair.lowerBound, firstPublication.lowerBound, "Neither half publishes until both reads succeed")
        XCTAssertFalse(detail.contains("history = try await issuances"))
        XCTAssertTrue(detail.contains("HistoryRefreshReader.read(retainingCount: history.count"))
        XCTAssertTrue(detail.contains("HistoryRefreshReader.read(retainingCount: policyHistory.count"))
        for intent in ["refresh", "policy", "issuances"] {
            XCTAssertTrue(detail.contains("historyRetry = .\(intent)"))
        }
        XCTAssertTrue(detail.contains("Button(\"Retry History\")"))
    }
    func testPayeeHistoryExplainsAllAliasesMergeAndQualifiedSuggestionWithoutDirectoryLoading() {
        let old = APIPayeeRevisionSnapshot(displayName: "Market", isArchived: false,
            aliases: ["Old B", "Keep", "Old A"], defaultCategoryID: "old-private")
        let new = APIPayeeRevisionSnapshot(displayName: "New Market", isArchived: true,
            mergedIntoPayeeID: "target-private", aliases: ["New B", "Keep", "New A"], defaultCategoryID: "new-private")
        func revision(_ before: APIPayeeRevisionSnapshot?, _ after: APIPayeeRevisionSnapshot) -> APIPayeeRevision {
            .init(id: "r", payeeID: "p", budgetID: "b", action: "merged", actorUserID: "owner",
                actorDisplayName: "Owner", beforeSnapshot: before, afterSnapshot: after, createdAt: "2026-10-09")
        }
        let changes = PayeeHistoryPresentation.changes(revision(old, new),
            payeeName: { _ in "Payee not available here" }, categoryName: { _ in "Daily / Groceries" })
        XCTAssertEqual(changes.count, 8)
        XCTAssertEqual(changes.filter { $0.label == "Alias added" }.map(\.after), ["New A", "New B"])
        XCTAssertEqual(changes.filter { $0.label == "Alias removed" }.map(\.before), ["Old A", "Old B"])
        XCTAssertEqual(changes.first(where: { $0.id == "category" })?.after, "Daily / Groceries")
        XCTAssertEqual(changes.first(where: { $0.id == "merge" })?.after, "Payee not available here")
        XCTAssertFalse(changes.contains { ($0.before ?? "").contains("private") || ($0.after ?? "").contains("private") })
        XCTAssertTrue(PayeeHistoryPresentation.changes(revision(new, new), payeeName: { $0 }, categoryName: { $0 }).isEmpty)
        let redacted = APIPayeeRevisionSnapshot(displayName: "Market")
        XCTAssertTrue(PayeeHistoryPresentation.changes(revision(redacted, redacted), payeeName: { $0 }, categoryName: { $0 }).isEmpty)
        let created = PayeeHistoryPresentation.changes(revision(nil, redacted), payeeName: { $0 }, categoryName: { $0 })
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created.first?.before)
    }

    func testStructureHistoryExplainsEveryChangedFieldWithoutLeakingResourceIDs() {
        let old = APIBudgetStructureSnapshot(groupID: "private-old", name: "Food", iconName: "fork.knife",
            note: "Weekly", sortOrder: 0, isArchived: false, isEssential: true,
            isEmergencyFund: false, delegatedUserID: "private-member")
        let new = APIBudgetStructureSnapshot(groupID: "private-new", name: "Groceries", iconName: nil,
            note: nil, sortOrder: 2, isArchived: true, isEssential: false,
            isEmergencyFund: true, delegatedUserID: nil)
        func revision(_ before: APIBudgetStructureSnapshot?, _ after: APIBudgetStructureSnapshot) -> APIBudgetStructureRevision {
            .init(id: "r", resourceType: "category", resourceID: "c", action: "updated",
                actorUserID: "owner", actorDisplayName: "Owner", beforeSnapshot: before,
                afterSnapshot: after, createdAt: "2026-10-09")
        }
        let changes = BudgetStructureHistoryPresentation.changes(revision(old, new),
            groupName: { _ in "Unavailable group" }, memberName: { _ in "Unavailable member" })
        XCTAssertEqual(changes.count, 9)
        XCTAssertEqual(changes.first(where: { $0.id == "note" })?.before, "Weekly")
        XCTAssertNil(changes.first(where: { $0.id == "note" })?.after)
        XCTAssertEqual(changes.first(where: { $0.id == "group" })?.before, "Unavailable group")
        XCTAssertEqual(changes.first(where: { $0.id == "group" })?.after, "Unavailable group")
        XCTAssertFalse(changes.contains { ($0.before ?? "").contains("private-") || ($0.after ?? "").contains("private-") })
        XCTAssertTrue(BudgetStructureHistoryPresentation.changes(revision(new, new), groupName: { $0 }, memberName: { $0 }).isEmpty)
        let created = BudgetStructureHistoryPresentation.changes(revision(nil, new), groupName: { _ in "Daily" }, memberName: { _ in "Child" })
        XCTAssertTrue(created.allSatisfy { $0.before == nil })
        XCTAssertEqual(created.first(where: { $0.id == "name" })?.after, "Groceries")
    }

    func testAllowanceHistoryExplainsExactSplitsCadenceAndPrivacy() {
        let before = APIAllowancePlanRevisionSnapshot(delegatedUserID: "child", sourceCategoryID: "source", name: "Weekly",
            amountMinor: 9007199254740993, nextIssueDate: "2026-10-01", recurrenceUnit: "weeks", intervalCount: 1,
            rolloverPolicy: "rollover", isActive: true, splits: [.init(destinationCategoryID: "a", amountMinor: 9007199254740993)])
        let after = APIAllowancePlanRevisionSnapshot(delegatedUserID: "child", sourceCategoryID: "source", name: "Weekly",
            amountMinor: 9007199254740994, nextIssueDate: "2026-10-08", recurrenceUnit: "weeks", intervalCount: 2,
            rolloverPolicy: "reclaim", isActive: false, splits: [.init(destinationCategoryID: "b", amountMinor: 9007199254740994)])
        let revision = APIAllowancePlanRevision(id: "r", planID: "p", action: "updated", actorUserID: "owner",
            actorDisplayName: "Owner", beforeSnapshot: before, afterSnapshot: after, createdAt: "2026-10-09")
        let changes = AllowanceHistoryPresentation.changes(revision, formatMoney: { String($0) }, categoryName: { "Group · \($0)" }, memberName: { $0 })
        XCTAssertEqual(changes.first { $0.label == "Amount" }?.before, "9007199254740993")
        XCTAssertEqual(changes.first { $0.label == "Interval" }?.after, "2")
        XCTAssertEqual(changes.first { $0.label == "Next issue" }?.after, "2026-10-08")
        XCTAssertEqual(changes.first { $0.label == "Status" }?.after, "Paused")
        XCTAssertNil(changes.first { $0.id == "split-a" }?.after)
        XCTAssertNil(changes.first { $0.id == "split-b" }?.before)
        XCTAssertEqual(changes.first { $0.id == "split-b" }?.label, "Destination: Group · b")
        let hidden = AllowanceHistoryPresentation.changes(revision, formatMoney: { _ in "••••" }, categoryName: { $0 }, memberName: { $0 })
        XCTAssertEqual(hidden.first { $0.label == "Amount" }?.after, "••••")
        XCTAssertEqual(hidden.first { $0.id == "split-b" }?.after, "••••")
        let unchanged = APIAllowancePlanRevision(id: "n", planID: "p", action: "updated", actorUserID: "owner",
            actorDisplayName: nil, beforeSnapshot: after, afterSnapshot: after, createdAt: "2026-10-09")
        XCTAssertTrue(AllowanceHistoryPresentation.changes(unchanged, formatMoney: { String($0) }, categoryName: { $0 }, memberName: { $0 }).isEmpty)
    }

    func testReceiptCategorySuggestionsRequireOneWholePhraseIdentity() throws {
        func category(_ id: String, _ name: String, archived: Bool = false) throws -> APICategory {
            let payload: [String: Any] = ["id": id, "budget_id": "budget", "group_id": id,
                "name": name, "note": "", "sort_order": 0, "is_archived": archived,
                "is_favorite": false, "favorite_sort_order": NSNull()]
            return try JSONDecoder().decode(APICategory.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let gas = try category("gas", "Gas")
        let grocery = try category("grocery", "Groceries")
        let duplicate = try category("other-grocery", "groceries")
        XCTAssertNil(ReceiptOCR.suggestedCategoryID(in: "VEGAS MARKET", categories: [gas]))
        XCTAssertEqual(ReceiptOCR.suggestedCategoryID(in: "GAS: TOTAL $20.00", categories: [gas]), "gas")
        XCTAssertNil(ReceiptOCR.suggestedCategoryID(in: "Groceries", categories: [grocery, duplicate]))
        XCTAssertNil(ReceiptOCR.suggestedCategoryID(in: "Groceries", categories: [duplicate, grocery]), "Order must not choose a group")
        XCTAssertNil(ReceiptOCR.suggestedCategoryID(in: "Groceries and gas", categories: [gas, grocery]))
        XCTAssertEqual(ReceiptOCR.suggestedCategoryID(in: "Groceries", categories: [grocery, try category("old", "Groceries", archived: true)]), "grocery")
        XCTAssertNil(ReceiptOCR.suggestedCategoryID(in: "anything", categories: [try category("empty", " ")]))
        XCTAssertEqual(ReceiptOCR.suggestedCategoryID(in: "CAFÉ\nDINING", categories: [try category("dining", "Cafe Dining")]), "dining")
        XCTAssertNil(ReceiptOCR.suggestedCategoryID(in: "hidden groceries", categories: []))
        XCTAssertEqual(ReceiptOCR.suggestedCategoryID(in: "Groceries", categories: [grocery, grocery]), "grocery")
    }

    func testReceiptVisionOrientationPreservesEveryRotationAndMirror() {
        let pairs: [(UIImage.Orientation, CGImagePropertyOrientation)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right),
            (.upMirrored, .upMirrored), (.downMirrored, .downMirrored),
            (.leftMirrored, .leftMirrored), (.rightMirrored, .rightMirrored)]
        for (source, expected) in pairs { XCTAssertEqual(ReceiptOCR.visionOrientation(source), expected) }
    }

    @MainActor
    func testReceiptVisionRecognizesRotatedCameraShapedJPEG() async throws {
        let size = CGSize(width: 900, height: 500)
        let renderer = UIGraphicsImageRenderer(size: size)
        let upright = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black]
            ("FRESH MARKET" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: attributes)
            ("Subtotal $18.00" as NSString).draw(at: CGPoint(x: 60, y: 150), withAttributes: attributes)
            ("TOTAL $19.50" as NSString).draw(at: CGPoint(x: 60, y: 250), withAttributes: attributes)
        }
        let rotated = renderer.image { context in
            context.cgContext.translateBy(x: size.width, y: size.height)
            context.cgContext.rotate(by: .pi)
            upright.draw(at: .zero)
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(rotated.cgImage),
            [kCGImagePropertyOrientation: CGImagePropertyOrientation.down.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try XCTUnwrap(UIImage(data: data as Data)).imageOrientation, .down)
        let suggestion = try await ReceiptOCR.recognize(data as Data, currencyCode: "USD", categories: [])
        XCTAssertEqual(suggestion.amountMinor, 1950)
        XCTAssertEqual(suggestion.payee, "FRESH MARKET")
    }

    func testProductionReceiptCameraUsesSharedCaptureAndReviewOnlyPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("BudgetApp/EditingViews.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("take-receipt-photo"))
        XCTAssertTrue(source.contains("AttachmentCameraPicker { image in"))
        XCTAssertTrue(source.contains("onDismiss:"))
        XCTAssertTrue(source.contains("await scanReceiptData(data)"))
        XCTAssertTrue(source.contains("AVCaptureDevice.requestAccess(for: .video)"))
        XCTAssertTrue(source.contains("Camera is not available on this device. Choose a receipt photo instead."))
        XCTAssertTrue(source.contains("workspace.categoryDisplayName($0)"))
        let start = try XCTUnwrap(source.range(of: "private func scanReceiptData"))
        let end = try XCTUnwrap(source.range(of: "private func apply(_ suggestion", range: start.upperBound..<source.endIndex))
        let capturePath = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(capturePath.contains("ReceiptOCR.recognize"))
        XCTAssertFalse(capturePath.contains("createTransaction"))
        XCTAssertFalse(capturePath.contains("uploadTransactionAttachment"))
        XCTAssertFalse(capturePath.contains("UIImageWriteToSavedPhotosAlbum"))
    }

    func testAuthorityHistoryExplainsRuleChangesAndPreservesAmountPrivacy() {
        let before = APIDelegatedPolicySnapshot(userID: "u", poolCategoryID: "pool", authorityMinor: 9007199254740993,
            allowCategoryCreation: false, allowReallocation: true,
            rules: [.init(categoryID: "a", ruleKind: "flexible", minimumMinor: 100, maximumMinor: 500),
                    .init(categoryID: "b", ruleKind: "fixed", minimumMinor: 200)])
        let after = APIDelegatedPolicySnapshot(userID: "u", poolCategoryID: "pool2", authorityMinor: 9007199254740994,
            allowCategoryCreation: true, allowReallocation: false,
            rules: [.init(categoryID: "a", ruleKind: "flexible", minimumMinor: 100, maximumMinor: 600),
                    .init(categoryID: "c", ruleKind: "fixed", maximumMinor: 400)])
        let revision = APIDelegatedPolicyRevision(id: "r", policyID: "p", memberUserID: "u", action: "updated",
            actorUserID: "owner", beforeSnapshot: before, afterSnapshot: after, createdAt: "2026-10-09")
        let changes = DelegatedPolicyHistoryPresentation.changes(revision, formatMoney: { String($0) }, categoryName: { "Group / \($0)" })
        XCTAssertEqual(changes.first { $0.id == "authority" }?.before, "9007199254740993")
        XCTAssertEqual(changes.first { $0.id == "create" }?.after, "Allowed")
        XCTAssertEqual(changes.first { $0.id == "move" }?.after, "Not allowed")
        XCTAssertEqual(changes.first { $0.id == "rule-a" }?.after, "Flexible · Minimum 100 · Maximum 600")
        XCTAssertNil(changes.first { $0.id == "rule-b" }?.after)
        XCTAssertNil(changes.first { $0.id == "rule-c" }?.before)
        XCTAssertEqual(changes.first { $0.id == "rule-c" }?.label, "Group / c")
        let hidden = DelegatedPolicyHistoryPresentation.changes(revision, formatMoney: { _ in "••••" }, categoryName: { _ in "Category" })
        XCTAssertEqual(hidden.first { $0.id == "authority" }?.before, "••••")
        XCTAssertTrue(hidden.contains { $0.id == "rule-a" }, "Changed limits must remain detectable after redaction")
        let same = APIDelegatedPolicyRevision(id: "n", policyID: "p", memberUserID: "u", action: "updated",
            actorUserID: "owner", beforeSnapshot: after, afterSnapshot: after, createdAt: "2026-10-09")
        XCTAssertTrue(DelegatedPolicyHistoryPresentation.changes(same, formatMoney: { String($0) }, categoryName: { $0 }).isEmpty)
    }

    func testScheduleHistoryExplainsExactChangesRemovalRealizationAndPrivacy() {
        let before = APIScheduledTransactionSnapshot(accountID: "a", categoryID: "c", payeeID: "p",
            name: "Rent", amountMinor: -9_007_199_254_740_993, nextDate: "2026-10-01",
            recurrenceUnit: "months", intervalCount: 1, endDate: "2027-10-01", remainingOccurrences: 12, memo: "Old")
        let after = APIScheduledTransactionSnapshot(accountID: "b", categoryID: "d", payeeID: "q",
            name: "New rent", amountMinor: -9_007_199_254_740_992, nextDate: "2026-11-01",
            recurrenceUnit: "months", intervalCount: 2, remainingOccurrences: 11, memo: "New",
            isActive: false, lastRealizedOn: "2026-10-01")
        let revision = APIScheduledTransactionRevision(id: "r", scheduleID: "s", action: "realized",
            actorUserID: "u", beforeSnapshot: before, afterSnapshot: after, transactionIDs: ["t"], createdAt: "2026-10-01")
        let changes = ScheduleHistoryPresentation.changes(revision, currencyCode: "USD", locale: Locale(identifier: "en_US"),
            accountName: { _ in "Same account name" }, categoryName: { "Group / \($0)" }, payeeName: { "Payee \($0)" })
        XCTAssertEqual(changes.first { $0.label == "Amount" }?.before, "-$90,071,992,547,409.93")
        XCTAssertTrue(changes.contains { $0.label == "Account" }, "Changed identity must survive identical display names")
        XCTAssertEqual(changes.first { $0.label == "Category" }?.after, "Group / d")
        XCTAssertEqual(changes.first { $0.label == "Payee" }?.after, "Payee q")
        XCTAssertNil(changes.first { $0.label == "End date" }?.after)
        XCTAssertEqual(changes.first { $0.label == "Remaining entries" }?.after, "11")
        XCTAssertEqual(changes.first { $0.label == "Last entered" }?.after, "2026-10-01")
        XCTAssertEqual(changes.first { $0.label == "Status" }?.after, "Paused")
        let hidden = ScheduleHistoryPresentation.changes(revision, currencyCode: "USD", hideAmounts: true)
        XCTAssertEqual(hidden.first { $0.label == "Amount" }?.before, "••••")
        XCTAssertEqual(hidden.first { $0.label == "Amount" }?.after, "••••")
        let deleted = APIScheduledTransactionRevision(id: "d", scheduleID: "s", action: "deleted",
            actorUserID: "u", beforeSnapshot: after, createdAt: "2026-10-02")
        XCTAssertTrue(ScheduleHistoryPresentation.changes(deleted, currencyCode: "USD").allSatisfy { $0.after == nil })
        let unchanged = APIScheduledTransactionRevision(id: "n", scheduleID: "s", action: "updated",
            actorUserID: "u", beforeSnapshot: after, afterSnapshot: after, createdAt: "2026-10-02")
        XCTAssertTrue(ScheduleHistoryPresentation.changes(unchanged, currencyCode: "USD").isEmpty)
    }

    @MainActor
    func testDropboxCommittedPublicationRemainsSuccessfulWhenListRefreshFails() async throws {
        let name = "dropbox-publication-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = DropboxBackupCoordinator(appKey: "", defaults: defaults)
        let publication = DropboxBackupPublication(remotePath: "/Backups/Verified.clearpocketbackup",
            encryptedBytes: 123, fileCount: 3, retentionCleanupPending: true)
        var calls = 0
        let result = await coordinator.finalizePublication(publication) {
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(result, publication)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(coordinator.lastSuccessfulBackupAt)
        XCTAssertNotNil(defaults.object(forKey: "backup.dropbox.last-success"))
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.publicationWarning?.contains("Do not upload") == true)
        XCTAssertEqual(coordinator.generations.map(\.path), [publication.remotePath])
        _ = await coordinator.finalizePublication(publication) { throw URLError(.timedOut) }
        XCTAssertEqual(coordinator.generations.count, 1, "Refresh failure must not duplicate the known generation")
        let recovered = DropboxBackupPublication(remotePath: publication.remotePath, encryptedBytes: 123, fileCount: 3)
        _ = await coordinator.finalizePublication(recovered) { coordinator.generations }
        XCTAssertNil(coordinator.publicationWarning)
    }

    @MainActor
    func testInvalidPayoffPlanPreservesPreviouslySavedScenarioAndLedger() async throws {
        let source = DemoWorkspaceDataSource()
        let id = try XCTUnwrap(source.demo.accounts.first(where: { $0.kind == .credit })?.id)
        let valid = try await source.saveDebtPayoffPlan(.init(strategy: "snowball", rollover: true,
            extraPaymentMinor: 2500, accountIDs: [id], customOrder: [], targetDate: "2028-02-29"))
        let accounts = source.demo.accounts
        let transactions = source.demo.transactions
        let categories = source.demo.categories
        let invalid: [APIDebtPayoffPlanUpsert] = [
            .init(strategy: "unknown", rollover: true),
            .init(strategy: "snowball", rollover: true, extraPaymentMinor: -1),
            .init(strategy: "avalanche", rollover: true, accountIDs: [id, id]),
            .init(strategy: "custom", rollover: true, accountIDs: [id], customOrder: []),
            .init(strategy: "snowball", rollover: true, accountIDs: [id], customOrder: [id]),
            .init(strategy: "avalanche", rollover: true, targetDate: "2026-02-30"),
        ]
        for request in invalid {
            do {
                _ = try await source.saveDebtPayoffPlan(request)
                XCTFail("Malformed scenario must not replace the stored plan")
            } catch let error as APIClientError {
                guard case .server(let status, _) = error else { return XCTFail("Unexpected error") }
                XCTAssertEqual(status, 422)
            }
            let unchanged = try await source.debtPayoffPlan()
            XCTAssertEqual(unchanged, valid)
            XCTAssertEqual(source.demo.accounts, accounts)
            XCTAssertEqual(source.demo.transactions, transactions)
            XCTAssertEqual(source.demo.categories, categories)
        }
    }

    @MainActor
    func testPayoffPlansAreActorOwnedAndEnforceCurrentAccountScope() async throws {
        let source = DemoWorkspaceDataSource()
        let debtIDs = source.demo.accounts.filter { [.credit, .loan, .mortgage].contains($0.kind) }.map(\.id)
        XCTAssertFalse(debtIDs.isEmpty)
        let owner = try await source.saveDebtPayoffPlan(.init(strategy: "avalanche", rollover: true,
            extraPaymentMinor: 9_007_199_254_740_993, accountIDs: debtIDs, customOrder: []))
        source.demo.persona = .partner
        let initiallyEmpty = try await source.debtPayoffPlan()
        XCTAssertNil(initiallyEmpty, "Another household member's saved plan must remain private")
        let initiallyEmptyHistory = try await source.debtPayoffPlanHistory(limit: 10, offset: 0)
        XCTAssertTrue(initiallyEmptyHistory.isEmpty)
        let partner = try await source.saveDebtPayoffPlan(.init(strategy: "snowball", rollover: false,
            extraPaymentMinor: 2345, accountIDs: debtIDs, customOrder: []))
        XCTAssertNotEqual(partner.userID, owner.userID)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
            capabilities: ["view_budget", "view_reports", "view_account_balances", "manage_planning"],
            restrictAccounts: true, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: nil))
        source.demo.persona = .partner
        let scopedValue = try await source.debtPayoffPlan()
        let scoped = try XCTUnwrap(scopedValue)
        XCTAssertTrue(scoped.accountIDs.isEmpty)
        XCTAssertTrue(scoped.customOrder.isEmpty)
        XCTAssertEqual(scoped.extraPaymentMinor, 2345)
        let scopedHistory = try await source.debtPayoffPlanHistory(limit: 10, offset: 0)
        XCTAssertEqual(scopedHistory.count, 1)
        XCTAssertTrue(scopedHistory[0].afterSnapshot?.accountIDs.isEmpty == true)
        XCTAssertEqual(scopedHistory[0].userID, partner.userID)
        try await source.deleteDebtPayoffPlan()
        source.demo.persona = .rey
        let unchangedOwner = try await source.debtPayoffPlan()
        XCTAssertEqual(unchangedOwner?.extraPaymentMinor, owner.extraPaymentMinor)
        XCTAssertEqual(unchangedOwner?.accountIDs, owner.accountIDs)
        XCTAssertEqual(unchangedOwner?.updatedAt, owner.updatedAt)
        let ownerHistory = try await source.debtPayoffPlanHistory(limit: 10, offset: 0)
        XCTAssertEqual(ownerHistory.count, 1)
        XCTAssertEqual(ownerHistory[0].afterSnapshot?.extraPaymentMinor, 9_007_199_254_740_993)
        source.demo.persona = .alex
        let delegatedPlan = try await source.debtPayoffPlan()
        XCTAssertNil(delegatedPlan)
        do {
            _ = try await source.saveDebtPayoffPlan(.init(strategy: "avalanche", rollover: true,
                extraPaymentMinor: 100, accountIDs: [], customOrder: []))
            XCTFail("Delegated member without manage_planning must not save a plan")
        } catch let error as APIClientError {
            guard case .server(let status, _) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(status, 403)
        }
    }

    @MainActor
    func testPayoffPlanReadRejectsRevokedBalanceVisibility() async throws {
        let source = DemoWorkspaceDataSource()
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
            capabilities: ["view_budget", "view_reports", "manage_planning"], restrictAccounts: false,
            accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: nil))
        source.demo.persona = .partner
        do {
            _ = try await source.debtPayoffPlan()
            XCTFail("Reading even an empty plan must require current balance visibility")
        } catch let error as APIClientError {
            guard case .server(let status, _) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(status, 403)
        }
    }

    @MainActor
    func testPayoffPlanSaveDoesNotRequireSeparateReportReadCapability() async throws {
        let source = DemoWorkspaceDataSource()
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
            capabilities: ["view_budget", "view_account_balances", "manage_planning"], restrictAccounts: false,
            accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: nil))
        source.demo.persona = .partner
        let saved = try await source.saveDebtPayoffPlan(.init(strategy: "avalanche", rollover: false,
            extraPaymentMinor: 1500, accountIDs: [], customOrder: []))
        XCTAssertEqual(saved.extraPaymentMinor, 1500)
        do {
            _ = try await source.debtPayoffPlan()
            XCTFail("Save capability must not implicitly grant report read access")
        } catch let error as APIClientError {
            guard case .server(let status, _) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(status, 403)
        }
    }

    func testTargetHistoryExplainsCadenceMinimumRemovalAndSnoozeExactly() {
        let before = APICategoryTargetSnapshot(targetType: "recurring", targetAmountMinor: 9_007_199_254_740_993,
            targetDate: "2028-12-31", recurrenceMonths: 3, minimumContributionMinor: 9_007_199_254_740_993)
        let after = APICategoryTargetSnapshot(targetType: "recurring", targetAmountMinor: 9_007_199_254_740_994,
            recurrenceMonths: 1, minimumContributionMinor: 0)
        func revision(_ old: APICategoryTargetSnapshot?, _ new: APICategoryTargetSnapshot?, action: String = "updated", month: String? = nil) -> APICategoryTargetRevision {
            .init(id: "target-history", categoryID: "category", action: action, actorUserID: "owner",
                  beforeSnapshot: old, afterSnapshot: new, affectedMonth: month, createdAt: "2026-10-09T12:00:00Z")
        }
        let changes = TargetHistoryPresentation.changes(revision(before, after), currencyCode: "USD", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(changes.map(\.label), ["Target amount", "Goal date", "Recurrence", "Minimum contribution"])
        XCTAssertEqual(changes[0].before, "$90,071,992,547,409.93")
        XCTAssertEqual(changes[0].after, "$90,071,992,547,409.94")
        XCTAssertNil(changes[1].after)
        XCTAssertEqual(changes[2].before, "Every 3 months")
        XCTAssertEqual(changes[2].after, "Every 1 month")
        XCTAssertEqual(changes[3].after, "$0.00")
        let hidden = TargetHistoryPresentation.changes(revision(before, after), currencyCode: "USD", hideAmounts: true)
        XCTAssertEqual(hidden.map(\.label), changes.map(\.label), "Redaction must not conceal that a value changed")
        XCTAssertEqual(hidden[0].before, "••••")
        XCTAssertEqual(hidden[0].after, "••••")
        XCTAssertEqual(hidden[3].before, "••••")
        XCTAssertEqual(hidden[3].after, "••••")
        XCTAssertNil(hidden[1].after)
        let deleted = TargetHistoryPresentation.changes(revision(before, nil), currencyCode: "USD")
        XCTAssertEqual(deleted.count, 7)
        XCTAssertTrue(deleted.allSatisfy { $0.before != nil && $0.after == nil })
        XCTAssertTrue(TargetHistoryPresentation.changes(revision(before, before), currencyCode: "USD").isEmpty)
        let snooze = TargetHistoryPresentation.changes(revision(before, before, action: "snoozed", month: "2026-10-01"), currencyCode: "USD")
        XCTAssertEqual(snooze.map(\.label), ["Guidance for 2026-10-01"])
        XCTAssertEqual(snooze[0].before, "Active")
        XCTAssertEqual(snooze[0].after, "Snoozed")
        let resume = TargetHistoryPresentation.changes(revision(before, before, action: "resumed", month: "2026-10-01"), currencyCode: "USD")
        XCTAssertEqual(resume[0].before, "Snoozed")
        XCTAssertEqual(resume[0].after, "Active")
    }

    func testDebtTermsHistoryShowsExactChangedValuesAndRemovedAssumptions() {
        let before = APIAccountDebtTermsRevisionSnapshot(termsType: "credit_card", annualRateBasisPoints: 2199,
            rateType: "variable", minimumPaymentMinor: 9_007_199_254_740_993, promotionalRateBasisPoints: 0)
        let after = APIAccountDebtTermsRevisionSnapshot(termsType: "credit_card", annualRateBasisPoints: 2299,
            rateType: "variable", minimumPaymentMinor: 9_007_199_254_740_994)
        func revision(_ old: APIAccountDebtTermsRevisionSnapshot?, _ new: APIAccountDebtTermsRevisionSnapshot?) -> APIAccountDebtTermsRevision {
            .init(id: "history", accountID: "card", action: new == nil ? "deleted" : "updated",
                  actorUserID: "owner", actorDisplayName: "Owner", beforeSnapshot: old,
                  afterSnapshot: new, createdAt: "2026-10-09T12:00:00Z")
        }
        let locale = Locale(identifier: "en_US")
        let changes = DebtTermsHistoryPresentation.changes(revision(before, after), currencyCode: "USD", locale: locale)
        XCTAssertEqual(changes.map(\.label), ["APR", "Minimum payment", "Promotional APR"])
        XCTAssertEqual(changes[0].before, "21.99%")
        XCTAssertEqual(changes[0].after, "22.99%")
        XCTAssertEqual(changes[1].before, "$90,071,992,547,409.93")
        XCTAssertEqual(changes[1].after, "$90,071,992,547,409.94")
        XCTAssertEqual(changes[2].before, "0%")
        XCTAssertNil(changes[2].after)
        let hidden = DebtTermsHistoryPresentation.changes(revision(before, after), currencyCode: "USD", hideAmounts: true)
        XCTAssertEqual(hidden.map(\.label), changes.map(\.label))
        XCTAssertEqual(hidden[1].before, "••••")
        XCTAssertEqual(hidden[1].after, "••••")
        XCTAssertEqual(hidden[0].before, "21.99%", "Non-money assumptions remain explainable")
        let removed = DebtTermsHistoryPresentation.changes(revision(before, nil), currencyCode: "USD", locale: locale)
        XCTAssertEqual(removed.count, 5)
        XCTAssertTrue(removed.allSatisfy { $0.before != nil && $0.after == nil })
        let added = DebtTermsHistoryPresentation.changes(revision(nil, before), currencyCode: "USD", locale: locale)
        XCTAssertEqual(added.count, 5)
        XCTAssertTrue(added.allSatisfy { $0.before == nil && $0.after != nil })
        XCTAssertTrue(DebtTermsHistoryPresentation.changes(revision(before, before), currencyCode: "USD").isEmpty)
    }

    func testSpendingTrendChangesRankExactServerDerivedIncreases() throws {
        let report = try JSONDecoder().decode(APISpendingTrendsReport.self, from: Data(#"""
        {
          "start_date":"2026-07-01","end_date":"2026-09-30","currency_code":"USD","dimension":"category","total_spending_minor":42000,
          "series":[
            {"dimension_id":"groceries","dimension_name":"Groceries","category_group":"Food","spending_minor":24000,"transaction_ids":["g1","g2","g3"],"transaction_ids_truncated":false,"points":[
              {"period_start":"2026-07-01","period_end":"2026-07-31","spending_minor":5000,"transaction_ids":["g1"],"transaction_ids_truncated":false},
              {"period_start":"2026-08-01","period_end":"2026-08-31","spending_minor":7000,"transaction_ids":["g2"],"transaction_ids_truncated":false},
              {"period_start":"2026-09-01","period_end":"2026-09-30","spending_minor":12000,"transaction_ids":["g3"],"transaction_ids_truncated":true}]},
            {"dimension_id":"fuel","dimension_name":"Fuel","category_group":"Transport","spending_minor":18000,"transaction_ids":["f1","f2","f3"],"transaction_ids_truncated":false,"points":[
              {"period_start":"2026-07-01","period_end":"2026-07-31","spending_minor":7000,"transaction_ids":["f1"],"transaction_ids_truncated":false},
              {"period_start":"2026-08-01","period_end":"2026-08-31","spending_minor":6000,"transaction_ids":["f2"],"transaction_ids_truncated":false},
              {"period_start":"2026-09-01","period_end":"2026-09-30","spending_minor":5000,"transaction_ids":["f3"],"transaction_ids_truncated":false}]}
          ]
        }
        """#.utf8))

        let changes = SpendingTrendChange.increases(in: report)

        XCTAssertEqual(changes.map(\.id), ["groceries"])
        XCTAssertEqual(changes.first?.priorAverageMinor, 6_000)
        XCTAssertEqual(changes.first?.latestMinor, 12_000)
        XCTAssertEqual(changes.first?.increaseMinor, 6_000)
        XCTAssertEqual(changes.first?.transactionIDs, ["g3"])
        XCTAssertEqual(changes.first?.latestPeriodEnd, "2026-09-30")
        XCTAssertTrue(changes.first?.transactionIDsTruncated == true)
    }

    @MainActor
    func testCategoryDisplayNamesAlwaysIncludeTheirGroup() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let category = try XCTUnwrap(store.categories.first)
        let group = try XCTUnwrap(store.groups.first(where: { $0.id == category.groupID }))

        XCTAssertEqual(store.categoryDisplayName(category), "\(group.name) · \(category.name)")
    }

    @MainActor
    func testMoneySelectorsDisambiguateSameNamedCategoriesWithoutChangingIdentity() async throws {
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        for groupName in ["Household", "Travel"] {
            try await store.createGroup(name: groupName)
            let group = try XCTUnwrap(store.groups.first { $0.name == groupName })
            try await store.createCategory(groupID: group.id, newGroupName: "", name: "Food", delegatedUserID: nil)
        }
        let rows = try XCTUnwrap(store.summary).categories.filter { $0.name == "Food" }
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(Set(rows.map(\.categoryID)).count, 2)
        XCTAssertEqual(Set(rows.map(store.categoryDisplayName)), ["Household · Food", "Travel · Food"])
        let before = store.summary
        for row in rows { _ = store.categoryDisplayName(row) }
        XCTAssertEqual(store.summary, before)
        // Names may fall back only to the already-authorized summary; no hidden directory lookup.
        store.categories = []
        XCTAssertEqual(Set(rows.map(store.categoryDisplayName)), ["Food"])
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp")
        let editor = try String(contentsOf: directory.appendingPathComponent("EditingViews.swift"))
        XCTAssertFalse(editor.contains("Text(category.name).tag(category.categoryID)"))
        XCTAssertFalse(editor.contains("Text(category.name).tag(category.id)"))
        XCTAssertTrue(editor.contains(".map(workspace.categoryDisplayName)"))
    }

    func testReceiptOCRPrefersTotalAndProducesReviewableExactSuggestions() throws {
        let category = try JSONDecoder().decode(APICategory.self, from: Data(#"{"id":"groceries","budget_id":"budget","group_id":"needs","name":"Groceries","icon_name":null,"note":"","sort_order":0,"is_archived":false,"system_type":null,"linked_account_id":null,"delegated_user_id":null,"is_favorite":false,"favorite_sort_order":null}"#.utf8))
        let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 7)))

        let suggestion = ReceiptOCR.parse(
            lines: ["FRESH MARKET", "09/15/2026", "Subtotal $18.00", "Tax $1.50", "TOTAL $19.50", "Groceries"],
            currencyCode: "USD",
            categories: [category],
            now: now
        )

        XCTAssertEqual(suggestion.payee, "FRESH MARKET")
        XCTAssertEqual(suggestion.amountMinor, 1_950)
        XCTAssertEqual(suggestion.categoryID, "groceries")
        XCTAssertEqual(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: try XCTUnwrap(suggestion.occurredOn)), DateComponents(year: 2026, month: 9, day: 15))
        XCTAssertTrue(suggestion.recognizedText.contains("Subtotal $18.00"))
    }

    func testReceiptOCRRejectsFutureDates() throws {
        let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 7)))
        let suggestion = ReceiptOCR.parse(lines: ["LOCAL SHOP", "10/08/2026", "TOTAL 2.00"], currencyCode: "USD", categories: [], now: now)
        XCTAssertNil(suggestion.occurredOn)
        XCTAssertEqual(suggestion.amountMinor, 200)
    }

    func testScheduledReminderDateIsBoundedAndFutureOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8)))
        let fire = ScheduledReminderSettings.fireDate(nextDate: "2026-10-08", now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(fire)), DateComponents(year: 2026, month: 10, day: 8, hour: 9))
        let afterMorningReminder = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10)))
        XCTAssertNil(ScheduledReminderSettings.fireDate(nextDate: "2026-10-07", now: afterMorningReminder, calendar: calendar))
        XCTAssertNil(ScheduledReminderSettings.fireDate(nextDate: "2027-01-01", now: now, calendar: calendar))
        XCTAssertNil(ScheduledReminderSettings.fireDate(nextDate: "not-a-date", now: now, calendar: calendar))
    }

    func testQuickEntryIntentRequestIsConsumedExactlyOnce() throws {
        UserDefaults.standard.removeObject(forKey: QuickEntryRequest.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: QuickEntryRequest.defaultsKey) }
        XCTAssertNil(QuickEntryRequest.consume())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let occurredOn = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12)))
        let draft = QuickEntryDraft(payee: " Corner Market ", amount: " 12.34 ", memo: " Lunch ", occurredOn: occurredOn, isInflow: false, now: now, calendar: calendar)
        QuickEntryRequest.request(draft)
        XCTAssertEqual(QuickEntryRequest.consume(), draft)
        XCTAssertNil(QuickEntryRequest.consume())

        QuickEntryRequest.request(QuickEntryDraft(payee: "Expired", createdAt: Date(timeIntervalSinceNow: -301)))
        XCTAssertNil(QuickEntryRequest.consume())
        XCTAssertNil(UserDefaults.standard.object(forKey: QuickEntryRequest.defaultsKey))
    }

    func testQuickEntryDateAcceptsPastDatesAndRejectsFutureDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12)))
        let past = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 18)))
        let future = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)))

        XCTAssertEqual(
            QuickEntryDraft(payee: "Past", occurredOn: past, now: now, calendar: calendar).occurredOn,
            calendar.startOfDay(for: past)
        )
        XCTAssertNil(QuickEntryDraft(payee: "Future", occurredOn: future, now: now, calendar: calendar).occurredOn)
    }

    func testWidgetQuickEntryDeepLinkAcceptsOnlyExactPrivateRoute() throws {
        UserDefaults.standard.removeObject(forKey: QuickEntryRequest.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: QuickEntryRequest.defaultsKey) }

        XCTAssertTrue(QuickEntryRequest.handle(try XCTUnwrap(URL(string: "clearpocket://quick-entry"))))
        XCTAssertNotNil(QuickEntryRequest.consume())
        XCTAssertNil(QuickEntryRequest.consume())

        for value in [
            "https://quick-entry",
            "clearpocket://quick-entry/extra",
            "clearpocket://quick-entry?payee=Private",
            "clearpocket://open?destination=activity"
        ] {
            XCTAssertFalse(QuickEntryRequest.handle(try XCTUnwrap(URL(string: value))), value)
            XCTAssertNil(QuickEntryRequest.consume())
        }
    }

    func testWidgetDeepLinkAcceptsOnlyKnownClearPocketDestinationsAndConsumesOnce() throws {
        UserDefaults.standard.removeObject(forKey: WorkspaceShortcutRequest.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: WorkspaceShortcutRequest.defaultsKey) }

        XCTAssertTrue(WorkspaceShortcutRequest.handle(try XCTUnwrap(URL(string: "clearpocket://open?destination=accounts"))))
        XCTAssertEqual(WorkspaceShortcutRequest.consume(), .accounts)
        XCTAssertNil(WorkspaceShortcutRequest.consume())

        XCTAssertFalse(WorkspaceShortcutRequest.handle(try XCTUnwrap(URL(string: "https://example.com/open?destination=plan"))))
        XCTAssertFalse(WorkspaceShortcutRequest.handle(try XCTUnwrap(URL(string: "clearpocket://open?destination=private-data"))))
        XCTAssertNil(WorkspaceShortcutRequest.consume())
    }
    @MainActor
    func testFundedCardPurchaseDoesNotRelabelLaterCashDeficitAsCreditDebt() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Cash", type: "checking", isOnBudget: true, startingBalance: 50000))
        XCTAssertTrue(source.demo.createAccount(name: "Card", type: "credit", isOnBudget: true))
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Plan"))
        let category = source.demo.categories[0].id
        try await source.assignMoney(.init(categoryID: category, month: "2026-09-01", assignedMinor: 10000, expectedVersion: 0))
        func record(account: String, amount: Int64, day: String) async throws {
            try await source.recordTransaction(.init(accountID: account, categoryID: category, amountMinor: amount, occurredOn: day, payeeName: "Mixed spending", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        }
        try await record(account: source.demo.accounts[1].id, amount: -10000, day: "2026-09-01")
        let purchaseID = try XCTUnwrap(source.demo.transactions.first?.id)
        try await record(account: source.demo.accounts[0].id, amount: -10000, day: "2026-09-02")
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        func row() async throws -> APICategoryMonth {
            let snapshot = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
            return try XCTUnwrap(snapshot.summary?.categories.first { $0.categoryID == category })
        }
        let mixed = try await row()
        XCTAssertEqual(mixed.availableMinor, -10000)
        XCTAssertEqual(mixed.fundedCreditSpendingMinor, 10000)
        XCTAssertEqual(mixed.creditOverspentMinor, 0)
        XCTAssertEqual(mixed.cashOverspentMinor, 10000)
        XCTAssertEqual(source.demo.accounts[1].paymentReserved, 10000)
        try await record(account: source.demo.accounts[1].id, amount: 3000, day: "2026-09-03")
        let refunded = try await row()
        XCTAssertEqual(refunded.availableMinor, -7000)
        XCTAssertEqual(refunded.fundedCreditSpendingMinor, 7000)
        XCTAssertEqual(refunded.creditOverspentMinor, 0)
        XCTAssertEqual(refunded.cashOverspentMinor, 7000)
        XCTAssertEqual(source.demo.accounts[1].paymentReserved, 7000)
        try await source.deleteTransaction(id: try XCTUnwrap(source.demo.transactions.first?.id))
        try await source.updateTransaction(id: purchaseID, operation: .init(accountID: source.demo.accounts[1].id, categoryID: category, amountMinor: -8000, occurredOn: "2026-09-01", payeeName: "Edited card purchase", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let edited = try await row()
        XCTAssertEqual(edited.fundedCreditSpendingMinor, 8000)
        XCTAssertEqual(edited.creditOverspentMinor, 0)
        XCTAssertEqual(edited.cashOverspentMinor, 8000)
        try await source.voidTransaction(id: purchaseID, reason: "Classification reversal")
        let voided = try await row()
        XCTAssertEqual(voided.fundedCreditSpendingMinor, 0)
        XCTAssertEqual(voided.creditOverspentMinor, 0)
        XCTAssertEqual(voided.cashOverspentMinor, 0)
        XCTAssertEqual(source.demo.accounts[1].paymentReserved, 0)
        XCTAssertTrue(source.demo.createCategory(name: "Unfunded", group: "Plan"))
        let second = source.demo.categories[1].id
        try await source.assignMoney(.init(categoryID: category, month: "2026-09-01", assignedMinor: 15000, expectedVersion: source.demo.allocationVersion))
        try await source.recordTransaction(.init(accountID: source.demo.accounts[1].id, categoryID: nil, amountMinor: -7000, occurredOn: "2026-09-15", payeeName: "Mixed funded split", memo: "", isCleared: true, splits: [.init(categoryID: category, amountMinor: -3000, memo: ""), .init(categoryID: second, amountMinor: -4000, memo: "")], flag: nil, tags: [], attachmentMetadata: []))
        let split = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        let fundedRow = try XCTUnwrap(split.summary?.categories.first { $0.categoryID == category })
        let unfundedRow = try XCTUnwrap(split.summary?.categories.first { $0.categoryID == second })
        XCTAssertEqual(fundedRow.fundedCreditSpendingMinor, 3000)
        XCTAssertEqual(fundedRow.creditOverspentMinor, 0)
        XCTAssertEqual(unfundedRow.fundedCreditSpendingMinor, 0)
        XCTAssertEqual(unfundedRow.creditOverspentMinor, 4000)
        XCTAssertEqual(unfundedRow.cashOverspentMinor, 0)
        XCTAssertEqual(source.demo.accounts[1].paymentReserved, 3000)
    }

    @MainActor
    func testMonthSummaryExplainsFutureReservationsWithoutChangingDatedMoney() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Cash", type: "checking", isOnBudget: true, startingBalance: 50000))
        XCTAssertTrue(source.demo.createCategory(name: "Needs", group: "Plan"))
        let category = source.demo.categories[0].id
        let month = source.demo.currentPlanningMonth
        let future = BudgetWorkspaceStore.dateString(try XCTUnwrap(Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: BudgetWorkspaceStore.parseDate(month))))
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate(month), end: BudgetWorkspaceStore.parseDate(future), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        func summary() async throws -> APIMonthSummary {
            let loaded = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate(month), report: query)
            return try XCTUnwrap(loaded.summary)
        }
        let before = try await summary()
        XCTAssertEqual(before.readyToAssignMinor, 50000)
        XCTAssertEqual(before.fundingLimitMinor, 50000)
        try await source.assignMoney(.init(categoryID: category, month: future, assignedMinor: 40000, expectedVersion: 0))
        let reserved = try await summary()
        XCTAssertEqual(reserved.readyToAssignMinor, 50000)
        XCTAssertEqual(reserved.allDateUnassignedMinor, 10000)
        XCTAssertEqual(reserved.fundingLimitMinor, 10000)
        try await source.assignMoney(.init(categoryID: category, month: future, assignedMinor: 30000, expectedVersion: 1))
        let released = try await summary()
        XCTAssertEqual(released.readyToAssignMinor, 50000)
        XCTAssertEqual(released.fundingLimitMinor, 20000)
        XCTAssertEqual(source.demo.accounts[0].balance, 50000)
        source.demo.persona = .alex
        let restricted = try await summary()
        XCTAssertNil(restricted.allDateUnassignedMinor)
        XCTAssertNil(restricted.fundingLimitMinor)
    }

    @MainActor
    func testAllocationVersionsRejectStaleNoOpsAndMoneyRoundTrips() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertEqual(source.demo.allocationVersion, 0)
        XCTAssertTrue(source.demo.createAccount(name: "Cash", type: "checking", isOnBudget: true, startingBalance: 10000))
        XCTAssertTrue(source.demo.createCategory(name: "One", group: "Needs"))
        XCTAssertTrue(source.demo.createCategory(name: "Two", group: "Needs"))
        let one = source.demo.categories[0].id, two = source.demo.categories[1].id
        let intent = AssignMoneyOperation(categoryID: one, month: "2026-09-01", assignedMinor: 1000, expectedVersion: 0)
        try await source.assignMoney(intent)
        XCTAssertEqual(source.demo.allocationVersion, 1)
        do { try await source.assignMoney(intent); XCTFail("Same-token second command must lose, even when its amount is now a no-op") } catch { }
        XCTAssertEqual(source.demo.allocationEvents.count, 1)
        try await source.assignMoney(.init(categoryID: one, month: "2026-09-01", assignedMinor: 1000, expectedVersion: 1))
        XCTAssertEqual(source.demo.allocationVersion, 1, "A current no-op creates no operation")
        try await source.moveMoney(.init(sourceCategoryID: one, destinationCategoryID: two, amountMinor: 100, occurredOn: "2026-09-02", note: "Out", expectedVersion: 1))
        try await source.moveMoney(.init(sourceCategoryID: two, destinationCategoryID: one, amountMinor: 100, occurredOn: "2026-09-02", note: "Back", expectedVersion: 2))
        XCTAssertEqual(source.demo.allocationVersion, 3)
        do {
            try await source.assignMoney(.init(categoryID: one, month: "2026-09-01", assignedMinor: 1000, expectedVersion: 1))
            XCTFail("Returning to the same amounts must not revive a stale token")
        } catch { }
        XCTAssertEqual(source.demo.allocationEvents.count, 3)
        XCTAssertEqual(source.demo.accounts[0].balance, 10000)
        XCTAssertEqual(source.demo.accounts[0].cleared, 10000)
        XCTAssertNil(source.demo.accounts[0].reconciledBalance)
    }

    @MainActor
    func testCompoundFundingIsAtomicVersionedAndWholeOperationPrivate() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Cash", type: "checking", isOnBudget: true, startingBalance: 10000))
        XCTAssertTrue(source.demo.createCategory(name: "One", group: "Needs"))
        XCTAssertTrue(source.demo.createCategory(name: "Two", group: "Needs"))
        let one = source.demo.categories[0].id, two = source.demo.categories[1].id
        source.demo.categories[0].target = 1000
        source.demo.categories[1].target = 2000
        let before = source.demo.financialObservation(accountReferences: ["cash": source.demo.accounts[0].id], categoryReferences: ["one": one, "two": two])
        XCTAssertThrowsError(try source.demo.fundTargets([(one, 1000), ("missing", 2000)], month: "2026-09-01", expectedVersion: 0))
        XCTAssertThrowsError(try source.demo.fundTargets([(one, 1000), (two, 10000)], month: "2026-09-01", expectedVersion: 0))
        XCTAssertEqual(source.demo.allocationVersion, 0)
        XCTAssertTrue(source.demo.allocationEvents.isEmpty)
        XCTAssertEqual(source.demo.financialObservation(accountReferences: ["cash": source.demo.accounts[0].id], categoryReferences: ["one": one, "two": two]), before)
        let preview = try await source.smartFundingPreview(month: "2026-09-01")
        XCTAssertEqual(preview.allocationVersion, 0)
        XCTAssertEqual(preview.proposals.count, 2)
        try await source.commitSmartFunding(preview)
        XCTAssertEqual(source.demo.allocationVersion, 1)
        XCTAssertEqual(Set(source.demo.allocationEvents.map(\.operationID)).count, 1)
        XCTAssertEqual(source.demo.readyToAssign, 7000)
        XCTAssertEqual(source.demo.accounts[0].balance, 10000)
        XCTAssertEqual(source.demo.accounts[0].cleared, 10000)
        XCTAssertEqual(source.demo.transactions.count, 1, "Funding never posts account transactions")
        do { try await source.commitSmartFunding(preview); XCTFail("Confirmation cannot be reused") } catch { }
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        func history() async throws -> [APIAllocationOperation] {
            try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query).allocationOperations
        }
        let rows = try await history()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, "smart_funding")
        XCTAssertEqual(rows[0].postings.count, 3)
        XCTAssertEqual(rows[0].postings.map(\.amountMinor).sorted(), [-3000, 1000, 2000])
        XCTAssertEqual(rows[0].allocationVersion, 1)
        let reloaded = try await history()
        XCTAssertEqual(reloaded.map(\.id), rows.map(\.id))
        try await source.moveMoney(.init(sourceCategoryID: one, destinationCategoryID: two, amountMinor: 100, occurredOn: "2026-09-02", note: "Out", expectedVersion: 1))
        try await source.moveMoney(.init(sourceCategoryID: two, destinationCategoryID: one, amountMinor: 100, occurredOn: "2026-09-02", note: "Back", expectedVersion: 2))
        let changed = try await history()
        XCTAssertEqual(changed.first?.id, rows[0].id)
        XCTAssertTrue(changed.allSatisfy { $0.allocationVersion == 3 }, "History returns the current budget token, not an invented historical token")
        source.demo.categories[0].delegatedTo = .alex
        source.demo.persona = .alex
        let restricted = try await history()
        XCTAssertTrue(restricted.isEmpty, "Never expose a partial compound operation")
        XCTAssertThrowsError(try source.demo.fundTargets([(one, 1)], month: "2026-09-01", expectedVersion: 3))
        XCTAssertEqual(source.demo.allocationVersion, 3)
    }

    @MainActor
    func testForecastRejectsOverflowAndExpandsOldRecurrencesWithoutSilentTruncation() async throws {
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-12-04"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        let overflow = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(overflow.demo.createAccount(name: "Boundary", type: "checking", isOnBudget: true, startingBalance: .max))
        let accountID = try XCTUnwrap(overflow.demo.accounts.first?.id)
        try await overflow.createSchedule(.init(accountID: accountID, name: "Beyond range", amountMinor: 1, nextDate: "2026-09-10", recurrenceUnit: "once"))
        let ids = overflow.demo.transactions.map(\.id)
        do {
            _ = try await overflow.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
            XCTFail("Unrepresentable projection must throw, never trap or post money")
        } catch MoneyError.arithmeticOverflow { }
        XCTAssertEqual(overflow.demo.accounts.first?.balance, .max)
        XCTAssertEqual(overflow.demo.transactions.map(\.id), ids)
        XCTAssertEqual(overflow.demo.unassignedMinor, .max)

        let daily = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(daily.demo.createAccount(name: "Daily", type: "checking", isOnBudget: true, startingBalance: 1000))
        let dailyID = try XCTUnwrap(daily.demo.accounts.first?.id)
        try await daily.createSchedule(.init(accountID: dailyID, name: "Old daily recurrence", amountMinor: -1, nextDate: "2025-09-01", recurrenceUnit: "days"))
        try await daily.createSchedule(.init(accountID: dailyID, name: "Paused", amountMinor: .max, nextDate: "2026-09-06", recurrenceUnit: "once", isActive: false))
        let snapshot = try await daily.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        XCTAssertEqual(snapshot.forecast?.occurrences.count, 91)
        XCTAssertEqual(snapshot.forecast?.occurrences.last?.occurredOn, "2026-12-04")
        XCTAssertEqual(snapshot.forecast?.projectedTotalOnBudgetMinor, 909)
        XCTAssertEqual(snapshot.forecast?.lowestProjectedTotalMinor, 909)
        XCTAssertEqual(daily.demo.accounts.first?.balance, 1000)
        XCTAssertEqual(daily.demo.transactions.count, 1)
    }

    @MainActor
    func testForecastTracksChronologicalCashLowWithoutPostingOrTransferDoubleCounting() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Checking", type: "checking", isOnBudget: true, startingBalance: 10_000))
        XCTAssertTrue(source.demo.createAccount(name: "Savings", type: "savings", isOnBudget: true))
        XCTAssertTrue(source.demo.createCategory(name: "Bills"))
        let checking = source.demo.accounts[0].id, savings = source.demo.accounts[1].id
        let category = try XCTUnwrap(source.demo.categories.first?.id)
        // Deliberately create schedules out of chronological order.
        try await source.createSchedule(.init(accountID: checking, name: "Later income", amountMinor: 9_000, nextDate: "2026-09-20", recurrenceUnit: "once"))
        try await source.createSchedule(.init(accountID: checking, categoryID: category, name: "Early bill", amountMinor: -8_000, nextDate: "2026-09-10", recurrenceUnit: "once"))
        try await source.createSchedule(.init(accountID: checking, destinationAccountID: savings, name: "Internal transfer", amountMinor: 5_000, nextDate: "2026-09-12", recurrenceUnit: "once"))
        let ids = source.demo.transactions.map(\.id)
        let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-12-04"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        for _ in 0..<2 {
            let snapshot = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
            let forecast = try XCTUnwrap(snapshot.forecast)
            XCTAssertEqual(forecast.actualTotalOnBudgetMinor, 10_000)
            XCTAssertEqual(forecast.projectedTotalOnBudgetMinor, 11_000)
            XCTAssertEqual(forecast.lowestProjectedTotalMinor, 2_000)
            XCTAssertEqual(forecast.occurrences.map(\.name), ["Early bill", "Internal transfer", "Later income"])
            XCTAssertEqual(forecast.accounts.first { $0.accountID == checking }?.projectedBalanceMinor, 6_000)
            XCTAssertEqual(forecast.accounts.first { $0.accountID == savings }?.projectedBalanceMinor, 5_000)
            XCTAssertEqual(snapshot.resilience?.lowestProjectedOnBudgetMinor, 2_000)
            XCTAssertEqual(snapshot.resilience?.scheduledIncomeMinor, 9_000)
            XCTAssertEqual(snapshot.resilience?.scheduledOutflowsMinor, 8_000)
            XCTAssertEqual(source.demo.accounts.map(\.balance), [10_000, 0])
            XCTAssertEqual(source.demo.transactions.map(\.id), ids)
            XCTAssertEqual(source.demo.unassignedMinor, 10_000)
        }
        for index in source.demo.schedules.indices { source.demo.schedules[index].nextDate = "2026-09-10" }
        let tied = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        XCTAssertEqual(tied.forecast?.occurrences.map(\.scheduledTransactionID), source.demo.schedules.map(\.id).sorted(), "Same-day ordering must match the server's stable ID tie-break")
    }

    @MainActor
    func testRestrictedForecastAndResilienceExcludeHiddenAndUncategorizedSchedules() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Shared", type: "checking", isOnBudget: true))
        source.demo.accounts[0].restrictedFromChildren = false
        let accountID = source.demo.accounts[0].id
        XCTAssertTrue(source.demo.createCategory(name: "Visible"))
        source.demo.categories[0].delegatedTo = .alex
        let visibleID = source.demo.categories[0].id
        XCTAssertTrue(source.demo.createCategory(name: "Hidden"))
        let hiddenID = try XCTUnwrap(source.demo.categories.last?.id)
        let date = BudgetWorkspaceStore.dateString(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        for (name, categoryID, amount) in [("Visible bill", Optional(visibleID), Int64(-700)), ("Secret bill", Optional(hiddenID), Int64(-12345)), ("Secret salary", nil, Int64(99999))] {
            try await source.createSchedule(.init(accountID: accountID, categoryID: categoryID, name: name, amountMinor: amount, nextDate: date, recurrenceUnit: "once"))
        }
        source.demo.persona = .alex
        let report = WorkspaceReportQuery(start: Date(), end: Calendar.current.date(byAdding: .day, value: 30, to: Date())!, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        let scoped = try await source.snapshot(planMonth: Date(), report: report)
        XCTAssertEqual(scoped.schedules.map(\.name), ["Visible bill"])
        XCTAssertEqual(scoped.forecast?.occurrences.map(\.name), ["Visible bill"])
        XCTAssertEqual(scoped.forecast?.projectedTotalOnBudgetMinor, -700)
        XCTAssertEqual(scoped.resilience?.scheduledIncomeMinor, 0)
        XCTAssertEqual(scoped.resilience?.scheduledOutflowsMinor, 700)
        source.demo.persona = .rey
        let owner = try await source.snapshot(planMonth: Date(), report: report)
        XCTAssertEqual(owner.forecast?.occurrences.count, 3)
        XCTAssertEqual(source.demo.accounts[0].balance, 0)
        XCTAssertTrue(source.demo.transactions.isEmpty)
    }

    @MainActor
    func testAccountOpeningOverflowIsRejectedBeforeAccountOrTransactionCreation() async throws {
        for (opening, extra) in [(Int64.max, Int64(1)), (Int64.min, Int64(-1))] {
            let source = DemoWorkspaceDataSource(fresh: true)
            let service = BudgetApplicationServices(repository: source).accounts
            try await service.create(.init(name: "Opening", kind: "checking", isOnBudget: true, openingBalanceMinor: opening))
            let accountIDs = source.demo.accounts.map(\.id), transactionIDs = source.demo.transactions.map(\.id)
            do {
                try await service.create(.init(name: "Overflow", kind: "savings", isOnBudget: true, openingBalanceMinor: extra))
                XCTFail("Unrepresentable opening aggregate must be refused")
            } catch { }
            XCTAssertEqual(source.demo.accounts.map(\.id), accountIDs)
            XCTAssertEqual(source.demo.transactions.map(\.id), transactionIDs)
            XCTAssertEqual(source.demo.unassignedMinor, opening)
            XCTAssertEqual(source.demo.accounts.first?.balance, opening)
            try await service.create(.init(name: "Cancellation", kind: "cash", isOnBudget: true, openingBalanceMinor: -extra))
            XCTAssertEqual(source.demo.unassignedMinor, opening - extra)
            XCTAssertEqual(source.demo.accounts.count, 2)
        }
    }

    @MainActor
    func testLegacyCategoryAttributionPreservesSignedExtremesWithoutAbsoluteValueTrap() throws {
        let demo = DemoStore(fresh: true)
        for amount: Int64 in [.min, .max, -5, 5, 0] {
            for ids in [["a"], ["c", "a", "b"], ["a", "a", "b"]] {
                let transaction = DemoTransaction(id: "legacy", date: Date(), payee: "", memo: "", accountID: "account", categoryIDs: ids, amount: amount, member: .rey, cleared: false)
                let attributed = demo.canonicalCategoryAmounts(for: transaction)
                XCTAssertEqual(attributed.values.reduce(Int64(0), +), amount)
                XCTAssertEqual(Set(attributed.keys), Set(ids))
                if amount == -5 && ids.count == 3 && Set(ids).count == 3 { XCTAssertEqual(attributed, ["a": -2, "b": -2, "c": -1]) }
            }
        }
        XCTAssertTrue(demo.createAccount(name: "Cash", type: "checking", isOnBudget: true))
        demo.addTransaction(payee: "Boundary", amount: .min, accountID: try XCTUnwrap(demo.accounts.first?.id), categoryIDs: [], memo: "", attachment: false)
        XCTAssertEqual(demo.transactions.first?.amount, .min)
        XCTAssertEqual(demo.accounts.first?.balance, .min)
        XCTAssertEqual(demo.unassignedMinor, .min)

        let duplicate = DemoStore(fresh: true)
        XCTAssertTrue(duplicate.createAccount(name: "Cash", type: "checking", isOnBudget: true))
        XCTAssertTrue(duplicate.createCategory(name: "Needs"))
        let accountID = try XCTUnwrap(duplicate.accounts.first?.id)
        let categoryID = try XCTUnwrap(duplicate.categories.first?.id)
        duplicate.addTransaction(payee: "Original", amount: 1, accountID: accountID, categoryIDs: [categoryID], memo: "", attachment: false)
        let original = try XCTUnwrap(duplicate.transactions.first)
        XCTAssertFalse(duplicate.updateTransaction(id: original.id, payee: "Invalid edit", amount: 1, accountID: accountID, categoryIDs: [categoryID, categoryID], memo: "", cleared: false, flag: nil))
        XCTAssertEqual(duplicate.transactions.first, original)
        XCTAssertEqual(duplicate.accounts.first?.balance, -1)
    }

    @MainActor
    func testTransferOverflowIsAtomicAndEditCancellationUsesFinalBalances() throws {
        let demo = DemoStore(fresh: true)
        demo.createAccount(name: "Source", type: "asset", isOnBudget: false)
        demo.createAccount(name: "Destination", type: "asset", isOnBudget: false, startingBalance: .max)
        let sourceID = demo.accounts[0].id, destinationID = demo.accounts[1].id
        let initialIDs = demo.transactions.map(\.id)
        XCTAssertFalse(demo.transfer(amount: 1, from: sourceID, to: destinationID, memo: "", cleared: true, date: .demo(monthsAgo: 0, day: 15)))
        XCTAssertEqual(demo.accounts.map(\.balance), [0, .max])
        XCTAssertEqual(demo.accounts.map(\.cleared), [0, .max])
        XCTAssertEqual(demo.transactions.map(\.id), initialIDs)

        let edit = DemoStore(fresh: true)
        edit.createAccount(name: "Source", type: "asset", isOnBudget: false, startingBalance: .max)
        edit.createAccount(name: "Destination", type: "asset", isOnBudget: false)
        let source = edit.accounts[0].id, destination = edit.accounts[1].id
        XCTAssertTrue(edit.transfer(amount: 1, from: source, to: destination, memo: "Original", cleared: true, date: .demo(monthsAgo: 0, day: 15)))
        let transferID = try XCTUnwrap(edit.transactions.first?.transferID)
        XCTAssertTrue(edit.recordCanonicalTransaction(.init(accountID: source, categoryID: nil, amountMinor: 1, occurredOn: BudgetWorkspaceStore.dateString(.demo(monthsAgo: 0, day: 15)), payeeName: "External", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])))
        let ids = edit.transactions.map(\.id)
        XCTAssertFalse(edit.deleteTransfer(id: transferID))
        XCTAssertEqual(edit.accounts.map(\.balance), [.max, 1])
        XCTAssertEqual(edit.accounts.map(\.cleared), [.max, 1])
        XCTAssertEqual(edit.transactions.map(\.id), ids)
        // Undoing the old amount alone would overflow, but replacing it with two is valid.
        XCTAssertTrue(edit.updateTransfer(id: transferID, amount: 2, from: source, to: destination, memo: "Edited", cleared: true, date: .demo(monthsAgo: 0, day: 15)))
        XCTAssertEqual(edit.accounts.map(\.balance), [Int64.max - 1, Int64(2)])
        XCTAssertEqual(edit.accounts.map(\.cleared), [Int64.max - 1, Int64(2)])
        XCTAssertEqual(edit.transactions.map(\.id), ids)
        XCTAssertEqual(edit.transactions.filter { $0.transferID == transferID }.map(\.amount).sorted(), [-2, 2])
        XCTAssertEqual(edit.unassignedMinor, 0)
    }

    @MainActor
    func testDemoPostingAndReversalOverflowRefuseWithoutPartialMutation() throws {
        func operation(_ accountID: String, _ amount: Int64) -> RecordTransactionOperation {
            .init(accountID: accountID, categoryID: nil, amountMinor: amount, occurredOn: BudgetWorkspaceStore.dateString(.demo(monthsAgo: 0, day: 15)), payeeName: "Boundary", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])
        }
        for (opening, amount) in [(Int64.max, Int64(1)), (Int64.min, Int64(-1))] {
            let demo = DemoStore(fresh: true)
            demo.createAccount(name: "Boundary", type: "checking", isOnBudget: true, startingBalance: opening)
            let account = try XCTUnwrap(demo.accounts.first)
            let ids = demo.transactions.map(\.id)
            XCTAssertFalse(demo.recordCanonicalTransaction(operation(account.id, amount)))
            XCTAssertEqual(demo.accounts.first?.balance, opening)
            XCTAssertEqual(demo.accounts.first?.cleared, opening)
            XCTAssertEqual(demo.unassignedMinor, opening)
            XCTAssertEqual(demo.transactions.map(\.id), ids)
        }
        let demo = DemoStore(fresh: true)
        demo.createAccount(name: "Reversal boundary", type: "checking", isOnBudget: true, startingBalance: .max - 1)
        let accountID = try XCTUnwrap(demo.accounts.first?.id)
        XCTAssertTrue(demo.recordCanonicalTransaction(operation(accountID, -1), id: "outflow"))
        XCTAssertTrue(demo.recordCanonicalTransaction(operation(accountID, 2), id: "income"))
        let ids = demo.transactions.map(\.id)
        XCTAssertFalse(demo.deleteTransaction(id: "outflow"))
        XCTAssertFalse(demo.updateCanonicalTransaction(id: "outflow", operation: operation(accountID, 3)))
        XCTAssertEqual(demo.accounts.first?.balance, .max)
        XCTAssertEqual(demo.accounts.first?.cleared, .max)
        XCTAssertEqual(demo.unassignedMinor, .max)
        XCTAssertEqual(demo.transactions.map(\.id), ids)
        XCTAssertEqual(demo.transactions.first { $0.id == "outflow" }?.amount, -1)
    }

    @MainActor
    func testTransactionServiceRejectsOverflowingAndDuplicateSplitsBeforeMutation() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        let service = TransactionService(repository: source)
        source.demo.createAccount(name: "Validation", type: "checking", isOnBudget: true)
        let accountID = try XCTUnwrap(source.demo.accounts.first?.id)
        func operation(_ amounts: [Int64], total: Int64, duplicate: Bool = false) -> RecordTransactionOperation {
            .init(accountID: accountID, categoryID: nil, amountMinor: total, occurredOn: "2026-09-01", payeeName: "", memo: "", isCleared: false,
                  splits: amounts.enumerated().map { .init(categoryID: duplicate ? "same" : "c\($0.offset)", amountMinor: $0.element, memo: "") }, flag: nil, tags: [], attachmentMetadata: [])
        }
        // These previously trapped in Int64 reduce, or later in Dictionary(uniqueKeysWithValues:).
        for invalid in [operation([.max, 1], total: .max), operation([.min, -1], total: .min), operation([1, 2], total: 3, duplicate: true)] {
            do { try await service.record(invalid); XCTFail("Invalid split request must not reach a provider") }
            catch BudgetApplicationError.invalidOperation { }
            catch { XCTFail("Expected shared command validation, got \(error)") }
            XCTAssertTrue(source.demo.transactions.isEmpty)
            XCTAssertEqual(source.demo.accounts.first?.balance, 0)
            XCTAssertFalse(source.demo.recordCanonicalTransaction(invalid))
        }
        // Valid mixed-sign cancellation has the same exact semantics as the server sum.
        XCTAssertNoThrow(try service.validate(operation([.max, 1, -1], total: .max)))
        XCTAssertNoThrow(try service.validate(operation([.min, -1, 1], total: .min)))
    }

    @MainActor
    func testReconciliationWithoutExplicitObservationDoesNotUsePartialWorkspaceLedger() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let cutoff = "2026-09-05"
        let observation = try await store.reconciliationReviewObservation(accountID: account.id, throughDate: cutoff)
        let working = store.balance(for: account)
        XCTAssertNotEqual(observation.clearedBalanceMinor, store.clearedBalance(for: account),
                          "Fixture must include later cleared postings")
        store.transactions = []
        try await store.reconcile(accountID: account.id, statementBalance: observation.clearedBalanceMinor,
            throughDate: cutoff, createAdjustment: false, reason: "")
        XCTAssertEqual(store.balance(for: account), working)
        XCTAssertEqual(store.accountBalances[account.id]?.reconciledBalanceMinor, observation.clearedBalanceMinor)
        XCTAssertFalse(store.transactions.contains { $0.payeeName == "Reconciliation adjustment" })
    }

    @MainActor
    func testWorkspaceReconciliationUsesDateScopedObservationIncludingOpening() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let cutoff = "2026-09-05"
        let later = store.transactions.filter { $0.accountID == account.id && $0.isCleared && $0.occurredOn > cutoff }
        XCTAssertFalse(later.isEmpty)
        let working = store.balance(for: account)
        let allCleared = store.clearedBalance(for: account)
        let statement = allCleared - later.reduce(0) { $0 + $1.amountMinor }
        XCTAssertEqual(try store.reconciliationClearedBalance(accountID: account.id, throughDate: cutoff), statement)
        let observed = try await store.reconciliationClearedObservation(accountID: account.id, throughDate: cutoff)
        XCTAssertEqual(observed, statement)
        let cachedTransactions = store.transactions
        store.transactions = []
        let independentObservation = try await store.reconciliationClearedObservation(accountID: account.id, throughDate: cutoff)
        XCTAssertEqual(independentObservation, statement, "Provider observation must not depend on downloaded workspace rows")
        store.transactions = cachedTransactions
        do {
            try await store.reconcile(accountID: account.id, statementBalance: statement, throughDate: cutoff,
                                      createAdjustment: true, reason: "Must not override stale observation", expectedClearedBalance: statement - 1)
            XCTFail("Submission must preserve and enforce the reviewed observation")
        } catch { }
        XCTAssertEqual(store.balance(for: account), working)
        try await store.reconcile(accountID: account.id, statementBalance: statement, throughDate: cutoff,
                                  createAdjustment: false, reason: "", expectedClearedBalance: observed)
        XCTAssertEqual(store.balance(for: account), working)
        XCTAssertEqual(store.clearedBalance(for: account), allCleared)
        for original in later {
            XCTAssertEqual(store.transactions.first { $0.id == original.id }?.isReconciled, original.isReconciled)
        }
        XCTAssertEqual(store.accountBalances[account.id]?.reconciledBalanceMinor, statement)
    }

    @MainActor
    func testProductionDemoReconciliationHonorsCutoffConsentAndStaleObservation() async throws {
        for adjustment in [false, true] {
            let source = DemoWorkspaceDataSource(fresh: true)
            let demo = source.demo
            demo.createAccount(name: "Reconciliation", type: "checking", isOnBudget: true)
            let accountID = try XCTUnwrap(demo.accounts.first?.id)
            for (date, amount, cleared) in [("2026-08-01", Int64(10_000), true), ("2026-09-10", 2_000, true), ("2026-09-11", 500, false)] {
                XCTAssertTrue(demo.recordCanonicalTransaction(.init(accountID: accountID, categoryID: nil, amountMinor: amount, occurredOn: date, payeeName: "Income", memo: "", isCleared: cleared, splits: [], flag: nil, tags: [], attachmentMetadata: [])))
            }
            let beforeIDs = demo.transactions.map(\.id)
            let beforeRTA = demo.unassignedMinor
            let observation = try await source.reconciliationClearedObservation(accountID: accountID, throughDate: "2026-09-05")
            XCTAssertEqual(observation, 10_000)
            for (expected, consent) in [(Int64(10_000), false), (9_999, true)] {
                do {
                    try await source.reconcileAccount(.init(accountID: accountID, statementBalanceMinor: 10_100, throughDate: "2026-09-05", createAdjustment: consent, reason: "Correction", expectedClearedBalanceMinor: expected))
                    XCTFail("Mismatch without consent and stale observations must be refused")
                } catch { }
                XCTAssertEqual(demo.transactions.map(\.id), beforeIDs)
                XCTAssertFalse(demo.transactions.contains(where: \.reconciled))
                XCTAssertEqual(demo.accounts.first?.cleared, 12_000)
                XCTAssertEqual(demo.unassignedMinor, beforeRTA)
            }
            demo.persona = .alex
            do {
                try await source.reconcileAccount(.init(accountID: accountID, statementBalanceMinor: 10_000, throughDate: "2026-09-05", createAdjustment: false, reason: "", expectedClearedBalanceMinor: 10_000))
                XCTFail("Restricted persona must not reconcile")
            } catch { }
            demo.persona = .rey
            try await source.reconcileAccount(.init(accountID: accountID, statementBalanceMinor: adjustment ? 10_100 : 10_000, throughDate: "2026-09-05", createAdjustment: adjustment, reason: " Correction ", expectedClearedBalanceMinor: 10_000))
            XCTAssertEqual(demo.accounts.first?.balance, adjustment ? 12_600 : 12_500)
            XCTAssertEqual(demo.accounts.first?.cleared, adjustment ? 12_100 : 12_000)
            XCTAssertEqual(demo.accounts.first?.reconciledBalance, adjustment ? 10_100 : 10_000)
            XCTAssertTrue(try XCTUnwrap(demo.transactions.first { BudgetWorkspaceStore.dateString($0.date) == "2026-08-01" }).reconciled)
            XCTAssertFalse(demo.transactions.filter { BudgetWorkspaceStore.dateString($0.date) > "2026-09-05" }.contains(where: \.reconciled))
            XCTAssertEqual(demo.unassignedMinor, beforeRTA + (adjustment ? 100 : 0))
            let corrections = demo.transactions.filter { $0.payee == "Reconciliation adjustment" }
            XCTAssertEqual(corrections.count, adjustment ? 1 : 0)
            if let correction = corrections.first {
                XCTAssertEqual(BudgetWorkspaceStore.dateString(correction.date), "2026-09-05")
                XCTAssertEqual(correction.memo, "Correction")
                XCTAssertTrue(correction.reconciled && correction.cleared)
            }
        }
    }

    func testReconciliationProductionCompositionUsesReviewedObservation() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "private struct LiveReconcileView"))
        let end = try XCTUnwrap(source.range(of: "private struct StatementImportHistoryView", range: start.upperBound..<source.endIndex))
        let view = source[start.upperBound..<end.lowerBound]
        XCTAssertFalse(view.contains("workspace.reconciliationClearedBalance("))
        XCTAssertTrue(view.contains("expectedClearedBalance: cutoffBalance"))
        XCTAssertTrue(view.contains("observedContext == observationContext"))
        XCTAssertTrue(view.contains(".task(id: observationContext)"))
        XCTAssertTrue(view.contains("context == observationContext"))
        XCTAssertFalse(view.contains(".onAppear { statementBalance ="), "Returning from an import must not overwrite typed statement money")
        XCTAssertTrue(view.contains("_statementBalance = State(initialValue:"))
        XCTAssertTrue(view.contains("observationID == id"))
        XCTAssertTrue(view.contains("observedDate == BudgetWorkspaceStore.dateString(throughDate)"))
        XCTAssertTrue(view.contains("cutoffBalance == nil || loadingObservation || isSaving"))
        XCTAssertTrue(view.contains("!workspace.workspaceAccessDenied"))
    }

    @MainActor
    func testWorkspaceCurrencyFormattingPreservesEveryMinorUnit() {
        let store = BudgetWorkspaceStore.demo()
        let identity = "CurrencyFormattingTest.\(UUID().uuidString)"
        store.configurePrivacy(userID: identity)
        defer { UserDefaults.standard.removeObject(forKey: "budget.privacy.hide-amounts.\(identity).\(store.budget.id)") }
        for minor: Int64 in [9_007_199_254_740_993, .max, .min] {
            XCTAssertEqual(store.format(minor).filter(\.isNumber), String(minor.magnitude), "Currency labels must not round through binary floating point")
        }
        XCTAssertEqual(CurrencyText.display(.max, currencyCode: "USD", locale: Locale(identifier: "en_US")), "$92,233,720,368,547,758.07")
        XCTAssertEqual(CurrencyText.display(.min, currencyCode: "USD", locale: Locale(identifier: "en_US")), "-$92,233,720,368,547,758.08")
        XCTAssertEqual(CurrencyText.display(1234, currencyCode: "JPY", locale: Locale(identifier: "en_US")).filter(\.isNumber), "1234")
        XCTAssertTrue(CurrencyText.display(1234, currencyCode: "KWD", locale: Locale(identifier: "en_US")).contains("1.234"))
        XCTAssertTrue(CurrencyText.display(123456, currencyCode: "EUR", locale: Locale(identifier: "de_DE")).contains("1.234,56"))
        store.setHideAmounts(true)
        XCTAssertEqual(store.format(.max), "••••")
    }

    @MainActor
    func testMonthlyPlanCostFailsSafelyAtAggregateLimitAndHonorsSnooze() async throws {
        let store = BudgetWorkspaceStore.demo()
        let identity = "PlanCostTest.\(UUID().uuidString)"
        store.configurePrivacy(userID: identity)
        defer { UserDefaults.standard.removeObject(forKey: "budget.privacy.hide-amounts.\(identity).\(store.budget.id)") }
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let rows = try XCTUnwrap(store.summary?.categories)
        for row in rows where row.targetType != nil { try await store.deleteTarget(categoryID: row.categoryID) }
        try await store.saveTarget(categoryID: "groceries", value: APICategoryTargetUpsert(targetType: "monthly_funding", targetAmountMinor: .max))
        var summary = try XCTUnwrap(store.summary)
        XCTAssertEqual(store.monthlyPlanCostDescription(summary), store.format(.max))
        try await store.saveTarget(categoryID: "dining", value: APICategoryTargetUpsert(targetType: "monthly_funding", targetAmountMinor: 1))
        summary = try XCTUnwrap(store.summary)
        XCTAssertTrue(Int64.max.addingReportingOverflow(1).overflow, "The former unchecked reduction cannot represent these individually valid targets")
        XCTAssertEqual(store.monthlyPlanCostDescription(summary), "Amount exceeds supported range")
        store.setHideAmounts(true)
        XCTAssertEqual(store.monthlyPlanCostDescription(summary), "••••")
        store.setHideAmounts(false)
        try await store.setTargetSnoozed(categoryID: "dining", month: summary.month, isSnoozed: true)
        XCTAssertEqual(store.monthlyPlanCostDescription(try XCTUnwrap(store.summary)), store.format(.max))
    }

    @MainActor
    func testTargetSnoozeSharedStoreRefreshAndMonthIsolationAreMoneyNeutral() async throws {
        let store = BudgetWorkspaceStore.demo()
        store.planMonth = BudgetWorkspaceStore.parseDate("2026-09-01")
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        try await store.saveTarget(categoryID: "groceries", value: APICategoryTargetUpsert(targetType: "monthly_funding", targetAmountMinor: 100000))
        let before = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == "groceries" })
        let rta = store.summary?.readyToAssignMinor
        let balances = store.accounts.map { store.balance(for: $0) }
        let transactions = store.transactions
        for _ in 0..<2 {
            try await store.setTargetSnoozed(categoryID: "groceries", month: "2026-09-01", isSnoozed: true)
            await store.refresh()
            let row = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == "groceries" })
            XCTAssertEqual(row.isTargetSnoozed, true)
            XCTAssertEqual(row.recommendedContributionMinor, 0)
            XCTAssertEqual(row.underfundedMinor, 0)
            XCTAssertEqual(row.assignedMinor, before.assignedMinor)
            XCTAssertEqual(row.activityMinor, before.activityMinor)
            XCTAssertEqual(row.availableMinor, before.availableMinor)
            XCTAssertEqual(store.targets["groceries"]?.isActive, true)
            let preview = try await store.smartFundingPreview(month: "2026-09-01")
            XCTAssertFalse(preview.proposals.contains { $0.categoryID == "groceries" })
        }
        store.planMonth = BudgetWorkspaceStore.parseDate("2026-10-01")
        await store.refresh()
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == "groceries" }?.isTargetSnoozed, false)
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == "groceries" }?.recommendedContributionMinor, 100000)
        store.planMonth = BudgetWorkspaceStore.parseDate("2026-09-01")
        await store.refresh()
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == "groceries" }?.isTargetSnoozed, true)
        try await store.setTargetSnoozed(categoryID: "groceries", month: "2026-09-01", isSnoozed: false)
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == "groceries" }?.recommendedContributionMinor, before.recommendedContributionMinor)
        XCTAssertEqual(store.summary?.readyToAssignMinor, rta)
        XCTAssertEqual(store.accounts.map { store.balance(for: $0) }, balances)
        XCTAssertEqual(store.transactions, transactions)
    }

    @MainActor
    func testSmartFundingPriorityShortfallAndOverflowAreExact() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        source.demo.categories = [
            .init(id: "large", group: "Goals", name: "Large", icon: "target", assigned: 0, activity: 0, available: 0, target: 90000),
            .init(id: "urgent", group: "Goals", name: "Urgent", icon: "target", assigned: 0, activity: 0, available: 0, target: 20000)
        ]
        source.demo.categories[0].targetPriority = 10
        source.demo.categories[1].targetPriority = 90
        source.demo.createAccount(name: "Actual cash", type: "checking", isOnBudget: true, startingBalance: 30000)
        let before = source.demo.categories
        let preview = try await source.smartFundingPreview(month: "2027-02-01")
        XCTAssertEqual(preview.proposals.map(\.categoryID), ["urgent", "large"])
        XCTAssertEqual(preview.proposals.map(\.amountMinor), [20000, 10000])
        XCTAssertEqual(preview.proposals[0].targetPriority, 90)
        XCTAssertEqual(preview.proposals[0].recommendedContributionMinor, 20000)
        XCTAssertEqual(preview.proposals[0].remainingNeedMinor, 0)
        XCTAssertEqual(preview.proposals[1].targetPriority, 10)
        XCTAssertEqual(preview.proposals[1].recommendedContributionMinor, 90000)
        XCTAssertEqual(preview.proposals[1].remainingNeedMinor, 80000)
        XCTAssertEqual(preview.remainingNeedMinor, 80000)
        XCTAssertEqual(preview.unfundedCategoryCount, 1)
        XCTAssertEqual(source.demo.categories, before)
        XCTAssertEqual(source.demo.readyToAssign, 30000)
        source.demo.categories[0].target = Int64.max
        do { _ = try await source.smartFundingPreview(month: "2027-02-01"); XCTFail("Overflow must fail, not wrap or clamp money") }
        catch { }
        XCTAssertEqual(source.demo.readyToAssign, 30000)
    }

    @MainActor
    func testMoneyChartDescriptorKeepsExactLabelsAndFormatsAudioGraphAxes() throws {
        let store = BudgetWorkspaceStore.demo()
        let source = MoneyChartDescriptor(title: "Recorded observations", points: [
            .init(date: "2026-09-01", series: "Assets", label: "Assets on 2026-09-01", amountMinor: 1234),
            .init(date: "2026-09-01", series: "Liabilities", label: "Liabilities on 2026-09-01", amountMinor: -567),
            .init(date: "2026-09-30", series: "Assets", label: "Assets on 2026-09-30", amountMinor: Int64.max)
        ], format: store.format)
        let descriptor = source.makeChartDescriptor()
        XCTAssertEqual(descriptor.series.map(\.name), ["Assets", "Liabilities"])
        XCTAssertEqual(descriptor.series[0].dataPoints[0].label, "Assets on 2026-09-01, \(store.format(1234))")
        XCTAssertEqual(descriptor.series[0].dataPoints[1].label, "Assets on 2026-09-30, \(store.format(Int64.max))", "Exact labels must not round-trip through chart Double geometry")
        let y = try XCTUnwrap(descriptor.yAxis)
        XCTAssertEqual(y.valueDescriptionProvider(1234), store.format(1234))
        XCTAssertEqual(y.valueDescriptionProvider(-567), store.format(-567))
        XCTAssertEqual(y.valueDescriptionProvider(.infinity), "Outside supported amount range")
        let hidden = MoneyChartDescriptor(title: "Amounts hidden", points: [], format: store.format)
        hidden.updateChartDescriptor(descriptor)
        XCTAssertTrue(descriptor.series.isEmpty, "Privacy/context changes must remove stale audio graph data")
        XCTAssertEqual(descriptor.title, "Amounts hidden")
    }

    @MainActor
    func testCurrentDebtCostIsReadOnlyAndPartialAPRDoesNotRequirePayoffTerms() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let balances = store.accountBalances
        let summary = store.summary
        try await store.deleteAccountDebtTerms(accountID: "visa")
        let missing = try await store.debtCost(accountIDs: ["visa"])
        XCTAssertEqual(missing.accounts.count, 1)
        XCTAssertNil(missing.accounts.first?.estimatedMonthlyInterestMinor)
        _ = try await store.updateAccountDebtTerms(accountID: "visa", value: .init(termsType: "credit_card", annualRateBasisPoints: 0))
        let zero = try await store.debtCost(accountIDs: ["visa"])
        XCTAssertEqual(zero.accounts.first?.estimatedMonthlyInterestMinor, 0)
        XCTAssertEqual(zero.model, "unchanged_balance_monthly_apr")
        XCTAssertEqual(zero.asOf, "2026-09-30")
        let cash = try XCTUnwrap(store.accounts.first { $0.accountType == "checking" })
        let noDebt = try await store.debtCost(accountIDs: [cash.id])
        XCTAssertTrue(noDebt.accounts.isEmpty)
        do {
            _ = try await store.debtCost(accountIDs: ["hidden-or-missing"])
            XCTFail("Unknown account must not broaden cost scope")
        } catch {}
        XCTAssertEqual(store.accountBalances, balances)
        XCTAssertEqual(store.summary, summary)
    }
    @MainActor
    func testDemoStrategyUsesPromotionalTermsNormalizedPaymentsAndPartialReadiness() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let balances = store.accountBalances
        let summary = store.summary
        let cardBalance = try XCTUnwrap(balances["visa"])
        let principal = -cardBalance.workingBalanceMinor
        XCTAssertGreaterThan(principal, 0)
        let query = APIDebtStrategyProjectionRequest(firstPaymentOn: "2026-09-17", strategy: "avalanche", rollover: false, accountIDs: ["visa"])
        let saved = try await store.updateAccountDebtTerms(accountID: "visa", value: .init(
            termsType: "credit_card", annualRateBasisPoints: 1_200, rateType: "fixed", paymentFrequency: "monthly",
            minimumPaymentRule: "fixed", minimumPaymentMinor: principal, dueDay: 17,
            promotionalRateBasisPoints: 0, promotionalEndsOn: "2026-09-17"))
        XCTAssertTrue(saved.projectionReady)
        let promo = try await store.debtStrategyProjection(query)
        XCTAssertEqual(promo.projectedInterestMinor, 0)
        XCTAssertEqual(promo.projectedTotalPaidMinor, principal)
        XCTAssertEqual(promo.paymentCount, 1)
        _ = try await store.updateAccountDebtTerms(accountID: "visa", value: .init(
            termsType: "credit_card", annualRateBasisPoints: 0, rateType: "fixed", paymentFrequency: "weekly",
            minimumPaymentRule: "fixed", minimumPaymentMinor: 1_000, dueDay: 17))
        let normalized = try await store.debtStrategyProjection(query)
        XCTAssertEqual(normalized.projectedInterestMinor, 0)
        XCTAssertEqual(normalized.paymentCount, Int((principal + 4_332) / 4_333))
        let partial = try await store.updateAccountDebtTerms(accountID: "visa", value: .init(termsType: "credit_card"))
        XCTAssertFalse(partial.projectionReady)
        XCTAssertTrue(partial.missingProjectionFields.contains("annual_rate_basis_points"))
        let incomplete = try await store.debtStrategyProjection(query)
        XCTAssertEqual(incomplete.status, "incomplete")
        XCTAssertEqual(incomplete.incompleteAccounts.first?.missingProjectionFields, partial.missingProjectionFields)
        XCTAssertEqual(store.accountBalances, balances)
        XCTAssertEqual(store.summary, summary)
    }

    @MainActor
    func testReportSelectionResetRecoversInvalidContextWithoutMoneyMutation() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let balances = store.accountBalances
        let summary = store.summary
        store.reportPeriod = "custom"
        store.customReportStart = BudgetWorkspaceStore.parseDate("1900-01-01")
        store.reportAccountID = "no-longer-visible"
        store.reportTag = "stale-filter"
        store.includeTrackingAccounts = true
        store.resetReportSelection()
        XCTAssertEqual(store.reportPeriod, "30d")
        XCTAssertEqual(store.reportAccountID, "")
        XCTAssertEqual(store.reportTag, "")
        XCTAssertFalse(store.includeTrackingAccounts)
        let range = store.reportRange()
        XCTAssertEqual(store.customReportStart, range.0)
        XCTAssertEqual(store.customReportEnd, range.1)
        XCTAssertEqual(store.summary, summary)
        XCTAssertEqual(store.accountBalances, balances)
    }

    @MainActor
    func testDemoDebtStrategyUsesSharedExactEngineWithoutMutation() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let before = store.accountBalances
        let result = try await store.debtStrategyProjection(.init(
            firstPaymentOn: "2026-09-17", strategy: "avalanche", rollover: true,
            extraPaymentMinor: 10_000
        ))
        XCTAssertEqual(result.status, "paid_off")
        XCTAssertFalse(result.payoffOrder.isEmpty)
        XCTAssertGreaterThan(result.projectedInterestMinor, 0)
        XCTAssertEqual(store.accountBalances, before)
    }

    @MainActor
    func testMissingDebtTermsRecoverThroughSharedStoreWithoutChangingMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        await store.loadReports([.debt])
        let balances = store.accountBalances
        let summary = store.summary
        let transactions = store.transactions
        XCTAssertFalse(store.includeTrackingAccounts)
        XCTAssertTrue(store.debtReport?.accounts.contains(where: { $0.accountID == "auto" }) == true,
                      "Debt reporting must include visible loans independently of Net Worth's tracking toggle, as Live does")
        let query = APIDebtStrategyProjectionRequest(firstPaymentOn: "2026-09-17", strategy: "avalanche", rollover: false)
        try await store.deleteAccountDebtTerms(accountID: "auto")
        let incomplete = try await store.debtStrategyProjection(query)
        XCTAssertEqual(incomplete.status, "incomplete")
        XCTAssertEqual(incomplete.incompleteAccounts.map(\.accountID), ["auto"])
        _ = try await store.updateAccountDebtTerms(accountID: "auto", value: .init(
            termsType: "installment_loan", annualRateBasisPoints: 625, rateType: "fixed",
            paymentFrequency: "monthly", scheduledPaymentMinor: 41_200, dueDay: 1
        ))
        let recovered = try await store.debtStrategyProjection(query)
        XCTAssertEqual(recovered.status, "paid_off")
        await store.refresh()
        XCTAssertEqual(store.accountBalances, balances)
        XCTAssertEqual(store.summary, summary)
        XCTAssertEqual(store.transactions, transactions)
    }

    @MainActor
    func testDebtHistoryIsIndependentOfNetWorthTrackingFilter() async throws {
        let store = BudgetWorkspaceStore.demo()
        store.reportPeriod = "custom"
        store.customReportStart = BudgetWorkspaceStore.parseDate("2026-08-01")
        store.customReportEnd = BudgetWorkspaceStore.parseDate("2026-09-01")
        await store.refresh()
        await store.loadReports([.debt])
        let withoutTracking = try XCTUnwrap(store.debtReport)
        XCTAssertEqual(withoutTracking.recordedInterestLifetimeMinor, 0)
        XCTAssertNil(withoutTracking.interestTrackingStartedOn, "Future classified observations must not leak into an earlier coverage date")
        XCTAssertTrue(withoutTracking.accounts.contains(where: { $0.accountID == "auto" }))
        store.includeTrackingAccounts = true
        await store.refresh()
        await store.loadReports([.debt])
        XCTAssertEqual(store.debtReport, withoutTracking,
                       "Debt balances, historical points and interest must not inherit Net Worth's tracking filter")
    }

    @MainActor
    func testGuidedOnboardingProgressPersistsWithoutMutatingFinancialState() async {
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.refresh()
        let userID = "onboarding-test-\(UUID().uuidString)"
        let prefix = "budget.guided-onboarding.\(userID).\(store.budget.id)"
        defer {
            for suffix in ["step", "dismissed", "completed"] { UserDefaults.standard.removeObject(forKey: "\(prefix).\(suffix)") }
        }
        let beforeAccounts = store.accounts
        let beforeCategories = store.categories
        let beforeTransactions = store.transactions
        let beforeSummary = store.summary
        store.configureOnboarding(userID: userID)
        XCTAssertTrue(store.isGenuinelyEmptyForOnboarding)
        store.saveOnboarding(step: 4, dismissed: true, completed: false)

        let restored = BudgetWorkspaceStore.demo(fresh: true)
        restored.configureOnboarding(userID: userID)
        XCTAssertEqual(restored.onboardingStep, 4)
        XCTAssertTrue(restored.onboardingDismissed)
        XCTAssertFalse(restored.onboardingCompleted)
        XCTAssertEqual(store.accounts, beforeAccounts)
        XCTAssertEqual(store.categories, beforeCategories)
        XCTAssertEqual(store.transactions, beforeTransactions)
        XCTAssertEqual(store.summary, beforeSummary)
    }
    @MainActor
    func testDemoHouseholdAccessPersistsPresetAndScopeWithoutChangingWorkspaceMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let before = (store.summary?.readyToAssignMinor, store.accounts.map(\.id), store.transactions.map(\.id))
        let initial = try await store.accessProfile(userID: "jordan")
        let capabilities = ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances"]
        _ = try await store.updateAccessProfile(userID: "jordan", value: .init(capabilities: capabilities, restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: initial.version))
        let reloaded = try await store.accessProfile(userID: "jordan")
        XCTAssertTrue(reloaded.restrictAccounts)
        XCTAssertEqual(reloaded.accountIDs, ["checking"])
        XCTAssertEqual((store.summary?.readyToAssignMinor, store.accounts.map(\.id), store.transactions.map(\.id)).0, before.0)
        XCTAssertEqual(store.accounts.map(\.id), before.1)
        XCTAssertEqual(store.transactions.map(\.id), before.2)
    }
    override func tearDown() {
        ConnectionURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testHideAmountsPersistsPerUserAndDoesNotMutateFinancialState() async {
        let firstUser = "privacy-\(UUID().uuidString)"
        let secondUser = "privacy-\(UUID().uuidString)"
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        let readyToAssign = store.summary?.readyToAssignMinor
        let balances = store.accountBalances
        let activity = store.summary?.categories.map(\.activityMinor)
        let transactions = store.transactions

        store.configurePrivacy(userID: firstUser)
        XCTAssertFalse(store.hideAmounts)
        XCTAssertNotEqual(store.format(12_345), "••••")
        store.setHideAmounts(true)
        XCTAssertEqual(store.format(12_345), "••••")

        let relaunched = BudgetWorkspaceStore.demo()
        relaunched.configurePrivacy(userID: firstUser)
        XCTAssertTrue(relaunched.hideAmounts, "the user's privacy preference must survive workspace reconstruction")
        let otherMember = BudgetWorkspaceStore.demo()
        otherMember.configurePrivacy(userID: secondUser)
        XCTAssertFalse(otherMember.hideAmounts, "one household member's preference must not alter another member's presentation")

        XCTAssertEqual(store.summary?.readyToAssignMinor, readyToAssign)
        XCTAssertEqual(store.accountBalances, balances)
        XCTAssertEqual(store.summary?.categories.map(\.activityMinor), activity)
        XCTAssertEqual(store.transactions, transactions)

        store.setHideAmounts(false)
    }

    @MainActor
    func testActivityLifecycleFilterKeepsDemoAndLiveContractParity() async throws {
        let source = DemoWorkspaceDataSource(fresh: false)
        try await source.voidTransaction(id: "t1", reason: "Lifecycle filter regression")

        let voided = try await source.browseTransactions(
            query: APITransactionQuery(lifecycleStatuses: ["voided"])
        )
        let reversals = try await source.browseTransactions(
            query: APITransactionQuery(lifecycleStatuses: ["reversal"])
        )
        let posted = try await source.browseTransactions(
            query: APITransactionQuery(lifecycleStatuses: ["posted"])
        )

        XCTAssertEqual(voided.items.map(\.id), ["t1"])
        XCTAssertEqual(reversals.items.count, 1)
        XCTAssertTrue(reversals.items.allSatisfy { $0.status == "reversal" })
        XCTAssertFalse(posted.items.contains(where: { $0.id == "t1" }))
    }

    @MainActor
    func testFreshBudgetStartingBalanceAndActivationSurfacesUseProductionPaths() throws {
        let demo = DemoStore(fresh: true)

        demo.createAccount(name: "Everyday Checking", type: "checking", isOnBudget: true, startingBalance: 72_000)
        XCTAssertEqual(demo.accounts.first?.balance, 72_000)
        XCTAssertEqual(demo.readyToAssign, 72_000)
        XCTAssertEqual(demo.transactions.first?.payee, "Starting Balance")
        XCTAssertTrue(demo.transactions.first?.cleared == true)
        XCTAssertEqual(demo.transactions.first?.categoryIDs, [])

        let testFile = URL(fileURLWithPath: #filePath)
        let appDirectory = testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp")
        let workspace = try String(contentsOf: appDirectory.appendingPathComponent("BudgetWorkspaceView.swift"))
        let root = try String(contentsOf: appDirectory.appendingPathComponent("RootView.swift"))
        let app = try String(contentsOf: appDirectory.appendingPathComponent("BudgetApp.swift"))
        let editor = try String(contentsOf: appDirectory.appendingPathComponent("EditingViews.swift"))
        XCTAssertTrue(root.contains("ActiveBudgetShell(context: context)"), "resolved routing must enter the persistent active-budget shell")
        XCTAssertTrue(root.contains("private struct AuthenticationFlowView"), "authentication drafts must be owned below the application route boundary")
        XCTAssertFalse(root.contains("@StateObject private var authenticationForm"), "RootView must not observe keystrokes and invalidate the routed hierarchy")
        XCTAssertFalse(root.contains(".fullScreenCover(item: $selectedBudget)"), "the active workspace must not be a temporary child of a Budgets browser")
        XCTAssertEqual(root.components(separatedBy: "ActiveBudgetShell(context: context)").count - 1, 1, "all resolved sources must enter the one product shell route")
        XCTAssertFalse(root.contains("case .deterministicWorkspace"), "deterministic and Live must not have separate workspace routes")
        let shell = root.components(separatedBy: "struct ActiveBudgetShell").last?.components(separatedBy: "private struct WorkspaceCompositionRoot").first ?? ""
        XCTAssertFalse(shell.contains("BudgetSelectionView"), "the active shell must never fall back to the legacy Budgets browser")
        XCTAssertTrue(workspace.contains("WorkspaceCommandRepository"))
        let commandWorkspace = workspace.replacingOccurrences(
            of: "try await (dataSource as? DemoWorkspaceDataSource)?.synchronizeLocalAuthorityForBackup()",
            with: ""
        )
        XCTAssertFalse(commandWorkspace.contains("dataSource as? DemoWorkspaceDataSource"), "workspace commands must use the common repository contract")
        XCTAssertTrue(workspace.contains("Add your first account"))
        XCTAssertEqual(workspace.components(separatedBy: ".workspaceProfileToolbar").count - 1, 6, "Profile & Settings must be global workspace chrome on every tab")
        XCTAssertTrue(workspace.contains(".id(activeTab)"), "the iOS 27 production shell must materialize the selected tab instead of rendering a blank lazy stack")
        XCTAssertTrue(workspace.contains("intentional identity replacement at the shell boundary"), "the exceptional shell identity boundary must remain documented")
        XCTAssertTrue(workspace.contains("Section(\"Household management\")"), "member lifecycle actions must remain ahead of the dynamic people list")
        XCTAssertTrue(workspace.contains(".sheet(item: $invitationDraft"), "re-invites must present the preserved address as the sheet payload")
        XCTAssertFalse(workspace.contains("workspaceDismissToolbar"), "the active budget must not navigate back to a Budgets parent")
        XCTAssertTrue(workspace.contains("Create Category Group"))
        XCTAssertTrue(workspace.contains("Add your first category"))
        XCTAssertTrue(workspace.contains("Unassigned in selected month"))
        XCTAssertTrue(workspace.contains("plan-funding-limit"))
        XCTAssertTrue(editor.contains("openingBalanceMinor: balance"))
        XCTAssertTrue(editor.contains("selection: $date, in: ...Date()"), "ordinary transaction entry must not accept future actual dates")
        XCTAssertTrue(workspace.contains("Button(\"Schedule Transaction\""), "the production Activity action menu must expose canonical schedule creation")
        XCTAssertTrue(workspace.contains(".task(id: session.token)"), "the production workspace must bind the current credential even when it first renders after rotation")
        XCTAssertTrue(workspace.contains("LiveWorkspaceCredentials"), "all long-lived Live repositories must share mutable credential ownership")
        XCTAssertTrue(workspace.contains("DeviceAccessSettingsView"), "production Profile & Settings must expose device pairing and revocation")
        XCTAssertTrue(workspace.contains("device-pairing-qr"), "the production pairing path must render a native QR rather than disclose credentials to a third party")
        XCTAssertTrue(workspace.contains("prepare-complete-budget-export"), "server owners must be able to prepare the existing privacy-gated structured export")
        XCTAssertTrue(workspace.contains("share-complete-budget-export"), "the structured export must be shareable without developer tooling")
        XCTAssertTrue(workspace.contains("budgetExportJSON"), "the export UI must use the canonical server export instead of reconstructing history on-device")
        XCTAssertTrue(app.contains("OpenClearPocketPlanIntent"))
        XCTAssertTrue(app.contains("OpenClearPocketAccountsIntent"))
        XCTAssertTrue(app.contains("OpenClearPocketInsightsIntent"))
        XCTAssertTrue(app.contains("OpenClearPocketActivityIntent"))
        XCTAssertTrue(app.contains("OpenClearPocketHouseholdIntent"))
        XCTAssertTrue(app.contains("OpenClearPocketScreenIntent"))
        XCTAssertTrue(workspace.contains("consumeWorkspaceShortcutRequest()"), "workspace shortcuts must route through the shared production shell")
        XCTAssertTrue(root.contains("PairingCodeScanner"), "the real source-selection flow must support native QR pairing")
        XCTAssertTrue(root.contains("PairingJoinView"), "pairing must enter through the canonical application route")
        XCTAssertTrue(workspace.contains("struct PayeeSearchSelectionView"), "all payee-selection workflows must share the bounded searchable selector")
        XCTAssertTrue(workspace.contains("activity-payee-selector"), "Activity filtering must select an existing first-class payee identity")
        XCTAssertTrue(workspace.contains("limit: 20"), "payee selection must request bounded result pages")
        XCTAssertTrue(workspace.contains("scoped-transaction-history-load-more"),
                      "payee and category history must page through the canonical transaction browser")
        XCTAssertTrue(workspace.contains("payee-view-all-transactions"),
                      "payee history must not stop at the hydrated recent rows")
        XCTAssertTrue(workspace.contains("category-view-all-transactions"),
                      "category history must not stop at the hydrated recent rows")
        XCTAssertTrue(workspace.contains("household-access-history-load-more"),
                      "owner-visible household access history must not silently stop at a recent-row cap")
        XCTAssertTrue(workspace.contains("store.householdAccessEvents(limit: limit, offset: offset)"),
                      "household access history must request older authoritative pages instead of slicing one snapshot")
        XCTAssertTrue(workspace.contains("WorkspaceDestination(id: 5, title: \"Household\", symbol: \"person.2.fill\")"),
                      "the production workspace must expose Household as a direct first-class destination")
        XCTAssertFalse(workspace.contains("TabView(selection: tabSelection)"),
                       "the six-destination iPhone shell must not regress to UITabBarController's More fallback")
        XCTAssertTrue(workspace.contains("LiveHouseholdOverviewView(session: session, store: store)"),
                      "the household tab must use the active production session and workspace store")
        XCTAssertTrue(workspace.contains("accessibilityIdentifier(\"household-overview-screen\")"),
                      "the real household destination must remain available to production UI coverage")
        XCTAssertTrue(workspace.contains("invitationDraft = .init(email: member.email, role: member.role)"),
                      "re-inviting a removed member must carry the known address and role in the presentation payload")
        XCTAssertTrue(workspace.contains("ShareLink(item: invitationMessage)"),
                      "one-time household invitations must support the native share sheet")
        XCTAssertTrue(workspace.contains("Section(\"Visibility preview\")"),
                      "member access must summarize budget, account, balance, category, and reporting visibility")
        XCTAssertTrue(workspace.contains("Section(\"What this member can see\")"),
                      "the most important household visibility controls must not be buried behind advanced customization")
        XCTAssertTrue(workspace.contains("visibilityToggle(\"Household Ready to Assign\", capability: \"view_budget_totals\""),
                      "whole-budget Available visibility must remain an explicit owner control")
        XCTAssertTrue(workspace.contains("payee-search-load-more"), "large payee histories must paginate instead of hydrating every identity")
        XCTAssertFalse(workspace.contains("async let loadedPayees = client.payees"), "workspace hydration must not download the entire household payee history")
        XCTAssertTrue(workspace.contains(".task(id: attachmentObservationContext)"), "attachment reads must follow current workspace and credential observations")
        XCTAssertTrue(workspace.contains("store.reportRevision)|\\(store.liveCredentialRevision)"))
        XCTAssertTrue(workspace.contains("AttachmentListObservation()"))
        XCTAssertTrue(workspace.contains("attachment-list-retry"))
        XCTAssertTrue(workspace.contains("attachment-take-photo"))
        XCTAssertTrue(workspace.contains("attachment-choose-photo"))
        XCTAssertTrue(workspace.contains("attachment-choose-file"))
        XCTAssertTrue(workspace.contains(".photosPicker(isPresented: $choosingPhoto"), "photo selection must use the native Photos picker")
        XCTAssertTrue(workspace.contains("try await upload(data: data"), "camera, Photos, and Files must converge on the existing attachment upload service")
        XCTAssertEqual(workspace.components(separatedBy: "uploadTransactionAttachment(id: transaction.id").count - 1, 1, "attachment sources must not create separate storage/upload paths")
        XCTAssertTrue(workspace.contains(".buttonStyle(.plain).accessibilityIdentifier(\"attachment-preview-"), "preview and remove must not inherit Form row-wide button activation")
        XCTAssertTrue(workspace.contains(".buttonStyle(.borderless).foregroundStyle(.red)"))
        XCTAssertTrue(workspace.contains(".accessibilityIdentifier(\"attachment-remove-"))
        XCTAssertTrue(workspace.contains(".confirmationDialog(\"Remove Attachment?\""), "detach must require explicit confirmation")
        XCTAssertTrue(workspace.contains("AttachmentPreviewScreen"), "Quick Look must be contained in an explicitly dismissible navigation boundary")
        XCTAssertTrue(workspace.contains("dismantleUIViewController"), "the Quick Look bridge must release its data source when dismissed")
        XCTAssertTrue(workspace.contains("payee-created-confirmation"), "payee management must confirm creation before presenting the exact server-authoritative result")
        XCTAssertTrue(workspace.contains("presentQueuedSourceAfterDismissal()"), "source modals must wait for the chooser to dismiss")
        XCTAssertTrue(workspace.contains("schedule == nil ? \"Unable to create schedule\" : \"Unable to update schedule\""))
        XCTAssertFalse(editor.contains("APITransactionCreate("), "production editors must emit canonical application operations")
        XCTAssertFalse(editor.contains("let serverURL"), "editors must submit through the shared workspace store, not own transport configuration")
        XCTAssertFalse(editor.contains("let token"), "credentials must not leak into local editing state")
    }

    func testFreshBudgetActivationIsAuthoritativeCapabilityDrivenAndHasNoLatch() {
        let freshOwner = FreshBudgetActivationState(accountCount: 0, groupCount: 0, categoryCount: 0, canManageStructure: true)
        XCTAssertTrue(freshOwner.needsAccount)
        XCTAssertTrue(freshOwner.showsAddAccount)
        XCTAssertTrue(freshOwner.showsCreateGroup)
        XCTAssertFalse(freshOwner.showsAddCategory)
        XCTAssertFalse(freshOwner.showsNormalPlan)

        let afterGroup = FreshBudgetActivationState(accountCount: 1, groupCount: 1, categoryCount: 0, canManageStructure: true)
        XCTAssertFalse(afterGroup.needsAccount)
        XCTAssertTrue(afterGroup.showsAddAccount, "adding another account remains discoverable")
        XCTAssertFalse(afterGroup.showsCreateGroup)
        XCTAssertTrue(afterGroup.showsAddCategory)

        let populated = FreshBudgetActivationState(accountCount: 1, groupCount: 1, categoryCount: 1, canManageStructure: true)
        XCTAssertTrue(populated.showsNormalPlan)
        XCTAssertTrue(populated.showsAddAccount)

        let restricted = FreshBudgetActivationState(accountCount: 0, groupCount: 0, categoryCount: 0, canManageStructure: false)
        XCTAssertFalse(restricted.showsAddAccount)
        XCTAssertFalse(restricted.showsCreateGroup)
        XCTAssertFalse(restricted.showsAddCategory)
    }

    @MainActor
    func testWorkspaceShortcutDestinationIsOneShotAndExact() {
        UserDefaults.standard.removeObject(forKey: WorkspaceShortcutRequest.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: WorkspaceShortcutRequest.defaultsKey) }

        WorkspaceShortcutRequest.request(.accounts)
        XCTAssertEqual(WorkspaceShortcutRequest.consume(), .accounts)
        XCTAssertNil(WorkspaceShortcutRequest.consume(), "a handled shortcut must not reroute later app activations")

        WorkspaceShortcutRequest.request(.insights)
        XCTAssertEqual(WorkspaceShortcutRequest.consume(), .insights)
    }

    @MainActor
    func testAllocationHistoryCarriesServerAuthoritativeActorDisplayName() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: try XCTUnwrap(URL(string: "http://localhost")), token: "demo")
        let operation = try XCTUnwrap(store.allocationOperations.first)
        XCTAssertFalse(try XCTUnwrap(operation.actorDisplayName).isEmpty)
    }

    @MainActor
    func testProductionWorkspaceRendersFreshAccountsAndPlanTabsWithLivePresentationChrome() async {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppSession(
            defaults: defaults,
            keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"),
            initialMode: .deterministic
        )
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")

        let accounts = WorkspaceSelectionHarness(store: store, session: session, start: 0, destination: 3)
        XCTAssertGreaterThan(renderedContentSignal(accounts), 1_000, "switching Home → Accounts rendered blank")
        let plan = WorkspaceSelectionHarness(store: store, session: session, start: 3, destination: 1)
        XCTAssertGreaterThan(renderedContentSignal(plan), 1_000, "switching Accounts → Plan rendered blank")

        // The live composition creates the same store from an authoritative budget before its first
        // snapshot arrives. Exercise that zero-content shape as well as the deterministic adapter.
        let liveShapedStore = BudgetWorkspaceStore(budget: store.budget)
        let liveShapedPlan = WorkspaceSelectionHarness(store: liveShapedStore, session: session, start: 3, destination: 1)
        XCTAssertGreaterThan(renderedContentSignal(liveShapedPlan), 1_000, "live-shaped Accounts → Plan rendered blank")
    }

    @MainActor
    func testAccountMetadataEditPreservesExactFinancialObservationAndRejectsUnsafeType() async throws {
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        try await store.createAccount(.init(name: "Everyday", kind: "checking", isOnBudget: true, openingBalanceMinor: 200_000))
        let account = try XCTUnwrap(store.accounts.first)
        let balanceBefore = store.accountBalances[account.id]
        let summaryBefore = store.summary
        let transactionCountBefore = store.transactions.count

        try await store.updateAccount(.init(accountID: account.id, name: "Emergency Savings", currentKind: "checking", kind: "savings", isOnBudget: true, isClosed: false))
        let updated = try XCTUnwrap(store.accounts.first(where: { $0.id == account.id }))
        XCTAssertEqual(updated.name, "Emergency Savings")
        XCTAssertEqual(updated.accountType, "savings")
        XCTAssertTrue(updated.isOnBudget)
        XCTAssertEqual(store.accountBalances[account.id], balanceBefore)
        XCTAssertEqual(store.summary, summaryBefore)
        XCTAssertEqual(store.transactions.count, transactionCountBefore)
        let history = try await store.accountHistory(accountID: account.id, limit: 25, offset: 0)
        XCTAssertEqual(history.map(\.action), ["updated", "created"])
        XCTAssertEqual(history.first?.beforeSnapshot?.name, "Everyday")
        XCTAssertEqual(history.first?.afterSnapshot.name, "Emergency Savings")
        XCTAssertNotNil(history.first?.actorDisplayName)

        try await store.updateAccount(.init(accountID: account.id, name: "Emergency Savings", currentKind: "savings", kind: "savings", isOnBudget: true, isClosed: false))
        let afterNoOp = try await store.accountHistory(accountID: account.id, limit: 25, offset: 0)
        XCTAssertEqual(afterNoOp, history, "A true no-op must not invent another account decision")

        do {
            try await store.updateAccount(.init(accountID: account.id, name: "Card", currentKind: "savings", kind: "credit", isOnBudget: true, isClosed: false))
            XCTFail("Expected an unsafe type transition to be rejected")
        } catch let error as BudgetApplicationError {
            guard case .invalidOperation = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testEmptyGroupPersistsThroughProviderRefreshAndOwnsNewCategory() async throws {
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        try await store.createGroup(name: "Monthly Expenses")
        let group = try XCTUnwrap(store.groups.first(where: { $0.name == "Monthly Expenses" }))
        XCTAssertFalse(store.categories.contains(where: { $0.groupID == group.id }))
        await store.refresh()
        XCTAssertTrue(store.groups.contains(where: { $0.id == group.id }))

        try await store.createCategory(groupID: group.id, newGroupName: "", name: "Groceries", delegatedUserID: nil)
        XCTAssertEqual(store.categories.first(where: { $0.name == "Groceries" })?.groupID, group.id)
        XCTAssertEqual(store.groups.filter { $0.name == "Monthly Expenses" }.count, 1)
    }

    @MainActor
    func testAdditionalGroupCreationPreservesPopulatedPlanAndFinancialState() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let categoriesBefore = store.categories
        let summaryBefore = store.summary
        let balancesBefore = store.accountBalances

        try await store.createGroup(name: "Savings Goals")
        let newGroup = try XCTUnwrap(store.groups.first(where: { $0.name == "Savings Goals" }))
        XCTAssertFalse(store.categories.contains(where: { $0.groupID == newGroup.id }))
        XCTAssertEqual(store.categories, categoriesBefore)
        XCTAssertEqual(store.summary, summaryBefore)
        XCTAssertEqual(store.accountBalances, balancesBefore)

        await store.refresh()
        XCTAssertEqual(store.groups.filter { $0.name == "Savings Goals" }.count, 1)
        XCTAssertTrue(store.categories.contains(where: { $0.name == "Groceries" }))
        try await store.createCategory(groupID: newGroup.id, newGroupName: "", name: "Rainy Day Reserve", delegatedUserID: nil)
        XCTAssertEqual(store.categories.first(where: { $0.name == "Rainy Day Reserve" })?.groupID, newGroup.id)
        XCTAssertEqual(store.groups.filter { $0.name == "Savings Goals" }.count, 1)
    }

    @MainActor
    func testCategoryNamesAreNormalizedUniqueWithinGroupWithoutFinancialMutation() async throws {
        let store = BudgetWorkspaceStore.demo(fresh: true)
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        try await store.createGroup(name: "Savings Goals")
        try await store.createGroup(name: "Monthly Expenses")
        let savings = try XCTUnwrap(store.groups.first(where: { $0.name == "Savings Goals" }))
        let monthly = try XCTUnwrap(store.groups.first(where: { $0.name == "Monthly Expenses" }))
        try await store.createCategory(groupID: savings.id, newGroupName: "", name: "Emergency Fund", delegatedUserID: nil)
        let summaryBefore = store.summary
        let balancesBefore = store.accountBalances
        let transactionsBefore = store.transactions

        for duplicateName in ["Emergency Fund", "emergency fund", "  EMERGENCY FUND  "] {
            do {
                try await store.createCategory(groupID: savings.id, newGroupName: "", name: duplicateName, delegatedUserID: nil)
                XCTFail("Expected duplicate category rejection for \(duplicateName)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("already exists"))
            }
        }
        XCTAssertEqual(store.summary, summaryBefore)
        XCTAssertEqual(store.accountBalances, balancesBefore)
        XCTAssertEqual(store.transactions, transactionsBefore)
        XCTAssertEqual(store.categories.filter { $0.groupID == savings.id }.count, 1)

        try await store.createCategory(groupID: monthly.id, newGroupName: "", name: " emergency fund ", delegatedUserID: nil)
        try await store.createCategory(groupID: savings.id, newGroupName: "", name: "Vacation", delegatedUserID: nil)
        let vacation = try XCTUnwrap(store.categories.first(where: { $0.name == "Vacation" }))
        do {
            try await store.updateCategory(id: vacation.id, value: .init(groupID: savings.id, name: "EMERGENCY FUND", sortOrder: vacation.sortOrder, isArchived: false), delegatedUserID: nil)
            XCTFail("Expected conflicting rename rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        let emergency = try XCTUnwrap(store.categories.first(where: { $0.groupID == savings.id && $0.name == "Emergency Fund" }))
        try await store.updateCategory(id: emergency.id, value: .init(groupID: savings.id, name: " emergency fund ", sortOrder: emergency.sortOrder, isArchived: false), delegatedUserID: nil)
        XCTAssertEqual(store.categories.first(where: { $0.id == emergency.id })?.name, "emergency fund")

        let directDemo = DemoStore()
        XCTAssertFalse(directDemo.createCategory(name: " groceries ", group: "Food"))
        XCTAssertTrue(directDemo.errorMessage?.contains("already exists") == true)
    }

    @MainActor
    func testScheduledRepositoryCRUDRecurrencesAndFutureIncomeStayNonSpendable() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        XCTAssertEqual(store.scheduledTransactions.count, 5)
        XCTAssertEqual(store.scheduledTransactions.filter(\.isActive).count, 4)
        XCTAssertTrue(store.scheduledTransactions.contains { $0.id == "schedule-inactive" && !$0.isActive })
        XCTAssertEqual(Set(store.scheduledTransactions.map(\.recurrenceUnit)), ["weeks", "months"])
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let before = (store.summary?.readyToAssignMinor, store.balance(for: account), store.transactions.count)
        for unit in ["once", "days", "weeks", "months", "years"] {
            try await store.createSchedule(.init(accountID: account.id, name: "Future \(unit)", amountMinor: 50_000, nextDate: "2026-12-01", recurrenceUnit: unit, intervalCount: unit == "weeks" ? 2 : 1))
            XCTAssertTrue(store.scheduledTransactions.contains { $0.name == "Future \(unit)" && $0.recurrenceUnit == unit })
        }
        try await store.createSchedule(.init(accountID: account.id, name: "Bounded daily", amountMinor: -100, nextDate: "2026-12-01", recurrenceUnit: "days", endDate: "2026-12-02"))
        XCTAssertEqual(store.scheduledTransactions.first { $0.name == "Bounded daily" }?.endDate, "2026-12-02")
        XCTAssertEqual(store.forecast?.occurrences.filter { $0.name == "Bounded daily" }.count, 2)
        try await store.createSchedule(.init(accountID: account.id, name: "Three paychecks", amountMinor: 25_000, nextDate: "2026-12-01", recurrenceUnit: "weeks", remainingOccurrences: 3))
        XCTAssertEqual(store.scheduledTransactions.first { $0.name == "Three paychecks" }?.remainingOccurrences, 3)
        let boundedPaychecks = store.forecast?.occurrences.filter { $0.name == "Three paychecks" } ?? []
        XCTAssertFalse(boundedPaychecks.isEmpty)
        XCTAssertLessThanOrEqual(boundedPaychecks.count, 3, "the occurrence limit caps the rolling forecast rather than extending its horizon")
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.0)
        XCTAssertEqual(store.balance(for: account), before.1)
        XCTAssertEqual(store.transactions.count, before.2)
        XCTAssertTrue(store.forecast?.occurrences.contains { $0.name == "Future years" && $0.amountMinor == 50_000 } == true)

        let edited = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Future months" })
        try await store.updateSchedule(id: edited.id, operation: .init(accountID: account.id, name: "Edited monthly", amountMinor: -1_234, nextDate: "2026-12-02", recurrenceUnit: "months", intervalCount: 3))
        XCTAssertTrue(store.scheduledTransactions.contains { $0.name == "Edited monthly" && $0.intervalCount == 3 })
        try await store.updateSchedule(id: edited.id, operation: .init(accountID: account.id, name: "Edited monthly", amountMinor: -1_234, nextDate: "2026-12-02", recurrenceUnit: "months", intervalCount: 3, isActive: false))
        XCTAssertTrue(store.scheduledTransactions.contains { $0.id == edited.id && !$0.isActive }, "paused schedules remain manageable after reload")
        try await store.updateSchedule(id: edited.id, operation: .init(accountID: account.id, name: "Edited monthly", amountMinor: -1_234, nextDate: "2026-12-02", recurrenceUnit: "months", intervalCount: 3, isActive: true))
        XCTAssertTrue(store.scheduledTransactions.contains { $0.id == edited.id && $0.isActive })
        let deletable = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Future days" })
        try await store.updateSchedule(id: deletable.id, operation: .init(accountID: account.id, name: deletable.name, amountMinor: deletable.amountMinor, nextDate: deletable.nextDate, recurrenceUnit: deletable.recurrenceUnit, intervalCount: deletable.intervalCount, isActive: false))
        try await store.deleteSchedule(id: deletable.id)
        XCTAssertFalse(store.scheduledTransactions.contains { $0.id == deletable.id })

        let history = try await store.scheduleHistory(limit: 100)
        XCTAssertTrue(history.contains { $0.scheduleID == edited.id && $0.action == "created" })
        XCTAssertTrue(history.contains { $0.scheduleID == edited.id && $0.action == "updated" && $0.afterSnapshot?.amountMinor == -1_234 })
        XCTAssertTrue(history.contains { $0.scheduleID == edited.id && $0.action == "paused" })
        XCTAssertTrue(history.contains { $0.scheduleID == edited.id && $0.action == "resumed" })
        XCTAssertTrue(history.contains { $0.scheduleID == deletable.id && $0.action == "deleted" && $0.afterSnapshot == nil })
        let reloadedHistory = try await store.scheduleHistory(limit: 100)
        XCTAssertEqual(history, reloadedHistory, "history is read-only and stable")
    }

    @MainActor
    func testSkippingScheduledOccurrenceAdvancesWithoutPostingOrMovingMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let before = (store.summary?.readyToAssignMinor, store.balance(for: account), store.transactions.count)

        try await store.createSchedule(.init(
            accountID: account.id,
            name: "Skip monthly",
            amountMinor: -1_234,
            nextDate: "2026-10-31",
            recurrenceUnit: "months"
        ))
        let recurring = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Skip monthly" })
        try await store.skipNextScheduleOccurrence(id: recurring.id)
        let advanced = try XCTUnwrap(store.scheduledTransactions.first { $0.id == recurring.id })
        XCTAssertEqual(advanced.nextDate, "2026-11-30")
        XCTAssertTrue(advanced.isActive)

        try await store.createSchedule(.init(
            accountID: account.id,
            name: "Skip counted final",
            amountMinor: -900,
            nextDate: "2026-11-30",
            recurrenceUnit: "months",
            remainingOccurrences: 1
        ))
        let countedFinal = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Skip counted final" })
        try await store.skipNextScheduleOccurrence(id: countedFinal.id)
        let exhausted = try XCTUnwrap(store.scheduledTransactions.first { $0.id == countedFinal.id })
        XCTAssertFalse(exhausted.isActive)
        XCTAssertEqual(exhausted.remainingOccurrences, 0)

        try await store.createSchedule(.init(
            accountID: account.id,
            name: "Skip final",
            amountMinor: -750,
            nextDate: "2026-11-30",
            recurrenceUnit: "months",
            endDate: "2026-11-30"
        ))
        let final = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Skip final" })
        try await store.skipNextScheduleOccurrence(id: final.id)
        XCTAssertFalse(try XCTUnwrap(store.scheduledTransactions.first { $0.id == final.id }).isActive)

        try await store.createSchedule(.init(
            accountID: account.id,
            name: "Skip once",
            amountMinor: -500,
            nextDate: "2026-11-01",
            recurrenceUnit: "once"
        ))
        let once = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Skip once" })
        try await store.skipNextScheduleOccurrence(id: once.id)
        XCTAssertFalse(try XCTUnwrap(store.scheduledTransactions.first { $0.id == once.id }).isActive)
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.0)
        XCTAssertEqual(store.balance(for: account), before.1)
        XCTAssertEqual(store.transactions.count, before.2)
    }

    @MainActor
    func testScheduledProductionSurfacesShareWorkspaceStateAndForecastContract() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let forecast = try XCTUnwrap(store.forecast)
        XCTAssertFalse(forecast.occurrences.isEmpty)
        XCTAssertTrue(forecast.occurrences.contains { $0.destinationAccountID != nil })
        XCTAssertTrue(forecast.occurrences.contains { $0.amountMinor > 0 })
        XCTAssertTrue(forecast.occurrences.contains { $0.accountID == "visa" })
        XCTAssertFalse(forecast.occurrences.contains { $0.scheduledTransactionID == "schedule-inactive" })

        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let contents = try String(contentsOf: source)
        XCTAssertTrue(contents.contains("LiveScheduledTransactionsView"))
        XCTAssertTrue(contents.contains("Upcoming scheduled"))
        XCTAssertTrue(contents.contains("View all scheduled transactions"))
        XCTAssertTrue(contents.contains("Paused · no forecast or realization"))
        XCTAssertTrue(contents.contains("Schedule history"))
        XCTAssertTrue(contents.contains("ScheduledTransactionHistoryView"))
        XCTAssertTrue(contents.contains("Load more"))
    }

    @MainActor
    func testForecastHorizonReloadsWithoutPostingMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let original = try XCTUnwrap(store.forecast)
        let transactionIDs = store.transactions.map(\.id)
        let balances = store.accountBalances.mapValues(\.workingBalanceMinor)

        let short = try await store.forecastObservation(days: 30)
        XCTAssertEqual(short.through, "2026-10-05")
        XCTAssertLessThanOrEqual(short.occurrences.count, original.occurrences.count)

        let annual = try await store.forecastObservation(days: 365)
        XCTAssertEqual(annual.through, "2027-09-05")
        XCTAssertGreaterThan(annual.occurrences.count, short.occurrences.count)
        XCTAssertEqual(annual.actualTotalOnBudgetMinor, original.actualTotalOnBudgetMinor)
        XCTAssertEqual(store.transactions.map(\.id), transactionIDs)
        XCTAssertEqual(store.accountBalances.mapValues(\.workingBalanceMinor), balances)
        XCTAssertEqual(store.forecast, original, "Detail horizons must not overwrite Home's 90-day observation")
        await store.refresh()
        XCTAssertEqual(store.forecast, original)
        let refreshedAnnual = try await store.forecastObservation(days: 365)
        XCTAssertEqual(refreshedAnnual.through, annual.through)
    }

    @MainActor
    func testReportRangeUsesFixtureClockOnlyForDeterministicProvider() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2031, month: 4, day: 18))!

        let demo = BudgetWorkspaceStore.demo()
        let demoRange = demo.reportRange(calendar: calendar, now: now)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: demoRange.1), DateComponents(year: 2026, month: 9, day: 30))

        let live = BudgetWorkspaceStore(budget: demo.budget)
        let liveRange = live.reportRange(calendar: calendar, now: now)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: liveRange.0), DateComponents(year: 2031, month: 3, day: 20))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: liveRange.1), DateComponents(year: 2031, month: 4, day: 18))
    }

    @MainActor
    func testLiveReportRangeUsesLocalCalendarDatesAcrossDSTAndUTCRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let demo = BudgetWorkspaceStore.demo()
        let live = BudgetWorkspaceStore(budget: demo.budget)
        live.reportPeriod = "30d"

        // Noon on the day after spring-forward avoids any nonexistent wall-clock component while
        // proving that report boundaries use local calendar days rather than subtracting 24-hour
        // UTC intervals.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let range = live.reportRange(calendar: calendar, now: now)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: range.0), DateComponents(year: 2026, month: 2, day: 8))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: range.1), DateComponents(year: 2026, month: 3, day: 9))
        XCTAssertEqual(calendar.dateComponents([.day], from: range.0, to: range.1).day, 29)
    }

    @MainActor
    func testScheduledRealizationAdvancesAndOnceDeactivatesWithWorkspaceRefresh() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let due = BudgetWorkspaceStore.dateString(Date.demo(monthsAgo: 0, day: 15))
        let account = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let category = try XCTUnwrap(store.categories.first { $0.id == "electric" })
        try await store.createSchedule(.init(accountID: account.id, categoryID: category.id, name: "Due weekly", amountMinor: -2_500, nextDate: due, recurrenceUnit: "weeks"))
        let recurring = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Due weekly" })
        let activityBefore = store.summary?.categories.first { $0.categoryID == category.id }?.activityMinor
        let transactionCount = store.transactions.count
        let result = try await store.realizeSchedule(id: recurring.id)
        XCTAssertEqual(result.transactionIDs.count, 1)
        XCTAssertEqual(store.transactions.count, transactionCount + 1)
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == category.id }?.activityMinor, (activityBefore ?? 0) - 2_500)
        XCTAssertGreaterThan(try XCTUnwrap(store.scheduledTransactions.first { $0.id == recurring.id }?.nextDate), due)

        try await store.createSchedule(.init(accountID: account.id, categoryID: category.id, name: "Final counted bill", amountMinor: -700, nextDate: due, recurrenceUnit: "months", remainingOccurrences: 1))
        let counted = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Final counted bill" })
        let countedResult = try await store.realizeSchedule(id: counted.id)
        XCTAssertFalse(countedResult.isActive)
        XCTAssertEqual(store.scheduledTransactions.first { $0.id == counted.id }?.remainingOccurrences, 0)

        try await store.createSchedule(.init(accountID: account.id, categoryID: category.id, name: "One time", amountMinor: -500, nextDate: due, recurrenceUnit: "once"))
        let once = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "One time" })
        let onceResult = try await store.realizeSchedule(id: once.id)
        XCTAssertFalse(onceResult.isActive)
        XCTAssertEqual(store.scheduledTransactions.first { $0.id == once.id }?.isActive, false)
    }

    @MainActor
    func testScheduledTransferAndCardRealizationUseExistingDemoAccountingPaths() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let due = BudgetWorkspaceStore.dateString(Date.demo(monthsAgo: 0, day: 15))
        let checking = try XCTUnwrap(store.accounts.first { $0.id == "checking" })
        let savings = try XCTUnwrap(store.accounts.first { $0.id == "savings" })
        let checkingBefore = store.balance(for: checking), savingsBefore = store.balance(for: savings)
        try await store.createSchedule(.init(accountID: checking.id, destinationAccountID: savings.id, name: "Due transfer", amountMinor: 1_000, nextDate: due, recurrenceUnit: "months"))
        let transfer = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Due transfer" })
        let transferResult = try await store.realizeSchedule(id: transfer.id)
        XCTAssertEqual(transferResult.transactionIDs.count, 2)
        XCTAssertEqual(store.balance(for: checking), checkingBefore - 1_000)
        XCTAssertEqual(store.balance(for: savings), savingsBefore + 1_000)

        let card = try XCTUnwrap(store.accounts.first { $0.id == "visa" })
        let groceries = try XCTUnwrap(store.categories.first { $0.id == "groceries" })
        let cardBefore = store.balance(for: card)
        let activityBefore = store.summary?.categories.first { $0.categoryID == groceries.id }?.activityMinor ?? 0
        try await store.createSchedule(.init(accountID: card.id, categoryID: groceries.id, name: "Due card purchase", amountMinor: -1_500, nextDate: due, recurrenceUnit: "months"))
        let purchase = try XCTUnwrap(store.scheduledTransactions.first { $0.name == "Due card purchase" })
        _ = try await store.realizeSchedule(id: purchase.id)
        XCTAssertEqual(store.balance(for: card), cardBefore - 1_500)
        XCTAssertEqual(store.summary?.categories.first { $0.categoryID == groceries.id }?.activityMinor, activityBefore - 1_500)
    }

    @MainActor
    func testSmartFundingUsesMonthlyGuidanceAndRejectsRepeatOrRestrictedCommit() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        source.demo.categories = [
            .init(id: "monthly", group: "Goals", name: "Monthly", icon: "target", assigned: 0, activity: 0, available: 0, target: 10000),
            .init(id: "annual", group: "Goals", name: "Annual", icon: "target", assigned: 0, activity: 0, available: 0, target: 120000, targetDate: "2027-01-31"),
            .init(id: "inactive", group: "Goals", name: "Inactive", icon: "target", assigned: 0, activity: 0, available: 0, target: 999999)
        ]
        source.demo.categories[0].targetType = "monthly_funding"
        source.demo.categories[1].targetType = "recurring_expense"
        source.demo.categories[1].targetRecurrenceMonths = 12
        source.demo.categories[2].targetIsActive = false
        source.demo.createAccount(name: "Actual cash", type: "checking", isOnBudget: true, startingBalance: 105000)
        try await source.assignMoney(.init(categoryID: "monthly", month: "2027-02-01", assignedMinor: 5000, expectedVersion: source.demo.allocationVersion))
        XCTAssertTrue(source.demo.recordCanonicalTransaction(.init(accountID: source.demo.accounts[0].id, categoryID: "monthly", amountMinor: -3000, occurredOn: "2026-09-01", payeeName: "Actual expense", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])))
        let before = source.demo.categories
        let preview = try await source.smartFundingPreview(month: "2027-02-01")
        XCTAssertEqual(source.demo.categories, before)
        XCTAssertEqual(preview.proposals.map(\.categoryID), ["annual", "monthly"])
        XCTAssertEqual(preview.proposals.map(\.amountMinor), [10000, 5000])
        XCTAssertEqual(preview.proposedMinor, 15000)
        try await source.commitSmartFunding(preview)
        XCTAssertEqual(source.demo.readyToAssign, 85000)
        XCTAssertEqual(source.demo.categories[0].activity, -3000)
        let futurePlan = try source.demo.planningSnapshot(month: "2027-02-01")
        XCTAssertEqual(futurePlan.categories["monthly"]?.assignedMinor, 10000)
        XCTAssertEqual(futurePlan.categories["annual"]?.assignedMinor, 10000)
        XCTAssertEqual(source.demo.categories[0].assigned, 0, "Future assignments do not overwrite current-month Assigned")
        let repeated = try await source.smartFundingPreview(month: "2027-02-01")
        XCTAssertTrue(repeated.proposals.isEmpty)
        do { try await source.commitSmartFunding(preview); XCTFail("Stale confirmation must not assign again") }
        catch { }
        XCTAssertEqual(source.demo.readyToAssign, 85000)
        source.demo.persona = .alex
        let restricted = try await source.smartFundingPreview(month: "2027-02-01")
        XCTAssertEqual(restricted.beforeReadyToAssignMinor, 0)
        XCTAssertTrue(restricted.proposals.isEmpty)
        do { try await source.commitSmartFunding(preview); XCTFail("Restricted confirmation must be denied") }
        catch { }
        source.demo.persona = .rey
        XCTAssertEqual(source.demo.readyToAssign, 85000)
    }

    @MainActor
    func testRecurringTargetAdvancesGuidanceWithoutChangingAnchorOrMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        store.planMonth = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2027, month: 2, day: 1)))
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let category = try XCTUnwrap(store.categories.first { store.targets[$0.id] == nil })
        let before = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == category.id })
        let balances = store.accounts.map { store.balance(for: $0) }
        let rta = store.summary?.readyToAssignMinor
        try await store.saveTarget(categoryID: category.id, value: APICategoryTargetUpsert(
            targetType: "recurring_expense", targetAmountMinor: 120000, targetDate: "2027-01-31",
            recurrenceMonths: 12, minimumContributionMinor: 0, priority: 50, isActive: true))
        for _ in 0..<2 {
            await store.refresh()
            let row = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == category.id })
            let gap = max(120000 - max(before.availableMinor - before.assignedMinor, 0), 0)
            XCTAssertEqual(row.recommendedContributionMinor, gap / 12 + (gap % 12 == 0 ? 0 : 1))
            XCTAssertEqual(row.targetDate, "2028-01-31")
            XCTAssertEqual(store.targets[category.id]?.targetDate, "2027-01-31")
            XCTAssertEqual(row.assignedMinor, before.assignedMinor)
            XCTAssertEqual(row.activityMinor, before.activityMinor)
            XCTAssertEqual(row.availableMinor, before.availableMinor)
            XCTAssertEqual(store.accounts.map { store.balance(for: $0) }, balances)
            XCTAssertEqual(store.summary?.readyToAssignMinor, rta)
        }
    }

    @MainActor
    func testTargetMetadataCreateDisableAndDeleteNeverChangesMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let category = try XCTUnwrap(store.categories.first { store.targets[$0.id] == nil })
        let before = (store.summary?.readyToAssignMinor, store.accounts.map { store.balance(for: $0) }, store.transactions.count)
        let initialPlanCost = store.summary?.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) }

        for type in ["monthly_funding", "savings_balance", "target_by_date", "recurring_expense"] {
            let active = type != "savings_balance"
            try await store.saveTarget(categoryID: category.id, value: APICategoryTargetUpsert(targetType: type, targetAmountMinor: 12_345, targetDate: type == "target_by_date" || type == "recurring_expense" ? "2027-09-05" : nil, recurrenceMonths: type == "recurring_expense" ? 12 : nil, minimumContributionMinor: 500, priority: 72, isActive: active))
            let saved = try XCTUnwrap(store.targets[category.id])
            XCTAssertEqual(saved.targetAmountMinor, 12_345)
            XCTAssertEqual(saved.targetType, type)
            XCTAssertEqual(saved.minimumContributionMinor, 500)
            XCTAssertEqual(saved.priority, 72)
            XCTAssertEqual(saved.isActive, active)
            let row = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == category.id })
            XCTAssertEqual(row.targetType, type)
            if active { XCTAssertGreaterThan(row.recommendedContributionMinor ?? 0, 0) }
            else { XCTAssertEqual(row.recommendedContributionMinor, 0) }
        }
        let editedPlanCost = store.summary?.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) }
        XCTAssertNotEqual(editedPlanCost, initialPlanCost, "Monthly Plan Cost must refresh after target edits")
        try await store.deleteTarget(categoryID: category.id)
        XCTAssertNil(store.targets[category.id])
        XCTAssertNil(store.summary?.categories.first { $0.categoryID == category.id }?.targetType)
        XCTAssertEqual(store.summary?.categories.reduce(Int64(0)) { $0 + ($1.recommendedContributionMinor ?? 0) }, initialPlanCost)
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.0)
        XCTAssertEqual(store.accounts.map { store.balance(for: $0) }, before.1)
        XCTAssertEqual(store.transactions.count, before.2)
    }

    @MainActor
    func testTargetDecisionHistoryUsesProductionStoreAndRemainsMoneyNeutral() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let category = try XCTUnwrap(store.categories.first { store.targets[$0.id] == nil })
        let before = (store.summary?.readyToAssignMinor, store.accounts.map { store.balance(for: $0) }, store.transactions.count)
        try await store.saveTarget(categoryID: category.id, value: .init(targetType: "monthly_funding", targetAmountMinor: 12_345, minimumContributionMinor: 500, priority: 60))
        try await store.saveTarget(categoryID: category.id, value: .init(targetType: "target_by_date", targetAmountMinor: 25_000, targetDate: "2027-09-05", minimumContributionMinor: 1_000, priority: 80))
        try await store.setTargetSnoozed(categoryID: category.id, month: "2027-08-01", isSnoozed: true)
        try await store.setTargetSnoozed(categoryID: category.id, month: "2027-08-01", isSnoozed: false)
        try await store.deleteTarget(categoryID: category.id)

        let history = try await store.targetHistory(categoryID: category.id)
        XCTAssertEqual(history.map(\.action), ["deleted", "resumed", "snoozed", "updated", "created"])
        XCTAssertEqual(history.last?.afterSnapshot?.targetAmountMinor, 12_345)
        XCTAssertEqual(history.first?.beforeSnapshot?.targetAmountMinor, 25_000)
        XCTAssertEqual(history.first?.actorDisplayName, "Rey")
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.0)
        XCTAssertEqual(store.accounts.map { store.balance(for: $0) }, before.1)
        XCTAssertEqual(store.transactions.count, before.2)
    }

    @MainActor
    func testCategoryFavoritePersistsThroughRefreshWithoutChangingMoney() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let category = try XCTUnwrap(store.categories.first { !$0.isFavorite })
        let before = (
            store.summary,
            store.accounts.map { store.balance(for: $0) },
            store.transactions.count
        )

        try await store.setCategoryFavorite(id: category.id, isFavorite: true)
        XCTAssertTrue(try XCTUnwrap(store.categories.first { $0.id == category.id }).isFavorite)
        await store.refresh()
        XCTAssertTrue(try XCTUnwrap(store.categories.first { $0.id == category.id }).isFavorite)
        XCTAssertEqual(store.summary, before.0)
        XCTAssertEqual(store.accounts.map { store.balance(for: $0) }, before.1)
        XCTAssertEqual(store.transactions.count, before.2)

        try await store.setCategoryFavorite(id: category.id, isFavorite: false)
        XCTAssertFalse(try XCTUnwrap(store.categories.first { $0.id == category.id }).isFavorite)
    }

    func testSpendingBreakdownBuildsRankedCategoryAndGroupSlicesFromReportContract() throws {
        let report = try JSONDecoder().decode(APISpendingReport.self, from: Data(#"{"start_date":"2026-08-01","end_date":"2026-08-31","currency_code":"USD","total_spending_minor":10000,"categories":[{"category_id":"food","category_name":"Food","category_group":"Everyday","spending_minor":7001,"transaction_ids":["purchase","refund","split"]},{"category_id":"fuel","category_name":"Fuel","category_group":"Everyday","spending_minor":2999,"transaction_ids":["split"]}]}"#.utf8))

        let categories = SpendingBreakdownSlice.make(from: report, mode: .category)
        XCTAssertEqual(categories.map(\.id), ["food", "fuel"])
        XCTAssertEqual(categories.map(\.spendingMinor), [7_001, 2_999])
        XCTAssertEqual(categories[0].percentage(of: report.totalSpendingMinor), 0.7001, accuracy: 0.000_001)

        let groups = SpendingBreakdownSlice.make(from: report, mode: .group)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].spendingMinor, report.totalSpendingMinor)
        XCTAssertEqual(Set(groups[0].transactionIDs), ["purchase", "refund", "split"])
    }

    func testProductionSpendingBreakdownRetainsSectorMarkPath() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let contents = try String(contentsOf: source)
        XCTAssertTrue(contents.contains("SectorMark(angle:"))
        XCTAssertTrue(contents.contains("spending-breakdown-sector-chart"))
        XCTAssertTrue(contents.contains("income-spending-trends-chart"))
        XCTAssertTrue(contents.contains("net-worth-history-chart"))
        XCTAssertTrue(contents.contains("debt-history-chart"))
        XCTAssertTrue(contents.contains("spending-trends-chart"))
        XCTAssertTrue(contents.contains("plan-performance-history-chart"))
        XCTAssertTrue(contents.contains("financial-resilience-insights"))
        XCTAssertTrue(contents.contains("Average age of money"))
        XCTAssertTrue(contents.contains("Current daily burn rate"))
        XCTAssertTrue(contents.contains("Cash runway"))
        XCTAssertTrue(contents.contains("Essential expense coverage"))
        XCTAssertTrue(contents.contains("Emergency fund coverage"))
        XCTAssertTrue(contents.contains("Upcoming obligations covered"))
        XCTAssertTrue(contents.contains("Scheduled income is deliberately excluded"))
        XCTAssertTrue(contents.contains("PlanGroupHeader"))
        XCTAssertTrue(contents.contains("group-add-transaction"))
        XCTAssertTrue(contents.contains("Task.sleep(for: .seconds(12))"))
        XCTAssertTrue(contents.contains("prepare-report-csv"))
        XCTAssertTrue(contents.contains("share-report-csv"))
        XCTAssertTrue(contents.contains(#"spending-trend-\(report.dimension)-\(series.dimensionID)"#))
        XCTAssertTrue(contents.contains("debt-account-"))
        XCTAssertTrue(contents.contains("plan-performance-category-"))
        XCTAssertTrue(contents.contains("category-target-history"))
        XCTAssertTrue(contents.contains("TargetHistoryView"))
        XCTAssertTrue(contents.contains(".chartXSelection(value: $selectedDate)"))
        XCTAssertTrue(contents.contains("income-spending-selected-period"))
        XCTAssertTrue(contents.contains("net-worth-selected-point"))
    }

    func testProductionReconciliationRetainsStatementImportReviewPath() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("import-bank-statement"))
        XCTAssertTrue(source.contains("StatementImportFlowView"))
        XCTAssertTrue(source.contains("Possible duplicate — skipped by default"))
        XCTAssertTrue(source.contains("APIStatementImportApprovalItem"))
        XCTAssertTrue(source.contains("Separate debit and credit"))
        XCTAssertTrue(source.contains("Text(\"Semicolon\").tag(\";\")"))
        XCTAssertTrue(source.contains("Text(\"Tab\").tag(\"\\t\")"))
        XCTAssertTrue(source.contains("[\"csv\", \"tsv\", \"txt\"]"))
        XCTAssertTrue(source.contains("Year-Month-Day"))
        XCTAssertTrue(source.contains("debitColumn: splitMoney ? debitColumn : nil"))
        XCTAssertTrue(source.contains("creditColumn: splitMoney ? creditColumn : nil"))
        XCTAssertTrue(source.contains("delimiter: delimiter"))
        XCTAssertTrue(source.contains("workspace.format(row.amountMinor)"), "Statement review must use the production privacy-aware formatter")
        XCTAssertFalse(source.contains("CurrencyText.display(row.amountMinor"), "Import review must not bypass Hide Amounts")
    }

    @MainActor
    func testProductionImportAmountFormatterHonorsPrivacyWithoutChangingRows() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let previous = store.hideAmounts
        defer { store.hideAmounts = previous }
        let amounts = store.transactions.map(\.amountMinor)
        store.hideAmounts = false
        let exact: Int64 = 9_007_199_254_740_993
        XCTAssertEqual(store.format(exact), CurrencyText.display(exact, currencyCode: store.budget.currencyCode))
        store.hideAmounts = true
        for amount in [exact, -exact, Int64(0)] { XCTAssertEqual(store.format(amount), "••••") }
        XCTAssertEqual(store.transactions.map(\.amountMinor), amounts)
    }

    @MainActor
    func testDemoIncomeSpendingPeriodsReconcileToCanonicalReportWithoutTransfers() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        XCTAssertNil(store.incomeReport, "Core activation must not publish detailed reports")
        await store.loadReports(Set(WorkspaceReportKind.allCases))
        let report = try XCTUnwrap(store.incomeReport)
        XCTAssertFalse(report.periods.isEmpty)
        XCTAssertEqual(report.periods.reduce(Int64(0)) { $0 + $1.incomeMinor }, report.incomeMinor)
        XCTAssertEqual(report.periods.reduce(Int64(0)) { $0 + $1.spendingMinor }, report.spendingMinor)
        XCTAssertEqual(report.periods.reduce(Int64(0)) { $0 + $1.differenceMinor }, report.differenceMinor)
        let transferIDs = Set(store.transactions.filter { $0.transferID != nil }.map(\.id))
        XCTAssertTrue(Set(report.incomeTransactionIDs).isDisjoint(with: transferIDs))
        XCTAssertTrue(Set(report.spendingTransactionIDs).isDisjoint(with: transferIDs))
        let netWorth = try XCTUnwrap(store.netWorthReport)
        XCTAssertEqual(netWorth.accounts.reduce(Int64(0)) { $0 + $1.balanceMinor }, netWorth.netWorthMinor)
        XCTAssertEqual(netWorth.assetsMinor + netWorth.liabilitiesMinor, netWorth.netWorthMinor)
        let debt = try XCTUnwrap(store.debtReport)
        XCTAssertEqual(debt.accounts.reduce(Int64(0)) { $0 + $1.debtMinor }, debt.debtMinor)
        XCTAssertEqual(debt.openingDebtMinor - debt.debtMinor, debt.principalReductionMinor)
        XCTAssertTrue(debt.accounts.allSatisfy { account in
            store.accounts.contains { $0.id == account.accountID && ["credit", "loan", "mortgage"].contains($0.accountType) }
        })
        let plan = try XCTUnwrap(store.planPerformanceReport)
        for point in plan.points {
            XCTAssertEqual(point.availableMinor, point.carriedAvailableMinor + point.assignedMinor + point.activityMinor)
        }
        let ending = try XCTUnwrap(plan.points.last)
        let cutoff = try DemoStore().planningSnapshot(month: String(ending.periodEnd.prefix(7)) + "-01", through: ending.periodEnd)
        XCTAssertEqual(ending.readyToAssignMinor, cutoff.readyToAssignMinor, "Report cutoff is not the selected Plan month's end")
        let resilience = try XCTUnwrap(store.resilienceReport)
        XCTAssertEqual(resilience.expectedMarginMinor, resilience.scheduledIncomeMinor - resilience.scheduledOutflowsMinor)
        XCTAssertNotNil(resilience.essentialExpenseCoverageDays)
        XCTAssertNotNil(resilience.emergencyFundCoverageDays)
        XCTAssertNil(resilience.unavailableMetrics["essential_expense_coverage_days"])
        XCTAssertNil(resilience.unavailableMetrics["emergency_fund_coverage_days"])
        XCTAssertEqual(store.insightsSummary?.netCashFlowMinor, report.differenceMinor)
        XCTAssertEqual(store.insightsSummary?.netWorthMinor, netWorth.netWorthMinor)
        XCTAssertEqual(store.insightsSummary?.debtMinor, debt.debtMinor)
        XCTAssertEqual(store.insightsSummary?.expectedMarginMinor, resilience.expectedMarginMinor)
    }

    @MainActor
    func testDemoReportExportUsesCanonicalOpenCSVContract() async throws {
        let source = DemoWorkspaceDataSource(fresh: false)
        let calendar = Calendar(identifier: .gregorian)
        let end = Date()
        let start = try XCTUnwrap(calendar.date(byAdding: .year, value: -2, to: end))
        let query = WorkspaceReportQuery(start: start, end: end, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)

        let data = try await source.exportReports(report: query)
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(csv.hasPrefix("report,period_start,period_end,dimension,name,amount_minor,currency_code\n"))
        XCTAssertTrue(csv.contains("spending,"))
        XCTAssertTrue(csv.contains("cash_flow,"))
        XCTAssertTrue(csv.contains("net_worth,"))
        XCTAssertTrue(csv.contains("debt,"))
        XCTAssertTrue(csv.contains("plan,"))
    }

    @MainActor
    func testInsightsMetadataFiltersUseSameDemoReportPathAsLive() async throws {
        let source = DemoWorkspaceDataSource(fresh: false)
        let rangeStart = Calendar.current.date(byAdding: .year, value: -2, to: Date.demo(monthsAgo: 0, day: 15))!
        let rangeEnd = Calendar.current.date(byAdding: .year, value: 2, to: Date.demo(monthsAgo: 0, day: 15))!
        let baselineQuery = WorkspaceReportQuery(start: rangeStart, end: rangeEnd, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        let baseline = try await source.snapshot(planMonth: .demo(monthsAgo: 0, day: 15), report: baselineQuery)
        let account = try XCTUnwrap(baseline.accounts.first { $0.isOnBudget && $0.accountType != "credit" })
        let category = try XCTUnwrap(baseline.categories.first { !$0.isArchived })
        try await source.recordTransaction(.init(accountID: account.id, categoryID: category.id, amountMinor: -4321, occurredOn: BudgetWorkspaceStore.dateString(.demo(monthsAgo: 0, day: 15)), payeeName: "Metadata filter fixture", memo: "", isCleared: false, splits: [], flag: "orange", tags: ["essential"], attachmentMetadata: []))

        let query = WorkspaceReportQuery(start: rangeStart, end: rangeEnd, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "uncleared", flag: "orange", tag: "essential", spendingTrendDimension: "category", includeTracking: true)
        let filtered = try await source.snapshot(planMonth: .demo(monthsAgo: 0, day: 15), report: query)
        let contributing = Set(try XCTUnwrap(filtered.spending).categories.flatMap(\.transactionIDs))
        let candidate = try XCTUnwrap(filtered.transactions.first { $0.payeeName == "Metadata filter fixture" })
        XCTAssertTrue(contributing.contains(candidate.id))
        for id in contributing {
            let transaction = try XCTUnwrap(filtered.transactions.first { $0.id == id })
            XCTAssertTrue(transaction.tags?.contains("essential") == true)
            XCTAssertEqual(transaction.flag, "orange")
            XCTAssertFalse(transaction.isCleared)
        }
    }

    @MainActor
    func testDemoRecordedInterestUsesExplicitClassificationAndServerShapedFilter() async throws {
        let source = DemoWorkspaceDataSource(fresh: false)
        let start = Calendar.current.date(byAdding: .year, value: -2, to: Date())!
        let end = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
        let all = try await source.snapshot(planMonth: Date(), report: WorkspaceReportQuery(start: start, end: end, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true))
        let debt = try XCTUnwrap(all.debt)
        XCTAssertEqual(debt.recordedInterestRangeMinor, 3_200)
        XCTAssertNotNil(debt.interestTrackingStartedOn)
        XCTAssertEqual(all.transactions.first(where: { $0.payeeName == "Auto Loan Payment" })?.financialClassification, nil, "memo text must never manufacture interest")

        let filtered = try await source.browseTransactions(query: APITransactionQuery(transactionType: "interest_charge"))
        XCTAssertEqual(filtered.items.map(\.payeeName), ["Card issuer"])
        XCTAssertEqual(filtered.items.first?.financialClassification, "interest_charge")
    }

    @MainActor
    func testDemoSpendingTrendsUseProductionContractForEveryDimension() async throws {
        let source = DemoWorkspaceDataSource(fresh: false)
        let rangeStart = Calendar.current.date(byAdding: .year, value: -2, to: Date())!
        let rangeEnd = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
        func snapshot(_ dimension: String) async throws -> WorkspaceSnapshot {
            try await source.snapshot(planMonth: Date(), report: WorkspaceReportQuery(
                start: rangeStart, end: rangeEnd, accountID: "", categoryID: "",
                categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all",
                flag: "", tag: "", spendingTrendDimension: dimension, includeTracking: true
            ))
        }
        for dimension in ["category", "group", "payee"] {
            let loaded = try await snapshot(dimension)
            let value = try XCTUnwrap(loaded.spendingTrends)
            XCTAssertEqual(value.dimension, dimension)
            XCTAssertEqual(value.series.reduce(Int64(0)) { $0 + $1.spendingMinor }, value.totalSpendingMinor)
            XCTAssertTrue(value.series.allSatisfy { $0.points.count > 0 })
        }
    }

    @MainActor
    func testDemoSpendingFiltersClipMixedSplitPurchaseAndRefundPortions() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        XCTAssertTrue(source.demo.createAccount(name: "Checking", type: "checking", isOnBudget: true, startingBalance: 50000))
        XCTAssertTrue(source.demo.createCategory(name: "Groceries", group: "Food"))
        XCTAssertTrue(source.demo.createCategory(name: "Dining", group: "Dining Group"))
        let account = try XCTUnwrap(source.demo.accounts.first?.id)
        let food = try XCTUnwrap(source.demo.categories.first(where: { $0.name == "Groceries" })?.id)
        let dining = try XCTUnwrap(source.demo.categories.first(where: { $0.name == "Dining" })?.id)
        for (total, foodAmount, diningAmount): (Int64, Int64, Int64) in [(-12000, -8000, -4000), (3000, 2000, 1000)] {
            try await source.recordTransaction(.init(accountID: account, categoryID: nil, amountMinor: total,
                occurredOn: "2026-09-04", payeeName: "Mixed market", memo: "", isCleared: true,
                splits: [.init(categoryID: food, amountMinor: foodAmount, memo: ""), .init(categoryID: dining, amountMinor: diningAmount, memo: "")],
                flag: nil, tags: [], attachmentMetadata: []))
        }
        for (category, group, expected): (String, String, Int64) in [(food, "", 6000), ("", "Dining Group", 3000), (food, "Dining Group", 0)] {
            for dimension in ["category", "group", "payee"] {
                let query = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"),
                    accountID: "", categoryID: category, categoryGroup: group, payee: "", memberID: "", transactionType: "",
                    cleared: "all", flag: "", tag: "", spendingTrendDimension: dimension, includeTracking: true)
                let snapshot = try await source.snapshot(planMonth: query.start, report: query)
                XCTAssertEqual(snapshot.spending?.totalSpendingMinor, expected)
                XCTAssertEqual(snapshot.spendingTrends?.totalSpendingMinor, expected)
            }
        }
    }

    @MainActor
    func testDemoAllocationHistoryMatchesLiveContractShape() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        // The same production category-detail view reads store.allocationOperations for demo and live.
        let fixtureOperations = store.allocationOperations
        XCTAssertFalse(fixtureOperations.isEmpty, "the fixture now executes real dated assignment commands")
        XCTAssertTrue(fixtureOperations.allSatisfy { $0.id.hasPrefix("fixture-") && $0.kind == "assignment" })
        let groceries = try XCTUnwrap(store.categories.first { $0.id == "groceries" })
        try await store.updateAssignment(categoryID: groceries.id, month: "2026-09-01", assignedMinor: 73_000, expectedVersion: try XCTUnwrap(store.summary).allocationVersion)
        try await store.moveAllocation(.init(sourceCategoryID: groceries.id, destinationCategoryID: "dining", amountMinor: 123, occurredOn: "2026-09-03", note: "Actual move", expectedVersion: try XCTUnwrap(store.summary).allocationVersion))
        XCTAssertEqual(store.allocationOperations.count, fixtureOperations.count + 2)
        let commands = Array(store.allocationOperations.suffix(2))
        XCTAssertEqual(commands[0].postings.last?.amountMinor, 1_000)
        XCTAssertEqual(commands[1].postings.last?.amountMinor, 123)
        XCTAssertEqual(commands.map(\.occurredOn), ["2026-09-01", "2026-09-03"])
        let recordedIDs = store.allocationOperations.map(\.id)
        await store.refresh()
        XCTAssertEqual(store.allocationOperations.map(\.id), recordedIDs)
        // Every operation balances to zero, exactly like the server allocation ledger.
        for operation in store.allocationOperations {
            XCTAssertEqual(operation.postings.reduce(Int64(0)) { $0 + $1.amountMinor }, 0)
        }
        // History includes an assignment and a category-to-category move (money in / money out).
        XCTAssertTrue(store.allocationOperations.contains { $0.kind == "assignment" })
        XCTAssertTrue(store.allocationOperations.contains { $0.kind == "category_transfer" })
        // At least one posting attributes to a real demo category, so category detail can filter it.
        let categoryIDs = Set(store.categories.map(\.id))
        XCTAssertTrue(store.allocationOperations.contains { operation in
            operation.postings.contains { $0.categoryID.map(categoryIDs.contains) == true }
        })
    }

    @MainActor
    func testDemoAllocationHistoryPreservesDatesActorsAndWholeOperationPrivacy() async throws {
        let source = DemoWorkspaceDataSource()
        let report = WorkspaceReportQuery(start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"), accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        func history(_ month: String) async throws -> [APIAllocationOperation] {
            try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate(month), report: report).allocationOperations
        }
        let initial = try await history("2026-09-01")
        XCTAssertTrue(initial.allSatisfy { $0.id.hasPrefix("fixture-") })
        try await source.assignMoney(.init(categoryID: "groceries", month: "2026-09-01", assignedMinor: 73_000, expectedVersion: source.demo.allocationVersion))
        XCTAssertTrue(source.demo.move(amount: 100, from: "buffer", to: "alexallow", occurredOn: "2026-09-02", note: "Private source"))
        source.demo.persona = .alex
        XCTAssertTrue(source.demo.move(amount: 123, from: "alexallow", to: "alexsave", occurredOn: "2026-09-03", note: "My move"))
        let restricted = try await history("2026-09-01")
        XCTAssertEqual(restricted.count, 1, "Hide the entire operation when its source is private")
        XCTAssertEqual(restricted.first?.note, "My move")
        XCTAssertEqual(restricted.first?.actorUserID, "alex")
        source.demo.persona = .rey
        let september = try await history("2026-09-01")
        let october = try await history("2026-10-01")
        XCTAssertEqual(september.count, initial.count + 3)
        XCTAssertEqual(october.map(\.id), september.map(\.id))
        XCTAssertEqual(october.suffix(3).map(\.occurredOn), ["2026-09-01", "2026-09-02", "2026-09-03"])
        XCTAssertEqual(october.suffix(3).map(\.actorUserID), ["rey", "rey", "alex"])
        source.demo.reset()
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), initial.map(\.id))
    }

    @MainActor
    func testAccountRegisterScopesOrdersAndDescribesProductionTransactions() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let account = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let destination = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        try await store.createTransfer(TransferMoneyOperation(sourceAccountID: account.id, destinationAccountID: destination.id, amountMinor: 500, occurredOn: "2026-09-05", memo: "Register transfer", isCleared: true))
        let rows = store.transactions(for: account)

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.accountID == account.id })
        XCTAssertEqual(rows.map(\.occurredOn), rows.map(\.occurredOn).sorted(by: >))
        XCTAssertEqual(store.transactions(for: account).map(\.id), rows.map(\.id), "same-date ordering must remain stable")
        XCTAssertTrue(rows.contains { $0.transferID != nil })
        XCTAssertTrue(store.transactions(for: destination).contains { $0.transferID != nil })
        XCTAssertTrue(rows.contains { !$0.splits.isEmpty })
        XCTAssertEqual(store.balance(for: account), store.clearedBalance(for: account) + store.unclearedBalance(for: account))

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift"))
        XCTAssertTrue(source.contains("compactDate(transaction.occurredOn)"), "posted register rows must show their transaction date")
        XCTAssertTrue(source.contains("ScheduledActivityPresentation"), "all upcoming and forecast schedule rows must share an explicit Scheduled/date treatment")
        XCTAssertFalse(source.contains("if $0.occurredOn == $1.occurredOn { return $0.id"), "same-date ordering must not use UUID order")
    }

    @MainActor
    func testQuickClearingUsesCanonicalMutationWithoutChangingFinancialStateAndLocksAfterReconcile() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let transaction = try XCTUnwrap(store.transactions.first(where: { $0.id == "t1" }))
        let account = try XCTUnwrap(store.accounts.first(where: { $0.id == transaction.accountID }))
        let workingBefore = store.balance(for: account)
        let clearedBefore = store.clearedBalance(for: account)
        let readyBefore = store.summary?.readyToAssignMinor
        let planBefore = store.summary?.categories.map { "\($0.categoryID)|\($0.activityMinor)|\($0.availableMinor)" }

        XCTAssertTrue(store.canQuickSetCleared(transaction))
        try await store.setTransactionCleared(id: transaction.id, cleared: true)
        XCTAssertTrue(try XCTUnwrap(store.transactions.first(where: { $0.id == transaction.id })).isCleared)
        XCTAssertEqual(store.clearedBalance(for: account), clearedBefore + transaction.amountMinor)
        try await store.setTransactionCleared(id: transaction.id, cleared: true)
        XCTAssertEqual(store.clearedBalance(for: account), clearedBefore + transaction.amountMinor, "Repeating the state must not apply the amount twice")
        XCTAssertEqual(store.balance(for: account), workingBefore)
        XCTAssertEqual(store.summary?.readyToAssignMinor, readyBefore)
        XCTAssertEqual(store.summary?.categories.map { "\($0.categoryID)|\($0.activityMinor)|\($0.availableMinor)" }, planBefore)

        try await store.setTransactionCleared(id: transaction.id, cleared: false)
        XCTAssertFalse(try XCTUnwrap(store.transactions.first(where: { $0.id == transaction.id })).isCleared)
        XCTAssertEqual(store.clearedBalance(for: account), clearedBefore)
        try await store.setTransactionCleared(id: transaction.id, cleared: true)
        try await store.reconcile(accountID: account.id, statementBalance: store.clearedBalance(for: account), throughDate: "2099-12-31", createAdjustment: false, reason: "")
        let reconciled = try XCTUnwrap(store.transactions.first(where: { $0.id == transaction.id }))
        XCTAssertTrue(reconciled.isReconciled)
        XCTAssertFalse(store.canQuickSetCleared(reconciled))
        do {
            try await store.setTransactionCleared(id: transaction.id, cleared: false)
            XCTFail("reconciled transactions must reject quick clearing")
        } catch {}
        XCTAssertTrue(try XCTUnwrap(store.transactions.first(where: { $0.id == transaction.id })).isCleared)
    }

    @MainActor
    func testCanonicalAccountTransferConservesPlanAndCreatesLinkedRegisterLegs() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let checking = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let savings = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        let checkingBefore = store.balance(for: checking)
        let savingsBefore = store.balance(for: savings)
        let unassignedBefore = store.summary?.readyToAssignMinor
        let assignedBefore = store.summary?.totalAssignedMinor
        let categoriesBefore = store.summary?.categories

        try await store.createTransfer(.init(sourceAccountID: checking.id, destinationAccountID: savings.id, amountMinor: 20_000, occurredOn: "2026-09-09", memo: "Acceptance transfer", isCleared: true))

        XCTAssertEqual(store.balance(for: checking), checkingBefore - 20_000)
        XCTAssertEqual(store.balance(for: savings), savingsBefore + 20_000)
        XCTAssertEqual(store.balance(for: checking) + store.balance(for: savings), checkingBefore + savingsBefore)
        XCTAssertEqual(store.summary?.readyToAssignMinor, unassignedBefore)
        XCTAssertEqual(store.summary?.totalAssignedMinor, assignedBefore)
        XCTAssertEqual(store.summary?.categories, categoriesBefore)
        let sourceLeg = try XCTUnwrap(store.transactions(for: checking).first(where: { $0.memo == "Acceptance transfer" }))
        let destinationLeg = try XCTUnwrap(store.transactions(for: savings).first(where: { $0.memo == "Acceptance transfer" }))
        XCTAssertEqual(sourceLeg.amountMinor, -20_000)
        XCTAssertEqual(destinationLeg.amountMinor, 20_000)
        XCTAssertNotNil(sourceLeg.transferID)
        XCTAssertEqual(sourceLeg.transferID, destinationLeg.transferID)
        XCTAssertNotEqual(sourceLeg.id, destinationLeg.id)
        XCTAssertLessThanOrEqual(sourceLeg.id.count, 36)
        XCTAssertLessThanOrEqual(destinationLeg.id.count, 36)
    }

    @MainActor
    func testCanonicalTransferEditAndDeletePreserveLinkageAndPlan() async throws {
        let store = BudgetWorkspaceStore.demo(); await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let checking = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let savings = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        try await store.createAccount(.init(name: "Transfer destination", kind: "savings", isOnBudget: true, openingBalanceMinor: 0))
        let destination = try XCTUnwrap(store.accounts.first(where: { $0.name == "Transfer destination" }))
        let checkingBefore = store.balance(for: checking), savingsBefore = store.balance(for: savings)
        let planBefore = store.summary
        try await store.createTransfer(.init(sourceAccountID: checking.id, destinationAccountID: savings.id, amountMinor: 20_000, occurredOn: "2026-09-09", memo: "original", isCleared: true))
        let transferID = try XCTUnwrap(store.transactions.first(where: { $0.memo == "original" })?.transferID)
        let legIDs = Set(store.transactions.filter { $0.transferID == transferID }.map(\.id))
        try await store.updateTransfer(id: transferID, operation: .init(sourceAccountID: checking.id, destinationAccountID: destination.id, amountMinor: 2_000, occurredOn: "2026-09-08", memo: "corrected", isCleared: false))
        let updated = store.transactions.filter { $0.transferID == transferID }
        XCTAssertEqual(updated.count, 2); XCTAssertEqual(Set(updated.map(\.id)), legIDs)
        XCTAssertEqual(Set(updated.map(\.amountMinor)), [-2_000, 2_000]); XCTAssertTrue(updated.allSatisfy { $0.memo == "corrected" && !$0.isCleared })
        XCTAssertEqual(updated.first(where: { $0.amountMinor > 0 })?.accountID, destination.id)
        XCTAssertEqual(store.summary?.readyToAssignMinor, planBefore?.readyToAssignMinor)
        XCTAssertEqual(store.summary?.totalAssignedMinor, planBefore?.totalAssignedMinor)
        XCTAssertEqual(store.summary?.categories, planBefore?.categories)
        let reviewedLegs = store.transactions.filter { $0.transferID == transferID }
        let deletionRevisions = Dictionary(uniqueKeysWithValues: reviewedLegs.compactMap { leg in
            leg.revision.map { (leg.id, $0) }
        })
        try await store.deleteTransfer(id: transferID, expectedRevisions: deletionRevisions)
        XCTAssertFalse(store.transactions.contains { $0.transferID == transferID })
        XCTAssertEqual(store.balance(for: checking), checkingBefore); XCTAssertEqual(store.balance(for: savings), savingsBefore)
        XCTAssertEqual(store.balance(for: destination), 0)
        XCTAssertEqual(store.summary?.categories, planBefore?.categories)
    }

    @MainActor
    func testAccountRegisterReflectsCreateEditAndDeleteRefreshes() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let checking = try XCTUnwrap(store.accounts.first(where: { $0.id == "checking" }))
        let savings = try XCTUnwrap(store.accounts.first(where: { $0.id == "savings" }))
        let category = try XCTUnwrap(store.categories.first(where: { !$0.isArchived }))
        let originalCount = store.transactions(for: checking).count
        let value = RecordTransactionOperation(accountID: checking.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-05", payeeName: "Register regression", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: [])

        try await store.createTransaction(value)
        let created = try XCTUnwrap(store.transactions.first(where: { $0.payeeName == "Register regression" }))
        XCTAssertEqual(store.transactions(for: checking).count, originalCount + 1)

        let moved = RecordTransactionOperation(accountID: savings.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-05", payeeName: "Register regression", memo: "moved", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])
        try await store.updateTransaction(id: created.id, operation: moved)
        XCTAssertFalse(store.transactions(for: checking).contains { $0.id == created.id })
        XCTAssertTrue(store.transactions(for: savings).contains { $0.id == created.id && $0.isCleared })

        try await store.deleteTransaction(id: created.id)
        XCTAssertFalse(store.transactions.contains { $0.id == created.id })
    }

    @MainActor
    func testPlanningGuidanceRecomputesAfterCanonicalTransactionChange() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        await store.loadPlanningGuidance()
        let before = try XCTUnwrap(store.planningSpendingReport?.totalSpendingMinor)
        let account = try XCTUnwrap(store.accounts.first(where: { $0.isOnBudget && !$0.isClosed }))
        let category = try XCTUnwrap(store.categories.first(where: { !$0.isArchived && $0.systemType == nil }))
        let operation = RecordTransactionOperation(
            accountID: account.id,
            categoryID: category.id,
            amountMinor: -1_234,
            occurredOn: "2026-09-05",
            payeeName: "Guidance refresh",
            memo: "",
            isCleared: false,
            splits: [],
            flag: nil,
            tags: [],
            attachmentMetadata: []
        )

        try await store.createTransaction(operation)
        await store.loadPlanningGuidance()

        XCTAssertEqual(store.planningSpendingReport?.totalSpendingMinor, before + 1_234)
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains(".task(id: \"\\(store.reportRevision)|\\(store.planMonth.timeIntervalSinceReferenceDate)\")"))
        XCTAssertTrue(source.contains("if !isTransientConnectivityFailure(error) { planningSpendingReport = nil }"))
    }

    @MainActor
    func testLocalDeviceWorkspacePersistsCanonicalMoneyAndMetadataAcrossReconstruction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secrets = InMemorySecretDataStore()
        let keyManager = LocalDeviceKeyManager(store: secrets)

        let first = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: directory, keyManager: keyManager)
        await first.refresh()
        XCTAssertTrue(first.accounts.isEmpty)
        XCTAssertEqual(first.groups.count, 4)
        XCTAssertEqual(first.categories.count, 11)
        XCTAssertEqual(first.householdMembers.map(\.displayName), ["You"])
        try await first.createAccount(.init(name: "Phone Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 123_456))
        try await first.createAccount(.init(name: "Phone Savings", kind: "savings", isOnBudget: true, openingBalanceMinor: 25_000))
        try await first.createAccount(.init(name: "Phone Card", kind: "credit", isOnBudget: true, openingBalanceMinor: -50_00))
        try await first.createGroup(name: "Everyday")
        let group = try XCTUnwrap(first.groups.first(where: { $0.name == "Everyday" }))
        try await first.createCategory(groupID: group.id, newGroupName: "", name: "Groceries", delegatedUserID: nil)
        let account = try XCTUnwrap(first.accounts.first(where: { $0.name == "Phone Checking" }))
        let savings = try XCTUnwrap(first.accounts.first(where: { $0.name == "Phone Savings" }))
        let card = try XCTUnwrap(first.accounts.first(where: { $0.name == "Phone Card" }))
        let category = try XCTUnwrap(first.categories.first(where: { $0.name == "Groceries" }))
        try await first.setCategoryFavorite(id: category.id, isFavorite: true)
        try await first.saveTarget(categoryID: category.id, value: .init(targetType: "recurring_expense", targetAmountMinor: 20_000, targetDate: "2027-01-15", recurrenceMonths: 3, minimumContributionMinor: 2_500, priority: 75, isActive: true))
        try await first.createSchedule(.init(accountID: account.id, categoryID: category.id, name: "Local utility", amountMinor: -7_500, nextDate: "2027-01-15", recurrenceUnit: "months", memo: "offline schedule"))
        _ = try await first.updateAccountDebtTerms(accountID: card.id, value: .init(termsType: "credit_card", annualRateBasisPoints: 2199, rateType: "variable", paymentFrequency: "monthly", minimumPaymentRule: "fixed", minimumPaymentMinor: 2_500, dueDay: 18))
        try await first.createTransaction(.init(accountID: account.id, categoryID: category.id, amountMinor: -1_234, occurredOn: "2026-09-30", payeeName: "Local Market", memo: "offline purchase", isCleared: true, splits: [], flag: "Orange", tags: ["offline"], attachmentMetadata: []))
        try await first.createTransfer(.init(sourceAccountID: account.id, destinationAccountID: savings.id, amountMinor: 10_000, occurredOn: "2026-09-30", memo: "offline transfer", isCleared: true))
        try await first.createTransaction(.init(accountID: account.id, categoryID: category.id, amountMinor: -99, occurredOn: "2026-09-30", payeeName: "Delete before relaunch", memo: "", isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let deletedID = try XCTUnwrap(first.transactions.first(where: { $0.payeeName == "Delete before relaunch" })?.id)
        try await first.deleteTransaction(id: deletedID)
        let statementBalance = try first.reconciliationClearedBalance(accountID: account.id, throughDate: "2026-09-30")
        try await first.reconcile(accountID: account.id, statementBalance: statementBalance, throughDate: "2026-09-30", createAdjustment: false, reason: "Local verification")
        let createdTransaction = try XCTUnwrap(first.transactions.first(where: { $0.payeeName == "Local Market" }))
        let receipt = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try await first.uploadTransactionAttachment(id: createdTransaction.id, filename: "receipt.png", contentType: "image/png", data: receipt)
        let expectedBalance = first.accountBalances[account.id]

        let reopened = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: directory, keyManager: keyManager)
        await reopened.refresh()
        XCTAssertEqual(Set(reopened.accounts.map(\.name)), Set(["Phone Checking", "Phone Savings", "Phone Card"]))
        XCTAssertEqual(reopened.categories.count, 12)
        XCTAssertTrue(reopened.categories.contains { $0.name == "Housing" })
        XCTAssertTrue(try XCTUnwrap(reopened.categories.first { $0.id == category.id }).isFavorite)
        let target = try XCTUnwrap(reopened.targets[category.id])
        XCTAssertEqual(target.targetType, "recurring_expense")
        XCTAssertEqual(target.targetAmountMinor, 20_000)
        XCTAssertEqual(target.targetDate, "2027-01-15")
        XCTAssertEqual(target.recurrenceMonths, 3)
        XCTAssertEqual(target.minimumContributionMinor, 2_500)
        XCTAssertEqual(target.priority, 75)
        XCTAssertTrue(target.isActive)
        let schedule = try XCTUnwrap(reopened.scheduledTransactions.first)
        XCTAssertEqual(schedule.name, "Local utility")
        XCTAssertEqual(schedule.amountMinor, -7_500)
        XCTAssertEqual(schedule.memo, "offline schedule")
        let debtTerms = try await reopened.accountDebtTerms(accountID: card.id)
        XCTAssertEqual(debtTerms?.annualRateBasisPoints, 2199)
        XCTAssertEqual(debtTerms?.minimumPaymentMinor, 2_500)
        let transaction = try XCTUnwrap(reopened.transactions.first(where: { $0.payeeName == "Local Market" }))
        XCTAssertEqual(transaction.amountMinor, -1_234)
        XCTAssertEqual(transaction.memo, "offline purchase")
        XCTAssertEqual(transaction.flag, "Orange")
        XCTAssertEqual(transaction.tags, ["offline"])
        XCTAssertTrue(transaction.isCleared)
        XCTAssertTrue(transaction.isReconciled)
        let transferRows = reopened.transactions.filter { $0.transferID != nil }
        XCTAssertEqual(transferRows.count, 2)
        XCTAssertEqual(Set(transferRows.map(\.accountID)), Set([account.id, savings.id]))
        XCTAssertEqual(transferRows.reduce(Int64(0)) { $0 + $1.amountMinor }, 0)
        XCTAssertTrue(transferRows.first(where: { $0.accountID == account.id })?.isReconciled == true)
        XCTAssertTrue(transferRows.first(where: { $0.accountID == savings.id })?.isReconciled == false,
                      "Reconciliation is account-scoped; the transfer counterpart remains cleared until its own account is reconciled")
        XCTAssertFalse(reopened.transactions.contains { $0.id == deletedID })
        XCTAssertEqual(reopened.accountBalances[account.id], expectedBalance)
        let recentReconciliations = try await reopened.recentReconciliationHistory()
        XCTAssertEqual(recentReconciliations.count, 1)
        XCTAssertEqual(recentReconciliations.first?.accountID, account.id)
        XCTAssertEqual(recentReconciliations.first?.actorUserID, "local-device-owner")
        XCTAssertEqual(recentReconciliations.first?.actorDisplayName, "You")
        XCTAssertEqual(recentReconciliations.first?.statementBalanceMinor, statementBalance)
        let attachments = try await reopened.transactionAttachments(id: transaction.id)
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.filename, "receipt.png")
        let downloadedReceipt = try await reopened.downloadTransactionAttachment(transactionID: transaction.id, attachmentID: attachment.id)
        XCTAssertEqual(downloadedReceipt, receipt)
    }

    @MainActor
    func testVoidAndMakeRecurringUseCanonicalDemoServicesWithoutRewritingOriginal() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let original = try XCTUnwrap(store.transactions.first(where: { $0.id == "t1" }))
        let balanceBefore = store.accounts.map { ($0.id, store.balance(for: $0)) }
        let categoryBefore = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == original.categoryID })
        let readyBefore = store.summary?.readyToAssignMinor
        try await store.createScheduleFromTransaction(id: original.id, operation: .init(recurrenceUnit: "months", intervalCount: 1, nextDate: "2026-10-03"))
        XCTAssertEqual(store.transactions.first(where: { $0.id == original.id })?.amountMinor, original.amountMinor)
        XCTAssertTrue(store.scheduledTransactions.contains { $0.name == original.payeeName && $0.nextDate == "2026-10-03" })
        XCTAssertEqual(store.accounts.map { ($0.id, store.balance(for: $0)) }.map(\.1), balanceBefore.map(\.1))
        try await store.voidTransaction(id: original.id, reason: "Test reversal")
        let voided = try XCTUnwrap(store.transactions.first(where: { $0.id == original.id }))
        let reversal = try XCTUnwrap(store.transactions.first(where: { $0.reversalOfTransactionID == original.id }))
        XCTAssertEqual(voided.status, "voided")
        XCTAssertEqual(reversal.status, "reversal")
        XCTAssertEqual(reversal.amountMinor, -original.amountMinor)
        XCTAssertEqual(voided.reversalTransactionID, reversal.id)
        let categoryAfter = try XCTUnwrap(store.summary?.categories.first { $0.categoryID == original.categoryID })
        XCTAssertEqual(categoryAfter.activityMinor, categoryBefore.activityMinor - original.amountMinor)
        XCTAssertEqual(categoryAfter.availableMinor, categoryBefore.availableMinor - original.amountMinor)
        XCTAssertEqual(store.summary?.readyToAssignMinor, readyBefore)
    }

    @MainActor
    func testHouseholdProfileHierarchyResolvesSharedDependenciesWhenRendered() throws {
        let session = AppSession()
        let store = BudgetWorkspaceStore.demo()
        let member = try JSONDecoder().decode(
            APIHouseholdMember.self,
            from: Data(#"{"user_id":"member-1","email":"member@example.com","display_name":"Member","role":"member","is_active":true}"#.utf8)
        )

        let household = LiveHouseholdView(session: session, store: store)
        let delegated = LiveDelegatedPolicyView(session: session, store: store, member: member)
        XCTAssertTrue(household.session === session)
        XCTAssertTrue(household.store === store)
        XCTAssertTrue(delegated.session === session)
        XCTAssertTrue(delegated.store === store)

        // Rendering both roots forces SwiftUI to resolve every dynamic property.
        // A missing EnvironmentObject traps here instead of escaping to manual QA.
        render(household.environmentObject(session).environmentObject(store))
        render(delegated.environmentObject(session).environmentObject(store))
    }

    @MainActor
    func testDataSourceModeAndServerURLPersistAcrossSessionRelaunch() async throws {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = "BudgetAppTests.\(UUID().uuidString)"
        let factory = connectionClientFactory { request in
            switch request.url?.path {
            case "/api/v1/health":
                return Self.response(request, body: #"{"status":"ok"}"#)
            case "/api/v1/bootstrap/status":
                return Self.response(request, body: #"{"initialized":true,"authentication_required":true,"api_version":"0.4.0"}"#)
            default:
                XCTFail("Unexpected connection request: \(request.url?.path ?? "nil")")
                return Self.response(request, body: "{}")
            }
        }
        let first = AppSession(defaults: defaults, keychain: KeychainStore(service: service), clientFactory: factory, initialMode: .deterministic)
        await first.configureServer("http://127.0.0.1:8000")
        XCTAssertEqual(first.composition, .liveServer)
        XCTAssertEqual(first.connectionStatus, .authenticationRequired)

        let relaunched = AppSession(defaults: defaults, keychain: KeychainStore(service: service), clientFactory: factory)
        XCTAssertEqual(relaunched.sourceMode, .liveServer)
        XCTAssertEqual(relaunched.serverURL?.absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(relaunched.composition, .liveServer)
        relaunched.selectDeterministic()
        let demoRelaunch = AppSession(defaults: defaults, keychain: KeychainStore(service: service), clientFactory: factory)
        XCTAssertEqual(demoRelaunch.composition, .deterministic)
    }

    @MainActor
    func testUnreachableAndInvalidLiveServerNeverFallBackToDemo() async {
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let unreachable = AppSession(
            defaults: defaults,
            keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"),
            clientFactory: connectionClientFactory { _ in throw URLError(.cannotConnectToHost) },
            initialMode: .deterministic
        )
        await unreachable.configureServer("http://127.0.0.1:65530")
        XCTAssertEqual(unreachable.composition, .liveServer)
        guard case .unreachable = unreachable.connectionStatus else { return XCTFail("Expected unreachable live state") }

        let invalid = AppSession(defaults: defaults, keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"), initialMode: .deterministic)
        await invalid.configureServer("not a server URL")
        XCTAssertEqual(invalid.composition, .liveServer)
        guard case .invalidConfiguration = invalid.connectionStatus else { return XCTFail("Expected invalid live configuration") }
    }

    @MainActor
    func testChangingCompositionDoesNotMutateDeterministicFinancialState() async {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let before = (store.transactions.count, store.summary?.readyToAssignMinor, store.summary?.categories.map(\.availableMinor))
        let (defaults, domain) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppSession(
            defaults: defaults,
            keychain: KeychainStore(service: "BudgetAppTests.\(UUID().uuidString)"),
            clientFactory: connectionClientFactory { request in Self.response(request, body: #"{"status":"ok"}"#) },
            initialMode: .deterministic
        )
        await session.configureServer("http://127.0.0.1:8000")
        XCTAssertEqual(session.composition, .liveServer)
        XCTAssertEqual(store.transactions.count, before.0)
        XCTAssertEqual(store.summary?.readyToAssignMinor, before.1)
        XCTAssertEqual(store.summary?.categories.map(\.availableMinor), before.2)
    }

    func testSplitAmountArithmeticRejectsOverflowWithoutTrapping() {
        XCTAssertEqual(CurrencyText.checkedSum([-600, -400]), -1000)
        XCTAssertEqual(CurrencyText.remaining(total: -1000, portions: [-600, -400]), 0)
        XCTAssertEqual(CurrencyText.remaining(total: -1000, portions: [-600]), -400)
        XCTAssertEqual(CurrencyText.checkedSum([.min]), .min)
        XCTAssertNil(CurrencyText.checkedSum([.max, 1]))
        XCTAssertNil(CurrencyText.checkedSum([-.max, -.max]))
        XCTAssertNil(CurrencyText.remaining(total: .max, portions: [-1]))
        XCTAssertNil(CurrencyText.remaining(total: -.max, portions: [-.max, -.max]))
        XCTAssertEqual(CurrencyText.remaining(total: -9_007_199_254_740_993,
            portions: [-9_007_199_254_740_000, -993]), 0)
    }

    func testMagnitudeBuffersRoundTripFullSignedMoneyRange() {
        for currency in ["USD", "JPY", "KWD"] {
            let minimum = CurrencyText.editableMagnitude(.min, currencyCode: currency)
            XCTAssertEqual(CurrencyText.parseMagnitude(minimum, currencyCode: currency, isInflow: false), .min)
            XCTAssertNil(CurrencyText.parseMagnitude(minimum, currencyCode: currency, isInflow: true))
            let maximum = CurrencyText.editableMagnitude(.max, currencyCode: currency)
            XCTAssertEqual(CurrencyText.parseMagnitude(maximum, currencyCode: currency, isInflow: true), .max)
        }
        XCTAssertNil(CurrencyText.parseMagnitude("-1", currencyCode: "USD", isInflow: false))
        XCTAssertNil(CurrencyText.parseMagnitude("1.001", currencyCode: "USD", isInflow: false))
        XCTAssertEqual(CurrencyText.parseMagnitude("0", currencyCode: "USD", isInflow: false), 0)
        XCTAssertEqual(CurrencyText.parseMagnitude("2 + 3", currencyCode: "USD", isInflow: false), -500)
        XCTAssertEqual(CurrencyText.displayMagnitude(.min, currencyCode: "USD", locale: Locale(identifier: "en_US")), "$92,233,720,368,547,758.08")
    }

    @MainActor
    func testMagnitudePresentationHonorsWorkspacePrivacy() {
        let store = BudgetWorkspaceStore.demo()
        XCTAssertEqual(store.formatMagnitude(.min), CurrencyText.displayMagnitude(.min, currencyCode: store.budget.currencyCode))
        store.hideAmounts = true
        XCTAssertEqual(store.formatMagnitude(.min), "••••")
        XCTAssertEqual(store.formatMagnitude(.max), "••••")
    }

    func testCurrencyTextAcceptsNaturalDecimalZeroAndSignedInput() {
        XCTAssertEqual(CurrencyText.parseMinorUnits("12.34", currencyCode: "USD"), 1_234)
        XCTAssertEqual(CurrencyText.parseMinorUnits("0", currencyCode: "USD"), 0)
        XCTAssertEqual(CurrencyText.parseMinorUnits("-12.34", currencyCode: "USD"), -1_234)
        XCTAssertNil(CurrencyText.parseMinorUnits("12.345", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("not money", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits(".", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("-", currencyCode: "USD"))
        XCTAssertEqual(CurrencyText.parseMinorUnits("820.00", currencyCode: "USD"), 82_000)
        XCTAssertEqual(CurrencyText.parseMinorUnits("12.50 + 7.25", currencyCode: "USD"), 1_975)
        XCTAssertEqual(CurrencyText.parseMinorUnits("(10 + 5) * 2", currencyCode: "USD"), 3_000)
        XCTAssertEqual(CurrencyText.parseMinorUnits("10 ÷ 4", currencyCode: "USD"), 250)
        XCTAssertEqual(CurrencyText.parseMinorUnits("20 − 3 * 2", currencyCode: "USD"), 1_400)
        XCTAssertNil(CurrencyText.parseMinorUnits("10 / 0", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("10 +", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("1 / 3", currencyCode: "USD"))
        XCTAssertNil(CurrencyText.parseMinorUnits("92233720368547758.07 + 0.01", currencyCode: "USD"))
    }

    @MainActor
    func testCategorySuggestionUsesTwoOfLastThreeEligibleVisiblePurchases() async {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()

        store.transactions.removeAll()
        let merchant = await store.suggestedCategoryID(forPayeeID: DemoStore.payeeID("Fresh Market"))
        let payroll = await store.suggestedCategoryID(forPayeeID: DemoStore.payeeID("Payroll"))
        let missing = await store.suggestedCategoryID(forPayeeID: "missing-payee")
        XCTAssertEqual(merchant, "groceries")
        XCTAssertNil(payroll)
        XCTAssertNil(missing)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/EditingViews.swift")
        let text = try? String(contentsOf: file)
        XCTAssertTrue(text?.contains("guard suggestionRequestID == requestID, payeeID == item.id, categoryID == nil") == true)
    }

    @MainActor
    func testPayeeHistoryRecordsLifecycleAndSuppressesNoOpSave() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.refresh()
        try await store.createPayee(.init(displayName: "History Market", defaultCategoryID: "groceries"))
        let created = try XCTUnwrap(store.payees.first(where: { $0.displayName == "History Market" }))
        let initial = try await store.payeeHistory(payeeID: created.id, limit: 50, offset: 0)
        XCTAssertEqual(initial.map(\.action), ["preference_updated", "created"])

        try await store.updatePayee(.init(
            payeeID: created.id, displayName: "History Market", isArchived: false,
            defaultCategoryID: "groceries"
        ))
        let afterNoOp = try await store.payeeHistory(payeeID: created.id, limit: 50, offset: 0)
        XCTAssertEqual(afterNoOp, initial, "Saving unchanged Payee metadata is not a new decision")

        try await store.createPayeeAlias(payeeID: created.id, displayName: "HMKT")
        let revised = try await store.payeeHistory(payeeID: created.id, limit: 2, offset: 0)
        XCTAssertEqual(revised.first?.action, "alias_added")
        XCTAssertEqual(revised.first?.actorDisplayName, "Rey")
        XCTAssertEqual(revised.first?.afterSnapshot.aliases, ["HMKT"])
    }

    @MainActor
    func testLocalDeviceAttachmentKeyIsGeneratedOnceAndReloadedExactly() throws {
        let secrets = InMemorySecretDataStore()
        let first = try LocalDeviceKeyManager(store: secrets).loadOrCreateAttachmentKey()
        XCTAssertEqual(first.count, 32)

        let reloaded = try LocalDeviceKeyManager(store: secrets).loadOrCreateAttachmentKey()
        XCTAssertEqual(reloaded, first, "Repository reconstruction must retain access to encrypted objects")
        XCTAssertEqual(secrets.saveCount, 1, "Reloading must not rotate the authority key")
    }

    @MainActor
    func testDropboxBackupRecoveryKeyIsStableSeparateAndMalformedMaterialFailsClosed() throws {
        let secrets = InMemorySecretDataStore()
        let firstManager = LocalDeviceKeyManager(store: secrets)
        let attachmentKey = try firstManager.loadOrCreateAttachmentKey()
        let first = try firstManager.loadOrCreateDropboxBackupRecoveryKey()

        XCTAssertEqual(first.data.count, 32)
        XCTAssertNotEqual(first.data, attachmentKey, "Backup recovery must not reuse the live attachment key")
        let reconstructed = try LocalDeviceKeyManager(store: secrets).loadOrCreateDropboxBackupRecoveryKey()
        XCTAssertEqual(reconstructed, first)
        XCTAssertEqual(secrets.saveCount, 2, "Reconstruction must not rotate either device-held key")

        let damaged = InMemorySecretDataStore()
        try damaged.saveData(Data(repeating: 9, count: 31),
                             account: LocalDeviceKeyManager.dropboxBackupRecoveryKeyAccount)
        XCTAssertThrowsError(try LocalDeviceKeyManager(store: damaged).loadOrCreateDropboxBackupRecoveryKey())
        XCTAssertEqual(damaged.readData(account: LocalDeviceKeyManager.dropboxBackupRecoveryKeyAccount),
                       Data(repeating: 9, count: 31))
        XCTAssertEqual(damaged.saveCount, 1, "Malformed recovery material must never be replaced silently")
    }

    func testDropboxRefreshTokenUsesDedicatedDeviceOnlyKeychainAccountAcrossReconstruction() throws {
        let keychain = KeychainStore(service: "BudgetAppTests.Dropbox.\(UUID().uuidString)")
        let first = DropboxRefreshTokenKeychainStore(keychain: keychain)
        defer { first.deleteRefreshToken() }

        try first.saveRefreshToken("refresh-token")
        let reconstructed = DropboxRefreshTokenKeychainStore(keychain: keychain)
        XCTAssertEqual(try reconstructed.loadRefreshToken(), "refresh-token")
        reconstructed.deleteRefreshToken()
        XCTAssertNil(try reconstructed.loadRefreshToken())
    }

    @MainActor
    func testDropboxCoordinatorFailsClosedWithAnExplicitBlankAppKey() {
        let coordinator = DropboxBackupCoordinator(appKey: "   ")
        XCTAssertFalse(coordinator.isConfigured)
        XCTAssertFalse(coordinator.isConnected)
    }

    @MainActor
    func testDropboxSuccessfulBackupStatusPersistsAcrossCoordinatorReconstruction() {
        let suite = "BudgetAppTests.DropboxStatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let first = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        first.recordSuccessfulBackup(at: completedAt)
        XCTAssertEqual(first.lastSuccessfulBackupAt, completedAt)

        let reconstructed = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        XCTAssertEqual(reconstructed.lastSuccessfulBackupAt, completedAt)
    }

    @MainActor
    func testAutomaticDropboxLifecycleReusesPendingAndSerializesManualCapture() async throws {
        let suite = "BudgetAppTests.DropboxLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent("Pending.clearpocketbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let coordinator = DropboxBackupCoordinator(appKey: "", defaults: defaults)
        coordinator.automaticBackupEnabled = true
        coordinator.retainPendingLocalGeneration(pending, at: Date().addingTimeInterval(-4000))
        var preparations = 0, captures = 0, publications = 0
        XCTAssertTrue(coordinator.claimManualTransfer())
        await coordinator.performAutomaticBackup(prepare: { preparations += 1; return true }, capture: {
            captures += 1; return pending
        }, publish: { _ in XCTFail("Manual claim must block automatic execution"); throw URLError(.cancelled) }, remove: { _ in })
        XCTAssertEqual(preparations, 0)
        coordinator.finishManualTransfer()
        await coordinator.performAutomaticBackup(prepare: { preparations += 1; return true }, capture: {
            captures += 1; return pending
        }, publish: { url in
            publications += 1
            XCTAssertEqual(url, pending)
            XCTAssertFalse(coordinator.claimManualTransfer(), "An automatic claim includes capture and publication")
            throw URLError(.notConnectedToInternet)
        }, remove: { _ in XCTFail("Failed publication must retain local custody") })
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(coordinator.pendingLocalGenerationURL, pending)
        XCTAssertFalse(coordinator.automaticBackupIsDue())
        coordinator.recordSuccessfulBackup(at: Date().addingTimeInterval(-172800))
        coordinator.retainPendingLocalGeneration(pending, at: Date().addingTimeInterval(-4000))
        await coordinator.performAutomaticBackup(prepare: { true }, capture: {
            captures += 1; return pending
        }, publish: { url in
            publications += 1
            XCTAssertEqual(url, pending)
            return .init(remotePath: "/Backups/Pending.clearpocketbackup", encryptedBytes: 10, fileCount: 1)
        }, remove: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(publications, 2)
        XCTAssertNil(coordinator.pendingLocalGenerationURL, "Cleanup failure cannot turn committed publication into a pending retry")
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNotNil(coordinator.lastSuccessfulBackupAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(coordinator.canStartManualBackup)
    }

    @MainActor
    func testAutomaticDropboxDisableDuringCaptureRetainsPackageWithoutPublication() async throws {
        for reenable in [false, true] {
            let suite = "BudgetAppTests.DropboxDisable.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("disabled-backup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let package = root.appendingPathComponent("Retained.clearpocketbackup", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let coordinator = DropboxBackupCoordinator(appKey: "", defaults: defaults)
            coordinator.automaticBackupEnabled = true
            var captures = 0, publications = 0
            await coordinator.performAutomaticBackup(prepare: { true }, capture: {
                captures += 1
                coordinator.automaticBackupEnabled = false
                if reenable { coordinator.automaticBackupEnabled = true }
                return package
            }, publish: { _ in
                publications += 1
                return .init(remotePath: "/Backups/Retained.clearpocketbackup", encryptedBytes: 10, fileCount: 1)
            }, remove: { _ in XCTFail("Disabling publication must not discard captured recovery data") })
            XCTAssertEqual(captures, 1); XCTAssertEqual(publications, 0)
            XCTAssertEqual(coordinator.pendingLocalGenerationURL, package)
            XCTAssertNil(coordinator.lastSuccessfulBackupAt); XCTAssertNil(coordinator.errorMessage)
            XCTAssertTrue(coordinator.canStartManualTransfer)
            let reopened = DropboxBackupCoordinator(appKey: "", defaults: defaults)
            XCTAssertEqual(reopened.pendingLocalGenerationURL, package)
            XCTAssertEqual(reopened.automaticBackupEnabled, reenable)
        }
    }

    @MainActor
    func testAutomaticDropboxPreparationFailureUsesCooldownWithoutCapture() async {
        let suite = "BudgetAppTests.DropboxPrepare.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = DropboxBackupCoordinator(appKey: "", defaults: defaults)
        coordinator.automaticBackupEnabled = true
        await coordinator.performAutomaticBackup(prepare: { false }, capture: {
            XCTFail("Disconnected preparation cannot capture"); throw URLError(.notConnectedToInternet)
        }, publish: { _ in XCTFail("No generation may publish"); throw URLError(.notConnectedToInternet) }, remove: { _ in })
        XCTAssertFalse(coordinator.automaticBackupIsDue())
        XCTAssertNil(coordinator.pendingLocalGenerationURL)
        XCTAssertTrue(coordinator.canStartManualBackup)
    }

    @MainActor
    func testPendingDropboxDiscardIsBlockedDuringCaptureAndRetainsCustodyOnFailure() throws {
        let suite = "BudgetAppTests.DropboxDiscard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).clearpocketbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pending) }
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let coordinator = DropboxBackupCoordinator(appKey: "", defaults: defaults)
        let now = Date()
        coordinator.retainPendingLocalGeneration(pending, at: now)
        coordinator.automaticBackupEnabled = true
        XCTAssertTrue(coordinator.claimAutomaticBackupIfDue(at: now.addingTimeInterval(DropboxBackupCoordinator.pendingRetryInterval)))
        XCTAssertFalse(coordinator.canDiscardPendingGeneration)
        var deletions = 0
        XCTAssertThrowsError(try coordinator.discardPendingGeneration { _ in deletions += 1 })
        XCTAssertEqual(deletions, 0)
        XCTAssertEqual(coordinator.pendingLocalGenerationURL, pending)
        coordinator.finishAutomaticBackupAttempt()
        XCTAssertTrue(coordinator.canDiscardPendingGeneration)
        XCTAssertThrowsError(try coordinator.discardPendingGeneration { _ in throw CocoaError(.fileWriteNoPermission) })
        let reopened = DropboxBackupCoordinator(appKey: "", defaults: defaults)
        XCTAssertEqual(reopened.pendingLocalGenerationURL, pending, "Failed removal must retain durable recovery custody")
        try reopened.discardPendingGeneration { url in
            XCTAssertEqual(url, pending)
            deletions += 1
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(deletions, 1)
        XCTAssertNil(reopened.pendingLocalGenerationURL)
        XCTAssertNil(DropboxBackupCoordinator(appKey: "", defaults: defaults).pendingLocalGenerationURL)
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL)
        XCTAssertTrue(source.contains(".disabled(creating || !dropbox.canDiscardPendingGeneration)"))
        XCTAssertTrue(source.contains("try dropbox.discardPendingGeneration { try store.deletePendingLocalDeviceBackup($0) }"))
    }

    @MainActor
    func testDropboxAutomaticBackupSchedulePersistsAndUsesLastVerifiedSuccess() throws {
        let suite = "BudgetAppTests.DropboxAutomatic.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let first = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        XCTAssertFalse(first.automaticBackupIsDue(at: completedAt))
        first.automaticBackupEnabled = true
        first.automaticBackupIntervalDays = 7
        XCTAssertTrue(first.automaticBackupIsDue(at: completedAt))
        XCTAssertTrue(first.claimAutomaticBackupIfDue(at: completedAt))
        XCTAssertFalse(first.claimAutomaticBackupIfDue(at: completedAt), "Overlapping activation must not duplicate capture")
        first.finishAutomaticBackupAttempt(at: completedAt)
        XCTAssertFalse(first.claimAutomaticBackupIfDue(at: completedAt), "Pre-capture failure must also respect cooldown")
        first.recordSuccessfulBackup(at: completedAt)
        XCTAssertFalse(first.automaticBackupIsDue(at: completedAt.addingTimeInterval(7 * 86_400 - 1)))
        XCTAssertTrue(first.automaticBackupIsDue(at: completedAt.addingTimeInterval(7 * 86_400)))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-dropbox-\(UUID().uuidString)", isDirectory: true)
        let pending = root.appendingPathComponent("Failed.clearpocketbackup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let failedAt = completedAt.addingTimeInterval(8 * 86_400)
        first.retainPendingLocalGeneration(pending, at: failedAt)
        XCTAssertEqual(first.pendingLocalGenerationURL, pending)
        XCTAssertFalse(first.automaticBackupIsDue(at: failedAt), "Failed uploads must not spin on activation")
        let retryAt = failedAt.addingTimeInterval(DropboxBackupCoordinator.pendingRetryInterval)
        XCTAssertTrue(first.automaticBackupIsDue(at: retryAt))
        XCTAssertTrue(first.claimAutomaticBackupIfDue(at: retryAt))
        XCTAssertFalse(first.claimAutomaticBackupIfDue(at: retryAt), "Only one pending upload may be claimed")
        first.finishAutomaticBackupAttempt(at: retryAt)

        let reconstructed = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        XCTAssertTrue(reconstructed.automaticBackupEnabled)
        XCTAssertEqual(reconstructed.automaticBackupIntervalDays, 7)
        XCTAssertEqual(reconstructed.lastSuccessfulBackupAt, completedAt)
        let retryAfterAttempt = retryAt.addingTimeInterval(DropboxBackupCoordinator.pendingRetryInterval)
        XCTAssertEqual(reconstructed.nextAutomaticBackupAt(), retryAfterAttempt)
        XCTAssertFalse(reconstructed.automaticBackupIsDue(at: retryAt.addingTimeInterval(-1)))
        XCTAssertFalse(reconstructed.automaticBackupIsDue(at: retryAt))
        XCTAssertTrue(reconstructed.automaticBackupIsDue(at: retryAfterAttempt))
        reconstructed.automaticBackupEnabled = false
        XCTAssertFalse(reconstructed.automaticBackupIsDue(at: retryAt))
        reconstructed.automaticBackupEnabled = true
        XCTAssertEqual(reconstructed.pendingLocalGenerationURL, pending)
        reconstructed.retainPendingLocalGeneration(pending, at: retryAt)
        XCTAssertFalse(reconstructed.automaticBackupIsDue(at: retryAt), "Another failure restarts the cooldown")
        reconstructed.clearPendingLocalGeneration()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path),
                      "The coordinator must never delete a path recovered from preferences")
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let coordinator = try String(contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("DropboxBackupCoordinator.swift"))
        XCTAssertTrue(coordinator.contains("generation = pendingLocalGenerationURL"), "Automatic retry must reuse the immutable package")
        XCTAssertEqual(source.components(separatedBy: "await store.performAutomaticDropboxBackup(using:").count - 1, 2)
        XCTAssertTrue(source.contains("guard !creating, dropbox.canStartManualTransfer else { return }"), "Leaving Settings cannot unlink an active upload source")
        XCTAssertTrue(source.contains("if let backup, backup.packageURL == dropbox.pendingLocalGenerationURL"))
        XCTAssertFalse(source.contains("if backup?.packageURL == dropbox.pendingLocalGenerationURL"), "Two absent URLs cannot block a first backup")
        XCTAssertTrue(source.contains("store.deletePendingLocalDeviceBackup(packageURL)"))
    }

    @MainActor
    func testDropboxPreCaptureFailureCooldownSurvivesRelaunchAndVerifiedSuccessClearsIt() {
        let suite = "BudgetAppTests.DropboxPreCapture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        first.automaticBackupEnabled = true
        XCTAssertTrue(first.claimAutomaticBackupIfDue(at: start))
        first.finishAutomaticBackupAttempt(at: start)
        XCTAssertNil(first.pendingLocalGenerationURL, "A failed capture must not invent a package")
        let retry = start.addingTimeInterval(DropboxBackupCoordinator.pendingRetryInterval)
        XCTAssertEqual(first.nextAutomaticBackupAt(), retry)
        let restored = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        XCTAssertFalse(restored.claimAutomaticBackupIfDue(at: retry.addingTimeInterval(-1)))
        XCTAssertTrue(restored.claimAutomaticBackupIfDue(at: retry))
        restored.recordSuccessfulBackup(at: retry.addingTimeInterval(1))
        restored.finishAutomaticBackupAttempt(at: retry.addingTimeInterval(2))
        XCTAssertEqual(restored.nextAutomaticBackupAt(), retry.addingTimeInterval(1 + 86_400))
        XCTAssertNil(restored.errorMessage)
        let afterSuccess = DropboxBackupCoordinator(appKey: nil, defaults: defaults)
        XCTAssertEqual(afterSuccess.nextAutomaticBackupAt(), restored.nextAutomaticBackupAt())
        XCTAssertFalse(afterSuccess.automaticBackupIsDue(at: retry.addingTimeInterval(2)))
    }

    @MainActor
    func testMalformedLocalDeviceAttachmentKeyFailsClosedWithoutReplacement() throws {
        let malformed = Data(repeating: 4, count: 31)
        let secrets = InMemorySecretDataStore(initial: malformed)
        let manager = LocalDeviceKeyManager(store: secrets)
        XCTAssertThrowsError(try manager.loadOrCreateAttachmentKey())
        XCTAssertEqual(secrets.readData(account: LocalDeviceKeyManager.attachmentKeyAccount), malformed)
        XCTAssertEqual(secrets.saveCount, 0, "A damaged key must not silently orphan encrypted attachments")
    }

    @MainActor
    func testLocalDeviceStorageCompositionUsesPrivateStablePathsAndOneKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretDataStore()
        let manager = LocalDeviceKeyManager(store: secrets)

        let composition = try LocalDeviceStorageComposition(
            applicationSupportDirectory: root,
            keyManager: manager
        )
        XCTAssertEqual(composition.paths.database.lastPathComponent, "authority.sqlite3")
        XCTAssertEqual(composition.paths.attachments.lastPathComponent, "Attachments")
        XCTAssertTrue(composition.paths.database.path.contains("BudgetApp/LocalDevice"))

        let identity = LocalAuthorityIdentity(
            householdID: "household", householdName: "My Household",
            ownerUserID: "owner", ownerDisplayName: "Owner",
            budgetID: "budget", budgetName: "My Budget", currencyCode: "USD"
        )
        try await composition.authority.bootstrap(identity, createdAt: "2026-09-30T12:00:00Z")
        let loaded = try await composition.authority.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(loaded.identity, identity)

        let payload = Data("receipt".utf8)
        let stored = try await composition.attachments.store(payload, objectName: "receipt.enc")
        let reopened = try await composition.attachments.data(
            objectName: stored.objectName,
            expectedSHA256: stored.plaintextSHA256
        )
        XCTAssertEqual(reopened, payload)
        XCTAssertEqual(secrets.saveCount, 1)
    }

    @MainActor
    func testProductionLocalWorkspaceCreatesRestorableEncryptedBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-backup-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let keyManager = LocalDeviceKeyManager(store: InMemorySecretDataStore())
        let store = BudgetWorkspaceStore.localDevice(
            applicationSupportDirectory: applicationSupport,
            keyManager: keyManager
        )
        await store.refresh()
        try await store.createAccount(.init(
            name: "Backup Checking", kind: "checking", isOnBudget: true,
            openingBalanceMinor: 54_321
        ))

        let dropboxRecovery = try store.localDeviceDropboxRecoveryKey()
        let exported = try await store.createLocalDeviceBackup(in: exports, recoveryKey: dropboxRecovery)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.packageURL.path))
        XCTAssertGreaterThan(exported.encryptedBytes, 0)
        XCTAssertEqual(try LocalDeviceBackupRecoveryKey(encoded: exported.recoveryKey).encoded, exported.recoveryKey)
        XCTAssertEqual(exported.recoveryKey, dropboxRecovery.encoded)
        XCTAssertThrowsError(try store.deletePendingLocalDeviceBackup(exported.packageURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.packageURL.path),
                      "A path outside protected pending storage must never be deleted")

        let pendingDirectory = try store.localDevicePendingBackupDirectory()
        let discardable = pendingDirectory.appendingPathComponent("Discardable.clearpocketbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: discardable, withIntermediateDirectories: true)
        try store.deletePendingLocalDeviceBackup(discardable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: discardable.path))

        let restored = root.appendingPathComponent("Restored", isDirectory: true)
        _ = try await LocalDeviceBackupService.restore(
            packageURL: exported.packageURL,
            destinationRootURL: restored,
            recoveryKey: try .init(encoded: exported.recoveryKey)
        )
        let authority = try LocalAuthorityStore(fileURL: restored.appendingPathComponent("authority.sqlite3"))
        let snapshot = try await authority.snapshot(budgetID: store.budget.id)
        XCTAssertEqual(snapshot.accounts.map(\.name), ["Backup Checking"])
        XCTAssertEqual(snapshot.transactions.first(where: { $0.payeeName == "Starting Balance" })?.amountMinor, 54_321)
    }

    @MainActor
    func testProductionLocalWorkspaceFirstLaunchPublishesZeroMoneyStarterPlanOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-starter-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyManager = LocalDeviceKeyManager(store: InMemorySecretDataStore())

        let firstLaunch = BudgetWorkspaceStore.localDevice(
            applicationSupportDirectory: root,
            keyManager: keyManager
        )
        await firstLaunch.refresh()
        XCTAssertNil(firstLaunch.errorMessage)
        XCTAssertEqual(firstLaunch.groups.map(\.name), LocalAuthorityStore.starterPlan.map(\.group))
        XCTAssertEqual(Set(firstLaunch.categories.map(\.name)), Set(LocalAuthorityStore.starterPlan.flatMap(\.categories)))
        XCTAssertEqual(firstLaunch.summary?.readyToAssignMinor, 0)
        XCTAssertTrue(firstLaunch.accounts.isEmpty)
        XCTAssertTrue(firstLaunch.transactions.isEmpty)
        XCTAssertTrue(firstLaunch.targets.isEmpty)

        let relaunch = BudgetWorkspaceStore.localDevice(
            applicationSupportDirectory: root,
            keyManager: keyManager
        )
        await relaunch.refresh()
        XCTAssertNil(relaunch.errorMessage)
        XCTAssertEqual(relaunch.groups.count, 4)
        XCTAssertEqual(relaunch.categories.count, 11)
    }

    @MainActor
    func testLocalDeviceDebtPayoffPlanPersistsAcrossWorkspaceReconstruction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-payoff-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyManager = LocalDeviceKeyManager(store: InMemorySecretDataStore())
        let first = BudgetWorkspaceStore.localDevice(
            applicationSupportDirectory: root, keyManager: keyManager
        )
        await first.refresh()
        try await first.createAccount(.init(
            name: "Payoff Card", kind: "credit", isOnBudget: true,
            openingBalanceMinor: -250_000
        ))
        let debtID = try XCTUnwrap(first.accounts.first(where: { $0.name == "Payoff Card" })?.id)

        let saved = try await first.saveDebtPayoffPlan(.init(
            strategy: "snowball", rollover: true, extraPaymentMinor: 12_345,
            accountIDs: [debtID], customOrder: [], targetDate: "2028-12-31"
        ))
        XCTAssertEqual(saved.extraPaymentMinor, 12_345)
        XCTAssertNotEqual(saved.userID, "demo-owner")

        let reopened = BudgetWorkspaceStore.localDevice(
            applicationSupportDirectory: root, keyManager: keyManager
        )
        await reopened.refresh()
        let loaded = try await reopened.debtPayoffPlan()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.strategy, "snowball")
        XCTAssertEqual(restored.accountIDs, [debtID])
        XCTAssertEqual(restored.extraPaymentMinor, 12_345)
        XCTAssertEqual(restored.targetDate, "2028-12-31")
        XCTAssertEqual(restored.userID, saved.userID)
        XCTAssertEqual(restored.updatedAt, saved.updatedAt)
        let savedHistory = try await reopened.debtPayoffPlanHistory(limit: 10, offset: 0)
        XCTAssertEqual(savedHistory.count, 1)
        XCTAssertEqual(savedHistory[0].afterSnapshot?.extraPaymentMinor, 12_345)
        XCTAssertEqual(savedHistory[0].userID, saved.userID)
        _ = try await reopened.saveDebtPayoffPlan(.init(strategy: "snowball", rollover: true,
            extraPaymentMinor: 12_345, accountIDs: [debtID], customOrder: [], targetDate: "2028-12-31"))
        let unchangedHistory = try await reopened.debtPayoffPlanHistory(limit: 10, offset: 0)
        XCTAssertEqual(unchangedHistory, savedHistory, "Identical saves must not create duplicate decisions")
        try await reopened.deleteDebtPayoffPlan()
        let afterRemoval = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keyManager)
        await afterRemoval.refresh()
        let deleted = try await afterRemoval.debtPayoffPlan()
        XCTAssertNil(deleted)
        let retainedHistory = try await afterRemoval.debtPayoffPlanHistory(limit: 10, offset: 0)
        XCTAssertEqual(retainedHistory.map(\.action), ["deleted", "created"])
        XCTAssertEqual(retainedHistory[0].beforeSnapshot, retainedHistory[1].afterSnapshot)
        XCTAssertNil(retainedHistory[0].afterSnapshot)
    }

    @MainActor
    func testLocalDeviceDebtTermsAndHistoryPersistAcrossWorkspaceReconstruction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("debt-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = LocalDeviceKeyManager(store: InMemorySecretDataStore())
        let first = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keys)
        await first.refresh()
        try await first.createAccount(.init(name: "History Card", kind: "credit", isOnBudget: true, openingBalanceMinor: -250_000))
        let id = try XCTUnwrap(first.accounts.first(where: { $0.name == "History Card" })?.id)
        let terms = APIAccountDebtTermsUpsert(termsType: "credit_card", annualRateBasisPoints: 2199, rateType: "variable", paymentFrequency: "monthly", minimumPaymentRule: "fixed", minimumPaymentMinor: 3500, dueDay: 18)
        _ = try await first.updateAccountDebtTerms(accountID: id, value: terms)
        _ = try await first.updateAccountDebtTerms(accountID: id, value: terms)
        let reopened = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keys)
        await reopened.refresh()
        let restored = try await reopened.accountDebtTerms(accountID: id)
        XCTAssertEqual(restored?.annualRateBasisPoints, 2199)
        XCTAssertEqual(restored?.minimumPaymentMinor, 3500)
        let created = try await reopened.accountDebtTermsHistory(accountID: id)
        XCTAssertEqual(created.map(\.action), ["created"])
        try await reopened.deleteAccountDebtTerms(accountID: id)
        let again = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keys)
        await again.refresh()
        let removed = try await again.accountDebtTerms(accountID: id)
        XCTAssertNil(removed)
        let history = try await again.accountDebtTermsHistory(accountID: id)
        XCTAssertEqual(history.map(\.action), ["deleted", "created"])
        XCTAssertEqual(history.first?.beforeSnapshot?.minimumPaymentMinor, 3500)
    }

    @MainActor
    func testLocalDeviceFutureMonthAssignmentPersistsWithoutRewritingCurrentMonth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-future-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try LocalAuthorityStore(fileURL: root.appendingPathComponent("authority.sqlite3"))
        let identity = LocalAuthorityIdentity(
            householdID: "local-device-household", householdName: "My Household",
            ownerUserID: "local-device-owner", ownerDisplayName: "You",
            budgetID: "local-device-budget", budgetName: "My Budget", currencyCode: "USD"
        )
        let budget = APIBudget(
            id: identity.budgetID, householdID: identity.householdID, name: identity.budgetName,
            currencyCode: identity.currencyCode, effectivePermission: .owner, capabilities: nil
        )
        let now = { BudgetWorkspaceStore.parseDate("2026-09-15") }
        let report = WorkspaceReportQuery(
            start: BudgetWorkspaceStore.parseDate("2026-09-01"),
            end: BudgetWorkspaceStore.parseDate("2026-10-31"),
            accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "",
            transactionType: "", cleared: "all", flag: "", tag: "",
            spendingTrendDimension: "category", includeTracking: true
        )
        let september = BudgetWorkspaceStore.parseDate("2026-09-01")
        let october = BudgetWorkspaceStore.parseDate("2026-10-01")
        let source = DemoWorkspaceDataSource(
            fresh: true, budgetOverride: budget, localAuthority: authority,
            localIdentity: identity, now: now
        )

        _ = try await source.snapshot(planMonth: september, report: report)
        try await source.createAccount(.init(
            name: "Planning Cash", kind: "checking", isOnBudget: true,
            openingBalanceMinor: 50_000
        ))
        let funded = try await source.snapshot(planMonth: september, report: report)
        let fundedSummary = try XCTUnwrap(funded.summary)
        let category = try XCTUnwrap(fundedSummary.categories.first)
        XCTAssertEqual(category.assignedMinor, 0)
        XCTAssertEqual(fundedSummary.readyToAssignMinor, 50_000)

        try await source.assignMoney(.init(
            categoryID: category.categoryID, month: "2026-10-01", assignedMinor: 20_000,
            expectedVersion: fundedSummary.allocationVersion
        ))
        let octoberAfterAssignment = try await source.snapshot(planMonth: october, report: report)
        let octoberSummary = try XCTUnwrap(octoberAfterAssignment.summary)
        XCTAssertEqual(
            octoberSummary.categories.first { $0.categoryID == category.categoryID }?.assignedMinor,
            20_000
        )
        XCTAssertEqual(octoberSummary.allDateUnassignedMinor, 30_000)
        let septemberAfterAssignment = try await source.snapshot(planMonth: september, report: report)
        let septemberSummary = try XCTUnwrap(septemberAfterAssignment.summary)
        XCTAssertEqual(
            septemberSummary.categories.first { $0.categoryID == category.categoryID }?.assignedMinor,
            0
        )
        XCTAssertEqual(septemberSummary.readyToAssignMinor, 50_000)
        XCTAssertEqual(septemberSummary.fundingLimitMinor, 30_000)

        let reopened = DemoWorkspaceDataSource(
            fresh: true, budgetOverride: budget, localAuthority: authority,
            localIdentity: identity, now: now
        )
        let restoredOctober = try await reopened.snapshot(planMonth: october, report: report)
        let restoredSummary = try XCTUnwrap(restoredOctober.summary)
        XCTAssertEqual(
            restoredSummary.categories.first { $0.categoryID == category.categoryID }?.assignedMinor,
            20_000
        )
        XCTAssertEqual(restoredSummary.allDateUnassignedMinor, 30_000)
        XCTAssertEqual(restoredOctober.accounts.first?.name, "Planning Cash")
        XCTAssertEqual(restoredOctober.accountBalances.values.first?.workingBalanceMinor, 50_000)
    }

    @MainActor
    func testConfirmedLocalEraseRemovesAuthorityAttachmentsKeysAndReopensFreshStarterPlan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-erase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretDataStore()
        let keyManager = LocalDeviceKeyManager(store: secrets)
        let composition = try LocalDeviceStorageComposition(applicationSupportDirectory: root, keyManager: keyManager)
        let identity = LocalAuthorityIdentity(
            householdID: "local-device-household", householdName: "My Household",
            ownerUserID: "local-device-owner", ownerDisplayName: "You",
            budgetID: "local-device-budget", budgetName: "My Budget", currencyCode: "USD"
        )
        try await composition.authority.bootstrap(identity, createdAt: "2026-10-01T12:00:00Z", installStarterPlan: true)
        _ = try await composition.attachments.store(Data("private receipt".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: composition.paths.database.path))
        XCTAssertNotNil(secrets.readData(account: LocalDeviceKeyManager.attachmentKeyAccount))

        try await LocalDeviceEraseCoordinator.erase(composition)
        XCTAssertFalse(FileManager.default.fileExists(atPath: composition.paths.rootDirectory.path))
        XCTAssertNil(secrets.readData(account: LocalDeviceKeyManager.attachmentKeyAccount))
        XCTAssertNil(secrets.readData(account: LocalDeviceKeyManager.dropboxBackupRecoveryKeyAccount))

        let reopened = BudgetWorkspaceStore.localDevice(applicationSupportDirectory: root, keyManager: keyManager)
        await reopened.refresh()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.groups.count, 4)
        XCTAssertEqual(reopened.categories.count, 11)
        XCTAssertTrue(reopened.accounts.isEmpty)
        XCTAssertTrue(reopened.transactions.isEmpty)
    }

    @MainActor
    func testLocalAuthorityPersistsCanonicalCreditReserveAttributionAndRejectsTampering() throws {
        let identity = LocalAuthorityIdentity(
            householdID: "local-household", householdName: "Local Household",
            ownerUserID: "local-owner", ownerDisplayName: "Owner",
            budgetID: "local-budget", budgetName: "Local Budget", currencyCode: "USD"
        )
        let source = DemoStore()
        let snapshot = try source.localAuthoritySnapshot(identity: identity)
        XCTAssertFalse(snapshot.creditReserveAttributions.isEmpty)

        let reopened = DemoStore(fresh: true)
        try reopened.loadLocalAuthority(snapshot)
        let roundTrip = try reopened.localAuthoritySnapshot(identity: identity)
        XCTAssertEqual(roundTrip.creditReserveAttributions, snapshot.creditReserveAttributions)

        let first = try XCTUnwrap(snapshot.creditReserveAttributions.first)
        let damaged = LocalAuthoritySnapshot(
            identity: snapshot.identity, accounts: snapshot.accounts, groups: snapshot.groups,
            categories: snapshot.categories, payees: snapshot.payees,
            payeeAliases: snapshot.payeeAliases, transactions: snapshot.transactions,
            allocations: snapshot.allocations, reconciliations: snapshot.reconciliations,
            targets: snapshot.targets, schedules: snapshot.schedules,
            attachments: snapshot.attachments, debtTerms: snapshot.debtTerms,
            cashRolloverPolicies: snapshot.cashRolloverPolicies,
            creditReserveAttributions: [
                .init(transactionID: first.transactionID, categoryID: first.categoryID,
                      amountMinor: first.amountMinor + 1)
            ] + Array(snapshot.creditReserveAttributions.dropFirst())
        )
        XCTAssertThrowsError(try DemoStore(fresh: true).loadLocalAuthority(damaged))
    }

    @MainActor
    func testLocalAuthorityPreservesCategoryGroupIdentityAcrossRenameReorderAndReload() throws {
        let identity = LocalAuthorityIdentity(
            householdID: "local-household", householdName: "Local Household",
            ownerUserID: "local-owner", ownerDisplayName: "Owner",
            budgetID: "local-budget", budgetName: "Local Budget", currencyCode: "USD"
        )
        let source = DemoStore(fresh: true)
        source.createCategoryGroup(named: "Long-term Plans")
        let original = try source.localAuthoritySnapshot(identity: identity)
        let originalGroup = try XCTUnwrap(original.groups.first { $0.name == "Long-term Plans" })

        source.renameCategoryGroup(from: "Long-term Plans", to: "Future Plans", sortOrder: 0)
        let renamed = try source.localAuthoritySnapshot(identity: identity)
        let renamedGroup = try XCTUnwrap(renamed.groups.first { $0.name == "Future Plans" })
        XCTAssertEqual(renamedGroup.id, originalGroup.id)
        XCTAssertEqual(renamedGroup.sortOrder, 0)

        let reopened = DemoStore(fresh: true)
        try reopened.loadLocalAuthority(renamed)
        let roundTrip = try reopened.localAuthoritySnapshot(identity: identity)
        XCTAssertEqual(roundTrip.groups, renamed.groups)
    }

    @MainActor
    func testVerifiedLocalRestoreCutsOverOnlyAtNextCompositionAndRetainsRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-cutover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceSupport = root.appendingPathComponent("SourceSupport", isDirectory: true)
        let targetSupport = root.appendingPathComponent("TargetSupport", isDirectory: true)
        let exportDirectory = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let identity = LocalAuthorityIdentity(
            householdID: "local-device-household", householdName: "Restored Household",
            ownerUserID: "local-device-owner", ownerDisplayName: "You",
            budgetID: "local-device-budget", budgetName: "Restored Budget", currencyCode: "USD"
        )

        let sourceSecrets = InMemorySecretDataStore()
        let source = try LocalDeviceStorageComposition(
            applicationSupportDirectory: sourceSupport,
            keyManager: LocalDeviceKeyManager(store: sourceSecrets)
        )
        try await source.authority.bootstrap(identity, createdAt: "2026-09-30T12:00:00Z")
        try await source.authority.insertAccount(.init(
            id: "restored-account", budgetID: identity.budgetID, name: "Restored Checking",
            kind: "checking", isOnBudget: true, openingBalanceMinor: 87_654,
            createdAt: "2026-09-30T12:00:00Z"
        ))
        let recoveryKey = try LocalDeviceBackupRecoveryKey(data: Data(repeating: 23, count: 32))
        let package = exportDirectory.appendingPathComponent("generation.clearpocketbackup", isDirectory: true)
        _ = try await LocalDeviceBackupService.create(
            authority: source.authority, budgetID: identity.budgetID,
            attachmentsDirectory: source.paths.attachments, attachmentKey: source.attachmentKey,
            destinationURL: package, recoveryKey: recoveryKey
        )

        let targetSecrets = InMemorySecretDataStore()
        let targetKeyManager = LocalDeviceKeyManager(store: targetSecrets)
        let target = try LocalDeviceStorageComposition(
            applicationSupportDirectory: targetSupport,
            keyManager: targetKeyManager
        )
        let oldKey = target.attachmentKey
        try await target.authority.bootstrap(
            .init(householdID: "local-device-household", householdName: "Current Household",
                  ownerUserID: "local-device-owner", ownerDisplayName: "You",
                  budgetID: "local-device-budget", budgetName: "Current Budget", currencyCode: "USD"),
            createdAt: "2026-09-29T12:00:00Z"
        )
        try await target.authority.insertAccount(.init(
            id: "current-account", budgetID: identity.budgetID, name: "Current Checking",
            kind: "checking", isOnBudget: true, openingBalanceMinor: 12_345,
            createdAt: "2026-09-29T12:00:00Z"
        ))

        let applicationDirectory = target.paths.rootDirectory.deletingLastPathComponent()
        do {
            _ = try await LocalDeviceRestoreCoordinator.prepare(
                packageURL: package,
                recoveryKey: try .init(data: Data(repeating: 99, count: 32)),
                applicationDirectory: applicationDirectory, keyManager: targetKeyManager
            )
            XCTFail("A backup with the wrong recovery key must not be scheduled")
        } catch {}
        XCTAssertFalse(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: applicationDirectory))
        XCTAssertNil(targetSecrets.readData(account: LocalDeviceKeyManager.pendingRestoreKeyAccount))

        let prepared = try await LocalDeviceRestoreCoordinator.prepare(
            packageURL: package, recoveryKey: recoveryKey,
            applicationDirectory: applicationDirectory, keyManager: targetKeyManager
        )
        XCTAssertEqual(prepared.budgetID, identity.budgetID)
        XCTAssertTrue(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: applicationDirectory))
        let stillCurrent = try await target.authority.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(stillCurrent.accounts.map(\.name), ["Current Checking"],
                       "Preparing must not mutate the open authority")
        XCTAssertFalse(try LocalDeviceRestoreCoordinator.applyPendingRestoreBeforeOpening(
            applicationDirectory: applicationDirectory, keyManager: targetKeyManager
        ), "A same-process composition rebuild must not promote a restore over an open authority")
        XCTAssertTrue(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: applicationDirectory))

        let candidateName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: applicationDirectory.path)
            .first(where: { $0.hasPrefix(".LocalDevice-Restore-") }))
        let rollbackName = candidateName.replacingOccurrences(of: ".LocalDevice-Restore-", with: "LocalDevice-Rollback-")
        // Model termination after the current authority was preserved but before the candidate was
        // promoted. The next cold composition must resume this journal state safely.
        try FileManager.default.moveItem(
            at: applicationDirectory.appendingPathComponent("LocalDevice"),
            to: applicationDirectory.appendingPathComponent(rollbackName)
        )
        XCTAssertTrue(try LocalDeviceRestoreCoordinator.applyPendingRestore(
            applicationDirectory: applicationDirectory, keyManager: targetKeyManager
        ))
        let reopened = try LocalDeviceStorageComposition(
            applicationSupportDirectory: targetSupport,
            keyManager: targetKeyManager
        )
        let restored = try await reopened.authority.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(restored.identity.budgetName, "Restored Budget")
        XCTAssertEqual(restored.accounts.map(\.name), ["Restored Checking"])
        XCTAssertEqual(reopened.attachmentKey, source.attachmentKey)
        XCTAssertFalse(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: applicationDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: applicationDirectory.appendingPathComponent(rollbackName).path))
        XCTAssertEqual(targetSecrets.readData(account: LocalDeviceKeyManager.rollbackKeyAccount(for: rollbackName)), oldKey)

        let generations = try LocalDeviceRestoreCoordinator.rollbackGenerations(
            applicationDirectory: applicationDirectory, keyManager: targetKeyManager
        )
        let prior = try XCTUnwrap(generations.first(where: { $0.id == rollbackName }))
        XCTAssertGreaterThan(prior.storedBytes, 0)
        _ = try LocalDeviceRestoreCoordinator.prepareRollback(
            prior, applicationDirectory: applicationDirectory, keyManager: targetKeyManager
        )
        XCTAssertTrue(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: applicationDirectory))
        XCTAssertTrue(try LocalDeviceRestoreCoordinator.applyPendingRestore(
            applicationDirectory: applicationDirectory, keyManager: targetKeyManager
        ))
        let switchedBack = try LocalAuthorityStore(
            fileURL: applicationDirectory.appendingPathComponent("LocalDevice/authority.sqlite3")
        )
        let original = try await switchedBack.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(original.identity.budgetName, "Current Budget")
        XCTAssertEqual(original.accounts.map(\.name), ["Current Checking"])
        XCTAssertEqual(try targetKeyManager.loadOrCreateAttachmentKey(), oldKey)
        XCTAssertNil(targetSecrets.readData(account: LocalDeviceKeyManager.rollbackKeyAccount(for: rollbackName)),
                     "A consumed rollback generation must not leave an orphaned key")

    }

    @MainActor
    func testRollbackCleanupRequiresMatchingKeyAndRemovesGenerationAndKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-device-rollback-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "LocalDevice-Rollback-\(UUID().uuidString)"
        let generationDirectory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: generationDirectory, withIntermediateDirectories: true)
        try Data("retained authority".utf8).write(to: generationDirectory.appendingPathComponent("authority.sqlite3"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("LocalDevice-Rollback-Symlink"),
            withDestinationURL: generationDirectory
        )
        let secrets = InMemorySecretDataStore()
        try secrets.saveData(Data(repeating: 31, count: 32),
                             account: LocalDeviceKeyManager.rollbackKeyAccount(for: name))
        let manager = LocalDeviceKeyManager(store: secrets)

        let generations = try LocalDeviceRestoreCoordinator.rollbackGenerations(
            applicationDirectory: root, keyManager: manager
        )
        let generation = try XCTUnwrap(generations.first)
        XCTAssertEqual(generations.count, 1, "Symbolic links must never become recovery generations")
        XCTAssertEqual(generation.id, name)
        XCTAssertGreaterThan(generation.storedBytes, 0)
        try LocalDeviceRestoreCoordinator.deleteRollback(
            generation, applicationDirectory: root, keyManager: manager
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: generationDirectory.path))
        XCTAssertNil(secrets.readData(account: LocalDeviceKeyManager.rollbackKeyAccount(for: name)))
    }

    @MainActor
    func testFirstServerImportPromotesWithoutInventingRollbackGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-local-device-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = root.appendingPathComponent(
            ".LocalDevice-Transfer-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let identity = LocalAuthorityIdentity(
            householdID: "household", householdName: "Imported Home", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "imported-budget", budgetName: "Imported Budget",
            currencyCode: "USD"
        )
        var authority: LocalAuthorityStore? = try LocalAuthorityStore(
            fileURL: candidate.appendingPathComponent("authority.sqlite3")
        )
        try await authority?.bootstrap(identity, createdAt: "2026-10-01T12:00:00Z")
        authority = nil

        let secrets = InMemorySecretDataStore()
        let keyManager = LocalDeviceKeyManager(store: secrets)
        let attachmentKey = Data(repeating: 41, count: 32)
        let prepared = try LocalDeviceRestoreCoordinator.prepareImportedCandidate(
            .init(rootURL: candidate, budgetID: identity.budgetID, attachmentCount: 0),
            attachmentKey: attachmentKey,
            createdAt: "2026-10-01T12:00:00Z",
            applicationDirectory: root,
            keyManager: keyManager
        )
        XCTAssertEqual(prepared.budgetID, identity.budgetID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("LocalDevice").path))
        XCTAssertTrue(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: root))

        XCTAssertTrue(try LocalDeviceRestoreCoordinator.applyPendingRestore(
            applicationDirectory: root, keyManager: keyManager
        ))
        XCTAssertEqual(try keyManager.loadOrCreateAttachmentKey(), attachmentKey)
        XCTAssertFalse(LocalDeviceRestoreCoordinator.hasPendingRestore(applicationDirectory: root))
        XCTAssertTrue(try LocalDeviceRestoreCoordinator.rollbackGenerations(
            applicationDirectory: root, keyManager: keyManager
        ).isEmpty)
        let reopened = try LocalAuthorityStore(
            fileURL: root.appendingPathComponent("LocalDevice/authority.sqlite3")
        )
        let reopenedSnapshot = try await reopened.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(reopenedSnapshot.identity, identity)
    }

    @MainActor
    func testServerTransferUsesCurrentCredentialPerObjectAndStableColdJournal() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-to-local-transfer-\(UUID().uuidString)", isDirectory: true)
        defer {
            ConnectionURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: support)
        }
        let receipt = Data("verified receipt".utf8)
        let projection = serverTransferFixture(attachment: receipt)
        let recorder = TransferRequestRecorder()
        let clientFactory = connectionClientFactory { request in
            recorder.append(
                path: request.url!.path,
                authorization: request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            if request.url!.path.hasSuffix("/local-device-transfer") {
                return Self.response(request, body: String(decoding: projection, as: UTF8.self))
            }
            if request.url!.path.hasSuffix("/attachments/attachment") {
                return (HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )!, receipt)
            }
            return (HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!, Data())
        }
        let tokens = ["token-a", "token-b", "token-c"]
        var credentialIndex = 0
        let keyManager = LocalDeviceKeyManager(store: InMemorySecretDataStore())
        let coordinator = ServerToLocalDeviceTransferCoordinator(
            credentialProvider: { _ in
                let token = tokens[credentialIndex]
                credentialIndex += 1
                return (URL(string: "http://127.0.0.1:8000")!, token)
            },
            clientFactory: clientFactory,
            applicationSupportDirectory: support,
            keyManager: keyManager
        )

        let result = try await coordinator.prepare(budgetID: "budget")
        XCTAssertEqual(result.sourceRevision, String(repeating: "a", count: 64))
        XCTAssertEqual(result.attachmentCount, 1)
        XCTAssertEqual(credentialIndex, 3)
        XCTAssertEqual(recorder.authorizations, ["Bearer token-a", "Bearer token-b", "Bearer token-c"])
        XCTAssertEqual(recorder.paths.filter { $0.hasSuffix("/local-device-transfer") }.count, 2)
        XCTAssertEqual(recorder.paths.filter { $0.hasSuffix("/attachments/attachment") }.count, 1)
        let applicationDirectory = support.appendingPathComponent("BudgetApp", isDirectory: true)
        XCTAssertTrue(LocalDeviceRestoreCoordinator.hasPendingRestore(
            applicationDirectory: applicationDirectory
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: applicationDirectory.appendingPathComponent("LocalDevice").path
        ), "Preparation must not activate the candidate in the running process")
    }

    @MainActor
    func testServerTransferRejectsConcurrentAuthorityChangeWithoutPublishingJournal() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("changed-server-transfer-\(UUID().uuidString)", isDirectory: true)
        defer {
            ConnectionURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: support)
        }
        let receipt = Data("verified receipt".utf8)
        let first = serverTransferFixture(attachment: receipt, revision: String(repeating: "a", count: 64))
        let changed = serverTransferFixture(attachment: receipt, revision: String(repeating: "b", count: 64))
        let projectionRequests = TransferCounter()
        let clientFactory = connectionClientFactory { request in
            if request.url!.path.hasSuffix("/local-device-transfer") {
                let response = projectionRequests.increment() == 1 ? first : changed
                return Self.response(request, body: String(decoding: response, as: UTF8.self))
            }
            return (HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            )!, receipt)
        }
        let secrets = InMemorySecretDataStore()
        let coordinator = ServerToLocalDeviceTransferCoordinator(
            credentialProvider: { _ in (URL(string: "http://127.0.0.1:8000")!, "current") },
            clientFactory: clientFactory,
            applicationSupportDirectory: support,
            keyManager: LocalDeviceKeyManager(store: secrets)
        )

        do {
            _ = try await coordinator.prepare(budgetID: "budget")
            XCTFail("A changed source revision must never publish a candidate journal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed during transfer"))
        }
        let applicationDirectory = support.appendingPathComponent("BudgetApp", isDirectory: true)
        XCTAssertFalse(LocalDeviceRestoreCoordinator.hasPendingRestore(
            applicationDirectory: applicationDirectory
        ))
        XCTAssertNil(secrets.readData(account: LocalDeviceKeyManager.pendingRestoreKeyAccount))
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: applicationDirectory.path)) ?? []
        XCTAssertFalse(remaining.contains { $0.hasPrefix(".LocalDevice-Transfer-") })
    }

    @MainActor
    func testEditingAssignmentTotalPreservesActivityAndAppliesOnlyExactDelta() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        let groceries = try XCTUnwrap(store.summary?.categories.first(where: { $0.name == "Groceries" }))
        XCTAssertEqual(groceries.assignedMinor, 72_000)
        XCTAssertEqual(groceries.activityMinor, -12_500)
        let readyBefore = try XCTUnwrap(store.summary?.readyToAssignMinor)

        try await store.updateAssignment(categoryID: groceries.categoryID, month: "2026-09-01", assignedMinor: 82_000, expectedVersion: store.summary!.allocationVersion)

        let updated = try XCTUnwrap(store.summary?.categories.first(where: { $0.categoryID == groceries.categoryID }))
        XCTAssertEqual(updated.assignedMinor, 82_000)
        XCTAssertEqual(updated.activityMinor, -12_500)
        XCTAssertEqual(updated.availableMinor, 69_500)
        XCTAssertEqual(store.summary?.readyToAssignMinor, readyBefore - 10_000)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let domain = "BudgetAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    private func connectionClientFactory(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> (URL) throws -> APIClient {
        ConnectionURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return { try APIClient(baseURL: $0, session: session) }
    }

    private func serverTransferFixture(
        attachment: Data,
        revision: String = String(repeating: "a", count: 64)
    ) -> Data {
        let sha = SHA256.hash(data: attachment).map { String(format: "%02x", $0) }.joined()
        return Data(#"""
        {
          "format":"com.clearpocket.local-device-transfer","version":1,
          "generated_at":"2026-10-01T12:00:00Z","authority_created_at":"2026-01-01T12:00:00Z",
          "source_revision":"\#(revision)",
          "identity":{"household_id":"household","household_name":"Home","owner_user_id":"owner","owner_display_name":"Owner","budget_id":"budget","budget_name":"Budget","currency_code":"USD"},
          "accounts":[{"id":"account","budget_id":"budget","name":"Checking","kind":"checking","is_on_budget":true,"is_closed":false,"opening_balance_minor":0,"created_at":"2026-01-01T12:00:00Z"}],
          "groups":[],"categories":[],"payees":[],"payee_aliases":[],
          "transactions":[{"id":"transaction","budget_id":"budget","account_id":"account","payee_id":null,"payee_name":"Store","amount_minor":-100,"occurred_on":"2026-10-01","memo":"","is_cleared":false,"is_reconciled":false,"status":"posted","transfer_id":null,"flag":null,"tags":[],"financial_classification":null,"void_reason":null,"reversal_of_transaction_id":null,"reversal_transaction_id":null,"created_by_user_id":"owner","created_at":"2026-10-01T12:00:00Z","splits":[]}],
          "allocations":[],"reconciliations":[],"targets":[],"schedules":[],
          "attachments":[{"id":"attachment","transaction_id":"transaction","filename":"receipt.jpg","content_type":"image/jpeg","size_bytes":\#(attachment.count),"sha256":"\#(sha)","object_name":"attachment","created_at":"2026-10-01T12:00:00Z"}],
          "debt_terms":[],"cash_rollover_policies":[],"credit_reserve_attributions":[],"transaction_changes":[],"credit_reserve_events":[],
          "observations":{"transaction_count":1,"transactions":[{"account_id":"account","status":"posted","amount_minor":-100}],"allocation_count":0,"allocations":[],"reserve_count":0,"reserves":[]}
        }
        """#.utf8)
    }

    private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    func testCurrencyTextEditableRoundTripsWithoutDoublePrecision() {
        for value: Int64 in [0, 1, -1, 12_345, -98_765, 9_007_199_254_740_991] {
            let text = CurrencyText.editable(value, currencyCode: "USD")
            XCTAssertEqual(CurrencyText.parseMinorUnits(text, currencyCode: "USD"), value)
        }
    }

    @MainActor
    func testProductionDemoSeedReconcilesOpeningAccountsDatedPlanAndCardReserves() throws {
        let demo = DemoStore()
        let opening = try XCTUnwrap(demo.fixtureOpening)
        XCTAssertEqual(opening.month.iso, "2025-10-01")
        XCTAssertThrowsError(try demo.fixturePlanningSnapshot(month: "2025-09-01"))
        XCTAssertTrue(demo.transactions.allSatisfy { !$0.scheduled && $0.date <= .demo(monthsAgo: 0, day: 15) })
        for account in demo.accounts {
            let posted = demo.transactions.filter { $0.accountID == account.id }
            let balance = try XCTUnwrap(demo.fixtureAccountOpening[account.id])
            XCTAssertEqual(account.balance, balance + posted.reduce(0) { $0 + $1.amount }, account.id)
            XCTAssertEqual(account.cleared, balance + posted.filter(\.cleared).reduce(0) { $0 + $1.amount }, account.id)
        }
        let plan = try demo.fixturePlanningSnapshot(month: "2026-09-01")
        XCTAssertEqual(plan.allDateUnassignedMinor, demo.readyToAssign)
        XCTAssertEqual(plan.categories["groceries"]?.assignedMinor, 72_000)
        XCTAssertEqual(plan.categories["groceries"]?.activityMinor, -12_500)
        for category in demo.categories {
            XCTAssertEqual(plan.categories[category.id]?.availableMinor, category.available)
            XCTAssertEqual(plan.categories[category.id]?.activityMinor, category.activity)
            XCTAssertEqual(plan.categories[category.id]?.assignedMinor, category.assigned)
        }
        let cards = demo.accounts.filter { $0.kind == .credit }
        let currentUnfunded = cards.reduce(Int64(0)) { $0 + max(-$1.balance - $1.paymentReserved, 0) }
        let openingUnfunded = cards.reduce(Int64(0)) { $0 + max(-(demo.fixtureAccountOpening[$1.id] ?? 0), 0) }
        let cash = demo.accounts.filter { $0.isOnBudget && [.checking, .savings, .cash].contains($0.kind) }.reduce(Int64(0)) { $0 + $1.balance }
        XCTAssertEqual(cash, demo.readyToAssign + demo.categories.reduce(0) { $0 + $1.available }
                       + cards.reduce(0) { $0 + $1.paymentReserved } + currentUnfunded - openingUnfunded)
        XCTAssertTrue(cards.allSatisfy { $0.paymentReserved >= 0 })
        XCTAssertEqual(currentUnfunded - openingUnfunded, 4_840, "Only the deliberate dining deficit is new unfunded debt")
        let again = DemoStore()
        XCTAssertEqual(demo.allocationEvents.map(\.id), again.allocationEvents.map(\.id))
        XCTAssertEqual(demo.fixtureOpening, again.fixtureOpening)
        let fresh = DemoStore(fresh: true)
        XCTAssertNil(fresh.fixtureOpening)
        XCTAssertTrue(fresh.accounts.isEmpty && fresh.transactions.isEmpty && fresh.categories.isEmpty && fresh.allocationEvents.isEmpty)
    }

    @MainActor
    func testSeedIsDeterministicAndHasTwelveMonthsOfActivity() {
        let first = DemoStore()
        let second = DemoStore()
        XCTAssertEqual(first.accounts, second.accounts)
        XCTAssertEqual(first.categories, second.categories)
        XCTAssertEqual(first.transactions, second.transactions)
        XCTAssertGreaterThanOrEqual(first.transactions.count, 70)
    }

    @MainActor
    func testChildVisibilityExcludesHouseholdAccountsAndOtherCategories() {
        let store = DemoStore()
        store.persona = .alex
        XCTAssertTrue(store.visibleAccounts.isEmpty)
        XCTAssertEqual(Set(store.visibleCategories.map(\.id)), ["alexallow", "alexsave", "alexgive"])
        XCTAssertTrue(store.visibleTransactions.allSatisfy { $0.member == .alex })
    }

    @MainActor
    func testMoveMoneyPreservesTotalAvailable() {
        let store = DemoStore()
        let before = store.categories.reduce(Int64(0)) { $0 + $1.available }
        store.move(amount: 5_000, from: "emergency", to: "fuel")
        XCTAssertEqual(store.categories.reduce(Int64(0)) { $0 + $1.available }, before)
    }

    @MainActor
    func testDemoRequestApprovalHonorsSelectedSourceAndRejectsSecondMutation() async throws {
        let source = DemoWorkspaceDataSource()
        let buffer = try XCTUnwrap(source.demo.categories.first { $0.id == "buffer" })
        let funding = try XCTUnwrap(source.demo.categories.first { $0.id == "emergency" })
        let destination = try XCTUnwrap(source.demo.categories.first { $0.id == "alexallow" })
        try await source.decideRequest(id: "request-game", decision: "approve", version: 0, amount: 2_000, sourceCategoryID: funding.id, note: "Selected source")
        XCTAssertEqual(source.demo.categories.first { $0.id == buffer.id }?.available, buffer.available)
        XCTAssertEqual(source.demo.categories.first { $0.id == funding.id }?.available, funding.available - 2_000)
        XCTAssertEqual(source.demo.categories.first { $0.id == destination.id }?.available, destination.available + 2_000)
        let categories = source.demo.categories
        let requests = source.demo.requests
        let eventIDs = source.demo.allocationEvents.map(\.id)
        do {
            try await source.decideRequest(id: "request-game", decision: "approve", version: 0, amount: 2_000, sourceCategoryID: funding.id, note: "Duplicate")
            XCTFail("A decided request must not allocate twice")
        } catch {}
        XCTAssertEqual(source.demo.categories, categories)
        XCTAssertEqual(source.demo.requests, requests)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), eventIDs)
    }

    @MainActor
    func testDemoOwnerCanConfigureDelegatedPolicyWithServerEquivalentFunding() async throws {
        let source = DemoWorkspaceDataSource()
        let query = WorkspaceReportQuery(
            start: BudgetWorkspaceStore.parseDate("2026-09-01"), end: BudgetWorkspaceStore.parseDate("2026-09-30"),
            accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "",
            transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category",
            includeTracking: true
        )
        let before = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        let beforeSummary = try XCTUnwrap(before.summary)
        let rta = beforeSummary.readyToAssignMinor
        let poolAssigned = try XCTUnwrap(beforeSummary.categories.first { $0.categoryID == "alexallow" }).assignedMinor

        try await source.updateDelegatedPolicy(userID: "alex", value: .init(
            userID: "alex", poolCategoryID: "alexallow", authorityMinor: 10_000,
            allowCategoryCreation: false, allowReallocation: true,
            expectedAllocationVersion: beforeSummary.allocationVersion,
            rules: [.init(categoryID: "alexsave", ruleKind: "soft_target", minimumMinor: 1_000, maximumMinor: 5_000)]
        ))

        let after = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        let afterSummary = try XCTUnwrap(after.summary)
        let policy = try XCTUnwrap(after.delegatedBudgets.first { $0.userID == "alex" })
        XCTAssertEqual(policy.authorityMinor, 10_000)
        XCTAssertFalse(policy.allowCategoryCreation)
        XCTAssertTrue(policy.allowReallocation)
        XCTAssertEqual(policy.rules.first?.categoryID, "alexsave")
        XCTAssertEqual(afterSummary.readyToAssignMinor, rta - 3_200)
        XCTAssertEqual(afterSummary.categories.first { $0.categoryID == "alexallow" }?.assignedMinor, poolAssigned + 3_200)
        XCTAssertEqual(source.demo.allocationEvents.last?.kind, "delegated_authority")
        XCTAssertEqual(source.demo.allocationEvents.last?.amountMinor, 3_200)
        let history = try await source.delegatedPolicyHistory(userID: "alex", limit: 50, offset: 0)
        XCTAssertEqual(history.map(\.action), ["created"])
        XCTAssertEqual(history.first?.afterSnapshot.authorityMinor, 10_000)
        XCTAssertEqual(history.first?.afterSnapshot.rules.first?.categoryID, "alexsave")
        XCTAssertEqual(history.first?.actorDisplayName, "Rey")

        // Re-saving the exact same policy is a no-op decision and does not manufacture history.
        let currentSnapshot = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        let currentVersion = try XCTUnwrap(currentSnapshot.summary?.allocationVersion)
        var editor = DelegatedPolicyEditorDraft()
        editor.prepare(scope: "owner|budget|alex", policy: policy, fallbackCategoryID: nil,
                       currencyCode: "USD", allocationVersion: currentVersion)
        try await source.updateDelegatedPolicy(userID: "alex", value: XCTUnwrap(editor.mutation(userID: "alex", currencyCode: "USD")))
        let historyAfterNoOp = try await source.delegatedPolicyHistory(userID: "alex", limit: 50, offset: 0)
        XCTAssertEqual(historyAfterNoOp, history)
        let reloaded = try await source.snapshot(planMonth: BudgetWorkspaceStore.parseDate("2026-09-01"), report: query)
        XCTAssertEqual(reloaded.delegatedBudgets.first { $0.userID == "alex" }?.rules, policy.rules)
        XCTAssertEqual(reloaded.summary?.readyToAssignMinor, currentSnapshot.summary?.readyToAssignMinor)
    }

    @MainActor
    func testDemoDelegatedPolicyRejectsStaleOrUnauthorizedMutationAtomically() async throws {
        let source = DemoWorkspaceDataSource()
        let categories = source.demo.categories
        let rta = source.demo.unassignedMinor
        let eventIDs = source.demo.allocationEvents.map(\.id)
        do {
            try await source.updateDelegatedPolicy(userID: "alex", value: .init(
                userID: "alex", poolCategoryID: "alexallow", authorityMinor: 10_000,
                allowCategoryCreation: true, allowReallocation: true, expectedAllocationVersion: 99
            ))
            XCTFail("A stale policy must be rejected")
        } catch {}
        XCTAssertEqual(source.demo.categories, categories)
        XCTAssertEqual(source.demo.unassignedMinor, rta)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), eventIDs)

        source.demo.persona = .alex
        do {
            try await source.updateDelegatedPolicy(userID: "alex", value: .init(
                userID: "alex", poolCategoryID: "alexallow", authorityMinor: 10_000,
                allowCategoryCreation: true, allowReallocation: true, expectedAllocationVersion: 0
            ))
            XCTFail("A delegated member must not edit authority")
        } catch {}
        XCTAssertEqual(source.demo.categories, categories)
        XCTAssertEqual(source.demo.unassignedMinor, rta)
        XCTAssertEqual(source.demo.allocationEvents.map(\.id), eventIDs)
    }

    @MainActor
    func testDemoRequestApprovalRefusesInvalidOrUnauthorizedIntentWithoutMutation() async throws {
        for scenario in ["restricted", "stale", "missing-source", "missing-destination", "same-category", "archived-source", "archived-group", "zero", "negative", "excess", "insufficient", "overflow"] {
            let source = DemoWorkspaceDataSource()
            var amount: Int64 = 2_000
            var categoryID = "buffer"
            var version = 0
            let buffer = try XCTUnwrap(source.demo.categories.firstIndex { $0.id == "buffer" })
            let request = try XCTUnwrap(source.demo.requests.firstIndex { $0.id == "request-game" })
            switch scenario {
            case "restricted": source.demo.persona = .alex
            case "stale": version = 1
            case "missing-source": categoryID = "missing"
            case "missing-destination": source.demo.requests[request].categoryID = "missing"
            case "same-category": categoryID = "alexallow"
            case "archived-source": source.demo.categories[buffer].isHidden = true
            case "archived-group": source.demo.archivedGroups.insert(source.demo.categories[buffer].group)
            case "zero": amount = 0
            case "negative": amount = -1
            case "excess": amount = 3_501
            case "insufficient":
                let available = try source.demo.planningSnapshot(month: source.demo.currentPlanningMonth).categories["buffer"]!.availableMinor
                XCTAssertTrue(source.demo.move(amount: available - 1, from: "buffer", to: "mortgage"))
            case "overflow":
                let assigned = try source.demo.planningSnapshot(month: source.demo.currentPlanningMonth).categories["alexallow"]!.assignedMinor
                // Adversarial ledger input, not corruption of a disposable display projection.
                source.demo.recordAllocation(amount: Int64.max - assigned, to: "alexallow")
            default: XCTFail("Unknown scenario")
            }
            let categories = source.demo.categories, requests = source.demo.requests
            let accounts = source.demo.accounts, transactions = source.demo.transactions
            let unassigned = source.demo.unassignedMinor
            let eventIDs = source.demo.allocationEvents.map(\.id)
            do {
                try await source.decideRequest(id: "request-game", decision: "approve", version: version, amount: amount, sourceCategoryID: categoryID, note: "Invalid")
                XCTFail("Approval should refuse \(scenario)")
            } catch {}
            XCTAssertEqual(source.demo.categories, categories, scenario)
            XCTAssertEqual(source.demo.requests, requests, scenario)
            XCTAssertEqual(source.demo.accounts, accounts, scenario)
            XCTAssertEqual(source.demo.transactions, transactions, scenario)
            XCTAssertEqual(source.demo.unassignedMinor, unassigned, scenario)
            XCTAssertEqual(source.demo.allocationEvents.map(\.id), eventIDs, scenario)
        }
    }

    @MainActor
    func testPartialApprovalFundsOnlyApprovedAmount() {
        let store = DemoStore()
        let before = store.categories.first { $0.id == "alexallow" }!.available
        let sourceBefore = store.categories.first { $0.id == "buffer" }!.available
        store.approve("request-game", amount: 2_000)
        XCTAssertEqual(store.requests.first { $0.id == "request-game" }?.status, "Partially approved")
        XCTAssertEqual(store.categories.first { $0.id == "alexallow" }?.available, before + 2_000)
        XCTAssertEqual(store.categories.first { $0.id == "buffer" }?.available, sourceBefore - 2_000)
    }

    @MainActor
    func testHideAmountsMasksCurrency() {
        let store = DemoStore()
        store.hideAmounts = true
        XCTAssertEqual(store.money(123_45), "••••")
    }

    @MainActor
    func testSmartAssignmentConsumesReadyToAssignWithoutCreatingMoney() {
        let store = DemoStore()
        let before = store.readyToAssign + store.categories.reduce(0) { $0 + $1.available }
        store.assign(amount: 12_345, to: "fuel")
        XCTAssertEqual(store.readyToAssign + store.categories.reduce(0) { $0 + $1.available }, before)
    }

    @MainActor
    func testSplitTransactionPreservesEveryMinorUnit() {
        let store = DemoStore()
        let before = store.categories.filter { ["groceries", "dining", "fuel"].contains($0.id) }.reduce(0) { $0 + $1.available }
        store.addTransaction(payee: "Split", amount: 101, accountID: "checking", categoryIDs: ["groceries", "dining", "fuel"], memo: "", attachment: false)
        let after = store.categories.filter { ["groceries", "dining", "fuel"].contains($0.id) }.reduce(0) { $0 + $1.available }
        XCTAssertEqual(before - after, 101)
    }

    @MainActor
    func testSharedEditorPreservesExactSplitsAndChangedDate() {
        let store = DemoStore()
        let changedDate = Date.demo(monthsAgo: 2, day: 14)
        XCTAssertTrue(store.updateTransactionSigned(
            id: "t4", payee: "Corrected split", signedAmount: -12_640,
            date: changedDate, accountID: "checking",
            categoryAmounts: ["repair": -10_001, "maintenance": -2_639],
            memo: "Exact correction", cleared: true, flag: "Reviewed",
            tags: ["home"], attachmentName: "invoice.pdf"
        ))
        let transaction = store.transactions.first { $0.id == "t4" }!
        XCTAssertEqual(transaction.date, changedDate)
        XCTAssertEqual(transaction.categoryAmounts, ["repair": -10_001, "maintenance": -2_639])
        XCTAssertEqual(transaction.tags, ["home"])
        XCTAssertEqual(transaction.attachmentName, "invoice.pdf")
    }

    @MainActor
    func testEditingCategoryPropagatesToInsightsAndBalances() {
        let store = DemoStore()
        let diningBefore = store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "dining" }!.1
        let groceriesBefore = store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "groceries" }!.1
        let balanceBefore = store.accounts.first { $0.id == "visa" }!.balance
        XCTAssertTrue(store.updateTransaction(id: "t1", payee: "Fresh Market", amount: 12_500, accountID: "visa", categoryIDs: ["dining"], memo: "Corrected", cleared: true, flag: nil))
        XCTAssertEqual(store.accounts.first { $0.id == "visa" }!.balance, balanceBefore)
        XCTAssertEqual(store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "dining" }!.1, diningBefore + 12_500)
        XCTAssertNil(store.spendingByCategory(in: .thirtyDays).first { $0.0.id == "groceries" && $0.1 == groceriesBefore })
    }

    @MainActor
    func testReconcileCreatesExplicitAdjustmentAndUpdatesBalance() {
        let store = DemoStore()
        let accountBefore = store.accounts.first { $0.id == "checking" }!
        let statement = accountBefore.cleared + 1_000
        XCTAssertTrue(store.reconcile(accountID: "checking", statementBalance: statement, createAdjustment: true), store.errorMessage ?? "")
        let accountAfter = store.accounts.first { $0.id == "checking" }!
        XCTAssertEqual(accountAfter.cleared, statement)
        XCTAssertEqual(accountAfter.balance, accountBefore.balance + 1_000)
        XCTAssertEqual(store.transactions.first?.payee, "Reconciliation adjustment")
        XCTAssertTrue(store.transactions.first?.reconciled == true)
    }

    @MainActor
    func testDelegatedCategoryCreationCannotExceedAuthority() {
        let store = DemoStore()
        store.persona = .alex
        let available = store.delegatedReadyToAssign
        XCTAssertFalse(store.createCategory(name: "Too Much", initialAssignment: available + 1))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.createCategory(name: "Concert", initialAssignment: available))
        XCTAssertEqual(store.delegatedReadyToAssign, 0)
        XCTAssertEqual(store.visibleCategories.last?.name, "Concert")
    }

    @MainActor
    func testDelegatedMoveCannotTouchParentCategory() {
        let store = DemoStore()
        store.persona = .alex
        XCTAssertFalse(store.move(amount: 100, from: "alexallow", to: "groceries"))
        XCTAssertEqual(store.errorMessage, DemoMutationError.restrictedCategory.localizedDescription)
    }

    @MainActor
    private func render<Content: View>(_ view: Content) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private func renderedContentSignal<Content: View>(_ view: Content) -> Int {
        let controller = UIHostingController(rootView: view)
        let frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let window = UIWindow(frame: frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func contentSignal() -> Int {
          let image = UIGraphicsImageRenderer(size: frame.size).image { _ in
              controller.view.drawHierarchy(in: frame, afterScreenUpdates: true)
          }
          guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
          let width = cgImage.width, height = cgImage.height, bytesPerRow = cgImage.bytesPerRow
          var signal = 0
          // Exclude tab/navigation chrome: those controls must not make a blank tab pass.
          for y in stride(from: height / 5, to: height * 3 / 4, by: 3) {
            for x in stride(from: width / 12, to: width * 11 / 12, by: 3) {
              let offset = y * bytesPerRow + x * 4
              let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
              if max(r, g, b) - min(r, g, b) > 28 || max(r, g, b) < 175 { signal += 1 }
            }
          }
          return signal
        }
        let signal = contentSignal()
        window.isHidden = true
        window.rootViewController = nil
        return signal
    }
    func testLocalDelimitedStatementParserRejectsAmbiguousMappingAndHeaders() throws {
        let mapping = APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        for header in ["Date,Amount,Amount,Payee", "Date,Amount, Amount ,Payee", "Date,Amount,,Payee"] {
            XCTAssertTrue(LocalDelimitedStatementParser.headers(data: Data("\(header)\n".utf8), delimiter: ",").isEmpty)
            XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(data: Data("\(header)\n2026-09-04,-1.00,-9.00,Market\n".utf8), mapping: mapping))
        }
        let data = Data("Date,Amount,Payee\n2026-09-04,-1.00,Market\n".utf8)
        for invalid in [
            APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount", payeeColumn: "Payee", memoColumn: "Missing", dateOrder: "ymd"),
            APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount", payeeColumn: "Payee", memoColumn: "Payee", dateOrder: "ymd"),
            APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount", payeeColumn: "Payee", debitColumn: "Amount", creditColumn: "Payee", dateOrder: "ymd")
        ] {
            XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(data: data, mapping: invalid))
        }
        XCTAssertEqual(try LocalDelimitedStatementParser.parse(data: data, mapping: mapping).first?.amountMinor, -100)
    }

    func testLocalDelimitedStatementParserRejectsOverlongMetadataWithoutTruncation() throws {
        let mapping = APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount", payeeColumn: "Payee", memoColumn: "Memo", dateOrder: "ymd")
        for (payee, memo) in [(String(repeating: "p", count: 151), ""), ("Market", String(repeating: "m", count: 501)),
                              (String(repeating: "e\u{301}", count: 76), "")] {
            let data = Data("Date,Amount,Payee,Memo\n2026-09-04,-1.00,\(payee),\(memo)\n".utf8)
            XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(data: data, mapping: mapping)) { error in
                XCTAssertFalse(error.localizedDescription.contains(payee))
                if !memo.isEmpty { XCTAssertFalse(error.localizedDescription.contains(memo)) }
            }
        }
        let payee = String(repeating: "p", count: 150), memo = String(repeating: "m", count: 500)
        let rows = try LocalDelimitedStatementParser.parse(data: Data("Date,Amount,Payee,Memo\n2026-09-04,-1.00,\(payee),\(memo)\n".utf8), mapping: mapping)
        XCTAssertEqual(rows.first?.payee, payee); XCTAssertEqual(rows.first?.memo, memo)
        XCTAssertEqual(rows.first?.amountMinor, -100)
    }

    func testLocalDelimitedStatementParserPreservesExactMoneyAndQuotedFields() throws {
        let data = Data("Date,Description,Amount,Memo\n09/15/2026,\"Corner, Market\",-12.34,\"weekly, food\"\n09/16/2026,Refund,2.50,\n".utf8)
        let rows = try LocalDelimitedStatementParser.parse(data: data, mapping: .init(
            sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount",
            payeeColumn: "Description", memoColumn: "Memo", dateOrder: "mdy"
        ))
        XCTAssertEqual(rows.map(\.amountMinor), [-1_234, 250])
        XCTAssertEqual(rows.map(\.payee), ["Corner, Market", "Refund"])
        XCTAssertEqual(rows.first?.memo, "weekly, food")
        XCTAssertEqual(rows.map(\.occurredOn), ["2026-09-15", "2026-09-16"])
    }

    func testLocalDelimitedStatementParserUsesExplicitNumberConvention() throws {
        let commaDecimal = try LocalDelimitedStatementParser.parse(
            data: Data("Date;Description;Amount\n15/09/2026;Market;-1.234,56\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "EUR", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Description", dateOrder: "dmy",
                           delimiter: ";", numberFormat: "comma_decimal")
        )
        XCTAssertEqual(commaDecimal.first?.amountMinor, -123_456)

        let dotDecimal = try LocalDelimitedStatementParser.parse(
            data: Data("Date;Description;Amount\n2026-09-15;Market;1,234.56\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Description", dateOrder: "ymd",
                           delimiter: ";", numberFormat: "dot_decimal")
        )
        XCTAssertEqual(dotDecimal.first?.amountMinor, 123_456)

        XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(
            data: Data("Date;Description;Amount\n2026-09-15;Private;1.234,56\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Description", dateOrder: "ymd",
                           delimiter: ";", numberFormat: "dot_decimal")
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains("Private"))
            XCTAssertTrue(error.localizedDescription.contains("selected number format"))
        }

        XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(
            data: Data("Date;Description;Debit;Credit\n2026-09-15;Private;-1.00;\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           payeeColumn: "Description", debitColumn: "Debit", creditColumn: "Credit",
                           dateOrder: "ymd", delimiter: ";")
        ))
    }

    func testLocalDelimitedStatementParserUsesExplicitDateOrderWithCommonSeparators() throws {
        for (order, value) in [("ymd", "2026/9/18"), ("mdy", "9-18-2026"), ("dmy", "18.09.2026")] {
            let rows = try LocalDelimitedStatementParser.parse(
                data: Data("Date;Description;Amount\n\(value);Market;-1.00\n".utf8),
                mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                               amountColumn: "Amount", payeeColumn: "Description", dateOrder: order,
                               delimiter: ";")
            )
            XCTAssertEqual(rows.first?.occurredOn, "2026-09-18")
        }

        for malformed in ["2026/09-18", "09.18/2026", "9/18/26"] {
            XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(
                data: Data("Date;Description;Amount\n\(malformed);Private;-1.00\n".utf8),
                mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                               amountColumn: "Amount", payeeColumn: "Description",
                               dateOrder: malformed.hasPrefix("2026") ? "ymd" : "mdy", delimiter: ";")
            )) { error in XCTAssertFalse(error.localizedDescription.contains("Private")) }
        }
    }

    func testLocalDelimitedStatementParserAcceptsBOMMarkedUTF16() throws {
        let source = "Date,Description,Amount\r\n2026-09-18,Caf\u{00e9},-12.34\r\n"
        for littleEndian in [true, false] {
            var data = Data(littleEndian ? [0xff, 0xfe] : [0xfe, 0xff])
            for unit in source.utf16 {
                let low = UInt8(unit & 0xff), high = UInt8(unit >> 8)
                data.append(contentsOf: littleEndian ? [low, high] : [high, low])
            }
            XCTAssertEqual(LocalDelimitedStatementParser.headers(data: data, delimiter: ","),
                           ["Date", "Description", "Amount"])
            let rows = try LocalDelimitedStatementParser.parse(
                data: data,
                mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                               amountColumn: "Amount", payeeColumn: "Description", dateOrder: "ymd")
            )
            XCTAssertEqual(rows.first?.payee, "Caf\u{00e9}")
            XCTAssertEqual(rows.first?.amountMinor, -1234)
        }

        var unmarked = Data()
        for unit in source.utf16 {
            unmarked.append(contentsOf: [UInt8(unit & 0xff), UInt8(unit >> 8)])
        }
        XCTAssertThrowsError(try LocalDelimitedStatementParser.parse(
            data: unmarked,
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Description", dateOrder: "ymd")
        ))
    }

    func testLocalQIFParserPreservesExactMoneyAndExplicitDateOrder() throws {
        let data = Data("!Type:Bank\nD10/02/2026\nT-1,234.56\nPUtility Company\nMSeptember bill\n^\nD03/10/'26\nT25.00\nPRefund\n^\n".utf8)
        let rows = try LocalQIFStatementParser.parse(data: data, mapping: .init(
            sourceFormat: "qif", currencyCode: "USD", dateOrder: "mdy"
        ))
        XCTAssertEqual(rows.map(\.amountMinor), [-123_456, 2_500])
        XCTAssertEqual(rows.map(\.occurredOn), ["2026-10-02", "2026-03-10"])
        XCTAssertEqual(rows.map(\.payee), ["Utility Company", "Refund"])
        XCTAssertEqual(rows.first?.memo, "September bill")

        let dmy = try LocalQIFStatementParser.parse(
            data: Data("D31/12/'69\nT1.00\nPInterest\n^\nD01/01/'70\nT1.00\nPInterest\n^".utf8),
            mapping: .init(sourceFormat: "qif", currencyCode: "USD", dateOrder: "dmy")
        )
        XCTAssertEqual(dmy.map(\.occurredOn), ["2069-12-31", "1970-01-01"])
    }

    func testLocalQIFParserRejectsMalformedPrivateRowsWithoutLeakingContents() throws {
        let privatePayee = "Private Medical Payee"
        XCTAssertThrowsError(try LocalQIFStatementParser.parse(
            data: Data("D02/30/2026\nT1.00\nP\(privatePayee)\n^".utf8),
            mapping: .init(sourceFormat: "qif", currencyCode: "USD", dateOrder: "mdy")
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains(privatePayee))
            XCTAssertTrue(error.localizedDescription.contains("record 1"))
        }
        XCTAssertThrowsError(try LocalQIFStatementParser.parse(
            data: Data("D10/02/2026\nT1e2\nP\(privatePayee)\n^".utf8),
            mapping: .init(sourceFormat: "qif", currencyCode: "USD", dateOrder: "mdy")
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains(privatePayee))
        }
    }

    func testLocalOFXParserSupportsSGMLAndXMLWithExactSignedMoney() throws {
        let data = Data("""
        OFXHEADER:100
        <OFX><BANKTRANLIST>
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260914120000[-4:EDT]<TRNAMT>-12.34<NAME>Corner Store<MEMO>card purchase
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260915</DTPOSTED><TRNAMT>2.34</TRNAMT><PAYEE>Corner Store</PAYEE><MEMO>refund</MEMO></STMTTRN>
        </BANKTRANLIST></OFX>
        """.utf8)
        let rows = try LocalOFXStatementParser.parse(
            data: data,
            mapping: .init(sourceFormat: "ofx", currencyCode: "USD")
        )
        XCTAssertEqual(rows.map(\.occurredOn), ["2026-09-14", "2026-09-15"])
        XCTAssertEqual(rows.map(\.amountMinor), [-1_234, 234])
        XCTAssertEqual(rows.map(\.payee), ["Corner Store", "Corner Store"])
        XCTAssertEqual(rows.map(\.memo), ["card purchase", "refund"])
    }

    func testLocalOFXParserRejectsDeclarationsAndPrivateMalformedRows() throws {
        let privatePayee = "Private Medical Payee"
        let unsafe = Data("<!DOCTYPE OFX [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20260914<TRNAMT>1</STMTTRN></BANKTRANLIST></OFX>".utf8)
        XCTAssertThrowsError(try LocalOFXStatementParser.parse(data: unsafe, mapping: .init(sourceFormat: "ofx", currencyCode: "USD"))) { error in
            XCTAssertFalse(error.localizedDescription.contains("passwd"))
            XCTAssertTrue(error.localizedDescription.contains("not supported"))
        }
        let malformed = Data("<OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20260230<TRNAMT>1<NAME>\(privatePayee)</STMTTRN></BANKTRANLIST></OFX>".utf8)
        XCTAssertThrowsError(try LocalOFXStatementParser.parse(data: malformed, mapping: .init(sourceFormat: "qfx", currencyCode: "USD"))) { error in
            XCTAssertFalse(error.localizedDescription.contains(privatePayee))
            XCTAssertTrue(error.localizedDescription.contains("record 1"))
        }
    }

    func testLocalMT940ParserPreservesExactMoneyAndDescriptions() throws {
        let data = Data("""
        :20:START
        :60F:C261001EUR1000,00
        :61:2610021002D12,34NTRFNONREF
        :86:Corner Market
        weekly groceries
        :61:261003C2,34NTRFREFUND
        :86:Corner Market refund
        :62F:C261003EUR990,00
        """.utf8)
        let rows = try LocalMT940StatementParser.parse(
            data: data, mapping: .init(sourceFormat: "mt940", currencyCode: "USD")
        )
        XCTAssertEqual(rows.map(\.occurredOn), ["2026-10-02", "2026-10-03"])
        XCTAssertEqual(rows.map(\.amountMinor), [-1_234, 234])
        XCTAssertEqual(rows.map(\.payee), ["Corner Market weekly groceries", "Corner Market refund"])
    }

    func testLocalMT940ParserRejectsMalformedPrivateRowsWithoutLeakingContents() throws {
        let privatePayee = "Private Medical Payee"
        XCTAssertThrowsError(try LocalMT940StatementParser.parse(
            data: Data(":61:260230D1,00NTRF\n:86:\(privatePayee)\n".utf8),
            mapping: .init(sourceFormat: "mt940", currencyCode: "USD")
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains(privatePayee))
            XCTAssertTrue(error.localizedDescription.contains("record 1"))
        }
    }

    func testLocalCAMTParserPreservesExactMoneyAndDescriptions() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"><BkToCstmrStmt><Stmt>
          <Ntry><Amt Ccy="USD">12.34</Amt><CdtDbtInd>DBIT</CdtDbtInd><BookgDt><Dt>2026-10-01</Dt></BookgDt>
            <NtryDtls><TxDtls><RltdPties><Dbtr><Pty><Nm>Account Owner</Nm></Pty></Dbtr><Cdtr><Pty><Nm>Corner Market</Nm></Pty></Cdtr></RltdPties><RmtInf><Ustrd>Weekly groceries</Ustrd></RmtInf></TxDtls></NtryDtls></Ntry>
          <Ntry><Amt Ccy="USD">1000.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><ValDt><Dt>2026-10-02</Dt></ValDt><NtryDtls><TxDtls><RltdPties><Dbtr><Pty><Nm>Employer</Nm></Pty></Dbtr><Cdtr><Pty><Nm>Account Owner</Nm></Pty></Cdtr></RltdPties></TxDtls></NtryDtls><AddtlNtryInf>Payroll deposit</AddtlNtryInf></Ntry>
        </Stmt></BkToCstmrStmt></Document>
        """.utf8)
        let rows = try LocalCAMTStatementParser.parse(data: data, mapping: .init(sourceFormat: "camt", currencyCode: "USD"))
        XCTAssertEqual(rows.map(\.occurredOn), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(rows.map(\.amountMinor), [-1_234, 100_000])
        XCTAssertEqual(rows.map(\.payee), ["Corner Market", "Employer"])
        XCTAssertEqual(rows.map(\.memo), ["Weekly groceries", "Payroll deposit"])
    }

    func testLocalCAMTParserRejectsDeclarationsWithoutLeakingPrivateContent() throws {
        let privateValue = "Private Medical Payee"
        let data = Data("<!DOCTYPE x [<!ENTITY secret '\(privateValue)'>]><Document><Ntry>&secret;</Ntry></Document>".utf8)
        XCTAssertThrowsError(try LocalCAMTStatementParser.parse(data: data, mapping: .init(sourceFormat: "camt", currencyCode: "USD"))) { error in
            XCTAssertFalse(error.localizedDescription.contains(privateValue))
            XCTAssertTrue(error.localizedDescription.contains("not supported"))
        }
    }

    func testLocalPDFParserRecognizesOnlyExplicitSignedRows() throws {
        let rows = try LocalPDFStatementParser.parse(lines: [
            "Statement for September",
            "09/14/2026 Corner Market -12.34",
            "09/15/2026 Payroll +1,234.56",
            "Ending balance 9,999.99",
            "09/16/2026 Card purchase (2.00)",
        ], mapping: .init(sourceFormat: "pdf", currencyCode: "USD", dateOrder: "mdy"))
        XCTAssertEqual(rows.map(\.sourceRow), [2, 3, 5])
        XCTAssertEqual(rows.map(\.occurredOn), ["2026-09-14", "2026-09-15", "2026-09-16"])
        XCTAssertEqual(rows.map(\.amountMinor), [-1_234, 123_456, -200])
        XCTAssertEqual(rows.map(\.payee), ["Corner Market", "Payroll", "Card purchase"])
    }

    func testLocalPDFParserRejectsAmbiguousRowsAndPrivateMalformedData() throws {
        let privateText = "Private Medical Merchant"
        XCTAssertThrowsError(try LocalPDFStatementParser.parse(
            lines: ["09/14/2026 \(privateText) 12.34"],
            mapping: .init(sourceFormat: "pdf", currencyCode: "USD", dateOrder: "mdy")
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains(privateText))
            XCTAssertTrue(error.localizedDescription.contains("no unambiguous signed"))
        }
        XCTAssertThrowsError(try LocalPDFStatementParser.parse(
            lines: ["02/30/2026 \(privateText) -12.34"],
            mapping: .init(sourceFormat: "pdf", currencyCode: "USD", dateOrder: "mdy")
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains(privateText))
            XCTAssertTrue(error.localizedDescription.contains("line 1"))
        }
    }

    func testScannedPDFReviewRowsPreserveExactMoneyAndEscapedDescriptions() throws {
        let candidates = try LocalPDFStatementParser.parse(lines: [
            "09/14/2026 Corner, \"Market\" -12.34",
            "09/15/2026 Payroll +1,234.56",
        ], mapping: .init(sourceFormat: "pdf", currencyCode: "USD", dateOrder: "mdy"))
        let data = StatementOCRStaging.delimitedData(candidates, currencyCode: "USD")
        let mapping = StatementOCRStaging.mapping(currencyCode: "USD")
        let reparsed = try LocalDelimitedStatementParser.parse(data: data, mapping: mapping)
        XCTAssertEqual(reparsed.map(\.occurredOn), ["2026-09-14", "2026-09-15"])
        XCTAssertEqual(reparsed.map(\.amountMinor), [-1_234, 123_456])
        XCTAssertEqual(reparsed.map(\.payee), ["Corner, \"Market\"", "Payroll"])
        XCTAssertEqual(mapping.sourceFormat, "pdf_ocr")
    }

    func testScannedPDFReviewRowsSupportZeroDigitCurrencyWithoutRounding() throws {
        let candidate = LocalDelimitedStatementParser.Candidate(
            sourceRow: 1, occurredOn: "2026-09-14", amountMinor: -1_234,
            payee: "Tokyo Market", memo: "Exact JPY"
        )
        let mapping = StatementOCRStaging.mapping(currencyCode: "JPY")
        let reparsed = try LocalDelimitedStatementParser.parse(
            data: StatementOCRStaging.delimitedData([candidate], currencyCode: "JPY"), mapping: mapping
        )
        XCTAssertEqual(reparsed.first?.amountMinor, -1_234)
    }

    @MainActor
    func testLocalPDFDocumentUsesMoneyNeutralStatementStaging() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            "09/15/2026 Interest +4.50".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let initialTransactions = source.demo.transactions
        let batch = try await source.stageStatementImport(
            accountID: account.id,
            data: data,
            mapping: .init(sourceFormat: "pdf", currencyCode: "USD", dateOrder: "mdy")
        )
        XCTAssertEqual(batch.sourceFormat, "pdf")
        XCTAssertEqual(batch.candidates.first?.amountMinor, 450)
        XCTAssertEqual(batch.candidates.first?.payee, "Interest")
        XCTAssertEqual(source.demo.transactions, initialTransactions)
    }

    @MainActor
    func testLocalOFXUsesOwnedMoneyNeutralStatementStaging() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let initialTransactions = source.demo.transactions
        let batch = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("<OFX><BANKTRANLIST><STMTTRN><DTPOSTED>20260915<TRNAMT>4.50<NAME>Interest</STMTTRN></BANKTRANLIST></OFX>".utf8),
            mapping: .init(sourceFormat: "ofx", currencyCode: "USD")
        )
        XCTAssertEqual(batch.sourceFormat, "ofx")
        XCTAssertEqual(batch.candidates.first?.amountMinor, 450)
        XCTAssertEqual(batch.candidates.first?.payee, "Interest")
        XCTAssertEqual(source.demo.transactions, initialTransactions)
    }

    @MainActor
    func testLocalStatementApprovalUsesCanonicalTransactionPath() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let initialCount = source.demo.transactions.count
        let batch = try await source.stageStatementImport(accountID: account.id,
            data: Data("Date,Description,Debit,Credit\n09/15/2026,Local deposit,,10.25\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           payeeColumn: "Description", debitColumn: "Debit", creditColumn: "Credit", dateOrder: "mdy"))
        XCTAssertEqual(batch.candidates.first?.amountMinor, 1_025)
        _ = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
            approval: .init(expectedVersion: batch.version, items: [.init(sourceRow: 2, action: "post")]))
        XCTAssertEqual(source.demo.transactions.count, initialCount + 1)
        XCTAssertEqual(source.demo.transactions.first(where: { $0.payee == "Local deposit" })?.amount, 1_025)
        XCTAssertEqual(source.demo.transactions.first(where: { $0.payee == "Local deposit" })?.cleared, true)
    }

    @MainActor
    func testLocalStatementDuplicatesPreserveDistinctMemosAndNormalizePayeeIdentity() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let before = source.demo.transactions
        let staged = try await source.stageStatementImport(accountID: account.id,
            data: Data("Date,Amount,Payee,Memo\n2026-09-15,-1.23,Café  Corner,First receipt\n2026-09-15,-1.23,CAFÉ CORNER,Second receipt\n2026-09-15,-1.23,Cafe\u{301} Corner,First receipt\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount",
                           payeeColumn: "Payee", memoColumn: "Memo", dateOrder: "ymd"))
        XCTAssertEqual(source.demo.transactions, before, "Review must remain money neutral")
        XCTAssertNil(staged.candidates[0].duplicateSourceRow)
        XCTAssertNil(staged.candidates[1].duplicateSourceRow, "Different memo represents a distinct purchase")
        XCTAssertEqual(staged.candidates[2].duplicateSourceRow, 2, "Canonical payee normalization must match the server")
        let result = try await source.approveStatementImport(accountID: account.id, batchID: staged.id,
            approval: .init(expectedVersion: staged.version, items: staged.candidates.map {
                .init(sourceRow: $0.sourceRow, action: $0.duplicateSourceRow == nil ? "post" : "skip")
            }))
        XCTAssertEqual(result.candidates.compactMap(\.postedTransactionID).count, 2)
        let posted = source.demo.transactions.filter { !Set(before.map(\.id)).contains($0.id) }
        XCTAssertEqual(Set(posted.map(\.memo)), ["First receipt", "Second receipt"])
        XCTAssertEqual(posted.map(\.amount), [-123, -123])
    }

    @MainActor
    func testLocalStatementDuplicateIndexHandlesLargeDistinctMemoBatch() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        source.demo.createAccount(name: "Statement scale", type: "checking", isOnBudget: true)
        let account = try XCTUnwrap(source.demo.accounts.first)
        let rows = (0..<1_001).map { "2026-09-15,-1.23,Same merchant,Receipt \($0)" }
        let data = Data((["Date,Amount,Payee,Memo"] + rows + [rows[500]]).joined(separator: "\n").utf8)
        let staged = try await source.stageStatementImport(accountID: account.id, data: data,
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date", amountColumn: "Amount",
                           payeeColumn: "Payee", memoColumn: "Memo", dateOrder: "ymd"))
        XCTAssertEqual(staged.candidateCount, 1_002)
        XCTAssertTrue(staged.candidates.prefix(1_001).allSatisfy { $0.duplicateSourceRow == nil })
        XCTAssertEqual(staged.candidates.last?.duplicateSourceRow, 502)
        XCTAssertTrue(source.demo.transactions.isEmpty)
    }

    @MainActor
    func testLocalStatementMatchingUsesSelectedAccountAndPostedRows() async throws {
        let source = DemoWorkspaceDataSource()
        let target = try XCTUnwrap(source.demo.accounts.first)
        let other = try XCTUnwrap(source.demo.accounts.first { $0.id != target.id })
        let occurredOn = "2026-09-15"
        let candidate = Data("Date,Amount,Payee\n2026-09-15,-12.34,Account-scoped merchant\n".utf8)
        let mapping = APIStatementImportMapping(
            sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
            amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"
        )

        try await source.recordTransaction(.init(
            accountID: other.id, categoryID: nil, amountMinor: -1_234, occurredOn: occurredOn,
            payeeName: "Account-scoped merchant", memo: "Other account", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []
        ))
        var staged = try await source.stageStatementImport(accountID: target.id, data: candidate, mapping: mapping)
        XCTAssertTrue(try XCTUnwrap(staged.candidates.first).exactTransactionIDs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(staged.candidates.first).possibleTransactionIDs.isEmpty)

        try await source.recordTransaction(.init(
            accountID: target.id, categoryID: nil, amountMinor: -1_234, occurredOn: occurredOn,
            payeeName: "Account-scoped merchant", memo: "Target account", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []
        ))
        staged = try await source.stageStatementImport(accountID: target.id, data: candidate, mapping: mapping)
        XCTAssertEqual(try XCTUnwrap(staged.candidates.first).exactTransactionIDs.count, 1)

        let postedID = try XCTUnwrap(staged.candidates.first?.exactTransactionIDs.first)
        try await source.voidTransaction(id: postedID, reason: "Exclude non-posted observations")
        staged = try await source.stageStatementImport(accountID: target.id, data: candidate, mapping: mapping)
        XCTAssertTrue(try XCTUnwrap(staged.candidates.first).exactTransactionIDs.isEmpty)
    }

    @MainActor
    func testLocalStatementMatchingRecognizesFirstClassPayeeAlias() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let payeeIndex = try XCTUnwrap(source.demo.payees.indices.first)
        let canonicalName = source.demo.payees[payeeIndex].name
        source.demo.payees[payeeIndex].aliases.append("BANK DESCRIPTION 4812")
        try await source.recordTransaction(.init(
            accountID: account.id, categoryID: nil, amountMinor: -1_234,
            occurredOn: "2026-09-15", payeeName: canonicalName, memo: "Alias match",
            isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []
        ))
        let staged = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-12.34,bank description 4812\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        )
        XCTAssertEqual(try XCTUnwrap(staged.candidates.first).exactTransactionIDs.count, 1)
    }

    @MainActor
    func testLocalStatementReviewSuggestsPayeeDefaultWithoutMutatingLedger() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let category = try XCTUnwrap(source.demo.visibleCategories.first)
        source.demo.payees.append(.init(
            id: "statement-payee", name: "Neighborhood Market",
            defaultCategoryID: category.id, aliases: ["BANK MARKET 4812"]
        ))
        let initialTransactions = source.demo.transactions

        let staged = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-12.34,BANK MARKET 4812\n2026-09-16,2.00,Neighborhood Market\n".utf8),
            mapping: .init(
                sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"
            )
        )

        XCTAssertEqual(staged.candidates[0].suggestedCategoryID, category.id)
        XCTAssertNil(staged.candidates[1].suggestedCategoryID, "Refunds remain uncategorized until explicitly reviewed")
        XCTAssertEqual(source.demo.transactions, initialTransactions, "Review-time guidance must remain money-neutral")
    }

    @MainActor
    func testRestrictedLocalStatementReviewDoesNotExposePayeeDefaultsOrAliases() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let category = try XCTUnwrap(source.demo.categories.first)
        source.demo.accounts[0].restrictedFromChildren = false
        source.demo.categories[0].delegatedTo = .alex
        source.demo.persona = .alex
        source.demo.payees.append(.init(
            id: "private-statement-payee", name: "Private Merchant",
            defaultCategoryID: category.id, aliases: ["PRIVATE BANK ALIAS"]
        ))

        let staged = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-12.34,PRIVATE BANK ALIAS\n".utf8),
            mapping: .init(
                sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"
            )
        )

        XCTAssertNil(staged.candidates.first?.suggestedCategoryID)
    }

    @MainActor
    func testLocalStatementMatchingBoundsSuggestionsAndReportsTruncation() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        for index in 0..<21 {
            try await source.recordTransaction(.init(
                accountID: account.id, categoryID: nil, amountMinor: -1_234,
                occurredOn: "2026-09-15", payeeName: "Repeated merchant", memo: "Occurrence \(index)",
                isCleared: false, splits: [], flag: nil, tags: [], attachmentMetadata: []
            ))
        }
        let staged = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-12.34,Repeated merchant\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        )
        let candidate = try XCTUnwrap(staged.candidates.first)
        XCTAssertEqual(candidate.exactTransactionIDs.count, 20)
        XCTAssertTrue(candidate.suggestionsTruncated)
        XCTAssertEqual(candidate.exactTransactionIDs, candidate.exactTransactionIDs.sorted())
    }

    @MainActor
    func testLocalAliasIDsSurviveDeletionReorderingAndReopen() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        try await source.createPayee(.init(displayName: "Alias owner", defaultCategoryID: nil))
        let payee = try XCTUnwrap(source.demo.payees.first)
        for name in ["First alias", "Second alias", "Third alias"] {
            try await source.createPayeeAlias(payeeID: payee.id, displayName: name)
        }
        let page = try await source.searchPayees(query: "Alias owner", includeArchived: false, limit: 20, cursor: nil)
        let aliases = try XCTUnwrap(page.items.first).aliases
        let firstID = try XCTUnwrap(aliases.first { $0.displayName == "First alias" }).id
        let secondID = try XCTUnwrap(aliases.first { $0.displayName == "Second alias" }).id
        let thirdID = try XCTUnwrap(aliases.first { $0.displayName == "Third alias" }).id
        try await source.deletePayeeAlias(payeeID: payee.id, aliasID: firstID)
        do { try await source.deletePayeeAlias(payeeID: payee.id, aliasID: firstID); XCTFail("Stale alias ID must not remove a shifted row") }
        catch { }
        let shifted = try await source.searchPayees(query: "Alias owner", includeArchived: false, limit: 20, cursor: nil)
        XCTAssertEqual(Set(shifted.items.first?.aliases.map(\.id) ?? []), Set([secondID, thirdID]))
        try await source.deletePayeeAlias(payeeID: payee.id, aliasID: secondID)
        try await source.createPayeeAlias(payeeID: payee.id, displayName: "First alias")
        let recreated = try await source.searchPayees(query: "Alias owner", includeArchived: false, limit: 20, cursor: nil)
        XCTAssertNotEqual(recreated.items.first?.aliases.first { $0.displayName == "First alias" }?.id, firstID)
        let identity = LocalAuthorityIdentity(householdID: "h", householdName: "Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "b", budgetName: "Budget", currencyCode: "USD")
        let snapshot = try source.demo.localAuthoritySnapshot(identity: identity)
        let reopened = DemoStore(fresh: true)
        try reopened.loadLocalAuthority(snapshot)
        let restored = try XCTUnwrap(reopened.payees.first)
        XCTAssertEqual(LocalPayeeIdentity.aliasID("Third alias", for: restored), thirdID)
        XCTAssertEqual(Set(restored.aliasIDs.values), Set(snapshot.payeeAliases.map(\.id)))
        let duplicate = try XCTUnwrap(snapshot.payeeAliases.first)
        let malformed = LocalAuthoritySnapshot(identity: identity, accounts: [], groups: [], categories: [],
            payees: snapshot.payees, payeeAliases: snapshot.payeeAliases + [.init(id: "duplicate-alias",
                payeeID: duplicate.payeeID, displayName: duplicate.displayName, normalizedName: "inconsistent-key")],
            transactions: [], allocations: [], reconciliations: [], targets: [], schedules: [], attachments: [])
        XCTAssertThrowsError(try DemoStore(fresh: true).loadLocalAuthority(malformed))
        try await source.createPayee(.init(displayName: "Merge destination", defaultCategoryID: nil))
        let destination = try XCTUnwrap(source.demo.payees.first { $0.name == "Merge destination" })
        try await source.mergePayee(sourceID: payee.id, destinationID: destination.id)
        let merged = try XCTUnwrap(source.demo.payees.first { $0.id == destination.id })
        XCTAssertEqual(LocalPayeeIdentity.aliasID("Third alias", for: merged), thirdID)
        let mergedSnapshot = try source.demo.localAuthoritySnapshot(identity: identity)
        XCTAssertEqual(Set(mergedSnapshot.payeeAliases.map(\.id)).count, mergedSnapshot.payeeAliases.count)
    }

    @MainActor
    func testLocalSchedulePayeeResolutionIsNonCreatingUntilRealization() async throws {
        var clock = BudgetWorkspaceStore.parseDate("2026-09-14")
        let source = DemoWorkspaceDataSource(fresh: true, now: { clock })
        try await source.createAccount(.init(name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let account = try XCTUnwrap(source.demo.accounts.first)
        try await source.createPayee(.init(displayName: "Known merchant", defaultCategoryID: nil))
        let payee = try XCTUnwrap(source.demo.payees.first)
        try await source.createPayeeAlias(payeeID: payee.id, displayName: "BANK NAME")
        let beforeAccounts = source.demo.accounts, beforeTransactions = source.demo.transactions
        try await source.createSchedule(.init(accountID: account.id, name: " bank name ", amountMinor: 100,
            nextDate: "2026-09-15", recurrenceUnit: "once", intervalCount: 1, memo: "", isActive: true))
        XCTAssertEqual(source.demo.schedules.first?.name, "Known merchant")
        try await source.createSchedule(.init(accountID: account.id, name: "Future merchant", amountMinor: 200,
            nextDate: "2026-09-15", recurrenceUnit: "once", intervalCount: 1, memo: "", isActive: true))
        XCTAssertEqual(source.demo.payees.count, 1, "Planning must not create a new payee")
        XCTAssertEqual(source.demo.accounts, beforeAccounts)
        XCTAssertEqual(source.demo.transactions, beforeTransactions)
        XCTAssertEqual(source.demo.unassignedMinor, 0)
        try await source.updatePayee(.init(payeeID: payee.id, displayName: "Renamed merchant", isArchived: false, defaultCategoryID: nil))
        XCTAssertEqual(source.demo.schedules.first?.name, "Renamed merchant")
        let renameHistory = try await source.scheduleHistory(limit: 50, offset: 0)
        XCTAssertTrue(renameHistory.contains { $0.action == "updated" && $0.beforeSnapshot?.name == "Known merchant" && $0.afterSnapshot?.name == "Renamed merchant" })
        try await source.updatePayee(.init(payeeID: payee.id, displayName: "Renamed merchant", isArchived: false, defaultCategoryID: nil))
        let unchangedHistory = try await source.scheduleHistory(limit: 50, offset: 0)
        XCTAssertEqual(unchangedHistory.count, renameHistory.count)
        try await source.createPayee(.init(displayName: "Destination merchant", defaultCategoryID: nil))
        let destination = try XCTUnwrap(source.demo.payees.first { $0.name == "Destination merchant" })
        try await source.mergePayee(sourceID: payee.id, destinationID: destination.id)
        let mergeHistory = try await source.scheduleHistory(limit: 50, offset: 0)
        XCTAssertTrue(mergeHistory.contains { $0.action == "updated" && $0.beforeSnapshot?.name == "Renamed merchant" && $0.afterSnapshot?.name == "Destination merchant" })
        XCTAssertEqual(source.demo.accounts, beforeAccounts)
        XCTAssertEqual(source.demo.transactions, beforeTransactions)
        let future = try XCTUnwrap(source.demo.schedules.first { $0.name == "Future merchant" })
        clock = BudgetWorkspaceStore.parseDate("2026-09-15")
        _ = try await source.realizeSchedule(id: future.id)
        let posted = try XCTUnwrap(source.demo.transactions.first)
        let createdPayee = try XCTUnwrap(source.demo.payees.first { $0.name == "Future merchant" })
        XCTAssertEqual(posted.payeeID, createdPayee.id)
        XCTAssertEqual(source.demo.accounts.first?.balance, 200)
        XCTAssertEqual(source.demo.unassignedMinor, 200)
        XCTAssertFalse(source.demo.schedules.first { $0.id == future.id }?.isActive ?? true)
    }

    @MainActor
    func testHistoricalLocalPayeeRepairsThroughProductionHydration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try LocalAuthorityStore(fileURL: root.appendingPathComponent("authority.sqlite3"))
        let identity = LocalAuthorityIdentity(householdID: "h", householdName: "Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "b", budgetName: "Budget", currencyCode: "USD")
        try await authority.bootstrap(identity, createdAt: "2026-10-01T12:00:00Z")
        try await authority.insertAccount(.init(id: "a", budgetID: "b", name: "Checking", kind: "checking",
            isOnBudget: true, openingBalanceMinor: 0, createdAt: "2026-10-01T12:00:00Z"))
        try await authority.insertTransaction(.init(id: "legacy", budgetID: "b", accountID: "a", payeeID: nil, payeeName: "Historical Merchant",
            amountMinor: 123, occurredOn: "2026-10-01", createdByUserID: "owner",
            createdAt: "2026-10-01T12:00:00Z", splits: []))
        let budget = APIBudget(id: "b", householdID: "h", name: "Budget", currencyCode: "USD", effectivePermission: .owner, capabilities: nil)
        let source = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget, localAuthority: authority, localIdentity: identity)
        let report = WorkspaceReportQuery(start: Date.demo(monthsAgo: 1), end: Date.demo(monthsAgo: 0),
            accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "",
            cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        _ = try await source.snapshot(planMonth: Date.demo(monthsAgo: 0), report: report)
        let page = try await source.searchPayees(query: "Historical", includeArchived: false, limit: 20, cursor: nil)
        let payee = try XCTUnwrap(page.items.first)
        let rows = try await source.browseTransactions(query: .init(payeeIDs: [payee.id], limit: 20))
        XCTAssertEqual(rows.items.map(\.id), ["legacy"])
        XCTAssertEqual(rows.items.first?.amountMinor, 123)
        let reopened = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget, localAuthority: authority, localIdentity: identity)
        _ = try await reopened.snapshot(planMonth: Date.demo(monthsAgo: 0), report: report)
        let again = try await reopened.searchPayees(query: "Historical", includeArchived: false, limit: 20, cursor: nil)
        XCTAssertEqual(again.items.map(\.id), [payee.id])
    }

    @MainActor
    func testCanonicalLocalTransactionCreatesSearchablePayeeIdentity() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        try await source.createAccount(.init(name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let account = try XCTUnwrap(source.demo.accounts.first { $0.kind == .checking })
        let name = "Fresh local merchant"
        let initial = try await source.searchPayees(query: name, includeArchived: true, limit: 20, cursor: nil)
        XCTAssertTrue(initial.items.isEmpty)
        try await source.recordTransaction(.init(accountID: account.id, categoryID: nil, amountMinor: 123,
            occurredOn: "2026-09-15", payeeName: name, memo: "Identity regression", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let page = try await source.searchPayees(query: name, includeArchived: false, limit: 20, cursor: nil)
        XCTAssertEqual(page.items.count, 1, "A posted merchant must exist in the canonical payee registry")
        let payee = try XCTUnwrap(page.items.first)
        let transactions = try await source.browseTransactions(query: .init(payeeIDs: [payee.id], limit: 20))
        XCTAssertEqual(transactions.items.filter { $0.payeeName == name }.count, 1)
        XCTAssertEqual(transactions.items.first?.payeeID, payee.id)
        try await source.createPayeeAlias(payeeID: payee.id, displayName: "BANK MERCHANT")
        try await source.recordTransaction(.init(accountID: account.id, categoryID: nil, amountMinor: 77,
            occurredOn: "2026-09-15", payeeName: " bank\tmerchant ", memo: "Alias", isCleared: false,
            splits: [], flag: nil, tags: [], attachmentMetadata: []))
        let aliasPage = try await source.searchPayees(query: "BANK MERCHANT", includeArchived: false, limit: 20, cursor: nil)
        XCTAssertEqual(aliasPage.items.map(\.id), [payee.id])
        XCTAssertEqual(aliasPage.items.first?.transactionCount, 2)
        let history = try await source.payeeHistory(payeeID: payee.id, limit: 20, offset: 0)
        XCTAssertTrue(history.contains { $0.action == "created" })
        let identity = LocalAuthorityIdentity(householdID: "h", householdName: "Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "b", budgetName: "Budget", currencyCode: "USD")
        let snapshot = try source.demo.localAuthoritySnapshot(identity: identity)
        XCTAssertTrue(snapshot.transactions.allSatisfy { $0.payeeID == payee.id })
        let reopened = DemoStore(fresh: true)
        try reopened.loadLocalAuthority(snapshot)
        XCTAssertEqual(reopened.payees.map(\.id), [payee.id])
        XCTAssertTrue(reopened.transactions.allSatisfy { $0.payeeID == payee.id })
        try await source.updatePayee(.init(payeeID: payee.id, displayName: "Renamed merchant", isArchived: false, defaultCategoryID: nil))
        let renamedRows = try await source.browseTransactions(query: .init(payeeIDs: [payee.id], limit: 20))
        XCTAssertEqual(renamedRows.items.count, 2)
        XCTAssertTrue(renamedRows.items.allSatisfy { $0.payeeID == payee.id && $0.payeeName == "Renamed merchant" })
        try await source.updatePayee(.init(payeeID: payee.id, displayName: "Renamed merchant", isArchived: true, defaultCategoryID: nil))
        let beforeBalance = source.demo.accounts.first?.balance
        do {
            try await source.recordTransaction(.init(accountID: account.id, categoryID: nil, amountMinor: 100,
                occurredOn: "2026-09-15", payeeName: "Renamed merchant", memo: "", isCleared: false,
                splits: [], flag: nil, tags: [], attachmentMetadata: []))
            XCTFail("Archived identity must not be recreated by free-text entry")
        } catch { }
        XCTAssertEqual(source.demo.accounts.first?.balance, beforeBalance)
        XCTAssertEqual(source.demo.payees.count, 1)
    }

    @MainActor
    func testLocalStatementExplicitRefundPreservesCategoryAndIncomeSemantics() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first { $0.kind == .checking })
        let category = try XCTUnwrap(source.demo.categories.first)
        let beforeBalance = account.balance, beforeRTA = source.demo.unassignedMinor
        let beforeActivity = category.activity, beforeAvailable = category.available
        let batch = try await source.stageStatementImport(accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,5.00,Merchant refund\n2026-09-15,7.50,New income\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"))
        XCTAssertTrue(batch.candidates.allSatisfy { $0.suggestedCategoryID == nil }, "Positive amounts must not be automatically classified as refunds")
        let approved = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
            approval: .init(expectedVersion: batch.version, items: [
                .init(sourceRow: 2, action: "post", categoryID: category.id),
                .init(sourceRow: 3, action: "post"),
            ]))
        let refund = try XCTUnwrap(source.demo.transactions.first { $0.id == approved.candidates[0].postedTransactionID })
        let income = try XCTUnwrap(source.demo.transactions.first { $0.id == approved.candidates[1].postedTransactionID })
        XCTAssertEqual(refund.amount, 500)
        XCTAssertEqual(refund.categoryIDs, [category.id])
        XCTAssertEqual(income.amount, 750)
        XCTAssertTrue(income.categoryIDs.isEmpty)
        XCTAssertEqual(source.demo.accounts.first { $0.id == account.id }?.balance, beforeBalance + 1250)
        XCTAssertEqual(source.demo.categories.first { $0.id == category.id }?.activity, beforeActivity + 500)
        XCTAssertEqual(source.demo.categories.first { $0.id == category.id }?.available, beforeAvailable + 500)
        XCTAssertEqual(source.demo.unassignedMinor, beforeRTA + 750)
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BudgetApp/BudgetWorkspaceView.swift"))
        XCTAssertTrue(view.contains("Picker(row.amountMinor > 0 ? \"Income or Refund\" : \"Category\""))
        XCTAssertTrue(view.contains("if reviewable && postRows.contains(row.sourceRow) && account.isOnBudget"))
    }

    @MainActor
    func testLocalStatementLaterPostingFailureRollsBackEarlierRows() async throws {
        let source = DemoWorkspaceDataSource(fresh: true)
        try await source.createAccount(.init(name: "Checking", kind: "checking", isOnBudget: true, openingBalanceMinor: 0))
        let account = try XCTUnwrap(source.demo.accounts.first)
        let beforeAccounts = source.demo.accounts, beforeCategories = source.demo.categories
        let beforeTransactions = source.demo.transactions, beforeRTA = source.demo.unassignedMinor
        let batch = try await source.stageStatementImport(accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,92233720368547758.06,First valid row\n2026-09-15,0.03,Overflow row\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"))
        do {
            _ = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
                approval: .init(expectedVersion: batch.version, items: batch.candidates.map { .init(sourceRow: $0.sourceRow, action: "post") }))
            XCTFail("A later overflow must reject the whole financial batch")
        } catch { }
        XCTAssertEqual(source.demo.accounts, beforeAccounts)
        XCTAssertEqual(source.demo.categories, beforeCategories)
        XCTAssertEqual(source.demo.transactions, beforeTransactions)
        XCTAssertEqual(source.demo.unassignedMinor, beforeRTA)
        let retained = try await source.statementImport(accountID: account.id, batchID: batch.id)
        XCTAssertEqual(retained.status, "review")
        XCTAssertEqual(retained.version, batch.version)
        XCTAssertTrue(retained.candidates.allSatisfy { $0.postedTransactionID == nil })
        let approved = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
            approval: .init(expectedVersion: batch.version, items: batch.candidates.enumerated().map {
                .init(sourceRow: $0.element.sourceRow, action: $0.offset == 0 ? "skip" : "post")
            }))
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(source.demo.accounts.first?.balance, 3)
        XCTAssertEqual(source.demo.transactions.count, beforeTransactions.count + 1)
    }

    @MainActor
    func testLocalStatementCachedReviewsRespectCurrentPermissionAndOwnership() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let data = Data("Date,Amount,Payee\n2026-09-15,10.25,Private deposit\n".utf8)
        let mapping = APIStatementImportMapping(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
            amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        let batch = try await source.stageStatementImport(accountID: account.id, data: data, mapping: mapping)
        let before = source.demo.transactions
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
            capabilities: ["view_budget"], restrictAccounts: false, accountIDs: [],
            restrictCategories: false, categoryIDs: [], expectedVersion: nil))
        source.demo.persona = .partner
        let readsAndWrites: [() async throws -> Void] = [
            { _ = try await source.statementImports(accountID: account.id, limit: 25, offset: 0) },
            { _ = try await source.statementImport(accountID: account.id, batchID: batch.id) },
            { _ = try await source.stageStatementImport(accountID: account.id, data: data, mapping: mapping) },
            { _ = try await source.cancelStatementImport(accountID: account.id, batchID: batch.id, expectedVersion: batch.version) },
            { _ = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
                approval: .init(expectedVersion: batch.version, items: [.init(sourceRow: 2, action: "skip")])) },
            { _ = try await source.undoStatementImport(accountID: account.id, batchID: batch.id, expectedVersion: batch.version) },
        ]
        for operation in readsAndWrites {
            do { try await operation(); XCTFail("Cached statement reviews must not bypass current permissions") }
            catch let APIClientError.server(status, _) { XCTAssertEqual(status, 403) }
        }
        XCTAssertEqual(source.demo.transactions, before)
        source.demo.persona = .rey
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
            capabilities: ["view_budget", "view_transactions", "create_transaction"],
            restrictAccounts: false, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: nil))
        source.demo.persona = .partner
        let otherHistory = try await source.statementImports(accountID: account.id, limit: 25, offset: 0)
        XCTAssertTrue(otherHistory.items.isEmpty, "Another actor's import metadata must not appear")
        for index in [1, 3, 4, 5] {
            do { try await readsAndWrites[index](); XCTFail("Import ownership must be checked before cached detail or mutation") }
            catch let APIClientError.server(status, _) { XCTAssertEqual(status, 404) }
        }
        source.demo.persona = .rey
        let retained = try await source.statementImport(accountID: account.id, batchID: batch.id)
        XCTAssertEqual(retained.status, "review")
        XCTAssertEqual(retained.version, batch.version)
        XCTAssertEqual(retained.candidates.first?.payee, "Private deposit")
        _ = try await source.updateAccessProfile(userID: "jordan", value: .init(
            capabilities: ["view_budget", "view_transactions", "create_transaction"],
            restrictAccounts: true, accountIDs: [], restrictCategories: false, categoryIDs: [], expectedVersion: nil))
        source.demo.persona = .partner
        for operation in readsAndWrites {
            do { try await operation(); XCTFail("Import access must respect current account scope") }
            catch let APIClientError.server(status, _) { XCTAssertEqual(status, 404) }
        }
        source.demo.persona = .rey
        for limit in [0, -1, Int.max] {
            do { _ = try await source.statementImports(accountID: account.id, limit: limit, offset: 0); XCTFail("Invalid pages must fail safely") }
            catch { }
        }
    }

    @MainActor
    func testLocalStatementRejectsDuplicateAndUnknownApprovalChoicesWithoutMutation() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let batch = try await source.stageStatementImport(accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,10.25,Local deposit\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"))
        let before = source.demo.transactions
        let choices: [[APIStatementImportApprovalItem]] = [
            [.init(sourceRow: 2, action: "skip"), .init(sourceRow: 2, action: "post")],
            [.init(sourceRow: 2, action: "unknown")],
        ]
        for items in choices {
            do {
                _ = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
                    approval: .init(expectedVersion: batch.version, items: items))
                XCTFail("Invalid review choices must be rejected before ledger mutation")
            } catch { }
            XCTAssertEqual(source.demo.transactions, before)
            let retained = try await source.statementImport(accountID: account.id, batchID: batch.id)
            XCTAssertEqual(retained.status, "review")
            XCTAssertEqual(retained.version, batch.version)
            XCTAssertNil(retained.candidates.first?.approvalAction)
            XCTAssertNil(retained.candidates.first?.postedTransactionID)
        }
        let approved = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
            approval: .init(expectedVersion: batch.version, items: [.init(sourceRow: 2, action: "post")]))
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(source.demo.transactions.count, before.count + 1)
    }

    @MainActor
    func testLocalStatementUndoUsesCanonicalVoidAndReversalPath() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let initialTotal = source.demo.transactions.reduce(Int64(0)) { $0 + $1.amount }
        let batch = try await source.stageStatementImport(accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,10.25,Local deposit\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"))
        let approved = try await source.approveStatementImport(accountID: account.id, batchID: batch.id,
            approval: .init(expectedVersion: batch.version, items: [.init(sourceRow: 2, action: "post")]))
        let postedID = try XCTUnwrap(approved.candidates.first?.postedTransactionID)
        let undone = try await source.undoStatementImport(
            accountID: account.id, batchID: batch.id, expectedVersion: approved.version
        )
        XCTAssertNotNil(undone.candidates.first?.reversalTransactionID)
        XCTAssertEqual(source.demo.transactions.first(where: { $0.id == postedID })?.status, "voided")
        XCTAssertEqual(source.demo.transactions.reduce(Int64(0)) { $0 + $1.amount }, initialTotal)
    }

    @MainActor
    func testLocalStatementCancellationIsMoneyNeutralAndRejectsReplay() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let initialTransactions = source.demo.transactions
        let initialBalance = account.balance
        let batch = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-12.34,Cancelled import\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        )
        let cancelled = try await source.cancelStatementImport(
            accountID: account.id, batchID: batch.id, expectedVersion: batch.version
        )
        XCTAssertEqual(cancelled.status, "cancelled")
        XCTAssertEqual(cancelled.version, batch.version + 1)
        XCTAssertEqual(source.demo.transactions, initialTransactions)
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == account.id })?.balance, initialBalance)
        do {
            _ = try await source.cancelStatementImport(
                accountID: account.id, batchID: batch.id, expectedVersion: batch.version
            )
            XCTFail("A cancelled import must not be cancellable again")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed"))
        }
    }

    @MainActor
    func testLocalStatementHistoryReopensPrivateDetailAndPaginates() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let first = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-1.00,First private payee\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        )
        _ = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-16,-2.00,Second private payee\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        )
        let page = try await source.statementImports(accountID: account.id, limit: 1, offset: 0)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextOffset, 1)
        let reopened = try await source.statementImport(accountID: account.id, batchID: first.id)
        XCTAssertEqual(reopened.candidates.first?.payee, "First private payee")
        XCTAssertEqual(source.demo.transactions.filter { $0.payee.contains("private payee") }.count, 0)
    }

    @MainActor
    func testLocalDeviceStatementImportHistorySurvivesRepositoryReconstruction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-import-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try LocalAuthorityStore(fileURL: root.appendingPathComponent("authority.sqlite3"))
        let identity = LocalAuthorityIdentity(
            householdID: "household", householdName: "Household", ownerUserID: "owner",
            ownerDisplayName: "Owner", budgetID: "budget", budgetName: "Budget", currencyCode: "USD"
        )
        let budget = APIBudget(id: identity.budgetID, householdID: identity.householdID,
                               name: identity.budgetName, currencyCode: "USD",
                               effectivePermission: .owner, capabilities: nil)
        let report = WorkspaceReportQuery(
            start: Date.demo(monthsAgo: 1), end: Date.demo(monthsAgo: 0), accountID: "",
            categoryID: "", categoryGroup: "", payee: "", memberID: "",
            transactionType: "", cleared: "all", flag: "", tag: "",
            spendingTrendDimension: "category", includeTracking: true
        )
        try await authority.bootstrap(identity, createdAt: "2026-10-07T12:00:00Z", installStarterPlan: true)
        try await authority.insertAccount(.init(
            id: "checking", budgetID: identity.budgetID, name: "Checking", kind: "checking",
            isOnBudget: true, openingBalanceMinor: 0, createdAt: "2026-10-07T12:00:00Z"
        ))
        let first = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget,
                                            localAuthority: authority, localIdentity: identity)
        _ = try await first.snapshot(planMonth: Date.demo(monthsAgo: 0), report: report)
        let account = try XCTUnwrap(first.demo.accounts.first { $0.name == "Checking" })
        let staged = try await first.stageStatementImport(
            accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,-12.34,Private Merchant\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                           amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd")
        )

        let relaunched = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget,
                                                 localAuthority: authority, localIdentity: identity)
        _ = try await relaunched.snapshot(planMonth: Date.demo(monthsAgo: 0), report: report)
        let history = try await relaunched.statementImports(accountID: account.id, limit: 25, offset: 0)
        XCTAssertEqual(history.items.map(\.id), [staged.id])
        let reopened = try await relaunched.statementImport(accountID: account.id, batchID: staged.id)
        XCTAssertEqual(reopened.candidates.first?.payee, "Private Merchant")
        XCTAssertTrue(relaunched.demo.transactions.allSatisfy { $0.payee != "Private Merchant" })
        let cancelled = try await relaunched.cancelStatementImport(
            accountID: account.id, batchID: staged.id, expectedVersion: reopened.version
        )
        XCTAssertEqual(cancelled.status, "cancelled")
        let afterMutationRelaunch = DemoWorkspaceDataSource(
            fresh: true, budgetOverride: budget, localAuthority: authority, localIdentity: identity
        )
        let persistedCancellation = try await afterMutationRelaunch.statementImport(
            accountID: account.id, batchID: staged.id
        )
        XCTAssertEqual(persistedCancellation.status, "cancelled")
        XCTAssertEqual(persistedCancellation.version, staged.version + 1)
        let approvalBatch = try await afterMutationRelaunch.stageStatementImport(accountID: account.id,
            data: Data("Date,Amount,Payee\n2026-09-15,10.25,Atomic deposit\n".utf8),
            mapping: .init(sourceFormat: "csv", currencyCode: "USD", dateColumn: "Date",
                amountColumn: "Amount", payeeColumn: "Payee", dateOrder: "ymd"))
        let approval = APIStatementImportApprove(expectedVersion: approvalBatch.version,
            items: approvalBatch.candidates.map { .init(sourceRow: $0.sourceRow, action: "post") })
        let beforeRows = afterMutationRelaunch.demo.transactions
        let beforeAccounts = afterMutationRelaunch.demo.accounts
        let staleSource = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget,
            localAuthority: authority, localIdentity: identity)
        _ = try await staleSource.statementImport(accountID: account.id, batchID: approvalBatch.id)
        let database = try LocalDatabase(fileURL: root.appendingPathComponent("authority.sqlite3"))
        try await database.execute(.init("CREATE TRIGGER reject_import_approval BEFORE INSERT ON statement_imports WHEN NEW.status='approved' BEGIN SELECT RAISE(ABORT,'simulated approval publication failure'); END"))
        do {
            _ = try await afterMutationRelaunch.approveStatementImport(accountID: account.id, batchID: approvalBatch.id, approval: approval)
            XCTFail("A failed review-marker write must roll back the financial publication")
        } catch { }
        XCTAssertEqual(afterMutationRelaunch.demo.transactions, beforeRows)
        XCTAssertEqual(afterMutationRelaunch.demo.accounts, beforeAccounts)
        let failedSnapshot = try await authority.snapshot(budgetID: identity.budgetID)
        XCTAssertTrue(failedSnapshot.transactions.allSatisfy { $0.payeeName != "Atomic deposit" })
        let failedReview = try await afterMutationRelaunch.statementImport(accountID: account.id, batchID: approvalBatch.id)
        XCTAssertEqual(failedReview.status, "review")
        XCTAssertEqual(failedReview.version, approvalBatch.version)
        try await database.execute(.init("DROP TRIGGER reject_import_approval"))
        let approved = try await afterMutationRelaunch.approveStatementImport(accountID: account.id, batchID: approvalBatch.id, approval: approval)
        do {
            _ = try await staleSource.approveStatementImport(accountID: account.id, batchID: approvalBatch.id, approval: approval)
            XCTFail("Stale repository must not approve an already accepted review")
        } catch { }
        XCTAssertEqual(staleSource.demo.transactions, beforeRows)
        XCTAssertEqual(staleSource.demo.accounts, beforeAccounts)
        let afterStaleApproval = try await authority.snapshot(budgetID: identity.budgetID)
        XCTAssertEqual(afterStaleApproval.transactions.filter { $0.payeeName == "Atomic deposit" }.count, 1)
        do {
            _ = try await staleSource.cancelStatementImport(accountID: account.id, batchID: approvalBatch.id, expectedVersion: approvalBatch.version)
            XCTFail("Stale cancellation must not overwrite an approved review")
        } catch { }
        let refreshedStaleReview = try await staleSource.statementImport(accountID: account.id, batchID: approvalBatch.id)
        XCTAssertEqual(refreshedStaleReview.status, "approved")
        XCTAssertEqual(refreshedStaleReview.version, approved.version)
        XCTAssertEqual(staleSource.demo.accounts.first { $0.id == account.id }?.balance, 1025)
        let finalSource = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget,
            localAuthority: authority, localIdentity: identity)
        let recovered = try await finalSource.statementImport(accountID: account.id, batchID: approvalBatch.id)
        XCTAssertEqual(recovered.status, "approved")
        XCTAssertEqual(recovered.version, approved.version)
        XCTAssertEqual(recovered.candidates.first?.postedTransactionID, approved.candidates.first?.postedTransactionID)
        XCTAssertEqual(finalSource.demo.transactions.filter { $0.payee == "Atomic deposit" }.count, 1)
        XCTAssertEqual(finalSource.demo.accounts.first { $0.id == account.id }?.balance, 1025)
        do {
            _ = try await finalSource.approveStatementImport(accountID: account.id, batchID: approvalBatch.id, approval: approval)
            XCTFail("Recovered approval must reject replay")
        } catch let APIClientError.server(status, _) { XCTAssertEqual(status, 409) }
        let acceptedTransactions = finalSource.demo.transactions
        let acceptedAccounts = finalSource.demo.accounts
        try await database.execute(.init("CREATE TRIGGER reject_import_undo BEFORE INSERT ON statement_imports WHEN NEW.version=\(approved.version + 1) BEGIN SELECT RAISE(ABORT,'simulated undo publication failure'); END"))
        do {
            _ = try await finalSource.undoStatementImport(accountID: account.id, batchID: approvalBatch.id, expectedVersion: approved.version)
            XCTFail("Failed undo marker publication must not retain reversals")
        } catch { }
        XCTAssertEqual(finalSource.demo.transactions, acceptedTransactions)
        XCTAssertEqual(finalSource.demo.accounts, acceptedAccounts)
        let failedUndoSnapshot = try await authority.snapshot(budgetID: identity.budgetID)
        XCTAssertTrue(failedUndoSnapshot.transactions.allSatisfy { $0.status != "reversal" })
        let unchangedReview = try await finalSource.statementImport(accountID: account.id, batchID: approvalBatch.id)
        XCTAssertEqual(unchangedReview.version, approved.version)
        XCTAssertNil(unchangedReview.candidates.first?.reversalTransactionID)
        try await database.execute(.init("DROP TRIGGER reject_import_undo"))
        let undone = try await finalSource.undoStatementImport(accountID: account.id, batchID: approvalBatch.id, expectedVersion: approved.version)
        let undoRelaunch = DemoWorkspaceDataSource(fresh: true, budgetOverride: budget,
            localAuthority: authority, localIdentity: identity)
        let recoveredUndo = try await undoRelaunch.statementImport(accountID: account.id, batchID: approvalBatch.id)
        XCTAssertEqual(recoveredUndo.version, undone.version)
        XCTAssertEqual(recoveredUndo.candidates.first?.reversalTransactionID, undone.candidates.first?.reversalTransactionID)
        XCTAssertNotNil(recoveredUndo.candidates.first?.reversalTransactionID)
        XCTAssertEqual(undoRelaunch.demo.transactions.filter { $0.status == "reversal" }.count, 1)
        XCTAssertEqual(undoRelaunch.demo.accounts.first { $0.id == account.id }?.balance, 0)
        do {
            _ = try await undoRelaunch.undoStatementImport(accountID: account.id, batchID: approvalBatch.id, expectedVersion: undone.version)
            XCTFail("Recovered undo must reject another reversal")
        } catch let APIClientError.server(status, _) { XCTAssertEqual(status, 409) }
        await database.close()
    }

    @MainActor
    func testLocalQIFStagingIsMoneyNeutralUntilCanonicalApproval() async throws {
        let source = DemoWorkspaceDataSource()
        let account = try XCTUnwrap(source.demo.accounts.first)
        let initialTransactions = source.demo.transactions
        let initialBalance = source.demo.accounts.first(where: { $0.id == account.id })?.balance
        let batch = try await source.stageStatementImport(
            accountID: account.id,
            data: Data("!Type:Bank\nD09/14/2026\nT-12.34\nPCorner Store\nMImported locally\n^\nD09/15/2026\nT2.34\nPRefund\n^".utf8),
            mapping: .init(sourceFormat: "qif", currencyCode: "USD", dateOrder: "mdy")
        )
        XCTAssertEqual(batch.candidates.map(\.amountMinor), [-1_234, 234])
        XCTAssertEqual(source.demo.transactions, initialTransactions)
        XCTAssertEqual(source.demo.accounts.first(where: { $0.id == account.id })?.balance, initialBalance)

        _ = try await source.approveStatementImport(
            accountID: account.id,
            batchID: batch.id,
            approval: .init(expectedVersion: batch.version, items: [
                .init(sourceRow: 1, action: "skip"),
                .init(sourceRow: 2, action: "post"),
            ])
        )
        XCTAssertEqual(source.demo.transactions.count, initialTransactions.count + 1)
        let posted = try XCTUnwrap(source.demo.transactions.first(where: { $0.payee == "Refund" }))
        XCTAssertEqual(posted.amount, 234)
        XCTAssertTrue(posted.cleared)
    }

    func testCompleteExportPackageIncludesOnlyActiveServerAttachmentsAndVerifiesPayloads() async throws {
        let first = Data("first receipt".utf8)
        let second = Data("second receipt".utf8)
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let export: [String: Any] = [
            "format": "com.clearpocket.portable-budget-data",
            "transaction_attachments": [
                ["id": "attachment-1", "transaction_id": "transaction-1",
                 "filename": "receipt.jpg", "content_type": "image/jpeg",
                 "byte_count": first.count, "sha256": digest(first), "detached_at": NSNull()],
                ["id": "attachment-2", "transaction_id": "transaction-2",
                 "filename": "../statement.pdf", "content_type": "application/pdf",
                 "byte_count": second.count, "sha256": digest(second), "detached_at": NSNull()],
                ["id": "detached", "transaction_id": "transaction-3",
                 "filename": "old.png", "content_type": "image/png",
                 "byte_count": 1, "sha256": String(repeating: "0", count: 64),
                 "detached_at": "2026-10-01T00:00:00Z"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: export, options: [.sortedKeys])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("complete-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var requested: [String] = []

        try await CompleteBudgetExportPackage.build(exportData: data, at: root) { item in
            requested.append(item.id)
            return item.id == "attachment-1" ? first : second
        }

        XCTAssertEqual(requested, ["attachment-1", "attachment-2"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("data.json")), data)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json")))
                as? [String: Any]
        )
        XCTAssertEqual(manifest["attachmentPayloadsIncluded"] as? Bool, true)
        let rows = try XCTUnwrap(manifest["attachments"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["originalFilename"] as? String }, ["receipt.jpg", "../statement.pdf"])
        for row in rows {
            let relativePath = try XCTUnwrap(row["relativePath"] as? String)
            XCTAssertFalse(relativePath.contains("../"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        }
    }

    func testCompleteExportPackageReadsLocalAttachmentIdentityAndRemovesFailedGeneration() async throws {
        let content = Data("local receipt".utf8)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let export: [String: Any] = [
            "authority": ["attachments": [[
                "id": "local-attachment", "transactionID": "local-transaction",
                "filename": "receipt.png", "contentType": "image/png",
                "sizeBytes": content.count, "sha256": digest,
            ]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: export)
        let metadata = try CompleteBudgetExportPackage.attachmentMetadata(in: data)
        XCTAssertEqual(metadata.map(\.id), ["local-attachment"])
        XCTAssertEqual(metadata.first?.transactionID, "local-transaction")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-complete-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try await CompleteBudgetExportPackage.build(exportData: data, at: root) { _ in
                Data("corrupt".utf8)
            }
            XCTFail("Expected integrity validation to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }
}

private final class InMemorySecretDataStore: SecretDataStoring {
    private var values: [String: Data] = [:]
    private(set) var saveCount = 0

    init(initial: Data? = nil) {
        if let initial { values[LocalDeviceKeyManager.attachmentKeyAccount] = initial }
    }

    func saveData(_ value: Data, account: String) throws {
        values[account] = value
        saveCount += 1
    }

    func readData(account: String) -> Data? { values[account] }
    func deleteData(account: String) { values.removeValue(forKey: account) }
}

private struct WorkspaceSelectionHarness: View {
    let store: BudgetWorkspaceStore
    let session: AppSession
    let start: Int
    let destination: Int
    @State private var selection: Int

    init(store: BudgetWorkspaceStore, session: AppSession, start: Int, destination: Int) {
        self.store = store
        self.session = session
        self.start = start
        self.destination = destination
        _selection = State(initialValue: start)
    }

    var body: some View {
        BudgetWorkspaceView(testStore: store, selection: $selection)
            .environmentObject(session)
            .onAppear { DispatchQueue.main.async { selection = destination } }
    }
}

private final class ConnectionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class TransferRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private var recordedAuthorizations: [String] = []

    func append(path: String, authorization: String) {
        lock.lock(); defer { lock.unlock() }
        recordedPaths.append(path)
        recordedAuthorizations.append(authorization)
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedPaths
    }

    var authorizations: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedAuthorizations
    }
}

@MainActor
private final class ReminderNotificationFixture: ScheduledReminderNotificationClient {
    var holdAuthorization = false, holdAdd = false, failAdd = false
    var authorization: CheckedContinuation<Bool, Never>?
    var addition: CheckedContinuation<Void, Never>?
    var onAuthorize: (() -> Void)?, onAdd: (() -> Void)?
    var requests: [String: UNNotificationRequest] = [:]
    var addCount = 0
    func authorize() async throws -> Bool {
        if holdAuthorization {
            return await withCheckedContinuation { authorization = $0; onAuthorize?() }
        }
        return true
    }
    func pendingIdentifiers() async -> [String] { Array(requests.keys) }
    func remove(_ identifiers: [String]) { for id in identifiers { requests.removeValue(forKey: id) } }
    func add(_ request: UNNotificationRequest) async throws {
        addCount += 1
        if holdAdd { await withCheckedContinuation { addition = $0; onAdd?() } }
        if failAdd { throw URLError(.cannotWriteToFile) }
        requests[request.identifier] = request
    }
}

private final class TransferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
