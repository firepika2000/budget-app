# Scheduled Transactions UI — Independent Review Checklist

For the reviewer (Claude) to run when Codex pushes the Scheduled Transactions SwiftUI checkpoint. Backend contract is locked (`docs/scheduled-transactions-api-contract.md`) and the client API surface landed in `afb211d` (`APIScheduledTransaction*` DTOs + `APIClient.scheduledTransactions / create / update / delete / realize`). The UI must build on that — not a second scheduler domain in Swift.

## How to review (Mac agent has Xcode; Windows reviewer is backend/source only)
- **Runtime/build items** (marked ⌘) require Xcode/Simulator — verifiable only on the Mac. The Windows reviewer verifies them by source trace + the backend contract and marks them "source-verified, runtime pending."
- Confirm the branch is synced and the Swift package + iOS targets build before functional review.

## Money-safety (highest priority — must hold)
- [ ] **Future income never spendable.** A scheduled inflow does not increase RTA, category Available, or any account actual balance before realization. It appears only in forecast/upcoming, visually distinct.
- [ ] **No pre-realization accounting mutation.** Creating/editing a schedule posts no allocation, moves no account balance, changes no category activity or credit reserve. (Backend proven by `test_scheduled_transactions_contract`; UI must not shadow-apply anything locally.)
- [ ] **Realization goes through the ordinary actual path exactly once** via `APIClient.realizeScheduledTransaction`; the resulting transaction uses the shared transaction detail/editor.
- [ ] **Duplicate realization is handled** — an "Enter Now" tapped twice (or on an advanced/again-not-due schedule) surfaces the server's `422`/`409` cleanly (via the structured-detail decoder), never a double post. No client-side optimistic realize.

## Behavior & correctness
- [ ] **Recurrence** exposes only backend-supported units: `once / days / weeks / months / years` + `interval_count`. No fake end-date/count, no per-occurrence skip, no background auto-posting.
- [ ] **Transfer schedule** realizes as a balanced pair (source ↓ / destination ↑), no income/spending, no category mutation.
- [ ] **Credit-card schedule** realizes through the existing reserve engine (funded → reserve; unfunded → debt); the UI does not reimplement reserve math.
- [ ] **Schedule advances / deactivates** after realization; `next_date` / `is_active` / `last_realized_on` reflect the realization response; the list refreshes.
- [ ] **Editor round-trips** all fields (account, destination, category, amount, memo, direction, recurrence, next date, active) with exact `Int64` currency (`CurrencyAmountField`).

## Authorization & scope
- [ ] Management (create/edit/delete) gated on `manage_planning`; realize gated on `create_transaction`; realize **re-checks scope at realization** (permission revoked after creation → blocked). UI hides guaranteed-403 actions.
- [ ] Restricted/delegated members see and act only within their permitted accounts/categories; no hidden-resource leakage in pickers or the list.

## State & parity
- [ ] **Actual-vs-forecast separation:** scheduled items appear in Home upcoming / forecast / (optionally) category context, but are **not** mixed into the actual transaction register/Activity as if posted.
- [ ] **Refresh after realization** propagates to Activity, account balances, Plan/category, Home, and forecast (single coherent `refresh()`); no stale local schedule shadow.
- [ ] **Demo/live parity:** the demo repository emits the same `APIScheduledTransaction` DTO shape and supports the same list/editor/realize screens (no demo-only scheduler view); deterministic demo schedule data. Add a `DemoStoreTests` parity test (runs in CI's swift job).

## Accessibility & build (⌘ runtime)
- [ ] ⌘ VoiceOver labels on list rows / Enter Now / editor controls; Dynamic Type; Hide Amounts respected.
- [ ] ⌘ `swift test` (BudgetCore + BudgetAPI, incl. the scheduled `APIClient` tests) green.
- [ ] ⌘ iOS unit tests (`DemoStoreTests`) green; generic Simulator build succeeds; deterministic demo walkthrough + authenticated live walkthrough.

## Verdict to return after Codex's push
`SCHEDULED UI REVIEW: PASS / PASS WITH FIXES / FAIL` — with money-safety items weighted highest. Do not pass on "screens exist"; require discover → use → save → reload → correct consequences. Report any finding that would require editing Codex-active SwiftUI files rather than editing them during the review.
