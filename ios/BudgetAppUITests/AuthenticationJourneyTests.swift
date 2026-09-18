import XCTest
import UIKit

final class AuthenticationJourneyTests: XCTestCase {
    func testProductionTargetSnoozePersistsThroughNavigationAndResumes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=plan"]
        app.launch()
        let groceries = app.buttons["plan-category-groceries"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        let action = app.buttons["target-month-snooze"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.label.hasPrefix("Snooze for"))
        action.tap()
        let state = app.descendants(matching: .any).matching(identifier: "target-month-snoozed-state").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(action.label.hasPrefix("Resume target for"))
        app.navigationBars["Groceries"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(groceries.label.contains("Target snoozed this month"), "A snoozed target must not masquerade as fully funded")
        groceries.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 5))
        XCTAssertTrue(action.label.hasPrefix("Snooze for"))
    }

    func testSmartFundingProductionPreviewCancelAndConfirmRefreshes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=plan"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        func openPreview() {
            app.buttons["plan-add-menu"].tap()
            app.buttons["Smart Funding"].tap()
            XCTAssertTrue(app.navigationBars["Smart Funding"].waitForExistence(timeout: 5))
        }
        openPreview()
        let confirm = app.navigationBars["Smart Funding"].buttons["Confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isEnabled)
        let shortfall = app.staticTexts["smart-funding-shortfall"]
        XCTAssertTrue(shortfall.exists, "The seeded needs exceed available money and must be explained")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Smart Funding"].waitForNonExistence(timeout: 5))
        openPreview()
        XCTAssertTrue(confirm.isEnabled, "Cancelling must not consume the available allocation")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Smart Funding"].waitForNonExistence(timeout: 5))
        openPreview()
        XCTAssertFalse(confirm.isEnabled, "The seeded available allocation is exhausted; no repeated commit is offered")
        XCTAssertTrue(shortfall.exists, "No available money does not mean every target is funded")
        app.buttons["Cancel"].tap()
    }

    func testProductionDebtOverviewActuallyRendersHistoryAndExactObservations() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()
        let debt = app.buttons["insights-debt-interest"]
        for _ in 0..<6 where !debt.exists { app.swipeUp() }
        debt.tap()
        app.buttons["report-period"].tap()
        app.buttons["90 Days"].tap()
        let chart = app.descendants(matching: .any)["debt-history-chart"]
        for _ in 0..<10 where !chart.exists || chart.frame.intersection(app.frame).height < 180 { app.swipeUp() }
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "An unused chart type or source-string assertion is not production rendering")
        XCTAssertTrue(chart.label.contains("Debt history"))
        XCTAssertGreaterThan(chart.frame.intersection(app.frame).height, 100)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production debt history with currency axis"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let accessibility = XCTAttachment(string: chart.debugDescription)
        accessibility.name = "Debt chart accessibility hierarchy"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        let observations = app.buttons["Recorded observations"]
        for _ in 0..<5 where !observations.exists { app.swipeUp() }
        observations.tap()
        let closing = app.descendants(matching: .any)["debt-observation-2026-09-30"]
        for _ in 0..<5 where !closing.exists { app.swipeUp() }
        XCTAssertTrue(closing.waitForExistence(timeout: 5))
        XCTAssertTrue(closing.label.contains("$") || String(describing: closing.value).contains("$"))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }
    func testDebtCurrentCostIsSeparateFromRecordedInterestAndOpensSharedTerms() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()
        let debt = app.buttons["insights-debt-interest"]
        for _ in 0..<6 where !debt.exists { app.swipeUp() }
        debt.tap()
        app.segmentedControls.buttons["Cost"].tap()
        let estimate = app.descendants(matching: .any)["estimated-debt-cost-visa"]
        for _ in 0..<8 where !estimate.exists { app.swipeUp() }
        XCTAssertTrue(estimate.waitForExistence(timeout: 5))
        XCTAssertTrue(estimate.label.contains("Estimated monthly interest"))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        let edit = app.buttons["cost-debt-terms-visa"]
        for _ in 0..<4 where !edit.exists { app.swipeUp() }
        edit.tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Debt & Interest"].waitForExistence(timeout: 5))
        for _ in 0..<8 where !app.segmentedControls.buttons["Interest"].isHittable { app.swipeDown() }
        app.segmentedControls.buttons["Interest"].tap()
        XCTAssertTrue(app.staticTexts["Recorded Interest"].waitForExistence(timeout: 5))
    }
    func testAppearancePreferenceUsesProductionSettingsAndPersistsAcrossRelaunch() {
        let suite = "BudgetAppUITests.Appearance.\(UUID().uuidString)"
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=home", "--ui-test-appearance-suite=\(suite)"]
        app.launch()

        app.buttons["profile-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        app.buttons["appearance-settings-action"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons["Dark"].isSelected || app.buttons["Dark"].value as? String == "1")

        app.terminate(); app.launch()
        app.buttons["profile-settings-button"].tap()
        app.buttons["appearance-settings-action"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Dark"].isSelected || app.buttons["Dark"].value as? String == "1")
        app.buttons["Light"].tap()
        app.buttons["System"].tap()
        XCTAssertTrue(app.buttons["System"].isSelected || app.buttons["System"].value as? String == "1")
    }

    func testHomeQuickActionsOpenCanonicalProductionEditors() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=home"]
        app.launch()

        XCTAssertTrue(app.buttons["home-add-transaction"].waitForExistence(timeout: 5))
        app.buttons["home-add-transaction"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["home-move-money"].waitForExistence(timeout: 5))
        app.buttons["home-move-money"].tap()
        XCTAssertTrue(app.navigationBars["Move Money"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["home-add-schedule"].waitForExistence(timeout: 5))
        app.buttons["home-add-schedule"].tap()
        XCTAssertTrue(app.navigationBars["New Schedule"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

    func testHomeNeedsAttentionOpensCanonicalCategoryResolution() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=home"]
        app.launch()

        let attention = app.buttons["home-attention-category-dining"]
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        attention.tap()
        XCTAssertTrue(app.navigationBars["Dining Out"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Assign money"].exists)
        XCTAssertTrue(app.buttons["Move money"].exists)
    }

    func testFreshHomeHasIntentionalUpcomingAndActivityEmptyStates() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=home", "--skip-guided-onboarding"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["home-upcoming-empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["home-recent-empty"].exists)
        XCTAssertFalse(app.staticTexts["Needs attention"].exists)
    }

    func testHomeActionsAndAttentionRemainReachableInDarkAccessibilityText() {
        let device = XCUIDevice.shared
        let originalAppearance = device.appearance
        device.appearance = .dark
        defer { device.appearance = originalAppearance }

        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--demo-screen=home",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        ]
        app.launch()

        XCTAssertTrue(app.buttons["home-add-transaction"].waitForExistence(timeout: 5))
        let attention = app.buttons["home-attention-category-dining"]
        if !attention.exists { app.swipeUp() }
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        attention.tap()
        XCTAssertTrue(app.navigationBars["Dining Out"].waitForExistence(timeout: 5))
    }

    func testPlanCategoryFavoritePersistsAndFiltersThroughProductionWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=plan"]
        app.launch()

        let dining = app.buttons["plan-category-dining"]
        XCTAssertTrue(dining.waitForExistence(timeout: 5))
        dining.tap()
        let favorite = app.buttons["category-favorite-action"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertTrue(favorite.label.contains("Add to favorites"))
        favorite.tap()
        XCTAssertTrue(app.buttons["category-favorite-action"].label.contains("Remove from favorites"))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let focus = app.buttons["Focus, All"]
        XCTAssertTrue(focus.waitForExistence(timeout: 5))
        focus.tap()
        app.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["plan-category-dining"].waitForExistence(timeout: 5))
    }

    func testProductionInsightsRemainReachableInDarkModeAtAccessibilityTextSize() {
        let device = XCUIDevice.shared
        let originalAppearance = device.appearance
        device.appearance = .dark
        defer { device.appearance = originalAppearance }

        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--demo-screen=insights",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        let spending = app.buttons["insights-spending-income"]
        for _ in 0..<8 where !spending.exists { app.swipeUp() }
        XCTAssertTrue(spending.waitForExistence(timeout: 5))
        let debt = app.buttons["insights-debt-interest"]
        for _ in 0..<8 where !debt.exists { app.swipeUp() }
        XCTAssertTrue(debt.waitForExistence(timeout: 5), "large accessibility text must keep every focused report reachable")
        debt.tap()
        let sections = app.buttons["debt-insights-sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5), "Accessibility sizes use a readable menu rather than four cramped segments")
        sections.tap()
        app.buttons["Cost"].tap()
        let estimated = app.descendants(matching: .any)["estimated-debt-cost-visa"]
        for _ in 0..<10 where !estimated.exists { app.swipeUp() }
        XCTAssertTrue(estimated.waitForExistence(timeout: 5))
    }

    func testProductionTimeSeriesMarksExposeCurrencyInsteadOfRawMinorUnits() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()

        func checkChart(_ identifier: String, labelPrefix: String) {
            let chart = app.descendants(matching: .any)[identifier]
            for _ in 0..<12 where !chart.exists { app.swipeUp() }
            XCTAssertTrue(chart.waitForExistence(timeout: 5))
            let hierarchy = XCTAttachment(string: chart.debugDescription)
            hierarchy.name = identifier + " accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let marks = chart.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix))
            XCTAssertGreaterThan(marks.count, 0, "The actual chart must expose its data points")
            for mark in marks.allElementsBoundByIndex {
                XCTAssertTrue((mark.value as? String)?.contains("$") == true, "Expected formatted currency, not integer cents: \(mark.debugDescription)")
            }
        }
        XCTAssertTrue(app.buttons["insights-spending-income"].waitForExistence(timeout: 5))
        app.buttons["insights-spending-income"].tap()
        checkChart("income-spending-trends-chart", labelPrefix: "Income during")
        checkChart("spending-trends-chart", labelPrefix: "Groceries spending during")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["insights-net-worth"].tap()
        checkChart("net-worth-history-chart", labelPrefix: "Net worth on")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["insights-plan-performance"].tap()
        checkChart("plan-performance-history-chart", labelPrefix: "Assigned during")
    }

    func testProductionDebtPayoffScenarioIsReadOnlyAndExposesExplicitAssumptions() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()

        let debt = app.buttons["insights-debt-interest"]
        for _ in 0..<8 where !debt.exists { app.swipeUp() }
        XCTAssertTrue(debt.waitForExistence(timeout: 5))
        debt.tap()
        XCTAssertTrue(app.navigationBars["Debt & Interest"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Payoff"].tap()
        XCTAssertTrue(app.segmentedControls["debt-payoff-strategy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["debt-payoff-rollover"].exists)
        let outcome = app.descendants(matching: .any)["debt-payoff-outcome"]
        for _ in 0..<8 where !outcome.exists { app.swipeUp() }
        XCTAssertTrue(outcome.waitForExistence(timeout: 8))
        let projectedInterest = app.staticTexts["Projected remaining interest"]
        for _ in 0..<4 where !projectedInterest.exists { app.swipeUp() }
        XCTAssertTrue(projectedInterest.exists)
        let readOnly = app.descendants(matching: .any)["debt-payoff-read-only"]
        for _ in 0..<5 where !readOnly.exists { app.swipeUp() }
        XCTAssertTrue(readOnly.waitForExistence(timeout: 5))
    }

    func testPayoffHorizonShowsPartialResultsInsteadOfCompleteCost() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()
        let debt = app.buttons["insights-debt-interest"]
        XCTAssertTrue(debt.waitForExistence(timeout: 5))
        debt.tap()
        app.segmentedControls.buttons["Payoff"].tap()
        let rollover = app.switches["debt-payoff-rollover"]
        XCTAssertTrue(rollover.waitForExistence(timeout: 5))
        rollover.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(rollover.value as? String, "0")
        let terms = app.buttons["payoff-debt-terms-auto"]
        for _ in 0..<10 where !terms.isHittable { app.swipeUp() }
        XCTAssertTrue(terms.isHittable)
        terms.tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForExistence(timeout: 5))
        let apr = app.textFields["debt-apr"]
        XCTAssertEqual(apr.value as? String, "6.25")
        apr.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        apr.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "0")
        app.buttons["Clear Payment"].tap()
        app.textFields["debt-payment"].typeText("0.01")
        app.buttons["save-debt-terms"].tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForNonExistence(timeout: 5))
        let horizon = app.descendants(matching: .any)["debt-payoff-horizon"]
        for _ in 0..<10 where !horizon.exists { app.swipeDown() }
        XCTAssertTrue(horizon.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Interest within modeled horizon"].exists)
        XCTAssertTrue(app.staticTexts["Payments within modeled horizon"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["debt-payoff-outcome"].exists)
        XCTAssertFalse(app.staticTexts["Total projected cost"].exists)
        XCTAssertFalse(app.staticTexts["Projected interest avoided"].exists)
    }

    func testPayoffMissingTermsOpensSharedEditorAndRecalculatesAfterSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()
        let debt = app.buttons["insights-debt-interest"]
        XCTAssertTrue(debt.waitForExistence(timeout: 5))
        debt.tap()
        app.segmentedControls.buttons["Payoff"].tap()
        let terms = app.buttons["payoff-debt-terms-auto"]
        for _ in 0..<10 where !terms.isHittable { app.swipeUp() }
        XCTAssertTrue(terms.isHittable)
        terms.tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForExistence(timeout: 5))
        let remove = app.buttons["Remove Debt Terms"]
        for _ in 0..<8 where !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForNonExistence(timeout: 5))
        let add = app.buttons["payoff-missing-terms-auto"]
        for _ in 0..<10 where !add.isHittable { app.swipeDown() }
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForExistence(timeout: 5))
        let apr = app.textFields["debt-apr"]
        XCTAssertTrue(apr.waitForExistence(timeout: 5))
        apr.tap(); apr.typeText("6.25")
        let payment = app.textFields["debt-payment"]
        payment.tap(); payment.typeText("412.00")
        let due = app.textFields["debt-due-day"]
        due.tap(); due.typeText("1")
        app.buttons["save-debt-terms"].tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForNonExistence(timeout: 5))
        let outcome = app.descendants(matching: .any)["debt-payoff-outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 8))
        XCTAssertFalse(add.exists)
    }

    func legacyProductionInsightsChartsAndDrillThroughRemainNavigable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        let spending = app.otherElements.matching(identifier: "spending-breakdown-sector-chart").firstMatch
        XCTAssertTrue(spending.waitForExistence(timeout: 5))
        XCTAssertFalse(spending.label.isEmpty)

        let spendingTrends = app.otherElements.matching(identifier: "spending-trends-chart").firstMatch
        for _ in 0..<5 where !spendingTrends.exists { app.swipeUp() }
        XCTAssertTrue(spendingTrends.waitForExistence(timeout: 5))
        XCTAssertTrue(spendingTrends.label.contains("Spending trends"))
        let payees = app.segmentedControls.buttons["Payees"]
        XCTAssertTrue(payees.waitForExistence(timeout: 5))
        payees.tap()
        let payeeTrend = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'spending-trend-payee-'")).firstMatch
        XCTAssertTrue(payeeTrend.waitForExistence(timeout: 5))
        payeeTrend.tap()
        XCTAssertTrue(app.navigationBars.element.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Insights"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))

        let cashFlow = app.otherElements.matching(identifier: "income-spending-trends-chart").firstMatch
        for _ in 0..<5 where !cashFlow.exists { app.swipeUp() }
        XCTAssertTrue(cashFlow.waitForExistence(timeout: 5))

        let netWorth = app.otherElements.matching(identifier: "net-worth-history-chart").firstMatch
        for _ in 0..<5 where !netWorth.exists { app.swipeUp() }
        XCTAssertTrue(netWorth.waitForExistence(timeout: 5))
        XCTAssertTrue(netWorth.value as? String != nil)

        let account = app.buttons["net-worth-account-checking"]
        for _ in 0..<3 where !account.exists { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.navigationBars["Household Checking"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Insights"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))

        let category = app.buttons["plan-performance-category-dining"]
        for _ in 0..<8 where !category.exists { app.swipeUp() }
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        XCTAssertTrue(app.navigationBars["Dining Out"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Insights"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
    }

    func testProductionDebtInsightsExposeExplicitRecordedInterest() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        app.buttons["insights-debt-interest"].tap()
        XCTAssertTrue(app.navigationBars["Debt & Interest"].waitForExistence(timeout: 5))
        let observation = app.descendants(matching: .any)["recorded-debt-as-of"]
        for _ in 0..<6 where !observation.exists { app.swipeUp() }
        XCTAssertTrue(observation.waitForExistence(timeout: 5))
        XCTAssertTrue(observation.label.contains("Debt as of"))
        for _ in 0..<6 where !app.segmentedControls.buttons["Interest"].isHittable { app.swipeDown() }
        app.segmentedControls.buttons["Interest"].tap()
        XCTAssertTrue(app.buttons["report-period"].exists || app.descendants(matching: .any)["report-period"].exists)
        let recordedInterest = app.staticTexts["Recorded Interest"]
        for _ in 0..<24 where !recordedInterest.exists { app.swipeUp() }
        XCTAssertTrue(recordedInterest.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Selected range"].exists)
        let range = app.descendants(matching: .any)["recorded-interest-range"]
        XCTAssertTrue(range.exists)
        XCTAssertTrue(range.label.contains("$32.00") || String(describing: range.value).contains("$32.00"))
        let allRecorded = app.descendants(matching: .any)["recorded-interest-lifetime"]
        for _ in 0..<6 where !allRecorded.exists { app.swipeUp() }
        XCTAssertTrue(allRecorded.waitForExistence(timeout: 5))
    }

    func testInsightsReportFiltersAreReachableAndPreserveAppliedContext() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()
        let filters = app.buttons["insights-report-filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        XCTAssertTrue(app.navigationBars["Report Filters"].waitForExistence(timeout: 5))
        let tag = app.textFields["Tag"]
        if !tag.isHittable { app.swipeUp() }
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.tap()
        tag.typeText("report-filter-regression")
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        filters.tap()
        XCTAssertTrue(app.navigationBars["Report Filters"].waitForExistence(timeout: 5))
        if !tag.isHittable { app.swipeUp() }
        XCTAssertEqual(tag.value as? String, "report-filter-regression")
        app.buttons["Reset"].tap()
        XCTAssertEqual(tag.value as? String, "Tag")
        app.buttons["Apply"].tap()
        app.buttons["insights-spending-income"].tap()
        XCTAssertTrue(app.navigationBars["Spending & Income"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements.matching(identifier: "spending-breakdown-sector-chart").firstMatch.waitForExistence(timeout: 5))
    }

    func testInsightsHubNavigatesFocusedReportsAndDebtProgression() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        app.buttons["insights-spending-income"].tap(); XCTAssertTrue(app.navigationBars["Spending & Income"].waitForExistence(timeout:5)); XCTAssertTrue(app.otherElements.matching(identifier:"spending-breakdown-sector-chart").firstMatch.waitForExistence(timeout:5)); app.navigationBars.buttons["Insights"].tap()
        app.buttons["insights-net-worth"].tap(); XCTAssertTrue(app.navigationBars["Net Worth"].waitForExistence(timeout:5)); app.navigationBars.buttons["Insights"].tap()
        app.buttons["insights-plan-performance"].tap(); XCTAssertTrue(app.descendants(matching:.any)["insights-plan-report"].waitForExistence(timeout:5)); app.swipeRight()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout:5))
        app.buttons["insights-debt-interest"].tap(); XCTAssertTrue(app.navigationBars["Debt & Interest"].waitForExistence(timeout:5)); app.navigationBars.buttons["Insights"].tap()
        app.buttons["insights-debt-interest"].tap()
        app.segmentedControls.buttons["Interest"].tap(); XCTAssertTrue(app.staticTexts["Recorded Interest"].exists)
        app.segmentedControls.buttons["Payoff"].tap()
        XCTAssertTrue(app.segmentedControls["debt-payoff-strategy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["debt-payoff-strategy"].buttons["Avalanche"].exists)
    }

    func testProductionAuthenticationFieldsAcceptContinuousKeyboardInput() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authentication"]
        app.launch()

        XCTAssertTrue(app.staticTexts["runtime-build-identity"].waitForExistence(timeout: 5))

        let email = app.textFields["auth-email-field"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("owner@example.com")
        XCTAssertEqual(email.value as? String, "owner@example.com")

        let password = app.secureTextFields["auth-password-field"]
        XCTAssertTrue(password.exists)
        password.tap()
        password.typeText("correct horse battery staple")
        XCTAssertEqual((password.value as? String)?.count, 28)

        XCTAssertTrue(email.exists, "typing must not replace the production authentication route")
        XCTAssertFalse(app.buttons["Budgets"].exists, "authentication must not restore a Budgets parent shell")
    }

    func testFreshProductionWorkspaceTabsAndGlobalProfileRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--skip-guided-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["runtime-build-identity"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Account"].exists)
        XCTAssertTrue(app.buttons["profile-settings-button"].exists)

        let planTab = app.tabBars.buttons["Plan"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            planTab.tap()
            XCTAssertTrue(planTab.isSelected, "the production Plan tab must actually accept the tap")
            XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Create Category Group"].exists)
            XCTAssertTrue(app.buttons["profile-settings-button"].exists)

            app.tabBars.buttons["Accounts"].tap()
            XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Add Account"].exists)
        }

        planTab.tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Category Group"].exists)
        XCTAssertTrue(app.buttons["profile-settings-button"].exists)

        app.buttons["profile-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Budgets"].exists)
    }

    func testFreshProductionWorkspaceGuidedOnboardingCanSkipResumeAndRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--ui-test-reset-guided-onboarding"]
        app.launch()

        let guide = app.descendants(matching: .any)["guided-onboarding"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Guided Tour"].exists)
        XCTAssertTrue(app.staticTexts["Where money lives"].exists)
        XCTAssertTrue(app.staticTexts["Next useful action: add your first real account."].exists)

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["What money is for"].waitForExistence(timeout: 5))
        app.buttons["Skip"].tap()
        XCTAssertTrue(guide.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)

        app.buttons["profile-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        app.buttons["Continue Guided Tour"].tap()
        XCTAssertTrue(app.staticTexts["What money is for"].waitForExistence(timeout: 5), "the production guide must resume at its persisted lesson")
        app.buttons["Open Plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Category Group"].exists)
    }

    func testFreshAccountMetadataEditPreservesBalanceAndExposesTreatment() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=accounts", "--skip-guided-onboarding"]
        app.launch()

        app.buttons["Add Account"].tap()
        XCTAssertTrue(app.navigationBars["New Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["new-account-treatment"].exists)
        app.textFields["new-account-name"].tap()
        app.textFields["new-account-name"].typeText("Test Checking")
        app.textFields["Balance"].tap()
        app.textFields["Balance"].typeText("2000.00")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-row-' AND label CONTAINS 'Test Checking'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["$2,000.00"].waitForExistence(timeout: 5))
        app.buttons["account-settings-action"].tap()
        XCTAssertTrue(app.navigationBars["Account Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Budget treatment"].exists)
        XCTAssertFalse(app.textFields["Balance"].exists, "metadata settings must not expose a balance editor")

        let name = app.textFields["account-settings-name"]
        name.tap()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Emergency Savings")
        app.buttons["account-settings-type"].tap()
        app.buttons["Savings"].tap()
        app.buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["Account Settings"].waitForNonExistence(timeout: 5))
        app.navigationBars.buttons["Accounts"].tap()
        let updatedRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-row-' AND label CONTAINS 'Emergency Savings'")).firstMatch
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 5))
        updatedRow.tap()
        XCTAssertTrue(app.staticTexts["$2,000.00"].exists)
    }

    func testDebtTermsUseProductionAccountSettingsAndPersistWithoutBalanceEditing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=accounts"]
        app.launch()

        let loan = app.buttons["account-row-auto"]
        XCTAssertTrue(loan.waitForExistence(timeout: 5))
        loan.tap()
        app.buttons["account-settings-action"].tap()
        XCTAssertTrue(app.navigationBars["Account Settings"].waitForExistence(timeout: 5))
        app.buttons["account-debt-terms-action"].tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["These are planning assumptions. Posted balances and actual interest remain separate financial facts."].exists)

        let apr = app.textFields["debt-apr"]
        XCTAssertEqual(apr.value as? String, "6.25")
        apr.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        apr.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        apr.typeText("7.25")
        let payment = app.textFields["debt-payment"]
        app.buttons["Clear Payment"].tap()
        payment.typeText("425.00")
        let dueDay = app.textFields["debt-due-day"]
        XCTAssertEqual(dueDay.value as? String, "1")
        dueDay.tap(); dueDay.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        app.buttons.matching(NSPredicate(format: "identifier == 'save-debt-terms'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForNonExistence(timeout: 5))

        app.buttons["account-debt-terms-action"].tap()
        XCTAssertTrue(app.navigationBars["Debt Terms"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["debt-apr"].value as? String, "7.25")
        XCTAssertEqual(app.textFields["debt-payment"].value as? String, "425.00")
        XCTAssertEqual(app.textFields["debt-due-day"].value as? String, "2")
        let remove = app.buttons["Remove Debt Terms"]
        for _ in 0..<6 where !remove.exists { app.swipeUp() }
        XCTAssertTrue(remove.exists)
    }

    func testEmptyCategoryGroupRemainsVisibleAndDefaultsCategoryCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=plan", "--skip-guided-onboarding"]
        app.launch()

        app.buttons["Create Category Group"].tap()
        XCTAssertTrue(app.navigationBars["New Category Group"].waitForExistence(timeout: 5))
        app.textFields["new-group-name"].tap()
        app.textFields["new-group-name"].typeText("Monthly Expenses")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["Monthly Expenses"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No categories yet"].exists)
        let addCategory = app.buttons["empty-group-add-category-demo-group-monthly-expenses"]
        XCTAssertTrue(addCategory.exists)
        addCategory.tap()
        XCTAssertTrue(app.navigationBars["New Category"].waitForExistence(timeout: 5))
        app.textFields["new-category-name"].tap()
        app.textFields["new-category-name"].typeText("Groceries")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["Monthly Expenses"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Groceries'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Monthly Expenses'")).count, 1)
    }

    func testPopulatedPlanCanCreateAndManageAdditionalCategoryGroups() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=plan", "--skip-guided-onboarding"]
        app.launch()
        let groupPicker = app.descendants(matching: .any).matching(identifier: "new-category-group").firstMatch

        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        app.buttons["Create Category Group"].tap()
        XCTAssertTrue(app.navigationBars["New Category Group"].waitForExistence(timeout: 5))
        app.textFields["new-group-name"].tap()
        app.textFields["new-group-name"].typeText("Monthly Expenses")
        app.buttons["Create"].tap()
        let addFirstCategory = app.buttons["empty-group-add-category-demo-group-monthly-expenses"]
        XCTAssertTrue(addFirstCategory.waitForExistence(timeout: 5))
        addFirstCategory.tap()
        app.textFields["new-category-name"].tap()
        app.textFields["new-category-name"].typeText("Groceries")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Monthly Expenses"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Groceries'")).firstMatch.exists)

        app.buttons["plan-add-menu"].tap()
        XCTAssertTrue(app.buttons["add-category-group-action"].waitForExistence(timeout: 5))
        app.buttons["add-category-group-action"].tap()
        XCTAssertTrue(app.navigationBars["New Category Group"].waitForExistence(timeout: 5))
        app.textFields["new-group-name"].tap()
        app.textFields["new-group-name"].typeText("Savings Goals")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["Savings Goals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No categories yet"].exists)
        let addCategory = app.buttons["empty-group-add-category-demo-group-savings-goals"]
        if !addCategory.exists { app.swipeUp() }
        XCTAssertTrue(addCategory.waitForExistence(timeout: 5))
        addCategory.tap()
        XCTAssertTrue(app.navigationBars["New Category"].waitForExistence(timeout: 5))
        XCTAssertTrue(groupPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(groupPicker.value as? String, "Savings Goals")
        app.textFields["new-category-name"].tap()
        app.textFields["new-category-name"].typeText("Emergency Fund")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Emergency Fund'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Groceries'")).firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Savings Goals'")).count, 1)

        app.swipeDown()
        let monthlyAddCategory = app.buttons["group-add-category-demo-group-monthly-expenses"]
        XCTAssertTrue(monthlyAddCategory.waitForExistence(timeout: 5))
        monthlyAddCategory.tap()
        XCTAssertTrue(app.navigationBars["New Category"].waitForExistence(timeout: 5))
        XCTAssertTrue(groupPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(groupPicker.value as? String, "Monthly Expenses")
        app.textFields["new-category-name"].tap()
        app.textFields["new-category-name"].typeText("Utilities")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Utilities'")).firstMatch.waitForExistence(timeout: 5))

        app.swipeUp()
        let savingsAddCategory = app.buttons["group-add-category-demo-group-savings-goals"]
        XCTAssertTrue(savingsAddCategory.waitForExistence(timeout: 5))
        savingsAddCategory.tap()
        XCTAssertTrue(app.navigationBars["New Category"].waitForExistence(timeout: 5))
        XCTAssertTrue(groupPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(groupPicker.value as? String, "Savings Goals")
        app.textFields["new-category-name"].tap()
        app.textFields["new-category-name"].typeText(" emergency fund ")
        XCTAssertTrue(app.staticTexts["category-name-conflict"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["plan-add-menu"].tap()
        app.buttons["global-add-category-action"].tap()
        XCTAssertTrue(app.navigationBars["New Category"].waitForExistence(timeout: 5))
        XCTAssertTrue(groupPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(groupPicker.value as? String, "Monthly Expenses", "global creation must use its normal first-group default, not stale contextual state")
        app.buttons["Cancel"].tap()

        app.buttons["plan-add-menu"].tap()
        app.buttons["manage-category-groups-action"].tap()
        XCTAssertTrue(app.navigationBars["Category Groups"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["manage-groups-add-action"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Order '")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Savings Goals"].exists)
        XCTAssertTrue(app.staticTexts["Monthly Expenses"].exists)
        app.buttons["manage-groups-add-action"].tap()
        XCTAssertTrue(app.navigationBars["New Category Group"].waitForExistence(timeout: 5))
    }

    func testProductionPlanAssignmentFieldCanClearReplaceAndSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=plan"]
        app.launch()

        XCTAssertTrue(app.staticTexts["runtime-build-identity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        let groceries = app.buttons["plan-category-groceries"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        app.buttons["Assign money"].tap()

        let field = app.textFields["Assigned amount"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "720.00")
        app.buttons["Clear Assigned amount"].tap()
        XCTAssertEqual(field.value as? String, "0.00", "the empty editing buffer must remain active rather than restoring the model value")
        field.typeText("820.00")
        XCTAssertEqual(field.value as? String, "820.00")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["Edit Assignment"].waitForNonExistence(timeout: 5))
        app.buttons["Assign money"].tap()
        let persistedField = app.textFields["Assigned amount"]
        XCTAssertTrue(persistedField.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedField.value as? String, "820.00")
    }

    func testDeterministicMutationResetsAfterProcessRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=plan"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        app.buttons["plan-category-groceries"].tap()
        app.buttons["Assign money"].tap()

        let field = app.textFields["Assigned amount"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "720.00")
        app.buttons["Clear Assigned amount"].tap()
        field.typeText("820.00")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Assignment"].waitForNonExistence(timeout: 5))

        app.terminate()
        app.launch()

        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        app.buttons["plan-category-groceries"].tap()
        app.buttons["Assign money"].tap()
        let relaunchedField = app.textFields["Assigned amount"]
        XCTAssertTrue(relaunchedField.waitForExistence(timeout: 5))
        XCTAssertEqual(
            relaunchedField.value as? String,
            "720.00",
            "the deterministic repository is an intentionally ephemeral fixture and must rebuild its seed after process relaunch"
        )
    }

    func testAccountRegisterExposesCanonicalTransferWithCurrentAccountSelected() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Accounts"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        app.buttons["account-row-checking"].tap()
        XCTAssertTrue(app.navigationBars["Household Checking"].waitForExistence(timeout: 5))
        app.buttons["Transfer"].tap()

        XCTAssertTrue(app.navigationBars["Transfer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["transfer-source-account"].value as? String, "Household Checking")
        XCTAssertEqual(app.buttons["transfer-destination-account"].value as? String, "High-Yield Savings")
        let amount = app.textFields["Amount"]
        amount.tap()
        var expectedAmount = ""
        for character in "200.00" {
            amount.typeText(String(character))
            expectedAmount.append(character)
            XCTAssertEqual(amount.value as? String, expectedAmount)
        }
        let memo = app.textFields["Memo"]
        memo.tap()
        var expectedMemo = ""
        for character in "Stage 2 transfer test" {
            memo.typeText(String(character))
            expectedMemo.append(character)
            XCTAssertEqual(memo.value as? String, expectedMemo)
        }
        app.buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["Transfer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Transfer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'To High-Yield Savings'" )).firstMatch.exists)

        let transferRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'")).matching(NSPredicate(format: "label CONTAINS 'Transfer'")).firstMatch
        XCTAssertTrue(transferRow.waitForExistence(timeout: 5)); transferRow.tap()
        XCTAssertTrue(app.navigationBars["Transfer Detail"].waitForExistence(timeout: 5))
        app.buttons["More"].tap(); app.buttons["edit-transfer-action"].tap()
        XCTAssertTrue(app.navigationBars["Edit Transfer"].waitForExistence(timeout: 5))
        app.buttons["Clear Amount"].tap(); app.textFields["Amount"].tap(); app.textFields["Amount"].typeText("20.00")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Transfer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["-$20.00"].waitForExistence(timeout: 5))
        app.buttons["More"].tap(); app.buttons["delete-transfer-action"].tap(); app.buttons["Delete Transfer"].tap()
        XCTAssertTrue(app.navigationBars["Transfer Detail"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'"))
                .matching(NSPredicate(format: "label CONTAINS 'To High-Yield Savings'"))
                .firstMatch.exists,
            "deleting the transfer must remove its canonical row from the originating register"
        )
    }

    func testAccountRegisterQuickClearingAndReconciledLockout() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=accounts"]
        app.launch()

        app.buttons["account-row-visa"].tap()
        let row = app.buttons["transaction-row-t1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "Details")
        row.swipeLeft()
        app.buttons["Clear"].tap()
        XCTAssertEqual(row.value as? String, "C · Details")

        row.swipeLeft()
        app.buttons["Unclear"].tap()
        XCTAssertEqual(row.value as? String, "Details")
        row.swipeLeft()
        app.buttons["Clear"].tap()
        app.buttons["Reconcile"].tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Reconcile'")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["Reconcile Everyday Visa"].buttons["Reconcile"].tap()
        XCTAssertTrue(app.navigationBars["Reconcile Everyday Visa"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "R · Details")
        row.swipeLeft()
        XCTAssertFalse(app.buttons["Clear"].exists)
        XCTAssertFalse(app.buttons["Unclear"].exists)
    }

    func testActivityUsesTheSharedQuickClearingInteraction() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        let row = app.buttons["transaction-row-t1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "Uncleared")
        row.swipeLeft()
        app.buttons["Clear"].tap()
        XCTAssertEqual(row.value as? String, "Cleared")
        row.swipeLeft()
        app.buttons["Unclear"].tap()
        XCTAssertEqual(row.value as? String, "Uncleared")
    }

    func testMoveMoneyFromCategoryPreservesSourceContextAndUsesUnassignedTerm() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=plan"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        app.buttons["plan-category-groceries"].tap()
        app.buttons["Move money"].tap()

        XCTAssertTrue(app.navigationBars["Move Money"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.buttons["move-source-category"].value as? String)?.hasPrefix("Groceries") == true)
        app.buttons["Cancel"].tap()
        app.buttons["Assign money"].tap()
        XCTAssertTrue(app.staticTexts["Enter a negative amount to move money back to Unassigned."].waitForExistence(timeout: 5))
    }

    func testDeletingTransactionReturnsToOriginatingRegister() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=accounts"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        app.buttons["account-row-checking"].tap()
        app.buttons["transaction-row-t2"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        app.buttons["Delete"].tap()
        app.buttons["Delete Transaction"].tap()

        XCTAssertTrue(app.navigationBars["Household Checking"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["transaction-row-t2"].exists)
    }

    func testProductionActivitySeparatesActualAndScheduledEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        app.buttons["add-activity-action"].tap()
        XCTAssertTrue(app.buttons["Schedule Transaction"].waitForExistence(timeout: 5))
        app.buttons["Schedule Transaction"].tap()
        XCTAssertTrue(app.navigationBars["New Schedule"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["schedule-next-date"].exists)
        app.buttons["Cancel"].tap()

        app.buttons["add-activity-action"].tap()
        app.buttons["Transaction"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Transactions record money that has already happened. Use Schedule Transaction for a future expense, income, or transfer."].exists)
    }

    func testProductionScheduledOccurrenceRealizesThroughPostedActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS 'Electric utility'")).firstMatch.exists,
            "a scheduled occurrence must not appear in posted activity before realization"
        )

        app.buttons["Scheduled transactions"].tap()
        XCTAssertTrue(app.navigationBars["Scheduled"].waitForExistence(timeout: 5))
        let schedule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Electric utility,'")).firstMatch
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()

        XCTAssertTrue(app.navigationBars["Edit Schedule"].waitForExistence(timeout: 5))
        app.buttons["Enter Now"].tap()
        let confirmation = app.sheets.buttons["Enter Now"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()

        XCTAssertTrue(app.navigationBars["Scheduled"].waitForExistence(timeout: 5))
        app.navigationBars["Scheduled"].buttons["Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS 'Electric utility'")).firstMatch.waitForExistence(timeout: 5),
            "realization must refresh the authoritative workspace and expose exactly one posted transaction"
        )
    }

    func testProductionPayeeManagementConfirmsAndFindsCreatedIdentity() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        app.buttons["profile-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        app.buttons["Household and access"].tap()
        XCTAssertTrue(app.navigationBars["Household"].waitForExistence(timeout: 5))
        app.buttons["Payees"].tap()
        XCTAssertTrue(app.navigationBars["Payees"].waitForExistence(timeout: 5))
        app.buttons["add-payee-action"].tap()
        XCTAssertTrue(app.navigationBars["New Payee"].waitForExistence(timeout: 5))
        app.textFields["payee-name"].tap()
        app.textFields["payee-name"].typeText("Neighborhood Market")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["New Payee"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["payee-created-confirmation"].waitForExistence(timeout: 5))
        let createdPayee = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payee-row-' AND label CONTAINS 'Neighborhood Market'")).firstMatch
        XCTAssertTrue(createdPayee.waitForExistence(timeout: 5), "management must search the authoritative identity after creation rather than relying on its first bounded page")

        app.navigationBars.buttons["Household"].tap()
        app.buttons["Payees"].tap()
        XCTAssertTrue(app.navigationBars["Payees"].waitForExistence(timeout: 5))
        app.searchFields["Search payees"].tap()
        app.searchFields["Search payees"].typeText("Neighborhood Market")
        XCTAssertTrue(createdPayee.waitForExistence(timeout: 5), "the created identity must persist when management is reopened")
    }

    func testOwnerCanPersistHumanReadableMemberAccessThroughProductionHouseholdFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        app.buttons["profile-settings-button"].tap()
        app.buttons["Household and access"].tap()
        XCTAssertTrue(app.navigationBars["Household"].waitForExistence(timeout: 5))
        app.buttons["member-access-demo-member"].tap()
        XCTAssertTrue(app.navigationBars["Sam Rivera"].waitForExistence(timeout: 5))

        let preset = app.buttons["member-access-preset"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        app.buttons["Full Access"].tap()
        let accountScope = app.switches["member-access-restrict-accounts"]
        for _ in 0..<6 where !accountScope.exists { app.swipeUp() }
        XCTAssertTrue(accountScope.waitForExistence(timeout: 5))
        accountScope.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.switches["Household Checking"].waitForExistence(timeout: 5))
        let checkingScope = app.switches["Household Checking"]
        checkingScope.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(checkingScope.value as? String, "1")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Saved"].waitForExistence(timeout: 5))

        app.navigationBars.buttons["Household"].tap()
        app.buttons["member-access-demo-member"].tap()
        XCTAssertTrue(app.navigationBars["Sam Rivera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["member-access-preset"].label.contains("Full Access"))
        for _ in 0..<6 where !app.switches["member-access-restrict-accounts"].exists { app.swipeUp() }
        XCTAssertEqual(app.switches["member-access-restrict-accounts"].value as? String, "1")
    }

    func testProductionPayeeManagementAddsAliasWithoutRewritingHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        app.buttons["profile-settings-button"].tap()
        app.buttons["Household and access"].tap()
        app.buttons["Payees"].tap()
        XCTAssertTrue(app.navigationBars["Payees"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payee-row-'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Payee"].waitForExistence(timeout: 5))
        if !app.textFields["payee-alias-name"].exists { app.swipeUp() }
        app.textFields["payee-alias-name"].tap()
        app.textFields["payee-alias-name"].typeText("Corner Shop")
        app.buttons["add-payee-alias"].tap()
        XCTAssertTrue(app.staticTexts["Corner Shop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Edit Payee"].exists)
    }

    func testProductionActivityUsesCanonicalSearchAndFilterBrowser() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction-row-t1"].waitForExistence(timeout: 5))
        app.buttons["transaction-filter-action"].tap()
        XCTAssertTrue(app.navigationBars["Filter Activity"].waitForExistence(timeout: 5))
        app.buttons["activity-payee-selector"].tap()
        XCTAssertTrue(app.navigationBars["Filter by Payee"].waitForExistence(timeout: 5))
        app.searchFields["Search payees"].tap()
        app.searchFields["Search payees"].typeText("Fresh")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payee-search-result-'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payee-search-result-'")).firstMatch.tap()
        app.buttons["Type, All types"].tap()
        app.buttons["Income"].tap()
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["transaction-row-t1"].waitForExistence(timeout: 1), "spending must be excluded from an income-only server-equivalent query")
        XCTAssertTrue(app.staticTexts["No matching transactions"].waitForExistence(timeout: 5), "the combined existing-payee and income filters should produce the production empty state")

        app.buttons["transaction-filter-action"].tap()
        app.swipeUp()
        app.buttons["Reset filters"].tap()
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["transaction-row-t1"].waitForExistence(timeout: 5))
    }

    func testProductionTransactionDetailDuplicatesThroughCanonicalWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        app.buttons["transaction-row-t1"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        app.buttons["duplicate-transaction-action"].tap()
        XCTAssertTrue(app.buttons["Duplicate Transaction"].waitForExistence(timeout: 5))
        app.buttons["Duplicate Transaction"].tap()

        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.navigationBars["Transaction"].buttons["Activity"].tap()
        let matchingRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS 'Fresh Market'")
        )
        XCTAssertEqual(matchingRows.count, 2, "duplication must refresh the canonical Activity browser with one additional posted row")
    }

    func testProductionAttachmentSourceChooserOffersCameraPhotosAndFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        XCTAssertTrue(app.buttons["transaction-row-t1"].waitForExistence(timeout: 5))
        app.buttons["transaction-row-t1"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.buttons["add-attachment-action"].tap()

        XCTAssertTrue(app.buttons.matching(identifier: "attachment-take-photo").firstMatch.waitForExistence(timeout: 5))
        let choosePhoto = app.buttons.matching(identifier: "attachment-choose-photo").firstMatch
        XCTAssertTrue(choosePhoto.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "attachment-choose-file").firstMatch.exists)
        choosePhoto.tap()
        XCTAssertFalse(choosePhoto.exists, "choosing Photos must dismiss the source dialog and present the native picker")
    }

    func testProductionAttachmentPreviewOpensWithoutInvokingRemoval() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        app.buttons["transaction-row-t1"].tap()
        let preview = app.buttons["attachment-preview-demo-attachment-t1"]
        let remove = app.buttons["attachment-remove-demo-attachment-t1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.exists)

        preview.tap()
        XCTAssertTrue(app.navigationBars["receipt-placeholder.png"].waitForExistence(timeout: 5), "preview must present the downloaded attachment")
        XCTAssertTrue(app.buttons["attachment-preview-back"].waitForExistence(timeout: 5))
    }

    func testProductionAttachmentRemovalRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        app.buttons["transaction-row-t1"].tap()
        let preview = app.buttons["attachment-preview-demo-attachment-t1"]
        let remove = app.buttons["attachment-remove-demo-attachment-t1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.exists)

        remove.tap()
        XCTAssertTrue(app.staticTexts["Remove Attachment?"].waitForExistence(timeout: 5))
        XCTAssertTrue(preview.exists, "opening removal confirmation must not detach")
        app.buttons["Remove Attachment"].tap()
        XCTAssertFalse(preview.waitForExistence(timeout: 2), "confirmed removal must detach exactly this attachment")
    }

    func testProductionTransactionDetailMakesRecurringThenCreatesAuditableReversal() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()
        XCTAssertTrue(app.buttons["transaction-row-t1"].waitForExistence(timeout: 5))
        app.buttons["transaction-row-t1"].tap()
        app.buttons["More"].tap()
        app.buttons["make-recurring-action"].tap()
        XCTAssertTrue(app.navigationBars["Make Recurring"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["recurring-next-date"].exists)
        app.buttons["save-recurring-action"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        app.buttons["void-transaction-action"].tap()
        XCTAssertTrue(app.navigationBars["Void Transaction"].waitForExistence(timeout: 5))
        app.textFields["void-reason"].tap()
        app.textFields["void-reason"].typeText("Duplicate charge")
        app.buttons["confirm-void-action"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        let postingStatus = app.staticTexts["transaction-posting-status"]
        XCTAssertTrue(postingStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(postingStatus.label.contains("VOIDED"))
        app.navigationBars["Transaction"].buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-posting-reversal-'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testProductionActivityBulkSelectionUpdatesThroughCanonicalWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        app.buttons["bulk-select-action"].tap()
        app.buttons["bulk-transaction-row-t1"].tap()
        app.buttons["bulk-update-menu"].tap()
        app.buttons["Mark Cleared"].tap()

        XCTAssertTrue(app.buttons["transaction-row-t1"].waitForExistence(timeout: 5))
        app.buttons["transaction-row-t1"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        let status = app.staticTexts["transaction-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Cleared"))
    }

    func testHideAmountsMasksProductionWorkspaceAndPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=home"]
        app.launch()

        XCTAssertTrue(app.buttons["profile-settings-button"].waitForExistence(timeout: 5))
        app.buttons["profile-settings-button"].tap()
        let toggle = app.switches["hide-amounts-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(expectValue("1", for: toggle, timeout: 2))
        app.buttons["Done"].tap()
        app.buttons["profile-settings-button"].tap()
        XCTAssertEqual(app.switches["hide-amounts-toggle"].value as? String, "1", "the production workspace must retain the active privacy state")
        app.buttons["Done"].tap()

        app.terminate()
        app.launch()
        app.buttons["profile-settings-button"].tap()
        let persistedToggle = app.switches["hide-amounts-toggle"]
        XCTAssertTrue(persistedToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedToggle.value as? String, "1")
        persistedToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func expectValue(_ value: String, for element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
