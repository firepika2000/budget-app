import XCTest
import SwiftUI
import UIKit
import BudgetAPI
@testable import Budget_App

final class DemoStoreTests: XCTestCase {
    @MainActor
    func testDemoPostingAndReversalOverflowRefuseWithoutPartialMutation() throws {
        func operation(_ accountID: String, _ amount: Int64) -> RecordTransactionOperation {
            .init(accountID: accountID, categoryID: nil, amountMinor: amount, occurredOn: BudgetWorkspaceStore.dateString(Date()), payeeName: "Boundary", memo: "", isCleared: true, splits: [], flag: nil, tags: [], attachmentMetadata: [])
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
        try await store.reconcile(accountID: account.id, statementBalance: statement, throughDate: cutoff, createAdjustment: false, reason: "")
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
        let initial = try await store.accessProfile(userID: "demo-member")
        let capabilities = ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "view_account_balances"]
        _ = try await store.updateAccessProfile(userID: "demo-member", value: .init(capabilities: capabilities, restrictAccounts: true, accountIDs: ["checking"], restrictCategories: false, categoryIDs: [], expectedVersion: initial.version))
        let reloaded = try await store.accessProfile(userID: "demo-member")
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
        XCTAssertFalse(workspace.contains("dataSource as? DemoWorkspaceDataSource"), "workspace commands must use the common repository contract")
        XCTAssertTrue(workspace.contains("Add your first account"))
        XCTAssertEqual(workspace.components(separatedBy: ".workspaceProfileToolbar").count - 1, 5, "Profile & Settings must be global workspace chrome on every tab")
        XCTAssertTrue(workspace.contains(".id(activeTab)"), "the iOS 27 production shell must materialize the selected tab instead of rendering a blank lazy stack")
        XCTAssertTrue(workspace.contains("intentional identity replacement at the shell boundary"), "the exceptional shell identity boundary must remain documented")
        XCTAssertFalse(workspace.contains("workspaceDismissToolbar"), "the active budget must not navigate back to a Budgets parent")
        XCTAssertTrue(workspace.contains("Create Category Group"))
        XCTAssertTrue(workspace.contains("Add your first category"))
        XCTAssertTrue(workspace.contains("Money you currently have that has not been given a purpose yet."))
        XCTAssertTrue(editor.contains("openingBalanceMinor: balance"))
        XCTAssertTrue(editor.contains("selection: $date, in: ...Date()"), "ordinary transaction entry must not accept future actual dates")
        XCTAssertTrue(workspace.contains("Button(\"Schedule Transaction\""), "the production Activity action menu must expose canonical schedule creation")
        XCTAssertTrue(workspace.contains(".task(id: session.token)"), "the production workspace must bind the current credential even when it first renders after rotation")
        XCTAssertTrue(workspace.contains("LiveWorkspaceCredentials"), "all long-lived Live repositories must share mutable credential ownership")
        XCTAssertTrue(workspace.contains("struct PayeeSearchSelectionView"), "all payee-selection workflows must share the bounded searchable selector")
        XCTAssertTrue(workspace.contains("activity-payee-selector"), "Activity filtering must select an existing first-class payee identity")
        XCTAssertTrue(workspace.contains("limit: 20"), "payee selection must request bounded result pages")
        XCTAssertTrue(workspace.contains("payee-search-load-more"), "large payee histories must paginate instead of hydrating every identity")
        XCTAssertFalse(workspace.contains("async let loadedPayees = client.payees"), "workspace hydration must not download the entire household payee history")
        XCTAssertTrue(workspace.contains(".task(id: store.liveCredentialRevision)"), "attachment loading must cancel stale credential work and run once for the current credential generation")
        XCTAssertTrue(workspace.contains("attachment-take-photo"))
        XCTAssertTrue(workspace.contains("attachment-choose-photo"))
        XCTAssertTrue(workspace.contains("attachment-choose-file"))
        XCTAssertTrue(workspace.contains(".photosPicker(isPresented: $choosingPhoto"), "photo selection must use the native Photos picker")
        XCTAssertTrue(workspace.contains("try await upload(data: data"), "camera, Photos, and Files must converge on the existing attachment upload service")
        XCTAssertEqual(workspace.components(separatedBy: "uploadTransactionAttachment(id: transaction.id").count - 1, 1, "attachment sources must not create separate storage/upload paths")
        XCTAssertTrue(workspace.contains(".buttonStyle(.plain).accessibilityIdentifier(\"attachment-preview-"), "preview and remove must not inherit Form row-wide button activation")
        XCTAssertTrue(workspace.contains(".buttonStyle(.borderless).foregroundStyle(.red).accessibilityIdentifier(\"attachment-remove-"))
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

        try await store.updateAccount(.init(accountID: account.id, name: "Emergency Savings", currentKind: "checking", kind: "savings", isOnBudget: true))
        let updated = try XCTUnwrap(store.accounts.first(where: { $0.id == account.id }))
        XCTAssertEqual(updated.name, "Emergency Savings")
        XCTAssertEqual(updated.accountType, "savings")
        XCTAssertTrue(updated.isOnBudget)
        XCTAssertEqual(store.accountBalances[account.id], balanceBefore)
        XCTAssertEqual(store.summary, summaryBefore)
        XCTAssertEqual(store.transactions.count, transactionCountBefore)

        do {
            try await store.updateAccount(.init(accountID: account.id, name: "Card", currentKind: "savings", kind: "credit", isOnBudget: true))
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
        XCTAssertTrue(contents.contains("Projected values include schedules but are not spendable"))
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
        let due = BudgetWorkspaceStore.dateString(Date())
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
        let due = BudgetWorkspaceStore.dateString(Date())
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
        try await source.assignMoney(.init(categoryID: "monthly", month: "2027-02-01", assignedMinor: 5000, expectedVersion: 1))
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
        XCTAssertTrue(contents.contains("prepare-report-csv"))
        XCTAssertTrue(contents.contains("share-report-csv"))
        XCTAssertTrue(contents.contains("spending-trend-payee-"))
        XCTAssertTrue(contents.contains("debt-account-"))
        XCTAssertTrue(contents.contains("plan-performance-category-"))
        XCTAssertTrue(contents.contains(".chartXSelection(value: $selectedDate)"))
        XCTAssertTrue(contents.contains("income-spending-selected-period"))
        XCTAssertTrue(contents.contains("net-worth-selected-point"))
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
            store.accounts.contains { $0.id == account.accountID && ["credit", "loan"].contains($0.accountType) }
        })
        let plan = try XCTUnwrap(store.planPerformanceReport)
        XCTAssertEqual(plan.points.last?.availableMinor, store.summary?.categories.reduce(Int64(0)) { $0 + $1.availableMinor })
        XCTAssertEqual(plan.points.last?.readyToAssignMinor, store.summary?.readyToAssignMinor)
        let resilience = try XCTUnwrap(store.resilienceReport)
        XCTAssertEqual(resilience.expectedMarginMinor, resilience.scheduledIncomeMinor - resilience.scheduledOutflowsMinor)
        XCTAssertNil(resilience.essentialExpenseCoverageDays)
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
        let rangeStart = Calendar.current.date(byAdding: .year, value: -2, to: Date())!
        let rangeEnd = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
        let baselineQuery = WorkspaceReportQuery(start: rangeStart, end: rangeEnd, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "all", flag: "", tag: "", spendingTrendDimension: "category", includeTracking: true)
        let baseline = try await source.snapshot(planMonth: Date(), report: baselineQuery)
        let account = try XCTUnwrap(baseline.accounts.first { $0.isOnBudget && $0.accountType != "credit" })
        let category = try XCTUnwrap(baseline.categories.first { !$0.isArchived })
        try await source.recordTransaction(.init(accountID: account.id, categoryID: category.id, amountMinor: -4321, occurredOn: BudgetWorkspaceStore.dateString(Date()), payeeName: "Metadata filter fixture", memo: "", isCleared: false, splits: [], flag: "orange", tags: ["essential"], attachmentMetadata: []))

