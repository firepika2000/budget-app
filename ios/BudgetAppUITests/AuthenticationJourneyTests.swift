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
        planTab.tap()
        if !app.navigationBars["Plan"].waitForExistence(timeout: 3) {
            planTab.tap()
        }
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Category Group"].exists)
        XCTAssertTrue(app.buttons["profile-settings-button"].exists)

        app.buttons["profile-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Budgets"].exists)
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
}
