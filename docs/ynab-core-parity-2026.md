# YNAB Core Behavioral Parity Matrix — 2026

**Reviewer:** independent architecture/product reviewer (Claude)
**Branch under review:** `codex/v0.4.0-stabilization` @ `43a5212`
**Purpose:** Behavioral capability parity as a **minimum baseline**, then exceed it with our household/delegation/forecasting/analytics system. This is **not** a request to copy YNAB branding, wording, visual design, trademarks, illustrations, or proprietary presentation.

## What "IMPLEMENTED" means here
A capability is **IMPLEMENTED** only if a normal production (live, authenticated) user can: (1) discover it, (2) use it, (3) persist it, (4) reload it, (5) see consequences propagate correctly, and (6) use it in both demo and live architecture where applicable. A backend model or endpoint alone is **PARTIAL** at best.

## Status legend
`IMPLEMENTED` · `PARTIAL` · `MISSING` · `REGRESSED` (source/history proves it previously worked) · `DEFERRED` (intentionally blocked) · `BETTER` (exceeds baseline).

## Severity
- **P0** — financial corruption, money creation/destruction, security/authorization/privacy integrity.
- **P1** — missing/broken core budgeting workflow needed for a viable product.
- **P2** — important completeness/usability capability.
- **P3** — polish/convenience.

## Source-quality caveat
YNAB behavior summaries are grounded in current first-party documentation (see references) and my knowledge of YNAB's public documentation as of early 2026. Naming confirmed against [ynab.com/features](https://www.ynab.com/features) and the [YNAB reports guide](https://www.ynab.com/blog/ynab-reports-and-data) / support center: reports live under **Reflect** — **Spending** (Totals donut + Trends bar/trendline), **Income v Expense** (web) / **Income vs. Spending** (mobile), **Net Worth**, **Age of Money**, plus **The Inspector** detail panel; funding is **Targets** + **Auto-Assign**; sharing is **YNAB Together** (up to 6). Items I could not re-confirm against a live page are marked *(unverified)*. Our-app columns are grounded in the actual code at `43a5212`.

---

## 1. Plan / Budgeting & Ready-to-Assign

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Ready-to-Assign / money available | Single pool of real, unassigned on-budget cash; only real money can be assigned | features | `ready_to_assign_balance` (on-budget cash + RTA postings) | Plan header + Home | Both | `test_advanced_ledger`, `test_allocation_ledger` | IMPLEMENTED | — | — | RTA shown on Plan/Home; equals cash − assigned; future income excluded |
| Assign money to category | Move RTA into a category for the month | features | `PUT /categories/{id}/assignment` | Plan tap → editor | Both | yes | IMPLEMENTED | — | — | Assigning reduces RTA, raises Available; persists+reloads |
| Only real money assignable | Cannot assign more than RTA | — | 409 "Not enough real money" | error surfaced | live | yes | IMPLEMENTED · **BETTER** | — | — | Over-assign blocked server-side |
| Future income never spendable now | Scheduled/future inflow not in RTA | method | RTA excludes future; planning layer separate | forecast only | live | `test_planning` | IMPLEMENTED | — | — | Future inflow shows in forecast, not RTA |

## 2. Category groups & Category CRUD

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Category groups | Group categories | features | `category-groups` CRUD (create) | create-on-new-category | Both | yes | PARTIAL | P2 | No rename/reorder/delete group in UI | Owner can create/rename/reorder/delete groups |
| Create category | Add category to a group | features | `POST /categories` | Plan → Add category | Both | yes | IMPLEMENTED | — | — | New category appears, persists |
| Rename category | Edit name | features | `PUT /categories/{id}` | Manage Category sheet | Both | yes | IMPLEMENTED | — | — | Rename persists+reloads |
| Reorder categories/groups | Drag to reorder | features | `sort_order` field | **no UI** | — | — | MISSING | P2 | Add drag-reorder writing `sort_order` | Reorder persists and reflects in Plan order |
| Hide/archive/unhide | Hide inactive categories, historical reports retain them | features | `is_archived` | Manage Category → Archived toggle | Both | yes | IMPLEMENTED | — | — | Archive hides from new spend/assign; unarchive restores |

