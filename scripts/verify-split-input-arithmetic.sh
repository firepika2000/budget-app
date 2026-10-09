#!/bin/bash
# Execute actual currency arithmetic without launching or resetting Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ruby - <<'RUBY' | xcrun swift -
source = File.read("ios/BudgetApp/EditingViews.swift")
first = source.index("enum CurrencyText {")
last = source.index("struct CurrencyAmountField:", first || 0)
abort "Currency parser boundaries changed" unless first && last
puts "import Foundation"
puts source[first...last]
workspace = File.read("ios/BudgetApp/BudgetWorkspaceView.swift")
abort "Creation does not use checked sum" unless source.include?('CurrencyText.checkedSum(parsedSplits.map(\.amountMinor)) == parsedAmount')
abort "Creation does not use checked remainder" unless source.include?('CurrencyText.remaining(total: parsedAmount, portions: parsedSplits.map(\.amountMinor))')
abort "Edit does not use checked remainder" unless workspace.include?('CurrencyText.remaining(total:parsed,portions:parsedSplits.map(\.amountMinor))')
puts <<'SWIFT'
precondition(CurrencyText.checkedSum([-600, -400]) == -1000)
precondition(CurrencyText.remaining(total: -1000, portions: [-600, -400]) == 0)
precondition(CurrencyText.remaining(total: -1000, portions: [-600]) == -400)
precondition(CurrencyText.checkedSum([.min]) == .min)
precondition(CurrencyText.checkedSum([.max, 1]) == nil)
precondition(CurrencyText.checkedSum([-.max, -.max]) == nil)
precondition(CurrencyText.remaining(total: .max, portions: [-1]) == nil)
precondition(CurrencyText.remaining(total: -.max, portions: [-.max, -.max]) == nil)
precondition(CurrencyText.remaining(total: -9_007_199_254_740_993, portions: [-9_007_199_254_740_000, -993]) == 0)
print("PASS: valid splits, exact large money, sum overflow and remainder overflow; creation/edit checked-arithmetic wiring")
SWIFT
RUBY
