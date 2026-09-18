import XCTest
import BudgetAPI

final class SmartFundingContractTests: XCTestCase {
    func testMonthFundingObservationsAreExactAndOptionalForOlderOrScopedServers() throws {
        let old = #"{"month":"2026-09-01","currency_code":"USD","ready_to_assign_minor":50000,"total_assigned_minor":0,"total_overspent_minor":0,"allocation_version":1,"categories":[]}"#
        let legacy = try JSONDecoder().decode(APIMonthSummary.self, from: Data(old.utf8))
        XCTAssertNil(legacy.allDateUnassignedMinor)
        XCTAssertNil(legacy.fundingLimitMinor)
        let current = String(old.dropLast()) + #", "all_date_unassigned_minor":10000,"funding_limit_minor":10000}"#
        let decoded = try JSONDecoder().decode(APIMonthSummary.self, from: Data(current.utf8))
        XCTAssertEqual(decoded.readyToAssignMinor, 50000)
        XCTAssertEqual(decoded.allDateUnassignedMinor, 10000)
        XCTAssertEqual(decoded.fundingLimitMinor, 10000)
        let scoped = String(old.dropLast()) + #", "all_date_unassigned_minor":null,"funding_limit_minor":null}"#
        XCTAssertNil(try JSONDecoder().decode(APIMonthSummary.self, from: Data(scoped.utf8)).fundingLimitMinor)
    }
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