## 3. Month navigation, rollover, overspending, money moves

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Month navigation | Move between months; future-month budgeting | features | month-addressed ledger; `GET /months/{m}` | Plan ‹ month › stepper | live | yes | IMPLEMENTED | — | — | Prev/next month loads that month's plan |
| Rollover | Positive Available carries to next month | method | `carried_available_minor` in summary | shown as Available | live | `test_advanced_ledger` | IMPLEMENTED | — | — | Prior-month leftover carries forward |
| Overspending (cash) | Cash overspend reduces next month RTA | method | negative available surfaced; `total_overspent` | Home "overspent", red Available | Both | yes | IMPLEMENTED | — | — | Overspent category flagged; math correct |
| Move money between categories | Reallocate Available; conserves total | features | `POST /allocation-transfers` (zero-sum, versioned) | Plan → Move money | Both | yes | IMPLEMENTED · **BETTER** (append-only, optimistic version) | — | — | Move updates both categories; no account effect |
| Money-move history | See recent moves | method | `GET /allocations` (append-only ledger) | **no UI** | — | — | MISSING | P2 | Add allocation-history view | User can view/audit past moves |

## 4. Targets

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Create/edit target | Set monthly/needed-by/refill targets per category | targets | `PUT/GET /categories/{id}/target` (type, amount, minimum, priority, date, recurrence) | **no client method, no UI** | — | server-side only | **MISSING** | **P1** | Add `APIClient.upsertTarget` + Plan target editor | User creates/edits a target; it persists and drives recommended/underfunded |
| Target progress | Show progress toward target | targets | `recommended_contribution`, `underfunded` in summary | values shown, no editing | live | `test_planning` | PARTIAL | P1 | Surface progress bar tied to editable target | Progress reflects assigned vs target |
| Target recurrence (weekly/monthly/yearly/custom) | Repeating cadence | targets | `recurrence_months` (monthly/simple) | none | — | partial | PARTIAL | P2 | Weekly/custom cadence + editor | Recurrence persists and recomputes each period |
| Snooze/skip target | Temporarily pause a target | targets *(unverified detail)* | none | none | — | — | MISSING | P3 | Add snooze state | Snoozed target excluded from underfunded that month |
| Delete target | Remove a target | targets | upsert can clear? verify | none | — | — | PARTIAL | P2 | Explicit delete path + UI | Deleting a target removes recommendations |

## 5. Auto-Assign / recommendations / underfunded

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Auto-Assign (underfunded / targets / etc.) | One-tap recommended assignment; preview then apply | features | `GET /smart-funding/{m}` preview + `POST /smart-funding` commit | Plan → Smart Funding (preview→confirm) | Both | `test_planning`, delegated guard | IMPLEMENTED · **BETTER** (recommendation-before-mutation, versioned) | — | Broaden strategies (assign-to-target, prior-month) | Preview shows before/proposed/after; commit assigns exactly once |
| Underfunded logic | Amount needed to reach target this month | targets | `underfunded_minor` (target_funding) | shown | live | `test_planning` | IMPLEMENTED | — | — | Underfunded equals target − assigned (bounded) |
| Focused / customizable views | Saved filtered category views | features (Customizable Views) | none (server) | demo had All/Underfunded/Overspent/Pinned filters (removed in unified) | demo-only historically | — | MISSING | P2 | Persisted focused views | Create/save/reload a focused Plan view |

