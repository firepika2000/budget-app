import Foundation

/// Bound identity-based report requests without fetching unrelated ledger pages.
public enum TransactionIdentitySelection {
    public static func batches(_ ids: [String]) -> [[String]] {
        let unique = Array(Set(ids)).sorted()
        return stride(from: 0, to: unique.count, by: 100).map {
            Array(unique[$0..<min($0 + 100, unique.count)])
        }
    }
}
