import XCTest

final class AuthenticationJourneyTests: XCTestCase {
    func testProductionInsightsRemainReachableInDarkModeAtAccessibilityTextSize() {
        let device = XCUIDevice.shared
        let originalAppearance = device.appearance
        device.appearance = .dark
        defer { device.appearance = originalAppearance }

        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--demo-screen=insights",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        let spending = app.otherElements.matching(identifier: "spending-breakdown-sector-chart").firstMatch
        XCTAssertTrue(spending.waitForExistence(timeout: 5))
        XCTAssertTrue(spending.label.contains("Spending breakdown"))

        let planRow = app.buttons["plan-performance-category-dining"]
        for _ in 0..<20 where !planRow.exists { app.swipeUp() }
        XCTAssertTrue(planRow.waitForExistence(timeout: 5), "large accessibility text must not make the final Insights sections unreachable")
    }

    func testProductionInsightsChartsAndDrillThroughRemainNavigable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=insights"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        let spending = app.otherElements.matching(identifier: "spending-breakdown-sector-chart").firstMatch
        XCTAssertTrue(spending.waitForExistence(timeout: 5))
        XCTAssertFalse(spending.label.isEmpty)

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
        app.launchArguments = ["--demo", "--demo-fresh-budget"]
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

    func testFreshAccountMetadataEditPreservesBalanceAndExposesTreatment() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=accounts"]
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

    func testEmptyCategoryGroupRemainsVisibleAndDefaultsCategoryCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=plan"]
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
        app.launchArguments = ["--demo", "--demo-fresh-budget", "--demo-screen=plan"]
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

    func testProductionPayeeManagementFeedsSharedTransactionEditor() {
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
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 5))

        app.navigationBars.buttons["Household"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Activity"].tap()
        app.buttons.matching(identifier: "Add").firstMatch.tap()
        app.buttons["Transaction"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        app.buttons["saved-payee-menu"].tap()
        XCTAssertTrue(app.navigationBars["Choose Payee"].waitForExistence(timeout: 5))
        app.searchFields["Search payees"].tap()
        app.searchFields["Search payees"].typeText("Neighborhood")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payee-search-result-' AND label CONTAINS 'Neighborhood Market'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payee-search-result-' AND label CONTAINS 'Neighborhood Market'")).firstMatch.tap()
        XCTAssertEqual(app.textFields["Payee"].value as? String, "Neighborhood Market")
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

    func testProductionAttachmentPreviewDoesNotRemoveAndRemovalRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-screen=activity"]
        app.launch()

        app.buttons["transaction-row-t1"].tap()
        let preview = app.buttons["attachment-preview-demo-attachment-t1"]
        let remove = app.buttons["attachment-remove-demo-attachment-t1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.exists)

        preview.tap()
        XCTAssertTrue(app.navigationBars["receipt-placeholder.jpg"].waitForExistence(timeout: 5), "preview must navigate to the downloaded attachment")
        app.navigationBars["receipt-placeholder.jpg"].buttons.firstMatch.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "returning from preview must leave the attachment attached")

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
}
