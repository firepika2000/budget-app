import XCTest
import BudgetAPI

final class SmartFundingContractTests: XCTestCase {
    func testShortfallFieldsDecodeWithoutBreakingOlderServers() throws {
        let old = #"{"month":"2027-02-01","currency_code":"USD","before_ready_to_assign_minor":30000,"proposed_minor":30000,"after_ready_to_assign_minor":0,"allocation_version":1,"proposals":[]}"#
        let legacy = try JSONDecoder().decode(APISmartFundingPreview.self, from: Data(old.utf8))
        XCTAssertNil(legacy.remainingNeedMinor)
        XCTAssertNil(legacy.unfundedCategoryCount)
        XCTAssertNil(legacy.fundingLimitMinor)
        let current = String(old.dropLast()) + #", "remaining_need_minor":80000,"unfunded_category_count":1,"funding_limit_minor":10000}"#
        let decoded = try JSONDecoder().decode(APISmartFundingPreview.self, from: Data(current.utf8))
        XCTAssertEqual(decoded.remainingNeedMinor, 80000)
        XCTAssertEqual(decoded.unfundedCategoryCount, 1)
        XCTAssertEqual(decoded.fundingLimitMinor, 10000)
        XCTAssertEqual(decoded.proposedMinor, legacy.proposedMinor)
    }
}
