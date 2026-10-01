import Foundation
import XCTest
@testable import BudgetStorage

final class LocalDeviceTransferProjectionTests: XCTestCase {
    func testStrictProjectionDecodesTypedSnapshotAndExactObservations() throws {
        let result = try LocalDeviceTransferProjectionDecoder.decode(fixture())

        XCTAssertEqual(result.sourceRevision, String(repeating: "a", count: 64))
        XCTAssertEqual(result.snapshot.identity.budgetID, "budget")
        XCTAssertEqual(result.snapshot.transactions.first?.amountMinor, 10_000)
        XCTAssertEqual(result.snapshot.allocations.first?.amountMinor, 4_000)
        XCTAssertEqual(result.observations.transactionCount, 1)
        XCTAssertEqual(result.observations.allocationPostingCount, 2)
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
          "categories":[{"id":"groceries","budget_id":"budget","group_id":"group","name":"Groceries","delegated_user_id":null,"is_archived":false,"sort_order":0,"is_favorite":true,"favorite_sort_order":0}],
          "payees":[],"payee_aliases":[],
          "transactions":[{"id":"income","budget_id":"budget","account_id":"checking","payee_id":null,"payee_name":"Payroll","amount_minor":10000,"occurred_on":"2026-09-01","memo":"","is_cleared":true,"is_reconciled":false,"status":"posted","transfer_id":null,"flag":null,"tags":[],"financial_classification":null,"void_reason":null,"reversal_of_transaction_id":null,"reversal_transaction_id":null,"created_by_user_id":"owner","created_at":"2026-09-01T12:00:00+00:00","splits":[]}],
          "allocations":[{"id":"posting","operation_id":"operation","budget_id":"budget","source_category_id":null,"category_id":"groceries","amount_minor":4000,"occurred_on":"2026-09-01","kind":"assignment","actor_user_id":"owner","note":"","created_at":"2026-09-01T12:00:00+00:00"}],
          "reconciliations":[],"targets":[],"schedules":[],"attachments":[],"debt_terms":[],"cash_rollover_policies":[],"credit_reserve_attributions":[],"transaction_changes":[],"credit_reserve_events":[],
          "observations":{"transaction_count":1,"transactions":[{"account_id":"checking","status":"posted","amount_minor":10000}],"allocation_count":2,"allocations":[{"bucket":"category","category_id":"groceries","amount_minor":4000},{"bucket":"ready_to_assign","category_id":null,"amount_minor":-4000}],"reserve_count":0,"reserves":[]}
        }
        """#.utf8)
    }
}