## 6. Transactions

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Manual entry (inflow/outflow) | Add transaction | features | `POST /transactions` | Activity → + | Both | yes | IMPLEMENTED | — | — | Create persists; balances/Available update |
| Edit transaction | Change any field | features | `PUT /transactions/{id}` (full fields) | Transaction detail → Edit | Both | `test_advanced_ledger` (metadata preserved) | IMPLEMENTED | — | — | Old effects reversed, new applied once; metadata preserved |
| Delete/void | Remove a transaction | features | `DELETE /transactions/{id}` (+ change history, reserve reversal) | detail → Delete | Both | `test_credit_cards` delete-reserve | IMPLEMENTED · **BETTER** (immutable change log) | — | — | Delete reverses all derived state; audited |
| Splits | Multi-category split; parts sum to total | features | split model + validator; edit transitions | entry + edit split rows | Both | `test_advanced_ledger` split transitions | IMPLEMENTED | — | — | Split parts must equal total; single↔split works |
| Account transfer | On-budget transfer creates no income/expense | features | `POST /transfers` (paired legs) | Activity → Transfer | Both | `test_advanced_ledger`, `test_credit_cards` | IMPLEMENTED | — | — | Transfer conserves total cash; no category activity |
| Refund / credit | Positive categorized amount reduces spending | features | reserve refund release; analytics net | entry supports inflow to category | Both | `test_credit_cards`, `test_analytics` | IMPLEMENTED | — | — | Refund reduces category spending, not income |
| Reimbursement | Track expected reimbursements | *(YNAB pattern via inflow/category)* | via refund/inflow to category | manual only | Both | — | PARTIAL | P3 | Optional first-class pattern | Reimbursement recorded as category inflow |
| Flags | Color flag on transaction | features | `flag` field | edit sheet Flag picker | Both | preserved test | IMPLEMENTED | — | Filter/sort by flag | Flag persists; visible in register (once register exists) |
| Memo | Free-text note | features | `memo` | entry/edit | Both | yes | IMPLEMENTED | — | — | Memo persists |
| Cleared/uncleared/reconciled | Transaction status lifecycle | features | `is_cleared`,`is_reconciled` | detail shows status; toggle cleared | Both | reconcile tests | IMPLEMENTED | — | Toggle cleared from register | Status persists; reconciled immutable |
| Search / filter / sort | Find transactions | features | list endpoint (no server search) | Activity search (payee/memo/category) | Both | — | PARTIAL | P2 | Filters (account/flag/cleared/date), sort, server paging | Filter+sort a register and see results |
| Scheduled / recurring | Repeating transactions materialize on date | features | `GET/POST /scheduled-transactions`, forecast occurrences | **no client create/list** | forecast shows only | server-side | **MISSING** | **P1** | `APIClient` + scheduled-txn editor & list | Create a schedule; it appears in forecast and materializes |
| Attachments / photos | Attach receipt image | features | `attachment_metadata` (names only) | edit sheet (names, no binary) | Both | — | PARTIAL | P2 | Binary storage endpoint + picker | Attach and reopen an image |
| Payees | Named payees, remembered | features | `payee_name` string (no payee table) | free text | Both | — | PARTIAL | P2 | First-class payee table, rename/merge | Reuse a payee; rename/merge |
| Payee categorization suggestion | Suggest category from payee history | features *(auto-categorize)* | none | none | — | — | MISSING | P3 | Deterministic "N of last M" suggestion (never silent) | Suggests, never auto-mutates |

