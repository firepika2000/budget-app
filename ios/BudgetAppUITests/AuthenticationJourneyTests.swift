import XCTest

final class AuthenticationJourneyTests: XCTestCase {
    func testProductionAuthenticationFieldsAcceptContinuousKeyboardInput() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authentication"]
        app.launch()

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
}
