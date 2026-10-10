import XCTest
import BudgetAPI

final class TransactionSelectionTests: XCTestCase {
    func testSelectionPreservesOriginalObservationAndDeterministicRequest() throws {
        var selection = APITransactionSelection()
        try selection.toggle(id: "b", revision: "original-b")
        try selection.toggle(id: "a", revision: "original-a")
        for action in ["set_cleared", "set_flag", "add_tags", "remove_tags"] {
            let request = try selection.update(action: action, cleared: true, flag: "orange", tags: ["review"])
            XCTAssertEqual(request.transactionIDs, ["a", "b"])
            XCTAssertEqual(request.expectedRevisions, ["a": "original-a", "b": "original-b"])
        }
        // Deselect/reselect is an explicit new observation, not an incidental page refresh.
        try selection.toggle(id: "a", revision: "new-a")
        XCTAssertEqual(selection.ids, ["b"])
        try selection.toggle(id: "a", revision: "new-a")
        XCTAssertEqual(try selection.update(action: "set_cleared").expectedRevisions?["a"], "new-a")
        selection.removeAll()
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testMixedObservationsCannotSilentlyDisablePreconditions() throws {
        var selection = APITransactionSelection()
        try selection.toggle(id: "legacy", revision: nil)
        XCTAssertNil(try selection.update(action: "set_cleared").expectedRevisions)
        try selection.toggle(id: "current", revision: "current")
        XCTAssertThrowsError(try selection.update(action: "set_cleared"))
        XCTAssertEqual(selection.ids.count, 2)
    }

    func testSelectionBoundRetainsExistingIntentAndAllowsDeselectionAtLimit() throws {
        var selection = APITransactionSelection()
        for index in 0..<200 { try selection.toggle(id: String(index), revision: "r") }
        XCTAssertThrowsError(try selection.toggle(id: "overflow", revision: "r"))
        XCTAssertEqual(selection.ids.count, 200)
        XCTAssertFalse(selection.ids.contains("overflow"))
        try selection.toggle(id: "0", revision: "r")
        try selection.toggle(id: "replacement", revision: "r")
        XCTAssertEqual(try selection.update(action: "set_flag").expectedRevisions?.count, 200)
    }
}