## 7. Accounts & registers

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Account types (checking/savings/cash) | On-budget cash accounts | features | account types | create account | Both | yes | IMPLEMENTED | — | — | Create typed account |
| **Account register / account-scoped history** | Tap account → its transaction register | features | data available (`transactions` filterable) | `LiveAccountRegisterView` (register, balances header, scoped add/edit, reconcile) — **added `f93dce2`** | live | `DemoStoreTests` register | **IMPLEMENTED** *(was REGRESSED at 43a5212; resolved by Codex `f93dce2` during this review)* | — | Mac runtime confirm | Open account → see its transactions, balances, add/edit within it |
| Account balances (cleared/uncleared/working) | Show three balances | features | `GET /accounts/{id}/balance` | Register header shows Working/Cleared/Uncleared (`f93dce2`) | live | `test_advanced_ledger` | IMPLEMENTED | — | — | Three balances visible per account |
| Reconciliation | Match to statement; adjustment | features | `POST /accounts/{id}/reconcile` (expected-cleared, authority-gated adjustment) | Accounts → tap → Reconcile | live | `test_advanced_ledger` reconcile suite | IMPLEMENTED · **BETTER** (stale-balance + adjustment authority) | — | — | Reconcile matches; adjustment needs `manage_budget_structure` |
| Closed accounts | Close/reopen | features | `is_closed` | shown "Closed"; no toggle UI | live | yes | PARTIAL | P3 | Close/reopen action | Closed account hidden from entry |

## 8. Credit cards & debt

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| CC purchase reserves cash | Funded purchase moves budgeted cash to the card payment category | method | reserve engine (`credit.py`) | reflected in summary | Both | `test_credit_cards` | IMPLEMENTED · **BETTER** (attributed reserves) | — | — | Purchase: category ↓, card debt ↑, payment reserve ↑ |
| CC payment reserve category | Auto payment category per card | method | `ensure_credit_payment_category` | shown in Plan | Both | yes | IMPLEMENTED | — | — | Payment category tracks reserved cash |
| CC payment (transfer) not a 2nd expense | Paying card moves cash, not expense | method | transfer + reserve event | Activity → Transfer to card | Both | `test_credit_cards` | IMPLEMENTED | — | — | Payment: checking ↓, card ↓, no new expense |
| CC overspending / carried debt | Unfunded spend increases debt | method | reserve math; funded vs unfunded | shown as negative | Both | `test_credit_cards` partial-fund | IMPLEMENTED | — | — | Unfunded purchase raises debt without inventing reserve |
| CC refund releases reserve | Refund releases only that reserve | method | attributed refund release | reflected | Both | `test_credit_cards` refund | IMPLEMENTED · **BETTER** | — | — | Refund can't release unrelated/manual reserve |
| Loan / mortgage / tracking | Loan accounts, payoff tools | features (Loan planner) | account types exist; no persisted loan metadata/amortization | demo payoff calc only (removed in unified) | demo-only historically | — | PARTIAL/MISSING | P2 | Loan metadata (APR, term) + payoff view | Track a loan; see payoff estimate live |

## 9. Reports (Reflect)

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Spending — Totals (donut/pie) | Color-coded donut of spending share | [spending-breakdown] | `GET /reports/spending` (per-category totals + IDs) | **bar chart only; donut regressed** | live | `test_analytics` | **REGRESSED** | P2 | Restore donut/pie (`SectorMark`) alongside bars; keep legend/%; a11y | Spending shows a donut with % and drill-in |
| Spending — Trends (bar + trendline) | Monthly bars with average trendline | [spending-trends] | server totals by range | single-range bar; no monthly trend series | live | — | PARTIAL | P2 | Multi-month trend series + trendline | Trend shows months + average line |
| Income v Expense | Income vs spending totals, averages | [income-v-expense] | `GET /reports/income-spending` (net, savings rate, IDs) | Insights section | live | `test_analytics` (transfers excluded, refund-net) | IMPLEMENTED | — | Monthly breakdown + averages | Income, spending, difference, savings rate correct & traceable |
| Net Worth | Assets − liabilities over time | [net-worth] | balances derivable; no net-worth aggregation endpoint | none live (demo had it) | demo-only historically | — | MISSING | P2 | Net-worth endpoint + trend UI | Net worth trend from real accounts |
| Age of Money | Avg days between earning and spending | [age-of-money] | none | none | — | — | MISSING | P3 | AoM calculation | AoM shown (if pursued) |
| Report filtering | Filter by account/category/date/etc. | reports | full server filters (account/category/group/payee/member/type/cleared/tracking) | Insights filter sheet | live | `test_analytics` filters | IMPLEMENTED · **BETTER** (member/tracking filters, scoped) | — | — | Every filter changes results; scoped by permission |
| Report drill-down → transactions → edit → recalc | Inspect contributing transactions | reports / The Inspector | `transaction_ids` per row | Insights → category → txns → edit → recalc | live | `test_analytics` recalc | IMPLEMENTED · **BETTER** (edit-in-place recalcs, D-004 fixed) | — | — | Every number traces to transactions; edit recalculates |
| Rolling 30/60/90, 3/6mo, YTD, 1y, custom | Date-range selection | reports | inclusive date query | Insights period picker | live | `test_analytics` inclusive range; `InsightsTests` rolling | IMPLEMENTED · **BETTER** (more ranges than mobile) | — | — | Rolling windows correct; custom inclusive both ends |

