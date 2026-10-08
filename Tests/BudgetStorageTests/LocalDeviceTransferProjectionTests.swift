import Foundation
import XCTest
@testable import BudgetStorage

final class LocalDeviceTransferProjectionTests: XCTestCase {
    func testStrictProjectionDecodesTypedSnapshotAndExactObservations() throws {
        let result = try LocalDeviceTransferProjectionDecoder.decode(fixture())

        XCTAssertEqual(result.sourceRevision, String(repeating: "a", count: 64))
        XCTAssertEqual(result.snapshot.identity.budgetID, "budget")
        XCTAssertEqual(result.snapshot.transactions.first?.amountMinor, 10_000)
        XCTAssertEqual(result.snapshot.transactions.first?.scheduledTransactionID, "schedule-1")
        XCTAssertEqual(result.snapshot.payees.first?.mergedIntoPayeeID, "canonical-payee")
        XCTAssertEqual(result.snapshot.attachmentTombstones.first?.id, "detached-receipt")
        XCTAssertNil(result.snapshot.attachmentTombstones.first?.tombstoneObjectName)
        XCTAssertEqual(result.snapshot.allocations.first?.amountMinor, 4_000)
        XCTAssertEqual(result.snapshot.reconciliations.first?.actorUserID, "owner")
        XCTAssertEqual(result.snapshot.reconciliations.first?.clearedBalanceBeforeMinor, 9_500)
        XCTAssertEqual(result.snapshot.reconciliations.first?.reconciledTransactionCount, 2)
        XCTAssertEqual(result.snapshot.categories.first?.iconName, "cart")
        XCTAssertEqual(result.snapshot.categories.first?.note, "Weekly essentials")
        XCTAssertEqual(result.snapshot.categories.first?.isEssential, true)
        XCTAssertEqual(result.snapshot.categories.first?.isEmergencyFund, false)
        XCTAssertEqual(result.snapshot.debtPayoffPlans?.first?.strategy, "snowball")
        XCTAssertEqual(result.snapshot.debtPayoffPlans?.first?.extraPaymentMinor, 12_345)
        XCTAssertEqual(result.snapshot.debtPayoffPlans?.first?.targetDate, "2028-12-31")
        XCTAssertEqual(result.observations.transactionCount, 1)
        XCTAssertEqual(result.observations.allocationPostingCount, 2)
    }

    func testLegacyProjectionDefaultsAbsentCategoryPresentationAndResilienceFields() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var categories = try XCTUnwrap(value["categories"] as? [[String: Any]])
        categories[0].removeValue(forKey: "icon_name")
        categories[0].removeValue(forKey: "note")
        categories[0].removeValue(forKey: "is_essential")
        categories[0].removeValue(forKey: "is_emergency_fund")
        value["categories"] = categories
        value.removeValue(forKey: "attachment_tombstones")

