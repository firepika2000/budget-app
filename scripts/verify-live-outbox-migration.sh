#!/bin/bash
# Real production persistence/replay decisions; no network or Simulator operations.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ruby - <<'RUBY' | xcrun swift -
s = File.read("ios/BudgetApp/ApplicationServices.swift")
puts "import Foundation\nimport CryptoKit"
puts 'enum BudgetApplicationError: Error { case invalidOperation(String) }'
puts s[s.index("struct AssignMoneyOperation:")...s.index("struct TransactionSplitOperation:")]
puts s[s.index("struct TransactionSplitOperation:")...s.index("struct MakeRecurringOperation:")]
puts s[s.index("struct TransferMoneyOperation:")...s.index("struct ScheduleOperation:")]
api = File.read("Sources/BudgetAPI/APIModels.swift")
puts api[api.index("public struct APITransactionBulkUpdate:")...api.index("/// Captures observations at selection time")]
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
record_first = workspace.index("    func recordTransaction(_ operation:", send_last)
record_last = workspace.index("    func updateTransaction(id:", record_first || 0)
abort "Canonical submission must use durable-first queue" unless record_first && record_last && workspace[record_first...record_last].include?("try transactionOutbox.enqueue(identified)") && workspace[record_first...record_last].include?("transactionOutbox.replayCommands(")
edit_last = workspace.index("    func deleteTransaction(id:", record_last || 0)
edit_body = workspace[record_last...edit_last]
abort "Edit must persist before replay" unless edit_body.index("enqueueEdit(") && edit_body.index("replayCommands(") && edit_body.index("enqueueEdit(") < edit_body.index("replayCommands(")
abort "Edit sender must use current endpoint binding" unless send_body.include?("client.updateTransaction(") && send_body.include?("operation.apiValue")
abort "Bulk sender missing from canonical command path" unless send_body.include?("client.bulkUpdateTransactions(") && workspace.include?("try transactionOutbox.enqueueBulk(identified)")
abort "Planning commands bypass durable canonical sender" unless send_body.include?("client.updateAssignment(") && send_body.include?("client.transferAllocation(") && workspace.include?("try transactionOutbox.enqueueAssignment(identified)") && workspace.include?("try transactionOutbox.enqueueMoneyMove(identified)")
abort "Transfers bypass durable canonical sender" unless send_body.include?("client.createTransfer(") && send_body.include?("client.updateTransfer(") && workspace.include?("try transactionOutbox.enqueueTransfer(identified)") && workspace.include?("try transactionOutbox.enqueueTransfer(identified, id: id)")
abort "Transfer editor loses observed versions" unless workspace.include?("_expectedRevisions = State(initialValue: presentation.expectedRevisions)") && workspace.include?("TransferMoneyOperation(expectedRevisions: expectedRevisions")
abort "Live reconciliation bypasses reviewed-set observation" unless workspace.include?("client.reconciliationObservation(") && workspace.include?("guard operation.expectedReviewRevision != nil else") && workspace.include?("expectedReviewRevision: operation.expectedReviewRevision")
abort "Live reconciliation bypasses durable canonical replay" unless workspace.include?("transactionOutbox.enqueueReconciliation(identified)") && send_body.include?("entry.reconciliation") && send_body.include?("mutationOperationID: operation.mutationOperationID")
abort "Pending reconciliation exposes unscoped account details" unless workspace.include?('budget.can("reconcile_account") && budget.can("view_account_balances") && accountIDs.contains(reconciliation.accountID)')
abort "Reconciliation editor loses captured review token" unless workspace.include?("@State private var observedReviewRevision: String?") && workspace.include?("observedReviewRevision = value.reviewRevision") && workspace.include?("expectedReviewRevision: observedReviewRevision")
abort "Pending rows bypass workspace access" unless workspace.include?('guard !workspaceAccessDenied else { return [] }') && workspace.include?('PendingTransactionVisibility.allows(operation, canView: budget.can("view_transactions")')
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
try await Task { @MainActor in
 let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-submit-\(UUID().uuidString)")
 defer { try? FileManager.default.removeItem(at: root) }
 let file = root.appendingPathComponent("queue.json")
 let operation = RecordTransactionOperation(accountID: "a", categoryID: "c", amountMinor: -9007199254740993,
  occurredOn: "2026-10-09", payeeName: "Durable", memo: "Exact draft", isCleared: false,
  splits: [], flag: "orange", tags: ["qa"], attachmentMetadata: [], clientOperationID: UUID().uuidString)
 let queue = LiveTransactionOutbox(fileURL: file)
 var sends = 0
 do {
  try await queue.submit(operation) { sent in
   sends += 1
   precondition(LiveTransactionOutbox(fileURL: file).entries.first?.operation == sent)
   do { try queue.remove(id: sent.clientOperationID!); fatalError("In-flight discard allowed") } catch {}
   throw URLError(.timedOut)
  }
  fatalError("Expected uncertain send")
 } catch {}
 precondition(sends == 1 && queue.count == 1 && !queue.isReplaying)
 let reopened = LiveTransactionOutbox(fileURL: file)
 var second = operation; second.clientOperationID = UUID().uuidString
 var order: [String] = []
 try await reopened.submit(second) { sent in order.append(sent.clientOperationID!) }
 precondition(order == [operation.clientOperationID!, second.clientOperationID!])
 precondition(LiveTransactionOutbox(fileURL: file).count == 0)
 do {
  try await reopened.submit(operation, shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Server rejection") }
  fatalError("Expected review state")
 } catch {}
 precondition(LiveTransactionOutbox(fileURL: file).entries.first?.operation == operation)
 let paused = LiveTransactionOutbox(fileURL: file)
 precondition(paused.entries.first?.requiresReview == true)
 var waiting = operation; waiting.clientOperationID = UUID().uuidString
 try paused.enqueue(waiting)
 var retrySends = 0
 do { try await paused.replay { _ in retrySends += 1 }; fatalError("Paused queue replayed") } catch {}
 precondition(retrySends == 0 && LiveTransactionOutbox(fileURL: file).count == 2)
 try paused.retryReviewed(id: operation.clientOperationID!)
 try await paused.replay { sent in retrySends += 1; precondition(sent == (retrySends == 1 ? operation : waiting)) }
 precondition(retrySends == 2 && LiveTransactionOutbox(fileURL: file).count == 0)
 var edit = operation
 edit.clientOperationID = nil; edit.mutationOperationID = UUID().uuidString
 edit.expectedRevision = "v1:" + String(repeating: "a", count: 64)
 try paused.enqueueEdit(transactionID: "existing", operation: edit)
 let editQueue = LiveTransactionOutbox(fileURL: file)
 precondition(editQueue.entries.first?.transactionID == "existing" && editQueue.entries.first?.operation == edit)
 do { try editQueue.enqueueEdit(transactionID: "other", operation: edit); fatalError("Edit identity rebound") } catch {}
 var missingRevision = edit; missingRevision.expectedRevision = nil
 do { try editQueue.enqueueEdit(transactionID: "existing", operation: missingRevision); fatalError("Unobserved edit queued") } catch {}
 var editSends = 0
 do {
  try await editQueue.replayCommands { entry in
   editSends += 1; precondition(entry.transactionID == "existing" && entry.operation == edit)
   throw URLError(.timedOut)
  }
 } catch {}
 try await LiveTransactionOutbox(fileURL: file).replayCommands { entry in
  editSends += 1; precondition(entry.operation == edit)
 }
 precondition(editSends == 2 && LiveTransactionOutbox(fileURL: file).count == 0)
 let bulk = APITransactionBulkUpdate(transactionIDs: ["existing", "second"], action: "set_cleared", cleared: true,
  expectedRevisions: ["existing": edit.expectedRevision!, "second": edit.expectedRevision!], mutationOperationID: UUID().uuidString)
 try LiveTransactionOutbox(fileURL: file).enqueueBulk(bulk)
 let reopenedBulk = LiveTransactionOutbox(fileURL: file)
 precondition(reopenedBulk.entries.first?.bulkUpdate == bulk && reopenedBulk.entries.first?.operation == nil)
 let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bulk)) as! [String: Any]
 precondition(encoded["tags"] == nil && encoded["flag"] == nil && encoded["mutation_operation_id"] as? String == bulk.mutationOperationID)
 var bulkSends = 0
 do { try await reopenedBulk.replayCommands { entry in bulkSends += 1; precondition(entry.bulkUpdate == bulk); throw URLError(.timedOut) } } catch {}
 try await LiveTransactionOutbox(fileURL: file).replayCommands { entry in bulkSends += 1; precondition(entry.bulkUpdate == bulk) }
 precondition(bulkSends == 2 && LiveTransactionOutbox(fileURL: file).count == 0)
 let unobserved = APITransactionBulkUpdate(transactionIDs: ["existing"], action: "set_cleared", cleared: false, mutationOperationID: UUID().uuidString)
 do { try paused.enqueueBulk(unobserved); fatalError("Unobserved bulk queued") } catch {}
 let shared = root.appendingPathComponent("shared.json")
 let staleOwner = LiveTransactionOutbox(fileURL: shared)
 let currentOwner = LiveTransactionOutbox(fileURL: shared)
 try currentOwner.enqueue(operation)
 let authoritativeBytes = try Data(contentsOf: shared)
 do { try staleOwner.enqueue(second); fatalError("Stale owner replaced saved queue") } catch {}
 var staleSends = 0
 do { try await staleOwner.replay { _ in staleSends += 1 }; fatalError("Stale owner replayed") } catch {}
 let afterStaleAttempt = try Data(contentsOf: shared)
 precondition(staleSends == 0 && afterStaleAttempt == authoritativeBytes)
 do { try await currentOwner.replayCommands { _ in
  // Another owner appends while the first owner's authenticated sender is suspended.
  let otherOwner = LiveTransactionOutbox(fileURL: shared)
  try otherOwner.enqueue(second)
 }; fatalError("Stale acknowledgement erased new intent") } catch {}
 let surviving = LiveTransactionOutbox(fileURL: shared)
 precondition(surviving.entries.map(\.operation) == [operation, second])
 var survivingOrder: [RecordTransactionOperation] = []
 try await surviving.replay { sent in survivingOrder.append(sent) }
 precondition(survivingOrder == [operation, second] && LiveTransactionOutbox(fileURL: shared).count == 0)
 let planningFile = root.appendingPathComponent("planning.json")
 let planningQueue = LiveTransactionOutbox(fileURL: planningFile)
 let assignment = AssignMoneyOperation(categoryID: "food", month: "2026-10-01", assignedMinor: 9007199254740993,
  expectedVersion: 7, mutationOperationID: UUID().uuidString)
 let move = MoveMoneyOperation(sourceCategoryID: "food", destinationCategoryID: "travel", amountMinor: 123,
  occurredOn: "2026-10-09", note: "Exact intent", expectedVersion: 7, mutationOperationID: UUID().uuidString)
 try planningQueue.enqueueAssignment(assignment); try planningQueue.enqueueMoneyMove(move)
 let reopenedPlanning = LiveTransactionOutbox(fileURL: planningFile)
 precondition(reopenedPlanning.entries[0].assignment == assignment && reopenedPlanning.entries[1].moneyMove == move)
 var planSends = 0
 do { try await reopenedPlanning.replayCommands(shouldPause: { _ in true }) { entry in
  planSends += 1
  if let pendingMove = entry.moneyMove {
   precondition(pendingMove.expectedVersion == 7 && pendingMove == move)
   throw BudgetApplicationError.invalidOperation("Plan changed after preceding assignment")
  }
  precondition(entry.assignment == assignment)
 }; fatalError("Stale plan was silently rebased") } catch {}
 let retainedPlan = LiveTransactionOutbox(fileURL: planningFile)
 precondition(planSends == 2 && retainedPlan.count == 1 && retainedPlan.entries[0].requiresReview == true && retainedPlan.entries[0].moneyMove == move)
 let blockedParent = root.appendingPathComponent("blocked")
 try Data("not a directory".utf8).write(to: blockedParent)
 let unwritable = LiveTransactionOutbox(fileURL: blockedParent.appendingPathComponent("queue.json"))
 var attempted = false
 do { try await unwritable.submit(operation) { _ in attempted = true }; fatalError("Write unexpectedly succeeded") } catch {}
 precondition(!attempted && unwritable.count == 0)
 let transferFile = root.appendingPathComponent("transfers.json")
 let transferQueue = LiveTransactionOutbox(fileURL: transferFile)
 let transfer = TransferMoneyOperation(mutationOperationID: UUID().uuidString.lowercased(), sourceAccountID: "cash", destinationAccountID: "card", amountMinor: 9_007_199_254_740_993, occurredOn: "2026-09-04", memo: "Exact transfer", isCleared: false)
 try transferQueue.enqueueTransfer(transfer)
 let transferEdit = TransferMoneyOperation(mutationOperationID: UUID().uuidString.lowercased(), expectedRevisions: ["source-leg": "v1:" + String(repeating: "a", count: 64), "destination-leg": "v1:" + String(repeating: "b", count: 64)], sourceAccountID: "cash", destinationAccountID: "card", amountMinor: 200, occurredOn: "2026-09-04", memo: "Observed edit", isCleared: true)
 try transferQueue.enqueueTransfer(transferEdit, id: "logical-transfer")
 let reopenedTransfers = LiveTransactionOutbox(fileURL: transferFile)
 precondition(reopenedTransfers.entries[0].accountTransfer == transfer && reopenedTransfers.entries[1].accountTransfer == transferEdit)
 precondition(reopenedTransfers.entries[1].transferID == "logical-transfer")
 var transferSends = 0
 do { try await reopenedTransfers.replayCommands(shouldPause: { _ in true }) { entry in
     transferSends += 1
     if entry.transferID != nil { throw BudgetApplicationError.invalidOperation("Stale transfer") }
 }; fatalError("Expected stale edit") } catch {}
 precondition(transferSends == 2 && reopenedTransfers.count == 1 && reopenedTransfers.entries[0].requiresReview == true)
 precondition(reopenedTransfers.entries[0].accountTransfer?.expectedRevisions == transferEdit.expectedRevisions)
 let reconciliationFile = root.appendingPathComponent("reconciliation.json")
 let reconciliationQueue = LiveTransactionOutbox(fileURL: reconciliationFile)
 let reconciliation = ReconcileAccountOperation(mutationOperationID: UUID().uuidString.lowercased(), expectedReviewRevision: "v1:" + String(repeating: "c", count: 64), accountID: "cash", statementBalanceMinor: 9_007_199_254_740_993, throughDate: "2026-09-04", createAdjustment: true, reason: "Reviewed correction", expectedClearedBalanceMinor: 9_007_199_254_740_990)
 try reconciliationQueue.enqueueReconciliation(reconciliation)
 var unreviewed = reconciliation
 unreviewed.expectedReviewRevision = nil
 do { try reconciliationQueue.enqueueReconciliation(unreviewed); fatalError("Unreviewed reconciliation was saved") } catch {}
 try reconciliationQueue.enqueueReconciliation(reconciliation)
 precondition(reconciliationQueue.count == 1)
 var duplicateReconciliation = reconciliation
 duplicateReconciliation.mutationOperationID = UUID().uuidString.lowercased()
 do { try reconciliationQueue.enqueueReconciliation(duplicateReconciliation); fatalError("Duplicate pending account reconciliation accepted") } catch {}
 let reopenedReconciliation = LiveTransactionOutbox(fileURL: reconciliationFile)
 precondition(reopenedReconciliation.entries[0].reconciliation == reconciliation)
 var reconciliationSends = 0
 do { try await reopenedReconciliation.replayCommands(shouldPause: { _ in false }) { entry in
     reconciliationSends += 1
     precondition(entry.reconciliation == reconciliation)
     throw URLError(.networkConnectionLost)
 }; fatalError("Expected lost acknowledgement") } catch {}
 let retryReconciliation = LiveTransactionOutbox(fileURL: reconciliationFile)
 precondition(retryReconciliation.count == 1 && retryReconciliation.entries[0].requiresReview != true)
 do { try await retryReconciliation.replayCommands(shouldPause: { _ in true }) { entry in
     reconciliationSends += 1
     precondition(entry.reconciliation?.expectedReviewRevision == reconciliation.expectedReviewRevision)
     throw BudgetApplicationError.invalidOperation("Reviewed transactions changed")
 }; fatalError("Expected stale review") } catch {}
 let pausedReconciliation = LiveTransactionOutbox(fileURL: reconciliationFile)
 precondition(pausedReconciliation.entries[0].requiresReview == true)
 do { try await pausedReconciliation.replayCommands { _ in fatalError("Paused reconciliation sent automatically") } } catch {}
 try pausedReconciliation.retryReviewed(id: reconciliation.mutationOperationID!)
 try await pausedReconciliation.replayCommands { entry in
     reconciliationSends += 1
     precondition(entry.reconciliation == reconciliation)
 }
 precondition(reconciliationSends == 3 && LiveTransactionOutbox(fileURL: reconciliationFile).count == 0)
 print("PASS: reviewed reconciliation exact amounts/consent/token/identity persist before send, duplicate account submissions rejected, lost acknowledgement retained, stale review paused across relaunch, explicit retry never rebases, acknowledgement clears original intent")
 print("PASS: durable before first send, exact uncertain intent survives relaunch, ordered submission, acknowledgement, persisted rejection pause, later operations blocked, explicit ordered retry, targeted edits/bulk/transfers survive relaunch, stale transfer versions never rebased, stale owners cannot overwrite/replay/ack newer intent, no send after persistence failure")
}.value
SWIFT
RUBY
