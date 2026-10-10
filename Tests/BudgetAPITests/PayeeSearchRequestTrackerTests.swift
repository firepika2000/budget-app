import XCTest
@testable import BudgetAPI

final class PayeeSearchRequestTrackerTests: XCTestCase {
    func testRepeatedQueryCannotPublishOlderCompletion() {
        var tracker = PayeeSearchRequestTracker()
        let older = tracker.begin(query: "Market", authority: 1)
        let newer = tracker.begin(query: "Market", authority: 1)
        XCTAssertFalse(tracker.accepts(older, query: "Market", authority: 1))
        XCTAssertTrue(tracker.accepts(newer, query: "Market", authority: 1))
    }
    func testQueryAndAuthorityChangesRejectOldResultsAndErrors() {
        var tracker = PayeeSearchRequestTracker()
        let request = tracker.begin(query: "Market", authority: 1)
        XCTAssertFalse(tracker.accepts(request, query: "Home", authority: 1))
        XCTAssertFalse(tracker.accepts(request, query: "Market", authority: 2))
        tracker.invalidate()
        XCTAssertFalse(tracker.accepts(request, query: "Market", authority: 1))
    }
}
