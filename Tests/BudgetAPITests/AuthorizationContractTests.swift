import XCTest
@testable import BudgetAPI

final class AuthorizationContractTests: XCTestCase {
    private func vectors() throws -> [String: [String]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: root.appendingPathComponent("server/tests/authorization_vectors/v1.json")))
    }

    func testEveryLegacyCapabilityMatchesSharedServerContractAndUnknownDenies() throws {
        let rows = try vectors()
        let all = try XCTUnwrap(rows["owner"])
        XCTAssertEqual(all.count, 21)
        for (permission, allowed) in rows {
            let value = APIBudget(id: "b", householdID: "h", name: "Budget", currencyCode: "USD",
                                  effectivePermission: try XCTUnwrap(APIBudgetPermission(rawValue: permission)))
            for capability in all + ["unknown_capability", "", "View_budget"] {
                XCTAssertEqual(value.can(capability), allowed.contains(capability), "\(permission): \(capability)")
            }
        }
    }

    func testExplicitCapabilitiesReplaceLegacyGrantAndOwnerStillHasKnownAuthority() throws {
        let all = try XCTUnwrap(vectors()["owner"])
        for permission in [APIBudgetPermission.view, .contribute, .manage] {
            let empty = APIBudget(id: "b", householdID: "h", name: "Budget", currencyCode: "USD", effectivePermission: permission, capabilities: [])
            XCTAssertTrue(all.allSatisfy { !empty.can($0) })
            let custom = APIBudget(id: "b", householdID: "h", name: "Budget", currencyCode: "USD", effectivePermission: permission, capabilities: ["view_budget", "manage_payees", "unknown_capability"])
            for capability in all { XCTAssertEqual(custom.can(capability), ["view_budget", "manage_payees"].contains(capability)) }
            XCTAssertFalse(custom.can("unknown_capability"))
        }
        let owner = APIBudget(id: "b", householdID: "h", name: "Budget", currencyCode: "USD", capabilities: [])
        XCTAssertTrue(all.allSatisfy(owner.can))
        XCTAssertFalse(owner.can("unknown_capability"))
    }
}
