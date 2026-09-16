import XCTest
@testable import Budget_App

@MainActor
final class AppearancePreferenceTests: XCTestCase {
    func testAppearanceDefaultsToSystemAndPersistsDeviceLocally() {
        let suite = "AppearancePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppearancePreference(defaults: defaults)
        XCTAssertEqual(first.selection, .system)
        first.selection = .dark
        XCTAssertEqual(AppearancePreference(defaults: defaults).selection, .dark)
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
}
