#!/bin/bash
# Execute the production cache with record doubles, without launching/resetting Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ruby - <<'RUBY' | xcrun swift -
source = File.read("ios/BudgetApp/ApplicationServices.swift")
puts "import Foundation\nimport CryptoKit"
%w[APIAccount APIAccountBalance APICategory APICategoryGroup APITransaction APIMonthSummary APICategoryTarget APIScheduledTransaction APIForecast].each { |name| puts "typealias #{name} = String" }
puts <<'SWIFT'
enum BudgetApplicationError: Error { case invalidOperation(String) }
struct WorkspaceSnapshot {
 var accounts: [String] = []; var accountBalances: [String:String] = [:]
 var categories: [String] = []; var groups: [String] = []; var transactions: [String] = ["private"]
 var summary: String?; var targets: [String] = []; var schedules: [String] = []; var forecast: String?
}
SWIFT
first = source.index("struct LiveWorkspaceCachePayload:")
last = source.index("func isTransientConnectivityFailure")
abort "Production cache boundaries changed; update harness deliberately" unless first && last && first < last
puts source[first...last]
workspace = File.read("ios/BudgetApp/BudgetWorkspaceView.swift")
month_first = workspace.index("    @Published var planMonth =")
month_last = workspace.index("    @Published var isLoading", month_first || 0)
abort "Production month observer changed; update harness deliberately" unless month_first && month_last
puts "@MainActor final class MonthProbe { var summary: String? = \"old month\"; var delegatedBudget: String? = \"old scope\"; var snapshotOperationID = UUID()"
puts workspace[month_first...month_last].sub("@Published ", "")
puts 'static func dateString(_ date: Date) -> String { let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date) } }'
puts <<'SWIFT'
try await MainActor.run {
 func token(_ subject: String, _ signature: String) throws -> String {
  let payload = try JSONSerialization.data(withJSONObject: ["sub": subject]).base64EncodedString()
   .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  return "header.\(payload).\(signature)"
 }
 let firstToken = try token("member", "old"), rotatedToken = try token("member", "new")
 let baseURL = URL(string: "https://server.example/family")!
 let baseScope = liveServerStorageScope(budgetID: "budget", serverURL: baseURL, token: firstToken)
 precondition(baseScope == liveServerStorageScope(budgetID: "budget", serverURL: URL(string: "https://SERVER.example:443/family/")!, token: rotatedToken))
 for address in ["https://server.example/friends", "http://server.example/family", "https://server.example:8443/family"] {
  precondition(baseScope != liveServerStorageScope(budgetID: "budget", serverURL: URL(string: address)!, token: firstToken))
 }
 precondition(baseScope != liveServerStorageScope(budgetID: "another", serverURL: baseURL, token: firstToken))
 let anotherUser = try token("another-member", "new")
 precondition(baseScope != liveServerStorageScope(budgetID: "budget", serverURL: baseURL, token: anotherUser))
 let probe = MonthProbe(), originalMonth = probe.planMonth, originalOperation = probe.snapshotOperationID
 probe.planMonth = Calendar.current.date(byAdding: .day, value: 1, to: originalMonth)!
 precondition(probe.summary != nil && probe.snapshotOperationID == originalOperation)
 probe.planMonth = Calendar.current.date(byAdding: .month, value: 1, to: originalMonth)!
 precondition(probe.summary == nil && probe.delegatedBudget == nil && probe.snapshotOperationID != originalOperation)
 let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-boundaries-\(UUID().uuidString)")
 defer { try? FileManager.default.removeItem(at: root) }
 let file = root.appendingPathComponent("cache.json"), snapshot = WorkspaceSnapshot()
 @MainActor func rejects(_ cache: LiveWorkspaceReadCache, month: String? = nil) {
  do { _ = try cache.load(planMonth: month); fatalError("Obsolete or wrong-month cache accepted: \(month ?? "unscoped")") }
  catch {}
 }
 let legacy = LiveWorkspaceReadCache(fileURL: file)
 try legacy.save(snapshot)
 let original = try legacy.load(); precondition(original.transactions == ["private"])
 let current = LiveWorkspaceReadCache(fileURL: file, accessRevision: "a"); rejects(current)
 try current.save(snapshot)
 let reopened = try LiveWorkspaceReadCache(fileURL: file, accessRevision: "a").load()
 precondition(reopened.transactions == ["private"])
 rejects(LiveWorkspaceReadCache(fileURL: file, accessRevision: "b"))
 current.updateAccessRevision("b"); rejects(current)
 try current.save(snapshot)
 let refreshed = try current.load(); precondition(refreshed.accessRevision == "b")
 try current.save(WorkspaceSnapshot(summary: "September"), planMonth: "2026-09-01")
 try current.save(WorkspaceSnapshot(summary: "October"), planMonth: "2026-10-01")
 let september = try current.load(planMonth: "2026-09-01")
 let october = try current.load(planMonth: "2026-10-01")
 precondition(september.summary == "September" && october.summary == "October")
 rejects(current, month: "2026-11-01")
 rejects(current, month: "../../private")
 do { try current.save(snapshot, planMonth: "2026-13-01"); fatalError("Invalid month accepted") } catch {}
 current.updateAccessRevision("c")
 rejects(current, month: "2026-09-01"); rejects(current, month: "2026-10-01")
 current.updateAccessRevision("b")
 current.remove()
 rejects(current); rejects(current, month: "2026-09-01"); rejects(current, month: "2026-10-01")
 print("PASS: immediate month-switch invalidation, scope/relaunch/legacy guards, independent month observations, missing/invalid months, scope eviction across months")
}
SWIFT
RUBY
