# Independent Product / UX / Financial-Domain Review — pre-v0.4.0

Reviewer role: independent senior product, UX, and financial-domain reviewer.
Scope: current `main` (`87517c1`, v0.3.0 tagged). Bank sync explicitly out of scope and not evaluated.
Method: hands-on code inspection of the live SwiftUI client, the DEBUG demo client, the FastAPI/PostgreSQL server (authorization, allocation ledger, credit engine, requests), and existing `docs/`. The iOS app cannot be built on this Windows host, so behavior is inferred from source with the same rigor as a runtime pass; where I could not execute a flow I say so.

---

## EXECUTIVE SUMMARY

The v0.2.0 **financial core is genuinely trustworthy**: exact integer money (`Money.swift`), a balanced append-only allocation ledger with optimistic versioning, a careful credit-card reserve engine, and deny-by-default resource-scoped authorization. That foundation should be protected, not rewritten.

The v0.3.0 "native product experience," however, is **two disconnected apps wearing one name**:

1. A **polished but fictional demo** (`DemoRootView` + `Demo*` files) that the app shows *by default in DEBUG* and that every screenshot/simulator artifact is captured from. Its numbers are hard-coded seed arrays; its Insights, forecast, persona switching, Smart Funding, and household screens are mockups that do not read or write the server.
2. A **thin live product** (`RootView → BudgetListView → BudgetDetailView`) reachable only with the `--live` launch argument. It can create budgets, accounts, categories, transactions, assignments, moves, and requests — but has **no Insights, no reporting, no forecast, no transaction editing, no reconciliation UI, no request approval UI, no targets/credit/allowance management, and no persona switching.**

