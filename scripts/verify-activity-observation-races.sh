#!/usr/bin/env bash
# Runs actual production loader bodies with transport/state doubles, not SwiftUI UI tests.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ruby <<'RUBY' | xcrun swift -
source = File.read('ios/BudgetApp/BudgetWorkspaceView.swift')
methods = %w[loadRecentTransactionChanges loadRecentReconciliations].map do |name|
  method = source[/    private func #{name}\(\) async \{.*?\n    }/m]
  abort "Missing production loader: #{name}" unless method
  method.sub('private func', 'func')
end
puts <<'SWIFT'
import Foundation
struct HistoryObservationPolicy { static func mustDiscard(after error: Error) -> Bool { false } }
enum HostFailure: Error { case transient }
@MainActor final class Store {
    var authorityRevision = 0
    var reads: [CheckedContinuation<[Int], Error>] = []
    func recentTransactionChanges() async throws -> [Int] {
        try await withCheckedThrowingContinuation { reads.append($0) }
    }
    func recentReconciliationHistory() async throws -> [Int] { try await recentTransactionChanges() }
}
@MainActor final class Probe {
    let store = Store()
    var transactionChangesLoading = false
    var transactionChangesAuthority: Int?
    var recentTransactionChanges: [Int] = []
    var transactionChangesError: String?
    var reconciliationLoading = false
    var reconciliationAuthority: Int?
    var recentReconciliations: [Int] = []
    var reconciliationAccount: Int?
    var reconciliationError: String?
SWIFT
methods.each { |method| puts method }
puts '}'
puts <<'SWIFT'
for reconciliation in [false, true] {
    for fails in [false, true] {
        let probe = await MainActor.run { Probe() }
        let old = Task { @MainActor in
            if reconciliation { await probe.loadRecentReconciliations() }
            else { await probe.loadRecentTransactionChanges() }
        }
        let firstDeadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { probe.store.reads.count < 1 }) {
            precondition(Date() < firstDeadline, "Initial loader did not reach the transport")
            await Task.yield()
        }
        await MainActor.run { probe.store.authorityRevision = 1 }
        let fresh = Task { @MainActor in
            if reconciliation { await probe.loadRecentReconciliations() }
            else { await probe.loadRecentTransactionChanges() }
        }
        // Fail promptly if the old loading guard incorrectly prevents a fresh-scope read.
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { probe.store.reads.count < 2 }) {
            precondition(Date() < deadline, "Fresh-scope read blocked by obsolete loader")
            await Task.yield()
        }
        await MainActor.run {
            if fails { probe.store.reads[0].resume(throwing: HostFailure.transient) }
            else { probe.store.reads[0].resume(returning: [111]) }
        }
        await old.value
        await MainActor.run {
            precondition(probe.recentTransactionChanges.isEmpty && probe.recentReconciliations.isEmpty)
            precondition(probe.transactionChangesError == nil && probe.reconciliationError == nil)
            precondition(reconciliation ? probe.reconciliationLoading : probe.transactionChangesLoading)
            probe.store.reads[1].resume(returning: [222])
        }
        await fresh.value
        await MainActor.run {
            precondition((reconciliation ? probe.recentReconciliations : probe.recentTransactionChanges) == [222])
            precondition((reconciliation ? probe.reconciliationLoading : probe.transactionChangesLoading) == false)
        }
    }
}
print("PASS: production Activity loaders reject obsolete success/error and preserve fresh-scope progress")
SWIFT
RUBY
