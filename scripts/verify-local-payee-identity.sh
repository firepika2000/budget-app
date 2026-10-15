#!/bin/bash
# Exercise the actual production resolver without starting or resetting Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ruby - <<'RUBY' | xcrun swift -
source = File.read("ios/BudgetApp/DemoModels.swift")
first = source.index("struct DemoPayee:")
last = source.index("struct DemoSchedule:", first || 0)
abort "Payee resolver boundaries changed" unless first && last
engine = File.read("ios/BudgetApp/DemoStore.swift")
abort "Transaction posting does not resolve canonical payees" unless engine.include?('LocalPayeeIdentity.resolve(id: operation.payeeID, name: operation.payeeName, in: payees)')
abort "Financial rollback does not preserve payee registry" unless engine.include?('payees = value.payees')
abort "Local projection loses explicit identity" unless engine.include?('payeeID: item.payeeID ?? payees.first')
abort "Local reopen loses explicit identity" unless engine.include?('transaction.payeeID = item.payeeID')
workspace = File.read("ios/BudgetApp/BudgetWorkspaceView.swift")
abort "Production browser loses explicit identity" unless workspace.include?('let resolvedPayeeID = item.payeeID ??')
abort "System reversals create merchant identities" unless workspace.include?('id: reversalID, resolvesPayee: false')
puts "import Foundation"
puts source[first...last]
puts <<'SWIFT'
let existing = DemoPayee(id: "stable", name: "Coffee Shop", aliases: ["BANK COFFEE"])
let resolved = try LocalPayeeIdentity.resolve(id: nil, name: "  bank\tcoffee  ", in: [existing])
precondition(resolved?.id == "stable" && resolved?.name == "Coffee Shop")
let byID = try LocalPayeeIdentity.resolve(id: "stable", name: "ignored", in: [existing])
precondition(byID?.id == "stable")
precondition(LocalPayeeIdentity.displayName(" Ｃａｆｅ\n Merchant ") == "Cafe Merchant")
precondition(LocalPayeeIdentity.key("Straße") == "strasse")
precondition(LocalPayeeIdentity.key("CAFÉ") == LocalPayeeIdentity.key("café"))
precondition(LocalPayeeIdentity.key("Cafe") != LocalPayeeIdentity.key("Café"))
let punctuation = try LocalPayeeIdentity.resolve(id: nil, name: "A-B", in: [])!
let letters = try LocalPayeeIdentity.resolve(id: nil, name: "AB", in: [punctuation])!
precondition(punctuation.id != letters.id)
let blank = try LocalPayeeIdentity.resolve(id: nil, name: "\n\t", in: [])
precondition(blank == nil)
let planned = try LocalPayeeIdentity.resolve(id: nil, name: "Future merchant", in: [], create: false)
precondition(planned == nil)
let plannedAlias = try LocalPayeeIdentity.resolve(id: nil, name: "bank coffee", in: [existing], create: false)
precondition(plannedAlias?.id == "stable")
for invalid in [DemoPayee(id: "old", name: "Old Merchant", isArchived: true),
                DemoPayee(id: "merged", name: "Old Merchant", mergedIntoPayeeID: "stable")] {
    do { _ = try LocalPayeeIdentity.resolve(id: nil, name: "old merchant", in: [invalid]); fatalError("Unavailable payee resurrected") }
    catch LocalPayeeIdentity.ResolutionError.unavailable { }
}
do { _ = try LocalPayeeIdentity.resolve(id: "missing", name: "Coffee Shop", in: [existing]); fatalError("Unknown identity accepted") }
catch LocalPayeeIdentity.ResolutionError.invalid { }
print("PASS: production payee resolver identity, aliases, normalization, accent distinction, punctuation, blank names, archive/merge and invalid identity")
SWIFT
RUBY
