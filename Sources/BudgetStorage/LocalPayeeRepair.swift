import Foundation

public enum LocalPayeeName {
    public static func displayName(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    public static func key(_ name: String) -> String {
        displayName(name).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension LocalDatabase {
    /// Repairs only missing merchant relationships. Original text and every financial column remain intact.
    func repairPayeeRelationships(budgetID: String, ownerID: String, timestamp: String) throws -> Int {
        try withTransaction { database in
            guard try database.rows(.init("SELECT b.id FROM budgets b JOIN memberships m ON m.household_id=b.household_id WHERE b.id=? AND m.user_id=? AND m.role='owner' AND m.is_active=1", values: [.text(budgetID), .text(ownerID)])).count == 1 else {
                throw LocalStorageError.invalidSnapshot("Local payee repair requires the budget owner.")
            }
            func text(_ row: LocalSQLiteRow, _ key: String) -> String? {
                if case let .text(value) = row[key] { return value }; return nil
            }
            let payees = try database.rows(.init("SELECT id,name,merged_into_payee_id FROM payees WHERE budget_id=?", values: [.text(budgetID)]))
            var destinations: [String: String] = [:]
            for payee in payees {
                guard let id = text(payee, "id") else { continue }
                destinations[id] = text(payee, "merged_into_payee_id") ?? id
            }
            func destination(_ id: String) throws -> String {
                var current = id; var visited = Set<String>()
                while let next = destinations[current], next != current {
                    guard visited.insert(current).inserted else { throw LocalStorageError.invalidSnapshot("Cyclic merged payee identity.") }
                    current = next
                }
                guard destinations[current] != nil else { throw LocalStorageError.invalidSnapshot("Missing merged payee identity.") }
                return current
            }
            var names: [String: Set<String>] = [:]
            for payee in payees {
                if let id = text(payee, "id"), let name = text(payee, "name") {
                    names[LocalPayeeName.key(name), default: []].insert(try destination(id))
                }
            }
            for alias in try database.rows(.init("SELECT a.payee_id,a.display_name FROM payee_aliases a JOIN payees p ON p.id=a.payee_id WHERE p.budget_id=?", values: [.text(budgetID)])) {
                if let id = text(alias, "payee_id"), let name = text(alias, "display_name") {
                    names[LocalPayeeName.key(name), default: []].insert(try destination(id))
                }
            }
            let candidates = try database.rows(.init("SELECT id,payee_name FROM transactions WHERE budget_id=? AND payee_id IS NULL AND transfer_id IS NULL AND reversal_of_transaction_id IS NULL AND status IN ('posted','voided') ORDER BY created_at,id", values: [.text(budgetID)]))
            var repaired = 0
            for row in candidates {
                guard let transactionID = text(row, "id"), let original = text(row, "payee_name") else { continue }
                let display = LocalPayeeName.displayName(original), key = LocalPayeeName.key(original)
                guard !key.isEmpty, display.count <= 150,
                      !["transfer", "starting balance", "reconciliation adjustment"].contains(key) else { continue }
                let matches = names[key] ?? []
                // Conflicting historical namespaces are not permission to merge identities.
                guard matches.count <= 1 else { continue }
                let payeeID: String
                if let existing = matches.first { payeeID = existing }
                else {
                    payeeID = UUID().uuidString
                    try database.execute(.init("INSERT INTO payees(id,budget_id,name,normalized_name,is_archived) VALUES (?,?,?,?,0)", values: [.text(payeeID), .text(budgetID), .text(display), .text(key)]))
                    let json = try JSONSerialization.data(withJSONObject: ["display_name": display, "is_archived": false, "aliases": []] as [String: Any], options: [.sortedKeys])
                    try database.execute(.init("INSERT INTO payee_revisions(id,budget_id,payee_id,action,actor_user_id,after_json,created_at) VALUES (?,?,?,'created',?,?,?)", values: [.text(UUID().uuidString), .text(budgetID), .text(payeeID), .text(ownerID), .text(String(decoding: json, as: UTF8.self)), .text(timestamp)]))
                    names[key] = [payeeID]
                }
                try database.execute(.init("UPDATE transactions SET payee_id=? WHERE id=? AND budget_id=? AND payee_id IS NULL", values: [.text(payeeID), .text(transactionID), .text(budgetID)]))
                repaired += 1
            }
            return repaired
        }
    }
}
