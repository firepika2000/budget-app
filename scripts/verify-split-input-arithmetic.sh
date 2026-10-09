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
abort "Transaction editor loses exact signed magnitude" unless workspace.include?('CurrencyText.editableMagnitude(transaction.amountMinor,') && workspace.include?('CurrencyText.parseMagnitude(amount,currencyCode:budget.currencyCode,isInflow:isInflow)')
abort "Schedule editor loses exact signed magnitude" unless workspace.include?('CurrencyText.editableMagnitude(schedule?.amountMinor ?? 0,') && workspace.include?('isInflow: kind != .expense), value != 0') && workspace.include?('amountMinor: parsed ?? 0, nextDate:')
abort "Unchecked monetary abs remains" if workspace.match?(/abs\((?:transaction|schedule|category|row|report|change|interestDifference|\$[01]\.availableMinor)/)
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
for currency in ["USD", "JPY", "KWD"] {
    let minimum = CurrencyText.editableMagnitude(.min, currencyCode: currency)
    precondition(CurrencyText.parseMagnitude(minimum, currencyCode: currency, isInflow: false) == .min)
    precondition(CurrencyText.parseMagnitude(minimum, currencyCode: currency, isInflow: true) == nil)
    let maximum = CurrencyText.editableMagnitude(.max, currencyCode: currency)
    precondition(CurrencyText.parseMagnitude(maximum, currencyCode: currency, isInflow: true) == .max)
}
precondition(CurrencyText.parseMagnitude("-1", currencyCode: "USD", isInflow: false) == nil)
precondition(CurrencyText.parseMagnitude("0", currencyCode: "USD", isInflow: false) == 0)
precondition(CurrencyText.parseMagnitude("1.001", currencyCode: "USD", isInflow: false) == nil)
precondition(CurrencyText.parseMagnitude("2 + 3", currencyCode: "USD", isInflow: false) == -500)
precondition(CurrencyText.displayMagnitude(.min, currencyCode: "USD", locale: Locale(identifier: "en_US")) == "$92,233,720,368,547,758.08")
print("PASS: exact signed bounds in USD/JPY/KWD, magnitude formatting, invalid precision/sign, expression parsing, split overflow; production creation/edit/schedule wiring")
SWIFT
RUBY