## 10. Home / attention, privacy, sharing, platform

| Capability | YNAB behavior | Ref | Backend | Prod UI | Demo/Live | Tests | Status | Sev | Required work | Acceptance |
|---|---|---|---|---|---|---|---|---|---|---|
| Mobile Home / attention surfaces | Overspending, underfunded, to-do | features | derived from summary/requests/forecast | LiveHomeView (overspent, pending requests, forecast) | Both | — | IMPLEMENTED | — | Add underfunded/upcoming | Home shows real attention items, no hard-coded totals |
| Pinned / favorite categories | Highlight categories | *(customizable views)* | none live | demo had "Pinned" | demo-only historically | — | MISSING | P3 | Pin flag + section | Pin persists |
| Hide Amounts / privacy | Mask amounts globally | features | n/a (client) | **absent in unified app** (demo `hideAmounts` unused by workspace) | demo model only | — | **REGRESSED** | P2 | Add store `hideAmounts` + mask `format` + toolbar toggle | Toggle masks every amount app-wide |
| Household / shared budget (YNAB Together, ≤6) | Share budget with up to 6 people | features (YNAB Together) | full household + grants + scoped capabilities | members list + delegated policy | live | `test_family_administration`, `test_delegated_access` | IMPLEMENTED · **BETTER** (scoped capabilities, per-resource visibility, deactivation) | — | — | Invite/scope/deactivate members; scoped access enforced |
| Delegated sub-budgets | *(no YNAB equivalent)* | — | delegated authority + rules + pool | member Plan + owner policy editor | live | delegated suite | **BETTER** (no baseline) | — | — | Member controls a bounded pool; can't exceed authority |
| Approvals / requests | *(no YNAB equivalent)* | — | request state machine, partial approval, audit | request detail approve/partial/reject/changes | live | request suite | **BETTER** | — | — | Approval funds exactly once from a named source |
| Export / import / manual | CSV/import; manual entry | features | formula-safe CSV + audit JSON (server) | desktop console only | server | `test_export` | PARTIAL | P3 | Optional in-app export | Owner exports scoped CSV/JSON |
| Category templates | Prebuilt category sets | features (Category Templates) | none | none | — | — | MISSING | P3 | Template seed | Apply a starter template |
| Widgets | Home-screen widgets | features (Mobile Widgets) | n/a | none | — | — | DEFERRED | P3 | Future | — |
| Multi-device offline | Offline use, sync | features | n/a | online-only; no offline queue | — | — | DEFERRED | P2 | Offline mutation queue | Future |

## 11. Intentionally deferred (blocked)

| Capability | Status | Note |
|---|---|---|
| Bank import / linked accounts | DEFERRED | Explicitly blocked until separately approved |
| Apple Card import | DEFERRED | Blocked |
| Bank OAuth / Plaid / MX / Finicity / Akoya / Teller | DEFERRED | Blocked |
| Direct institution credentials / screen scraping | DEFERRED | Blocked |

---

## Summary counts

Counting the ~55 in-scope capability rows above (deferred bank-sync excluded from parity math):

