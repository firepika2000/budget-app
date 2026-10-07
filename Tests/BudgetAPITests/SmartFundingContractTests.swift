import XCTest
import BudgetAPI

final class SmartFundingContractTests: XCTestCase {
    func testMonthFundingObservationsAreExactAndOptionalForOlderOrScopedServers() throws {
        let old = #"{"month":"2026-09-01","currency_code":"USD","ready_to_assign_minor":50000,"total_assigned_minor":0,"total_overspent_minor":0,"allocation_version":1,"categories":[]}"#
        let legacy = try JSONDecoder().decode(APIMonthSummary.self, from: Data(old.utf8))
        XCTAssertTrue(legacy.budgetTotalsVisible, "Older servers retain their established visibility contract")
        XCTAssertNil(legacy.allDateUnassignedMinor)
        XCTAssertNil(legacy.fundingLimitMinor)
        let current = String(old.dropLast()) + #", "all_date_unassigned_minor":10000,"funding_limit_minor":10000}"#
        let decoded = try JSONDecoder().decode(APIMonthSummary.self, from: Data(current.utf8))
        XCTAssertEqual(decoded.readyToAssignMinor, 50000)
        XCTAssertEqual(decoded.allDateUnassignedMinor, 10000)
        XCTAssertEqual(decoded.fundingLimitMinor, 10000)
        let scoped = String(old.dropLast()) + #", "budget_totals_visible":false,"all_date_unassigned_minor":null,"funding_limit_minor":null}"#
        let scopedDecoded = try JSONDecoder().decode(APIMonthSummary.self, from: Data(scoped.utf8))
        XCTAssertFalse(scopedDecoded.budgetTotalsVisible)
        XCTAssertEqual(scopedDecoded.readyToAssignMinor, 50000, "Visibility is explicit and never inferred from a numeric sentinel")
        XCTAssertNil(scopedDecoded.fundingLimitMinor)
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
    func testProposalExplanationFieldsDecodeWithoutBreakingOlderServers() throws {
        let legacyJSON = #"{"category_id":"food","category_name":"Food","amount_minor":1000,"before_available_minor":0,"after_available_minor":1000}"#
        let legacy = try JSONDecoder().decode(APISmartFundingProposal.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.targetType)
        XCTAssertNil(legacy.targetPriority)
        XCTAssertNil(legacy.recommendedContributionMinor)
        XCTAssertNil(legacy.remainingNeedMinor)

        let currentJSON = #"{"category_id":"food","category_name":"Food","amount_minor":1000,"before_available_minor":0,"after_available_minor":1000,"target_type":"monthly_funding","target_priority":80,"recommended_contribution_minor":2500,"remaining_need_minor":1500}"#
        let current = try JSONDecoder().decode(APISmartFundingProposal.self, from: Data(currentJSON.utf8))
        XCTAssertEqual(current.targetType, "monthly_funding")
        XCTAssertEqual(current.targetPriority, 80)
        XCTAssertEqual(current.recommendedContributionMinor, 2500)
        XCTAssertEqual(current.remainingNeedMinor, 1500)
    }
}
