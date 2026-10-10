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
puts s[s.index("struct MakeRecurringOperation:")...s.index("struct CreatePayeeOperation:")]
puts s[s.index("struct TransferMoneyOperation:")...s.index("struct ScheduleOperation:")]
puts s[s.index("struct ScheduleOperation:")...s.index("struct AccountBalanceObservation:")]
api = File.read("Sources/BudgetAPI/APIModels.swift")
puts api[api.index("public struct APITransactionBulkUpdate:")...api.index("/// Captures observations at selection time")]
puts s[s.index("@MainActor\nfinal class LiveTransactionOutbox")...s.index("struct LiveWorkspaceCachePayload:")]
puts s[s.index("private func liveCredentialSubject")...s.index("func isTransientConnectivityFailure")]
session = File.read("ios/BudgetApp/AppSession.swift")
puts 'struct APIBudget: Equatable { let id: String }'
puts session[session.index("enum WorkspaceRouteContext:")...session.index("enum ApplicationRoute:")]
workspace = File.read("ios/BudgetApp/BudgetWorkspaceView.swift")
abort "Attachment upload must stage before replay" unless workspace.include?("try transactionOutbox.enqueueAttachment(id: operationID") && workspace.include?("operationID: entry.id, token: token") && workspace.include?("let data = try transactionOutbox.stagedAttachmentData(for: entry)")
abort "Attachment acknowledgement must verify integrity" unless workspace.include?("accepted.sha256 == upload.sha256") && workspace.include?("accepted.byteCount == Int64(upload.byteCount)") && workspace.include?("accepted.transactionID == upload.transactionID") && workspace.include?("accepted.detachedAt == nil")
preview_start = workspace.index("    private func openPending(")
preview_end = workspace.index("    private func open(_ attachment:", preview_start || 0)
abort "Pending preview must read scoped local bytes without transport or mutation" unless preview_start && preview_end && workspace[preview_start...preview_end].include?("store.pendingAttachmentBytes(id: entry.id)") && !workspace[preview_start...preview_end].include?("detach") && !workspace[preview_start...preview_end].include?("await")
abort "Staged previews must be gated by currently visible pending entries" unless workspace.include?("guard pendingLiveTransactions.contains(where: { $0.id == id && $0.attachmentUpload != nil })")
send_first = workspace.index("    private func sendTransaction(")
send_last = workspace.index("    func householdInvitations()", send_first || 0)
abort "Canonical send path moved; review binding guard" unless send_first && send_last
send_body = workspace[send_first...send_last]
abort "Duplication bypasses reviewed durable replay" unless workspace.include?("transactionOutbox.enqueueDuplicate(identified)") && send_body.include?("entry.duplicateCommand") && send_body.include?("client.duplicateTransaction(") && workspace.include?("expectedRevision: duplicateRevision")
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
abort "Schedules must persist before canonical identified replay" unless workspace.include?("try transactionOutbox.enqueueSchedule(id:") && send_body.include?("entry.scheduleCreation") && send_body.include?("schedule: schedule.apiValue, operationID: entry.id, token: token")
abort "Schedule edits lose review or bypass durable replay" unless workspace.include?("transactionOutbox.enqueueScheduleEdit(scheduleID: id, operation: identified)") && send_body.include?("entry.scheduleEdit") && send_body.include?("schedule: edit.apiValue, token: token") && workspace.include?("_observedRevision = State(initialValue: schedule?.revision)") && workspace.include?("reviewed.expectedRevision = observedRevision")
abort "Schedule deletion bypasses durable reviewed replay" unless workspace.include?("transactionOutbox.enqueueScheduleDeletion(identified)") && send_body.include?("entry.scheduleDeletion") && send_body.include?("expectedRevision: deletion.expectedRevision, operationID: deletion.mutationOperationID, token: token") && workspace.include?("store.deleteSchedule(id: schedule.id, expectedRevision: observedRevision)")
abort "Realization bypasses durable reviewed replay" unless workspace.include?("transactionOutbox.enqueueScheduleRealization(identified)") && send_body.include?("entry.scheduleRealization") && send_body.include?("expectedRevision: realization.expectedRevision, operationID: realization.mutationOperationID, token: token") && workspace.include?("store.realizeReviewedSchedule(id: schedule.id, expectedRevision: observedRevision)")
abort "Attachment removal bypasses reviewed durable replay" unless workspace.include?("transactionOutbox.enqueueAttachmentRemoval(identified)") && send_body.include?("entry.attachmentRemoval") && send_body.include?("expectedSHA256: removal.expectedSHA256") && workspace.include?("store.detachTransactionAttachment(transactionID: transaction.id, attachment: attachment)")
abort "Schedule editor loses existing interest classification" unless workspace.include?("financialClassification: schedule?.financialClassification, isActive: isActive ?? active")
abort "Make Recurring loses captured intent or bypasses durable replay" unless workspace.include?("transactionOutbox.enqueueMakeRecurring(transactionID: id, operation: identified)") && send_body.include?("entry.makeRecurring") && send_body.include?("expectedRevision: recurring.expectedRevision") && workspace.include?("expectedRevision: transaction.revision")
abort "Pending schedules must remain separate from accepted forecast" unless workspace.include?('Section("Awaiting Server Confirmation")') && workspace.include?('not yet included in forecast')
abort "Planning commands bypass durable canonical sender" unless send_body.include?("client.updateAssignment(") && send_body.include?("client.transferAllocation(") && workspace.include?("try transactionOutbox.enqueueAssignment(identified)") && workspace.include?("try transactionOutbox.enqueueMoneyMove(identified)")
abort "Transfers bypass durable canonical sender" unless send_body.include?("client.createTransfer(") && send_body.include?("client.updateTransfer(") && workspace.include?("try transactionOutbox.enqueueTransfer(identified)") && workspace.include?("try transactionOutbox.enqueueTransfer(identified, id: id)")
abort "Transfer editor loses observed versions" unless workspace.include?("_expectedRevisions = State(initialValue: presentation.expectedRevisions)") && workspace.include?("TransferMoneyOperation(expectedRevisions: expectedRevisions")
abort "Live reconciliation bypasses reviewed-set observation" unless workspace.include?("client.reconciliationObservation(") && workspace.include?("guard operation.expectedReviewRevision != nil else") && workspace.include?("expectedReviewRevision: operation.expectedReviewRevision")
abort "Live reconciliation bypasses durable canonical replay" unless workspace.include?("transactionOutbox.enqueueReconciliation(identified)") && send_body.include?("entry.reconciliation") && send_body.include?("mutationOperationID: operation.mutationOperationID")
abort "Pending reconciliation exposes unscoped account details" unless workspace.include?('budget.can("reconcile_account") && budget.can("view_account_balances") && accountIDs.contains(reconciliation.accountID)')
abort "Void bypasses durable observed replay" unless workspace.include?("transactionOutbox.enqueueVoid(identified)") && send_body.include?("entry.voidCommand") && send_body.include?("client.voidTransaction(") && workspace.include?("expectedRevision: observedRevision")
abort "Pending void exposes an unavailable transaction" unless workspace.include?('budget.can("delete_transaction") && budget.can("view_transactions") && transactions.contains(where: { $0.id == command.transactionID })')
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
 let deletionFile = root.appendingPathComponent("deletion.json")
 let deletionQueue = LiveTransactionOutbox(fileURL: deletionFile)
 let deletion = DeleteTransactionOperation(transactionID: "original", expectedRevision: "v1:" + String(repeating: "a", count: 64), mutationOperationID: UUID().uuidString.lowercased())
 try deletionQueue.enqueueDeletion(deletion); try deletionQueue.enqueueDeletion(deletion)
 precondition(deletionQueue.count == 1)
 var otherDeletion = deletion; otherDeletion.mutationOperationID = UUID().uuidString.lowercased()
 do { try deletionQueue.enqueueDeletion(otherDeletion); fatalError("Duplicate pending deletion accepted") } catch {}
 do { try await deletionQueue.replayCommands(shouldPause: { _ in false }) { entry in
     precondition(entry.deletionCommand == deletion); throw URLError(.networkConnectionLost)
 }; fatalError("Expected lost deletion response") } catch {}
 let reopenedDeletion = LiveTransactionOutbox(fileURL: deletionFile)
 precondition(reopenedDeletion.entries[0].deletionCommand == deletion)
 do { try await reopenedDeletion.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Changed target") }; fatalError("Expected stale deletion") } catch {}
 let pausedDeletion = LiveTransactionOutbox(fileURL: deletionFile)
 do { try await pausedDeletion.replayCommands { _ in fatalError("Paused deletion replayed") } } catch {}
 try pausedDeletion.retryReviewed(id: deletion.mutationOperationID!)
 try await pausedDeletion.replayCommands { entry in precondition(entry.deletionCommand == deletion) }
 precondition(LiveTransactionOutbox(fileURL: deletionFile).count == 0)
 print("PASS: reviewed deletion identity/target/revision survive response loss/relaunch, duplicate refused, rejection paused, original retry and acknowledgement cleanup")
 let duplicateFile = root.appendingPathComponent("duplicate.json")
 let duplicateQueue = LiveTransactionOutbox(fileURL: duplicateFile)
 let duplicateCommand = DuplicateTransactionOperation(transactionID: "source", occurredOn: "2026-10-09",
     expectedRevision: "v1:" + String(repeating: "d", count: 64), mutationOperationID: UUID().uuidString.lowercased())
 try duplicateQueue.enqueueDuplicate(duplicateCommand)
 try duplicateQueue.enqueueDuplicate(duplicateCommand); precondition(duplicateQueue.count == 1)
 var secondDuplicate = duplicateCommand; secondDuplicate.mutationOperationID = UUID().uuidString.lowercased()
 do { try duplicateQueue.enqueueDuplicate(secondDuplicate); fatalError("Duplicate pending copy accepted") } catch {}
 var duplicateSends = 0
 do { try await duplicateQueue.replayCommands(shouldPause: { _ in false }) { entry in
     duplicateSends += 1; precondition(entry.duplicateCommand == duplicateCommand); throw URLError(.networkConnectionLost)
 }; fatalError("Expected response loss") } catch {}
 let reopenedDuplicate = LiveTransactionOutbox(fileURL: duplicateFile)
 precondition(reopenedDuplicate.entries[0].duplicateCommand == duplicateCommand)
 do { try await reopenedDuplicate.replayCommands(shouldPause: { _ in true }) { _ in
     duplicateSends += 1; throw BudgetApplicationError.invalidOperation("Source changed")
 }; fatalError("Expected stale duplicate") } catch {}
 let pausedDuplicate = LiveTransactionOutbox(fileURL: duplicateFile)
 do { try await pausedDuplicate.replayCommands { _ in fatalError("Paused duplicate automatically sent") } } catch {}
 try pausedDuplicate.retryReviewed(id: duplicateCommand.mutationOperationID!)
 try await pausedDuplicate.replayCommands { entry in duplicateSends += 1; precondition(entry.duplicateCommand == duplicateCommand) }
 precondition(duplicateSends == 3 && LiveTransactionOutbox(fileURL: duplicateFile).count == 0)
 print("PASS: reviewed duplication date/source/revision/identity survive response loss/relaunch, duplicate refused, rejection paused, original-intent retry and acknowledgement cleanup")
 let voidFile = root.appendingPathComponent("void.json")
 let voidQueue = LiveTransactionOutbox(fileURL: voidFile)
 let voidCommand = VoidTransactionOperation(transactionID: "original", reason: "Reviewed duplicate", expectedRevision: "v1:" + String(repeating: "d", count: 64), mutationOperationID: UUID().uuidString.lowercased())
 try voidQueue.enqueueVoid(voidCommand)
 try voidQueue.enqueueVoid(voidCommand)
 precondition(voidQueue.count == 1)
 var duplicateVoid = voidCommand
 duplicateVoid.mutationOperationID = UUID().uuidString.lowercased()
 do { try voidQueue.enqueueVoid(duplicateVoid); fatalError("Duplicate pending void accepted") } catch {}
 let reopenedVoid = LiveTransactionOutbox(fileURL: voidFile)
 var voidSends = 0
 do { try await reopenedVoid.replayCommands(shouldPause: { _ in false }) { entry in
     voidSends += 1; precondition(entry.voidCommand == voidCommand)
     throw URLError(.networkConnectionLost)
 }; fatalError("Expected lost void acknowledgement") } catch {}
 let retainedVoid = LiveTransactionOutbox(fileURL: voidFile)
 precondition(retainedVoid.entries[0].voidCommand == voidCommand && retainedVoid.entries[0].requiresReview != true)
 do { try await retainedVoid.replayCommands(shouldPause: { _ in true }) { _ in
     voidSends += 1; throw BudgetApplicationError.invalidOperation("Transaction changed")
 }; fatalError("Expected stale void") } catch {}
 let pausedVoid = LiveTransactionOutbox(fileURL: voidFile)
 precondition(pausedVoid.entries[0].requiresReview == true)
 do { try await pausedVoid.replayCommands { _ in fatalError("Paused void sent automatically") } } catch {}
 try pausedVoid.retryReviewed(id: voidCommand.mutationOperationID!)
 try await pausedVoid.replayCommands { entry in
     voidSends += 1; precondition(entry.voidCommand == voidCommand)
 }
 precondition(voidSends == 3 && LiveTransactionOutbox(fileURL: voidFile).count == 0)
 print("PASS: void target/reason/revision/identity survive lost response and relaunch, duplicate pending void rejected, stale rejection pauses, explicit retry preserves original intent, acknowledgement removes saved command")
 print("PASS: durable before first send, exact uncertain intent survives relaunch, ordered submission, acknowledgement, persisted rejection pause, later operations blocked, explicit ordered retry, targeted edits/bulk/transfers survive relaunch, stale transfer versions never rebased, stale owners cannot overwrite/replay/ack newer intent, no send after persistence failure")
 let uploadFile = root.appendingPathComponent("upload.json")
 let uploadQueue = LiveTransactionOutbox(fileURL: uploadFile)
 let uploadID = UUID().uuidString.lowercased()
 let bytes = Data("%PDF-staged-receipt".utf8)
 try uploadQueue.enqueueAttachment(id: uploadID, transactionID: "original", filename: "receipt.pdf", contentType: "application/pdf", data: bytes)
 try uploadQueue.enqueueAttachment(id: uploadID, transactionID: "original", filename: "receipt.pdf", contentType: "application/pdf", data: bytes)
 precondition(uploadQueue.count == 1)
 do { try uploadQueue.enqueueAttachment(id: uploadID, transactionID: "different", filename: "receipt.pdf", contentType: "application/pdf", data: bytes); fatalError("Upload identity reused for different target") } catch {}
 let persistedUploadJSON = try Data(contentsOf: uploadFile)
 precondition(persistedUploadJSON.count < 4096)
 let stagedURL = uploadFile.appendingPathExtension("attachments").appendingPathComponent(uploadID)
 let uploadPermissions = try FileManager.default.attributesOfItem(atPath: stagedURL.path)[.posixPermissions] as? NSNumber
 precondition(uploadPermissions?.intValue == 0o600)
 let reopenedUpload = LiveTransactionOutbox(fileURL: uploadFile)
 let reopenedBytes = try reopenedUpload.stagedAttachmentData(for: reopenedUpload.entries[0])
 precondition(reopenedBytes == bytes)
 do { try await reopenedUpload.replayCommands { _ in throw URLError(.networkConnectionLost) }; fatalError("Expected interrupted upload") } catch {}
 let retainedUpload = LiveTransactionOutbox(fileURL: uploadFile)
 precondition(retainedUpload.entries[0].id == uploadID)
 try await retainedUpload.replayCommands { entry in
     precondition(entry.id == uploadID)
     let retryBytes = try retainedUpload.stagedAttachmentData(for: entry)
     precondition(retryBytes == bytes)
 }
 precondition(LiveTransactionOutbox(fileURL: uploadFile).count == 0 && !FileManager.default.fileExists(atPath: stagedURL.path))
 let corruptQueue = LiveTransactionOutbox(fileURL: root.appendingPathComponent("corrupt-upload.json"))
 let corruptID = UUID().uuidString.lowercased()
 try corruptQueue.enqueueAttachment(id: corruptID, transactionID: "original", filename: "receipt.pdf", contentType: "application/pdf", data: bytes)
 let corruptURL = root.appendingPathComponent("corrupt-upload.json").appendingPathExtension("attachments").appendingPathComponent(corruptID)
 try Data(repeating: 0, count: bytes.count).write(to: corruptURL)
 do { try await corruptQueue.replayCommands(shouldPause: { $0 is AttachmentStagingError }) { entry in
     _ = try corruptQueue.stagedAttachmentData(for: entry)
     fatalError("Corrupt bytes reached transport")
 }; fatalError("Expected corrupt-byte refusal") } catch {}
 precondition(corruptQueue.entries[0].requiresReview == true && FileManager.default.fileExists(atPath: corruptURL.path))
 do { try corruptQueue.enqueueAttachment(id: UUID().uuidString, transactionID: "original", filename: "bad.pdf", contentType: "application/pdf", data: Data("not a PDF".utf8)); fatalError("Invalid signature accepted") } catch {}
 do { try corruptQueue.enqueueAttachment(id: UUID().uuidString, transactionID: "original", filename: "large.pdf", contentType: "application/pdf", data: bytes + Data(repeating: 0, count: 10 * 1024 * 1024)); fatalError("Oversized file accepted") } catch {}
 let boundedQueue = LiveTransactionOutbox(fileURL: root.appendingPathComponent("bounded-upload.json"))
 for _ in 0..<20 { try boundedQueue.enqueueAttachment(id: UUID().uuidString, transactionID: "original", filename: "receipt.pdf", contentType: "application/pdf", data: bytes) }
 do { try boundedQueue.enqueueAttachment(id: UUID().uuidString, transactionID: "original", filename: "receipt.pdf", contentType: "application/pdf", data: bytes); fatalError("Twenty-first pending upload accepted") } catch {}
 precondition(boundedQueue.count == 20)
 print("PASS: protected upload bytes and identity survive interrupted transport/relaunch; verified acknowledgement removes bytes; corrupt bytes pause without transport or deletion; invalid signature rejected")
 let scheduleFile = root.appendingPathComponent("schedule.json")
 let scheduleQueue = LiveTransactionOutbox(fileURL: scheduleFile)
 let scheduleID = UUID().uuidString.lowercased()
 let schedule = ScheduleOperation(accountID: "checking", categoryID: "food", payeeID: "payee", name: "Reviewed bill", amountMinor: -9007199254740993, nextDate: "2099-01-01", recurrenceUnit: "months", intervalCount: 2, remainingOccurrences: 4, memo: "Original", isActive: false)
 try scheduleQueue.enqueueSchedule(id: scheduleID, operation: schedule)
 try scheduleQueue.enqueueSchedule(id: scheduleID, operation: schedule)
 precondition(scheduleQueue.count == 1)
 let reopenedSchedule = LiveTransactionOutbox(fileURL: scheduleFile)
 do { try await reopenedSchedule.replayCommands { entry in
     precondition(entry.id == scheduleID && entry.scheduleCreation == schedule)
     throw URLError(.networkConnectionLost)
 }; fatalError("Expected interrupted schedule") } catch {}
 let retainedSchedule = LiveTransactionOutbox(fileURL: scheduleFile)
 do { try await retainedSchedule.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Revoked scope") }; fatalError("Expected schedule rejection") } catch {}
 let pausedSchedule = LiveTransactionOutbox(fileURL: scheduleFile)
 precondition(pausedSchedule.entries[0].requiresReview == true && pausedSchedule.entries[0].scheduleCreation == schedule)
 do { try await pausedSchedule.replayCommands { _ in fatalError("Paused schedule retried automatically") } } catch {}
 try pausedSchedule.retryReviewed(id: scheduleID)
 try await pausedSchedule.replayCommands { entry in precondition(entry.id == scheduleID && entry.scheduleCreation == schedule) }
 precondition(LiveTransactionOutbox(fileURL: scheduleFile).count == 0)
 let invalidSchedule = ScheduleOperation(accountID: "checking", name: "Invalid", amountMinor: -1, nextDate: "2099-02-30", recurrenceUnit: "months")
 do { try pausedSchedule.enqueueSchedule(id: UUID().uuidString, operation: invalidSchedule); fatalError("Invalid date persisted") } catch {}
 print("PASS: exact schedule resources/cadence/limit/paused state/identity survive loss and relaunch, rejected intent pauses, explicit retry preserves original payload, acknowledgement removes it, invalid date is not saved")
 let recurringFile = root.appendingPathComponent("recurring.json")
 let recurringQueue = LiveTransactionOutbox(fileURL: recurringFile)
 let recurringID = UUID().uuidString.lowercased()
 let recurring = MakeRecurringOperation(recurrenceUnit: "months", intervalCount: 2, nextDate: "2099-01-01", expectedRevision: "v1:" + String(repeating: "a", count: 64), mutationOperationID: recurringID)
 try recurringQueue.enqueueMakeRecurring(transactionID: "original", operation: recurring)
 try recurringQueue.enqueueMakeRecurring(transactionID: "original", operation: recurring)
 do { try recurringQueue.enqueueMakeRecurring(transactionID: "different", operation: recurring); fatalError("Recurring identity reused for different source") } catch {}
 do { try await recurringQueue.replayCommands { entry in
     precondition(entry.transactionID == "original" && entry.makeRecurring == recurring)
     throw URLError(.networkConnectionLost)
 }; fatalError("Expected transport interruption") } catch {}
 let reopenedRecurring = LiveTransactionOutbox(fileURL: recurringFile)
 precondition(reopenedRecurring.count == 1 && reopenedRecurring.entries[0].makeRecurring == recurring)
 do { try await reopenedRecurring.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Stale observed source") }; fatalError("Expected rejection") } catch {}
 let pausedRecurring = LiveTransactionOutbox(fileURL: recurringFile)
 precondition(pausedRecurring.entries[0].requiresReview == true)
 do { try await pausedRecurring.replayCommands { _ in fatalError("Stale source automatically retried") } } catch {}
 try pausedRecurring.retryReviewed(id: recurringID)
 try await pausedRecurring.replayCommands { entry in precondition(entry.id == recurringID && entry.makeRecurring == recurring) }
 precondition(LiveTransactionOutbox(fileURL: recurringFile).count == 0)
 var invalidRecurring = recurring; invalidRecurring.expectedRevision = nil
 do { try pausedRecurring.enqueueMakeRecurring(transactionID: "original", operation: invalidRecurring); fatalError("Unobserved template persisted") } catch {}
 print("PASS: Make Recurring preserves source/revision/date/identity across interruption and relaunch; rejected template pauses, explicit retry never rebases, acknowledgement removes intent")
 do {
 let editFile = root.appendingPathComponent("schedule-edit.json")
 let editQueue = LiveTransactionOutbox(fileURL: editFile)
 var edit = schedule; edit.expectedRevision = "v1:" + String(repeating: "a", count: 64); edit.mutationOperationID = UUID().uuidString
 try editQueue.enqueueScheduleEdit(scheduleID: "existing", operation: edit)
 try editQueue.enqueueScheduleEdit(scheduleID: "existing", operation: edit)
 do { try editQueue.enqueueScheduleEdit(scheduleID: "different", operation: edit); fatalError("Edit identity rebound") } catch {}
 var secondEdit = edit; secondEdit.mutationOperationID = UUID().uuidString
 do { try editQueue.enqueueScheduleEdit(scheduleID: "existing", operation: secondEdit); fatalError("Second edit queued without pending review") } catch {}
 do { try await editQueue.replayCommands { _ in throw URLError(.networkConnectionLost) }; fatalError("Expected lost edit acknowledgement") } catch {}
 let reopenedEdit = LiveTransactionOutbox(fileURL: editFile)
 precondition(reopenedEdit.entries[0].scheduleEdit == edit && reopenedEdit.entries[0].scheduleID == "existing")
 do { try await reopenedEdit.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Stale revision") }; fatalError("Expected edit rejection") } catch {}
 let pausedEdit = LiveTransactionOutbox(fileURL: editFile)
 precondition(pausedEdit.entries[0].requiresReview == true)
 do { try await pausedEdit.replayCommands { _ in fatalError("Stale edit auto replayed") } } catch {}
 try pausedEdit.retryReviewed(id: edit.mutationOperationID!)
 try await pausedEdit.replayCommands { entry in precondition(entry.scheduleEdit == edit) }
 precondition(LiveTransactionOutbox(fileURL: editFile).count == 0)
 let exhausted = ScheduleOperation(accountID: "checking", name: "Finished", amountMinor: -1, nextDate: "2099-01-01", recurrenceUnit: "months", remainingOccurrences: 0, isActive: false, expectedRevision: edit.expectedRevision, mutationOperationID: UUID().uuidString)
 try pausedEdit.enqueueScheduleEdit(scheduleID: "exhausted", operation: exhausted)
 precondition(LiveTransactionOutbox(fileURL: editFile).entries[0].scheduleEdit == exhausted)
 print("PASS: reviewed schedule edits retain exact payload/revision/identity through loss and relaunch; stale edits pause, retry never rebases; inactive exhausted limits remain valid")
 }
 do {
 let deletionFile = root.appendingPathComponent("schedule-delete.json")
 let deletionQueue = LiveTransactionOutbox(fileURL: deletionFile)
 let deletion = DeleteScheduleOperation(scheduleID: "existing", expectedRevision: "v1:" + String(repeating: "a", count: 64), mutationOperationID: UUID().uuidString)
 try deletionQueue.enqueueScheduleDeletion(deletion)
 try deletionQueue.enqueueScheduleDeletion(deletion)
 var duplicate = deletion; duplicate.mutationOperationID = UUID().uuidString
 do { try deletionQueue.enqueueScheduleDeletion(duplicate); fatalError("Second deletion saved") } catch {}
 do { try deletionQueue.enqueueScheduleDeletion(.init(scheduleID: "other", expectedRevision: deletion.expectedRevision, mutationOperationID: deletion.mutationOperationID)); fatalError("Deletion identity rebound") } catch {}
 do { try await deletionQueue.replayCommands { _ in throw URLError(.networkConnectionLost) }; fatalError("Expected lost delete acknowledgement") } catch {}
 let reopened = LiveTransactionOutbox(fileURL: deletionFile)
 precondition(reopened.entries[0].scheduleDeletion == deletion)
 do { try await reopened.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Stale deletion review") }; fatalError("Expected stale deletion") } catch {}
 let paused = LiveTransactionOutbox(fileURL: deletionFile)
 precondition(paused.entries[0].requiresReview == true)
 do { try await paused.replayCommands { _ in fatalError("Paused deletion auto retried") } } catch {}
 try paused.retryReviewed(id: deletion.mutationOperationID!)
 try await paused.replayCommands { entry in precondition(entry.scheduleDeletion == deletion) }
 precondition(LiveTransactionOutbox(fileURL: deletionFile).count == 0)
 do { try paused.enqueueScheduleDeletion(.init(scheduleID: "unreviewed", expectedRevision: nil, mutationOperationID: UUID().uuidString)); fatalError("Unreviewed deletion saved") } catch {}
 print("PASS: deletion target/revision/identity survive lost response and relaunch; stale request pauses; original-intent retry and acknowledgement cleanup; duplicate/unreviewed deletion refused")
 }
 do {
 let file = root.appendingPathComponent("schedule-realize.json")
 let queue = LiveTransactionOutbox(fileURL: file)
 let operation = RealizeScheduleOperation(scheduleID: "due", expectedRevision: "v1:" + String(repeating: "a", count: 64), mutationOperationID: UUID().uuidString)
 try queue.enqueueScheduleRealization(operation)
 try queue.enqueueScheduleRealization(operation)
 var duplicate = operation; duplicate.mutationOperationID = UUID().uuidString
 do { try queue.enqueueScheduleRealization(duplicate); fatalError("Second occurrence queued") } catch {}
 do { try await queue.replayCommands { _ in throw URLError(.networkConnectionLost) }; fatalError("Expected lost acknowledgement") } catch {}
 let reopened = LiveTransactionOutbox(fileURL: file)
 precondition(reopened.entries[0].scheduleRealization == operation)
 do { try await reopened.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Changed schedule") }; fatalError("Expected stale rejection") } catch {}
 let paused = LiveTransactionOutbox(fileURL: file)
 precondition(paused.entries[0].requiresReview == true)
 do { try await paused.replayCommands { _ in fatalError("Paused realization auto retried") } } catch {}
 try paused.retryReviewed(id: operation.mutationOperationID!)
 try await paused.replayCommands { entry in precondition(entry.scheduleRealization == operation) }
 precondition(LiveTransactionOutbox(fileURL: file).count == 0)
 do { try paused.enqueueScheduleRealization(.init(scheduleID: "unreviewed", expectedRevision: nil, mutationOperationID: UUID().uuidString)); fatalError("Unreviewed realization saved") } catch {}
 print("PASS: reviewed realization survives response loss/relaunch; duplicate refused; stale request pauses; original-intent retry and acknowledgement cleanup")
 }
 do {
 let file = root.appendingPathComponent("attachment-remove.json")
 let queue = LiveTransactionOutbox(fileURL: file)
 let operation = DetachAttachmentOperation(transactionID: "posted", attachmentID: "receipt", expectedSHA256: String(repeating: "a", count: 64), filename: "receipt.pdf", mutationOperationID: UUID().uuidString)
 try queue.enqueueAttachmentRemoval(operation)
 try queue.enqueueAttachmentRemoval(operation)
 var duplicate = operation; duplicate.mutationOperationID = UUID().uuidString
 do { try queue.enqueueAttachmentRemoval(duplicate); fatalError("Second removal queued") } catch {}
 do { try await queue.replayCommands { _ in throw URLError(.networkConnectionLost) }; fatalError("Expected lost acknowledgement") } catch {}
 let reopened = LiveTransactionOutbox(fileURL: file)
 precondition(reopened.entries[0].attachmentRemoval == operation)
 do { try await reopened.replayCommands(shouldPause: { _ in true }) { _ in throw BudgetApplicationError.invalidOperation("Permission revoked") }; fatalError("Expected rejected removal") } catch {}
 let paused = LiveTransactionOutbox(fileURL: file)
 precondition(paused.entries[0].requiresReview == true)
 do { try await paused.replayCommands { _ in fatalError("Rejected removal auto retried") } } catch {}
 try paused.retryReviewed(id: operation.mutationOperationID!)
 try await paused.replayCommands { entry in precondition(entry.attachmentRemoval == operation) }
 precondition(LiveTransactionOutbox(fileURL: file).count == 0)
 do { try paused.enqueueAttachmentRemoval(.init(transactionID: "posted", attachmentID: "receipt", expectedSHA256: "bad", filename: "receipt.pdf", mutationOperationID: UUID().uuidString)); fatalError("Unreviewed file saved") } catch {}
 print("PASS: exact attachment removal target/digest/identity survives response loss/relaunch; duplicate refused; rejection pauses; original-intent retry and cleanup")
 }
}.value
SWIFT
RUBY
