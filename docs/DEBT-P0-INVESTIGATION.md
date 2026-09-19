# Debt / Insights P0 — open investigation

Human report: repeated SwiftUI PlatformAlertController presentation conflicts in Live Debt,
successful summary/debt/projection API responses, eventual debugger code 9. Human failure is
authoritative; neither passing automated tests nor successful HTTP responses close this issue.

Starting HEAD: `d3f405d499ba5d190799d41576cd9b9f111425ce`. Feature expansion STOPPED.

## Reproduction evidence so far

- Xcode Beta `/Users/firepika/Downloads/Xcode-beta.app/Contents/Developer`, 27.0 / 27A5252f.
- Existing iPhone 17 Pro Max, iOS 27, `3ABD861E-D38D-4AFD-A356-959266051564`.
- Existing production Demo payoff scenario XCUITest PASS (`/tmp/budget-debt-p0-before.log`).
- Added DEBUG-only store-level `--ui-test-debt-projection-failure` and production-composition
  `testDebtProjectionFailureDismissalDoesNotImmediatelyRepresent`: PASS. Single alert, dismiss,
  navigate Overview, no immediate repeated alert (`/tmp/budget-debt-p0-error-before.log`).
- These are Demo-data production views, NOT a reproduction of the human Live session.
- Simulator unified-log query did not capture the reported alert or chart warning during these
  runs (`/tmp/budget-debt-p0-runtime.log`). Absence in this capture is not proof of absence generally.
- No reset, Live migration or human data modification. No P0 correction claimed.

## Source trace / presentation owners

| Owner | Trigger | Presentation / consumption |
|---|---|---|
| RootView | `session.errorMessage` | Something went wrong alert; binding clears on dismissal |
| BudgetWorkspaceView | `store.errorMessage`, unless access denied | Unable to complete request; retry reloads workspace; dismissal clears |
| DebtInterestDestinationView | `editingTermsAccount` | Shared Debt Terms sheet; dismissal increments terms revision |
| DebtPayoffContent | local `errorMessage` from calculate catch | Unable to calculate payoff alert attached to final Section; dismissal clears |
| DebtCurrentCostContent | local load error | Inline error/retry section, not an alert |
| ReportLoadModifier | `store.reportErrors[kind]` | Inline unavailable/retry overlay, not an alert |
| DebtTermsEditorView | local save error | Unable to update debt terms alert within editor |
| Insights hub / spending export | local export error | Export alert; separate operation from debt projection |

Potential parent/child competition exists in the graph. It has not yet been reproduced or proven
to cause the reported loop. Inspect simultaneous failures and Live lifecycle transitions next.

## Request/task findings

`AppSession.refreshIfNeeded` logs `refresh requested` BEFORE eligibility/expiry guards. Every
credential lookup can emit it without an auth-refresh POST or workspace hydration. Do not count
these lines as actual workspace refreshes. Instrument/check actual calls independently.

Payoff `calculate` intentionally starts two requests: selected scenario plus avalanche/no-rollover/
zero-extra baseline. Two successful POSTs alone are expected, not proof of duplication.

Scenario task key includes strategy, rollover, amount, custom order, account filter, terms revision,
report revision and credential revision. Initial onAppear fills custom order, changing the key.
Current task uses a 180 ms debounce. Success checks Task.isCancelled; generic error catch does not.
An obsolete network cancellation/error may therefore assign error state; this is a concrete review
target but NOT yet established as the human loop. Loading-state defers can also overlap between
cancelled/replacement operations. Do not add arbitrary presentation delays as a fix.

## Charts and termination

Production chart axes are centralized in CurrencyChartAxis and ReportDateChartAxis in
BudgetWorkspaceView. Source search found no explicit custom UnitPoint axis anchors. Defaults or
framework-derived anchors require runtime tracing; exact warning source remains unproven.

Code 9 cause is UNPROVEN. No OOM, memory runaway, CPU runaway or external termination diagnosis
has been established. Resource sampling and crash/termination evidence remain required.

## Required next work / release block

1. Disposable Live-shaped reproduction with lifecycle/credential/report failures, actual request
   counters, stable presentation identifiers, and memory/CPU sampling.
2. Prove first error and repeat trigger, then correct presentation ownership/task generation.
3. Assert bounded refresh/projection calls, latest-response ownership and failure dismissal.
4. Reproduce/resolve actionable chart warning; inspect all Insights charts.
5. Full native XCTest + production XCUITest, Core/API, Beta build/runtime logs/diff check.
6. Complete HUMAN-VISIBLE-PRODUCT-AUDIT and address discovered P0/P1 before feature expansion.

No human acceptance, crash fix, alert-loop fix, or release readiness claimed.
