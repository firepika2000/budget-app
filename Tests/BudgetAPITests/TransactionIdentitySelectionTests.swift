import XCTest
@testable import BudgetAPI

final class TransactionIdentitySelectionTests: XCTestCase {
    func testLargeContributorSelectionIsBoundedStableAndCompleteWithoutDuplicates() {
        let ids = (0..<1501).map { "transaction-\($0)" }
        let batches = TransactionIdentitySelection.batches(ids.reversed() + ids)
        XCTAssertEqual(batches.count, 16)
        XCTAssertTrue(batches.allSatisfy { !$0.isEmpty && $0.count <= 100 })
        XCTAssertEqual(batches.flatMap { $0 }, ids.sorted())
        XCTAssertEqual(batches, TransactionIdentitySelection.batches(ids))
    }

    func testEmptySelectionNeverProducesAnUnfilteredRequest() {
        XCTAssertTrue(TransactionIdentitySelection.batches([]).isEmpty)
    }
}
