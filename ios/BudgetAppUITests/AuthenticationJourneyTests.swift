import XCTest

final class AuthenticationJourneyTests: XCTestCase {
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

        XCTAssertTrue(app.navigationBars["Emergency Savings"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["To High-Yield Savings"].exists)

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
        XCTAssertFalse(app.staticTexts["To High-Yield Savings"].exists)
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
}
