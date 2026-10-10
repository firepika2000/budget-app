#!/bin/bash
# Real production persistence/replay decisions; no network or Simulator operations.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ruby - <<'RUBY' | xcrun swift -
s = File.read("ios/BudgetApp/ApplicationServices.swift")
puts "import Foundation\nimport CryptoKit"
puts 'enum BudgetApplicationError: Error { case invalidOperation(String) }'
puts s[s.index("struct TransactionSplitOperation:")...s.index("struct MakeRecurringOperation:")]
puts s[s.index("@MainActor\nfinal class LiveTransactionOutbox")...s.index("struct LiveWorkspaceCachePayload:")]
puts s[s.index("private func liveCredentialSubject")...s.index("func isTransientConnectivityFailure")]
session = File.read("ios/BudgetApp/AppSession.swift")
puts 'struct APIBudget: Equatable { let id: String }'
puts session[session.index("enum WorkspaceRouteContext:")...session.index("enum ApplicationRoute:")]
workspace = File.read("ios/BudgetApp/BudgetWorkspaceView.swift")
send_first = workspace.index("    private func sendTransaction(")
send_last = workspace.index("    func householdInvitations()", send_first || 0)
abort "Canonical send path moved; review binding guard" unless send_first && send_last
send_body = workspace[send_first...send_last]
prepare = send_body.index("try await credentials.prepare()")
binding = send_body.index("try transactionOutbox.requireServer(")
mutation = send_body.index("client.createTransaction(")
abort "Canonical mutation must recheck binding after refresh" unless prepare && binding && mutation && prepare < binding && binding < mutation
abort "Pending rows bypass workspace access" unless workspace.include?('guard !workspaceAccessDenied else { return [] }') && workspace.include?('PendingTransactionVisibility.allows($0.operation, canView: budget.can("view_transactions")')
abort "Pending restricted state appears fully synced" unless workspace.include?('store.pendingLiveTransactions.isEmpty && !store.pendingLiveDetailsRestricted') && workspace.include?('pending-sync-restricted')
abort "Pending discard bypasses visible entry check" unless workspace.include?('guard pendingLiveTransactions.contains(where: { $0.id == id }) else')
puts <<'SWIFT'
try await MainActor.run {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-migration-\(UUID().uuidString)")
 defer { try? FileManager.default.removeItem(at: root) }
 let legacyURL = root.appendingPathComponent("legacy.json"), newURL = root.appendingPathComponent("new.json")
 let operation = RecordTransactionOperation(accountID: "checking", categoryID: "food", amountMinor: -9007199254740993,
  occurredOn: "2026-10-09", payeeName: "Market", memo: "Preserved", isCleared: false,
  splits: [], flag: "orange", tags: ["qa"], attachmentMetadata: [], clientOperationID: UUID().uuidString)
 let original = LiveTransactionOutbox(fileURL: legacyURL); try original.enqueue(operation)
 let bytes = try Data(contentsOf: legacyURL)
 precondition(PendingTransactionVisibility.allows(operation, canView: true, accountIDs: ["checking"], categoryIDs: ["food"]))
 precondition(!PendingTransactionVisibility.allows(operation, canView: false, accountIDs: ["checking"], categoryIDs: ["food"]))
 precondition(!PendingTransactionVisibility.allows(operation, canView: true, accountIDs: [], categoryIDs: ["food"]))
 precondition(!PendingTransactionVisibility.allows(operation, canView: true, accountIDs: ["checking"], categoryIDs: []))
 let split = RecordTransactionOperation(accountID: "checking", categoryID: nil, amountMinor: -3,
  occurredOn: "2026-10-09", payeeName: "Private mixed purchase", memo: "Sensitive", isCleared: false,
  splits: [.init(categoryID: "food", amountMinor: -1, memo: ""), .init(categoryID: "hidden", amountMinor: -2, memo: "")],
  flag: nil, tags: [], attachmentMetadata: [])
 precondition(!PendingTransactionVisibility.allows(split, canView: true, accountIDs: ["checking"], categoryIDs: ["food"]))
 precondition(PendingTransactionVisibility.allows(split, canView: true, accountIDs: ["checking"], categoryIDs: ["food", "hidden"]))
 let preservedAfterScopeChecks = try Data(contentsOf: legacyURL)
 precondition(preservedAfterScopeChecks == bytes)
 let server = URL(string: "https://server.example/family")!
 let scope = liveServerStorageScope(budgetID: "budget", serverURL: server, token: "token")
 let route = WorkspaceRouteContext.live(budget: APIBudget(id: "budget"), serverURL: server, token: "token")
 let rotatedRoute = WorkspaceRouteContext.live(budget: APIBudget(id: "budget"), serverURL: server, token: "rotated")
 let otherRoute = WorkspaceRouteContext.live(budget: APIBudget(id: "budget"), serverURL: URL(string: "https://server.example/friends")!, token: "token")
 precondition(route.identity == rotatedRoute.identity && route.identity != otherRoute.identity)
 let queue = LiveTransactionOutbox(fileURL: newURL, legacyFileURL: legacyURL, scope: scope)
 precondition(queue.requiresLegacyReview && queue.entries == original.entries)
 do { _ = try queue.beginReplay(); fatalError("Legacy auto-replay permitted") } catch {}
 do { try queue.remove(id: operation.clientOperationID!); fatalError("Legacy discard permitted") } catch {}
 do { try queue.enqueue(operation); fatalError("Ambiguous queue append permitted") } catch {}
 try queue.requireServer(budgetID: "budget", serverURL: server, token: "rotated")
 do { try queue.requireServer(budgetID: "budget", serverURL: URL(string: "https://server.example/friends")!, token: "token"); fatalError("Wrong endpoint permitted") } catch {}
 try queue.confirmLegacyServer()
 precondition(!queue.requiresLegacyReview && queue.entries == original.entries)
 let retained = try Data(contentsOf: legacyURL); precondition(retained == bytes)
 let reopened = LiveTransactionOutbox(fileURL: newURL, legacyFileURL: legacyURL, scope: scope)
 precondition(!reopened.requiresLegacyReview && reopened.entries == original.entries)
 let other = LiveTransactionOutbox(fileURL: root.appendingPathComponent("other.json"), legacyFileURL: legacyURL, scope: "another-server")
 precondition(other.count == 0 && !other.requiresLegacyReview)
 let claimed = try reopened.beginReplay(); precondition(claimed)
 try reopened.acknowledgeReplay(id: operation.clientOperationID!); reopened.finishReplay()
 precondition(reopened.count == 0)
 // A crash/failure after binding but before publishing the new queue is recoverable only here.
 let secondLegacy = root.appendingPathComponent("second-legacy.json")
 let secondOriginal = LiveTransactionOutbox(fileURL: secondLegacy); try secondOriginal.enqueue(operation)
 let delayed = root.appendingPathComponent("missing/new.json")
 let interrupted = LiveTransactionOutbox(fileURL: delayed, legacyFileURL: secondLegacy, scope: scope)
 do { try interrupted.confirmLegacyServer(); fatalError("Missing parent should reject publication") } catch {}
 precondition(interrupted.requiresLegacyReview)
 try FileManager.default.createDirectory(at: delayed.deletingLastPathComponent(), withIntermediateDirectories: true)
 let retry = LiveTransactionOutbox(fileURL: delayed, legacyFileURL: secondLegacy, scope: scope)
 precondition(retry.requiresLegacyReview); try retry.confirmLegacyServer()
 precondition(retry.entries == secondOriginal.entries && !retry.requiresLegacyReview)
 print("PASS: current whole-resource scope and preserved bytes, explicit adoption, no legacy replay/append/discard, exact identity/money/metadata, endpoint isolation, relaunch, canonical acknowledgement, interrupted-publication recovery")
}
SWIFT
RUBY