- **IMPLEMENTED:** ~24 (many **BETTER-than-baseline**: move-money audit trail, smart-funding preview, credit reserves, reconciliation authority, report drill-down/recalc, extra ranges/filters, household scoping)
- **PARTIAL:** ~14 (groups mgmt, target progress/recurrence/delete, search/filter/sort, attachments, payees, balances display, spending trends, loans, closed accounts, reimbursements, export)
- **MISSING:** ~11 (**targets create/edit UI**, **scheduled-transaction UI**, category reorder, money-move history UI, focused views, net worth, age of money, category templates, pinned, payee suggestions)
- **REGRESSED:** 3 (**account register**, **spending donut**, **Hide Amounts**)
- **DEFERRED:** bank sync family (4) + widgets + offline
- **BETTER-than-baseline:** ~10 distinct capabilities (delegation, approvals, scoped permissions, auditability, forecasting, drill-through recalc, credit attribution, reconciliation authority, smart-funding preview, extra report ranges)

## Top P1 gaps (viability-blocking)
1. ~~Account register / account-scoped transaction history~~ — **RESOLVED by Codex `f93dce2`** (`LiveAccountRegisterView`); pending Mac runtime confirmation.
2. **Targets: create/edit in-app** — MISSING client (server-ready).
3. **Scheduled/recurring transactions: create/list in-app** — MISSING client (server-ready).
4. **Target progress surfaced with an editable target** — PARTIAL.

## Confirmed regressions (with source evidence)
- **Account register:** was REGRESSED at `43a5212` (`LiveAccountsView` taps opened `LiveReconcileView` only). **Resolved `f93dce2`** — accounts now navigate to `LiveAccountRegisterView`. Verify at runtime on Mac.
- **Spending donut → bar:** current Insights uses `BarMark` (`BudgetWorkspaceView.swift:759`). The prior donut existed as `SectorMark` in `git show 87517c1:ios/BudgetApp/DemoInsightsViews.swift` (`SpendingInsightView`), deleted during the v0.4 unification.
- **Hide Amounts:** `DemoStore.hideAmounts` / `DemoStore.money()` exist but the unified workspace renders via `BudgetWorkspaceStore.format` (no mask). The global privacy toggle from v0.3 is absent from the shipping app.

## Where we already exceed YNAB
- **Household delegation with a hard monetary boundary** (no YNAB equivalent): a member commands a bounded pool and cannot exceed authority or touch household RTA (server-enforced, tested).
- **Approvals / funding requests** with partial approval, named funding source, and immutable action history.
- **Scoped, per-capability permissions** and per-resource (account/category) visibility, with member deactivation.
- **Auditability:** append-only allocation ledger + transaction change history (before/after/delete).
- **Forecasting** (30d–1y cash outlook) separated from actuals; **scenarios never mutate actuals** until applied.
- **Financial drill-through** that recalculates in place after an edit; every report number traces to contributing transactions.
- **Credit-card reserve attribution** (refunds can't release unrelated reserves) and **reconciliation-adjustment authority** gating.

## References
- [YNAB Features](https://www.ynab.com/features)
- [YNAB Reports overview](https://www.ynab.com/blog/ynab-reports-and-data)
- [Spending Breakdown](https://support.ynab.com/en_us/spending-breakdown-H1H7YxmD0) · [Spending Trends](https://support.ynab.com/en_us/spending-trends-H1inlhzAc) · [Income v Expense](https://support.ynab.com/en_us/income-v-expense-Byu1BYWRq) · [Net Worth](https://support.ynab.com/en_us/net-worth-BkwQO5WA5) · [Age of Money](https://support.ynab.com/en_us/age-of-money-H1ZS84W1s) · [Reflect](https://support.ynab.com/en_us/reflect-in-ynab-B1GJsrWkj) · [The Inspector](https://support.ynab.com/en_us/the-inspector-an-overview-ryylY7OCq)
