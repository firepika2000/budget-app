import XCTest
@testable import BudgetAPI

final class TransactionPageTests: XCTestCase {
    private func row(_ id: String) throws -> APITransaction {
        try JSONDecoder().decode(APITransaction.self, from: Data("""
        {"id":"\(id)","account_id":"a","amount_minor":-9007199254740993,"occurred_on":"2026-10-01","payee_name":"Merchant","memo":"","is_cleared":false,"is_reconciled":false,"splits":[]}
        """.utf8))
    }

    func testValidatedPagesPreserveOrderAndExactMoney() throws {
        let first = APITransactionPage(items: [try row("one")], nextCursor: "next", totalCount: 2)
        let rows = try first.validatedRows(after: [], previousTotal: nil, requestedCursor: nil)
        let final = APITransactionPage(items: [try row("two")], nextCursor: nil, totalCount: 2)
        let combined = try final.validatedRows(after: rows, previousTotal: 2, requestedCursor: "next")
        XCTAssertEqual(combined.map(\.id), ["one", "two"])
        XCTAssertEqual(combined.last?.amountMinor, -9_007_199_254_740_993)
    }

    func testInvalidPagesCannotReplacePreviouslyLoadedRows() throws {
        let existing = [try row("one")]
        let invalid: [APITransactionPage] = [
            .init(items: [try row("one")], nextCursor: nil, totalCount: 2),
            .init(items: [try row("two")], nextCursor: "same", totalCount: 3),
            .init(items: [], nextCursor: "different", totalCount: 3),
            .init(items: [try row("two")], nextCursor: "", totalCount: 3),
            .init(items: [], nextCursor: nil, totalCount: 2),
            .init(items: [try row("two")], nextCursor: nil, totalCount: 1),
            .init(items: [try row("two")], nextCursor: nil, totalCount: -1)
        ]
        for page in invalid {
            XCTAssertThrowsError(try page.validatedRows(after: existing, previousTotal: page.totalCount, requestedCursor: "same"))
            XCTAssertEqual(existing.map(\.id), ["one"])
        }
        let changed = APITransactionPage(items: [try row("two")], nextCursor: nil, totalCount: 2)
        XCTAssertThrowsError(try changed.validatedRows(after: existing, previousTotal: 3, requestedCursor: "same"))
        let duplicate = APITransactionPage(items: [try row("two"), try row("two")], nextCursor: nil, totalCount: 2)
        XCTAssertThrowsError(try duplicate.validatedRows(after: [], previousTotal: nil, requestedCursor: nil))
        XCTAssertThrowsError(try changed.validatedRows(after: [], previousTotal: nil, requestedCursor: nil, limit: 0))
    }
}