        let result = try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        )

        XCTAssertNil(result.snapshot.categories.first?.iconName)
        XCTAssertEqual(result.snapshot.categories.first?.note, "")
        XCTAssertEqual(result.snapshot.categories.first?.isEssential, false)
        XCTAssertEqual(result.snapshot.categories.first?.isEmergencyFund, false)
        XCTAssertTrue(result.snapshot.attachmentTombstones.isEmpty)
    }

    func testProjectionPreservesStatementImportReviewHistory() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        let payload: [String: Any] = [
            "id": "import-1", "budget_id": "budget", "account_id": "checking",
            "status": "review", "version": 1, "source_format": "csv",
            "candidate_count": 1, "created_at": "2026-09-03T12:00:00+00:00",
            "candidates": [[
                "source_row": 2, "occurred_on": "2026-09-03", "amount_minor": -250,
                "payee": "Portable import", "memo": "Retain review",
                "exact_transaction_ids": [], "possible_transaction_ids": [],
                "suggestions_truncated": false, "duplicate_source_row": false,
            ]],
        ]
        value["statement_imports"] = [[
            "id": "import-1", "budget_id": "budget", "account_id": "checking",
            "status": "review", "version": 1, "source_format": "csv",
            "candidate_count": 1, "created_at": "2026-09-03T12:00:00+00:00",
            "payload": payload,
        ]]

        let result = try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        )
        let imported = try XCTUnwrap(result.snapshot.statementImports.first)
        XCTAssertEqual(imported.id, "import-1")
        XCTAssertEqual(imported.amountFromFirstCandidate, -250)
    }

    func testProjectionPreservesSplitFinancialClassification() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var transactions = try XCTUnwrap(value["transactions"] as? [[String: Any]])
        transactions[0]["amount_minor"] = -10_000
        transactions[0]["splits"] = [[
            "id": "interest", "category_id": "groceries", "amount_minor": -10_000,
            "memo": "Finance charge", "financial_classification": "interest_charge",
        ]]
        value["transactions"] = transactions
        var observations = try XCTUnwrap(value["observations"] as? [String: Any])
        observations["transactions"] = [[
            "account_id": "checking", "status": "posted", "amount_minor": -10_000,
        ]]
        value["observations"] = observations

        let result = try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        )

        XCTAssertEqual(result.snapshot.transactions.first?.splits.first?.financialClassification,
                       "interest_charge")
    }

    func testProjectionRejectsTamperedFinancialObservationAndMixedBudgetIdentity() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var observations = try XCTUnwrap(value["observations"] as? [String: Any])
        var transactions = try XCTUnwrap(observations["transactions"] as? [[String: Any]])
        transactions[0]["amount_minor"] = 9_999
        observations["transactions"] = transactions
        value["observations"] = observations
        XCTAssertThrowsError(try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        ))

        value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var accounts = try XCTUnwrap(value["accounts"] as? [[String: Any]])
        accounts[0]["budget_id"] = "other-budget"
        value["accounts"] = accounts
        XCTAssertThrowsError(try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        ))
    }

    func testProjectionRejectsUnsupportedEnvelopeAndDuplicateIdentity() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        value["version"] = 2
        XCTAssertThrowsError(try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        ))

        value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        let accounts = try XCTUnwrap(value["accounts"] as? [[String: Any]])
        value["accounts"] = accounts + accounts
        XCTAssertThrowsError(try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        ))

        value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var observations = try XCTUnwrap(value["observations"] as? [String: Any])
        let totals = try XCTUnwrap(observations["transactions"] as? [[String: Any]])
        observations["transactions"] = totals + totals
        value["observations"] = observations
        XCTAssertThrowsError(try LocalDeviceTransferProjectionDecoder.decode(
            JSONSerialization.data(withJSONObject: value)
        ))
    }

    private func fixture() -> Data {
        Data(#"""
        {
          "format":"com.clearpocket.local-device-transfer","version":1,
          "generated_at":"2026-10-01T12:00:00+00:00","authority_created_at":"2026-01-01T12:00:00+00:00",
          "source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "identity":{"household_id":"household","household_name":"Home","owner_user_id":"owner","owner_display_name":"Owner","budget_id":"budget","budget_name":"Budget","currency_code":"USD"},
          "accounts":[{"id":"checking","budget_id":"budget","name":"Checking","kind":"checking","is_on_budget":true,"is_closed":false,"opening_balance_minor":0,"created_at":"2026-01-01T12:00:00+00:00"}],
          "groups":[{"id":"group","budget_id":"budget","name":"Needs","sort_order":0,"is_archived":false}],
          "categories":[{"id":"groceries","budget_id":"budget","group_id":"group","name":"Groceries","icon_name":"cart","note":"Weekly essentials","delegated_user_id":null,"is_archived":false,"sort_order":0,"is_favorite":true,"favorite_sort_order":0,"is_essential":true,"is_emergency_fund":false}],
          "payees":[{"id":"legacy-payee","budget_id":"budget","name":"Old Payroll","normalized_name":"","default_category_id":null,"is_archived":true,"merged_into_payee_id":"canonical-payee"},{"id":"canonical-payee","budget_id":"budget","name":"Payroll","normalized_name":"payroll","default_category_id":null,"is_archived":false,"merged_into_payee_id":null}],"payee_aliases":[],
          "transactions":[{"id":"income","budget_id":"budget","account_id":"checking","payee_id":null,"payee_name":"Payroll","amount_minor":10000,"occurred_on":"2026-09-01","memo":"","is_cleared":true,"is_reconciled":false,"status":"posted","transfer_id":null,"scheduled_transaction_id":"schedule-1","flag":null,"tags":[],"financial_classification":null,"void_reason":null,"reversal_of_transaction_id":null,"reversal_transaction_id":null,"created_by_user_id":"owner","created_at":"2026-09-01T12:00:00+00:00","splits":[]}],
          "allocations":[{"id":"posting","operation_id":"operation","budget_id":"budget","source_category_id":null,"category_id":"groceries","amount_minor":4000,"occurred_on":"2026-09-01","kind":"assignment","actor_user_id":"owner","note":"","created_at":"2026-09-01T12:00:00+00:00"}],
          "reconciliations":[{"id":"reconciliation-1","account_id":"checking","statement_date":"2026-09-02","statement_balance_minor":10000,"actor_user_id":"owner","cleared_balance_before_minor":9500,"reconciled_transaction_count":2,"adjustment_transaction_id":null,"created_at":"2026-09-02T12:00:00+00:00"}],"targets":[],"schedules":[{"id":"schedule-1","budget_id":"budget","account_id":"checking","destination_account_id":null,"category_id":null,"payee_id":null,"name":"Payroll","amount_minor":10000,"next_date":"2026-10-01","recurrence_unit":"months","interval_count":1,"memo":"","end_date":null,"remaining_occurrences":null,"is_active":true,"financial_classification":"income","last_realized_on":"2026-09-01"}],"attachments":[],"attachment_tombstones":[{"id":"detached-receipt","budget_id":"budget","transaction_id":"income","filename":"receipt.pdf","content_type":"application/pdf","size_bytes":12,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","created_at":"2026-09-01T12:00:00+00:00","detached_at":"2026-09-02T12:00:00+00:00","detached_by_user_id":"owner","purge_after":"2026-10-02T12:00:00+00:00","tombstone_object_name":null}],"debt_terms":[],"debt_payoff_plans":[{"id":"payoff-plan","budget_id":"budget","user_id":"owner","strategy":"snowball","rollover":true,"extra_payment_minor":12345,"account_ids":[],"custom_order":[],"target_date":"2028-12-31","updated_at":"2026-10-08T12:00:00+00:00"}],"cash_rollover_policies":[],"credit_reserve_attributions":[],"transaction_changes":[],"credit_reserve_events":[],
          "observations":{"transaction_count":1,"transactions":[{"account_id":"checking","status":"posted","amount_minor":10000}],"allocation_count":2,"allocations":[{"bucket":"category","category_id":"groceries","amount_minor":4000},{"bucket":"ready_to_assign","category_id":null,"amount_minor":-4000}],"reserve_count":0,"reserves":[]}
        }
        """#.utf8)
    }
}

private extension LocalStatementImportRecord {
    var amountFromFirstCandidate: Int64? {
        guard let data = payloadJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = value["candidates"] as? [[String: Any]],
              let amount = candidates.first?["amount_minor"] as? NSNumber else { return nil }
        return amount.int64Value
    }
}