        let query = WorkspaceReportQuery(start: rangeStart, end: rangeEnd, accountID: "", categoryID: "", categoryGroup: "", payee: "", memberID: "", transactionType: "", cleared: "uncleared", flag: "orange", tag: "essential", spendingTrendDimension: "category", includeTracking: true)
        let filtered = try await source.snapshot(planMonth: Date(), report: query)
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
    func testDemoAllocationHistoryMatchesLiveContractShape() async throws {
        let store = BudgetWorkspaceStore.demo()
        await store.load(serverURL: URL(string: "http://localhost")!, token: "demo")
        // The same production category-detail view reads store.allocationOperations for demo and live.
        let fixtureOperations = store.allocationOperations
        XCTAssertFalse(fixtureOperations.isEmpty, "the fixture now executes real dated assignment commands")
        XCTAssertTrue(fixtureOperations.allSatisfy { $0.id.hasPrefix("fixture-") && $0.kind == "assignment" })
        let groceries = try XCTUnwrap(store.categories.first { $0.id == "groceries" })
        try await store.updateAssignment(categoryID: groceries.id, month: "2026-09-01", assignedMinor: 73_000, expectedVersion: 1)
        try await store.moveAllocation(.init(sourceCategoryID: groceries.id, destinationCategoryID: "dining", amountMinor: 123, occurredOn: "2026-09-03", note: "Actual move", expectedVersion: 1))
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
        try await source.assignMoney(.init(categoryID: "groceries", month: "2026-09-01", assignedMinor: 73_000, expectedVersion: 1))
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
        try await store.deleteTransfer(id: transferID)
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
            case "insufficient": source.demo.categories[buffer].available = 1
            case "overflow":
                let destination = try XCTUnwrap(source.demo.categories.firstIndex { $0.id == "alexallow" })
                source.demo.categories[destination].assigned = Int64.max
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