The most important consequence for a stabilization milestone: **the experience being demoed is not the experience that ships, and several core workflows the milestone implies (edit a transaction, drill an Insight, approve a delegated request, enforce a child's spending ceiling) do not exist in the live product — and in some cases cannot exist without schema/authorization changes.**

The single most consequential domain finding: **the delegated-budget model the product is built around is not representable in the backend.** There is no per-member spending ceiling, minimum-savings, max-category, locked-savings, or approval-gated field anywhere. A delegated member with `assign_money` can draw from the *entire household* Ready-to-Assign pool with no cap.

Rank of what to fix first: (1) decide and enforce the delegated boundary in the data model; (2) wire request **approval** and transaction **editing** into the live client; (3) make Insights read real data with working controls and transaction drill-down; (4) close the reconciliation "mint money" gap; (5) resolve the demo-vs-live identity so hands-on testing tests the real product.

---

## P0 DEFECTS (broken / core correctness)

### P0-1 — The shipped app defaults to the in-memory demo, not the product
- **Observed:** `RootView` renders `DemoRootView()` whenever `#if DEBUG` is set and `--live` is *absent* (`ios/BudgetApp/RootView.swift:26-35`). All screenshots (`docs/screenshots/v0.3.0/*`) and the simulator demo are this path. The demo is `@StateObject DemoStore`, seeded from static arrays, resets on relaunch, and never contacts the server.
- **Expected:** Hands-on testing and review artifacts should exercise the product that ships to users. A demo is fine, but it must be clearly a *sample data* mode layered on the real engine, not a parallel fake.
- **Root cause:** The v0.3.0 experience was built as a presentation prototype (`DemoStore`) rather than as views over `APIClient`. `docs/feature-parity.md` candidly marks much of it "PLANNED FOR v0.3.0 … not yet wired to every live endpoint."
- **Files:** `ios/BudgetApp/RootView.swift`, all `ios/BudgetApp/Demo*.swift`.
- **Fix direction:** Treat the demo as *seed data injected into the real view layer* (a `PreviewStore`/sample-server), or gate it behind an explicit "Explore sample household" entry rather than making it the default. Ensure every reviewed screen has a live counterpart before the milestone claims it.

### P0-2 — Transactions cannot be edited or corrected anywhere
- **Observed:** `TransactionEntryView` (`ios/BudgetApp/EditingViews.swift:349`) is create-only. In `BudgetDetailView` the recent-transactions rows are plain `HStack`s with no tap target (`BudgetDetailView.swift:216-230`). The demo `TransactionRow` likewise does not open an editor. `feature-parity.md` lists "Edit and delete/void" as **FUTURE**.
- **Expected:** The Insights workflow in the brief requires: tap a transaction → edit/correct it → return → see corrected analytics. None of that is possible.
- **Root cause:** No `PATCH /transactions/{id}` client call and no edit view; server also appears to lack an edit/void endpoint (append-only design never got its reversal workflow).
- **Files:** `ios/BudgetApp/EditingViews.swift`, `server/app/budgeting_routes.py`.
- **Fix direction:** Add an append-only *void + re-enter* or a corrective-edit endpoint (preserving ledger auditability), then a tappable transaction detail/edit sheet. This unblocks the entire "correct a number and watch it flow through" story.

### P0-3 — Parents cannot approve requests in the live product
- **Observed:** The live `requestsSection` only *displays* requests and their status (`BudgetDetailView.swift:192-214`); there is no approve/reject/partial control, and the client never calls the existing `POST /requests/{id}/decision` endpoint (`server/app/request_routes.py:991`). Approval exists only as a demo mockup (`RequestApprovalView` + `DemoStore.approve`).
- **Expected:** The delegated model's core loop is *child requests → parent approves*. The server supports it; the live app dead-ends at "view."
- **Root cause:** Approval UI was built in the demo layer only.
- **Files:** `ios/BudgetApp/BudgetDetailView.swift`, `Sources/BudgetAPI/APIClient.swift` (needs a `decideRequest`), server endpoint already present.
- **Fix direction:** Add the decision call to `APIClient`, a partial-approval sheet with source-category picker (mirroring the server's `source_category_id` requirement), and wire it behind `approve_request`.

### P0-4 — The delegated spending boundary ($200 model) is not representable or enforced
- **Observed:** `BudgetAccessProfile` has only `restrict_accounts` and `restrict_categories` booleans (`server/app/models.py:116-127`). There is **no** ceiling, minimum-savings, max-per-category, locked, or approval-gated field in the schema. `upsert_assignment` gates on the `assign_money` capability and category visibility, then checks `ready_to_assign_balance(db, budget_id)` — the **whole household's** unassigned cash — not a per-delegate allotment (`budgeting_routes.py:382-414`). A delegated member granted `assign_money` can assign unlimited household money into their own categories.
- **Expected (from brief):** Parent grants Alex a $200 boundary. Alex organizes/moves money *within* $200 but can never increase his total authority beyond it; parent can impose hard totals, minimum savings, max category limits, approval-gated categories, and locked savings.
- **Root cause:** Delegation was modeled as *visibility scoping* (which categories you can see), never as *a bounded sub-budget with its own conserved total*.
- **Files:** `server/app/models.py`, `server/app/access.py`, `server/app/budgeting_routes.py`.
- **Fix direction:** Introduce a delegated-envelope concept: either (a) a per-member ceiling enforced on every assign/move so the sum of the member's category balances cannot exceed their grant, or (b) model the delegate's space as its own conserved pool the parent funds, where the delegate has `move_money` *only* within it (no `assign_money` against household RTA). Add optional `minimum_savings`, `max_category`, `locked`, and `approval_required` flags. Until then, **do not grant delegates `assign_money`** — document that the only safe current config is parent-funded categories + `move_money`, and even that lacks locked-savings protection.

### P0-5 — Insights range controls do nothing and headline numbers are hard-coded and mutually inconsistent
- **Observed:** `InsightsView` range picker offers only `3M/6M/12M`, and the selected `range` is **never read** by any child view (`DemoInsightsViews.swift:8-...`). Detail screens use fixed six-element seed arrays regardless. Income appears as three different figures depending on screen: `IncomeSpendingView` computes a six-month average from `incomeHistory` (~$7,400), `ForecastView` states "Expected income $7,500.00" (hard-coded `750000`), and `PlanCostView` states "Expected income $7,250.00" (hard-coded `725000`). `HouseholdInsightView` spending/allowance/request figures are literals unrelated to `store.transactions`/`requests`/`allowances`.
- **Expected (from brief):** 30/60/90-day, 3/6-month, YTD, 1-year, and custom ranges; every reported number explainable from underlying transactions.
- **Root cause:** Insights is a static visual mock.
- **Files:** `ios/BudgetApp/DemoInsightsViews.swift`, `ios/BudgetApp/DemoStore.swift`.
- **Fix direction:** Drive all Insights aggregates from the transaction/allocation store, make the range control actually filter, add the missing ranges (30/60/90-day, YTD, custom), and reconcile the single income concept across screens.

---

## P1 PRODUCT GAPS (major missing capability)

- **P1-1 No Insights drill-down to contributing transactions.** `SpendingInsightView` groups by category *group* but the rows are `LabeledContent` with no navigation; the pie, income/spending bars, and net-worth line are not tappable. The required chain report → group → category → payee/member → contributing transactions → tap → edit does not exist. (`DemoInsightsViews.swift`.)
- **P1-2 No Insights filtering by dimension.** No payee/member/account/group filter on any report.
- **P1-3 Reconciliation adjustments are unbounded and inflate Ready-to-Assign.** `reconcile_account` will create an adjustment transaction of *any* size (`statement_balance_minor − cleared`) with `category_id = None` on an on-budget cash account, which flows straight into `unassigned_cash_balance` → Ready-to-Assign (`budgeting_routes.py:685-743`, `allocation.py:unassigned_cash_balance`). A member with `reconcile_account` can effectively mint household money. Expected: reconciliation should surface a discrepancy for review, and any created adjustment should be bounded/audited and ideally not silently increase assignable cash. See also SECURITY.
- **P1-4 Delegates cannot create/organize their own categories within their sandbox.** Category creation requires `manage_budget_structure` (`budgeting_routes.py:314-337`), a broad capability granting structural control over the *entire* budget; and a newly created category is not auto-added to the delegate's `ResourceGrant` scope, so under restriction they couldn't even see it. The brief's "Alex creates Games/Food/Bike Savings within his $200" is unsupported without over-privileging him.
- **P1-5 Restricted-delegate assignment inconsistency.** `month_summary` forces `ready_to_assign_minor = 0` for a resource-restricted user (`budgeting_routes.py:865-867`), so the UI tells a delegate they have $0 to assign, yet `upsert_assignment` still evaluates the real household pool. The guardrail is cosmetic, not enforced.
- **P1-6 The live product is a thin CRUD shell.** Missing live: Insights/reports, forecast, target creation/editing, credit-card payment & reserve views, reconciliation, allowance issuance, category reorder/hide, persona/household switching, move-for-delegate. All exist only as demo mockups. For a "stabilization" milestone this is the bulk of the perceived product.
- **P1-7 No first-class payees, no scheduled-transaction materialization UI, no live net worth.** Consistent with `feature-parity.md`, but they gate real daily use.

---

## P2 UX / VISUAL ISSUES

- **P2-1 Decorative, non-real Home forecast.** `HomeView.forecastCard` shows a fixed "Projected low point $5,234.00 · No shortfall expected" regardless of data (`DemoRootView.swift:631-640`). A financial app showing an invented safety signal is a trust hazard.
- **P2-2 Cross-screen number inconsistency** (see P0-5) reads as a bug to any attentive user; premium financial software must reconcile.
- **P2-3 Quick-add is outflow-only in the demo.** `DemoStore.addTransaction` always stores `-abs(amount)` (`DemoStore.swift:84-100`); there is no inflow/income path in the fast entry sheet, and the account balance is always debited.
- **P2-4 Silent no-op on invalid money moves.** `DemoStore.move`/`assign`/`approve` simply `return` when a guard fails (insufficient funds, bad category) with no user feedback; the confirmation sheet dismisses as if it succeeded.
- **P2-5 Currency formatting via `Double` division** in the live client (`BudgetDetailView.format`, `CurrencyText.editable`) reintroduces floating point for display; fine for typical values but inconsistent with the exact-integer discipline and lossy at large magnitudes. Also `NumberFormatter.currencyCode` set without a matching locale can mis-place symbols for some currencies.
- **P2-6 Debt payoff sentinel leaks.** `DebtPayoffView` uses `months = 999` when payment ≤ interest and would display "Projected payments 999"/a 999-month date instead of a "payment too low" message (`DemoInsightsViews.swift`).
- **P2-7 Home toolbar crowding.** Two `.topBarTrailing` items plus the hide-amounts eye can crowd on smaller devices; consider grouping.
- **P2-8 Plan grouping order is alphabetical** (`Dictionary(grouping:).keys.sorted()`), ignoring any intended group sort order, so "Housing/Food/Goals" ordering is not authorable.

---

## P3 FUTURE IDEAS

- YTD and custom date ranges; persisted custom/focused views (currently ephemeral demo filters).
- Calculator keypad for amount entry; duplicate detection ahead of any future import.
- Real attachment storage (currently a picker with no backing store).
- Widgets, receipt OCR, Reduce-Motion-aware reserve animations.
- Learned payee/category suggestions (explicitly deferred, "2 of last 3" idea).
- Per-point audio/table alternatives for charts (see accessibility).

---

## YNAB CAPABILITY GAPS (benchmark only — no branding/UI copying implied)

Meaningful gaps beyond what `feature-parity.md` already lists, ranked:

- **P0-ish for parity:** transaction **edit/void** (missing), request **approval in-product** (missing), category **drill-down from reports** (missing).
- **P1:** first-class **payees** (rename/merge/remembered) — no payee table; **scheduled-transaction** materialization into real transactions; **auto-assign / smart funding** as a real bulk-ledger operation (currently a preview that loops single assigns); **net worth** from live accounts; **income vs spending** and **spending trends** from live data; **future-month budgeting** UI (server supports month-addressed ledger; live client only shows the current month, computed as "today" in `BudgetDetailView.currentMonth`).
- **P2:** flags/tags persistence; refill/"up-to" target behavior; weekly/custom target cadence; snooze/skip targets; reconciliation lock semantics; credit-card *payment* creation from the card screen.
- **P3:** import pipeline, duplicate matching, calculator keypad, attachments.

Where Budget App *exceeds* the benchmark (keep): resource-scoped visibility, independently granted capabilities, child/teen presentation that removes rather than disables, first-class requests with partial approval + action history + source redaction, recurring allowance splits, self-hosting with audit export.

---

## INSIGHTS FINDINGS

- Time ranges: only 3M/6M/12M offered, and **the control is inert**. Missing 30/60/90-day, YTD, 1-year (Forecast has its own 30d–1y horizon but scales only two hard-coded points), and custom.
- Filtering: none.
- Drill-down: only Goals → `CategoryDetailView`. Spending, Income vs Spending, Net Worth, Household are terminal.
- Contributing transactions / tap / edit / return / reflect: **not possible** (no drill + no edit + static aggregates). Adding a transaction updates `accounts`/category `activity` but **not** `incomeHistory`/`spendingHistory`/`netWorthHistory`, so charts never move.
- Explainability: fails. `SpendingInsightView` sums **current-month** `activity` per group but is presented under a 3M/6M/12M frame; other figures are literals; income differs by screen (P0-5).
- Stale/disconnected aggregates: confirmed — the three history arrays are seed constants decoupled from all mutations (`DemoStore.swift:16-18`).

## DELEGATED-BUDGET FINDINGS

- Intended model (bounded sub-budget the delegate controls internally) is **not** in the architecture. Delegation = category visibility scoping only (`BudgetAccessProfile.restrict_categories` + `ResourceGrant`, `Category.delegated_user_id`).
- No hard total limit, minimum savings, max category, approval-gated category, or locked savings fields exist (`models.py`). None can be enforced today.
- Autonomy is inverted vs the brief: in the *demo*, the child persona is **view + request only** — PlanView hides Smart Fund/Move and the goal "+" for children (`DemoRootView.swift:685-712`), and `GoalCreationView` is unreachable for a child. So "Alex moves money between his own categories without approval" is demonstrated *nowhere*.
- In the *live* product, giving a delegate real autonomy requires `move_money` (works, scoped to both endpoints — good) and, for creating categories, `manage_budget_structure` (over-privileged, see P1-4). `assign_money` for a delegate is actively unsafe (P0-4).
- Approval loop is server-complete but client-incomplete (P0-3).

## SECURITY / PERMISSION FINDINGS

- **Strong foundations (keep):** deny-by-default `visible_budgets_query`; owner check; per-resource `can_access_resource` enforced on assign/move/transaction/transfer/reconcile/request; request `source_category_id` redacted from non-approvers (`request_routes.serialize_request`); optimistic `allocation_version`/request `version` guards; login throttling + Argon2 + rotating refresh (per changelog).
- **Hole 1 — reconciliation mint (P1-3):** unbounded adjustment increases assignable household cash; scope it, cap it, or route it through an explicit "found money → income" step rather than silent RTA inflation.
- **Hole 2 — no delegated ceiling (P0-4):** a scoped member with `assign_money` reaches the whole household pool.
- **Minor — self-transfer:** `create_transfer` does not reject `source_account_id == destination_account_id` (`budgeting_routes.py:609-682`); a same-account transfer creates an offsetting pair (and, for a credit account, paired reserve events). Low impact but should 422.
- **Minor — inconsistent guard (P1-5):** UI-only RTA=0 for restricted users is not matched by server enforcement.

## STATE-MANAGEMENT FINDINGS

- Demo Insights aggregates are static seeds disconnected from mutations → no reflect-after-edit (root of the Insights complaints).
- Live `BudgetDetailView.load()` re-fetches the entire budget after each mutation — correct but heavy; fine for now, revisit for large budgets.
- `AppSession`: `createBudget` refreshes `budgets` but not `profile`; budget list otherwise refreshes only on `scenePhase == .active` or manual pull. A newly granted/revoked budget won't appear/disappear until one of those. Deactivated members are correctly blocked server-side (`membership.is_active`).
- Optimistic concurrency is handled well (allocation + request versions with 409s and a "refresh and try again" payload).

## VISUAL / UX FINDINGS

- Aesthetic in the demo is close to the "premium native Apple financial software" target: rounded numerals, grouped backgrounds, restrained accent palette (`Theme`), SF Symbols, dark mode. Good.
- Undercut by: invented forecast numbers (P2-1), cross-screen inconsistency (P2-2), silent no-ops (P2-4), and the fact that none of it is real (P0-1). Premium software's credibility is precisely that the numbers are trustworthy and consistent — the current gap between polish and truth is the biggest brand risk.
- Live product visual density is far below the demo (plain `List` sections); a reviewer comparing screenshots to the shipped `--live` app would see two different products.

## ACCESSIBILITY FINDINGS

- Present and commendable: VoiceOver labels on profile/amount/eye controls, `hideAmounts` announces "Amount hidden," `accessibilityElement(children: .combine)` on rows, Dynamic Type via native controls, non-color status via `StatusLabel` icon+text, chart `accessibilityLabel`s including hidden-amount variants.
- Gaps: charts expose a single summary label but **no per-point data table / audiograph**, so blind users get "net worth increased" but no values; `SpendingInsightView` hides the legend (`chartLegend(.hidden)`) leaving group→color mapping color-only for low-vision sighted users; the **non-functional range/segmented controls** actively mislead AT users (they announce options that change nothing); very dense composed rows in `DemoInsightsViews` are runtime-fine but should be spot-checked at AX5 text sizes; no VoiceOver hint that "Available to assign" is actionable.
- No formal assistive-technology audit has been done (self-reported).

---

## RECOMMENDED FIX ORDER

1. **Decide the delegated-budget architecture** (P0-4) — this shapes schema, authorization, and every delegate UI. Add ceiling/min-savings/locked/approval-gated fields and enforce on assign/move. Until shipped, document the only safe config.
2. **Close the reconciliation mint hole** (P1-3) — small change, real integrity risk.
3. **Wire request approval into the live client** (P0-3) — server already supports it; unblocks the delegated loop.
4. **Add transaction edit/void** (P0-2, server + client) — unblocks the "correct a number" story end-to-end.
5. **Make Insights real** (P0-5, P1-1, P1-2): live aggregates, working ranges (+30/60/90/YTD/custom), and transaction drill-down; reconcile the single income figure.
6. **Resolve demo-vs-live identity** (P0-1): reframe the demo as sample data over the real views, or gate it explicitly, so hands-on testing tests the product.
7. Then P2 polish (forecast honesty, inflow entry, error feedback, formatting).

---

## AREAS THE PRIMARY AGENT SHOULD NOT REWRITE

These are correct and load-bearing; changes risk regressions and should be additive only:

- `Sources/BudgetCore/Money.swift` — exact integer money with overflow-checked arithmetic.
- `server/app/allocation.py` — the balanced append-only ledger, `append_operation` zero-sum invariant, and `require_version` optimistic concurrency.
- `server/app/credit.py` — the credit-card reserve engine (funded/refund/payment attribution is subtle and well-reasoned).
- `server/app/request_routes.py` — request state machine, version guards, and source redaction.
- `server/app/access.py` — deny-by-default visibility and `can_access_resource` scoping (extend with a ceiling; do not loosen).
- CSV formula-injection guard (`safe_csv_text`) and the audit/export scoping.

Build the delegated ceiling, approval UI, edit/void, and Insights **on top of** these rather than through them.

---

*Prepared as an independent cross-check against the primary development agent's v0.4.0 work. Findings are code-grounded; items I could not execute at runtime (native build unavailable on this host) are flagged as inferred from source.*
