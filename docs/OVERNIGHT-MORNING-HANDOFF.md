# Overnight Engineering — Morning Handoff

This is a durable, incrementally updated handoff for the autonomous run beginning 2026-09-16.
It records engineering evidence separately from human acceptance and does not authorize a merge,
tag, or release.

## 2026-09-17 — v0.8 exact strategy parity checkpoint

- `d7a702d` adds one versioned debt-strategy fixture consumed directly by Python and BudgetCore.
  Ten cases lock exact cents, dates, payoff order, payment count, rollover, extra payments, final
  partial payments, and typed non-amortizing output across providers.
- Focused verification passed: 18 Python projection/vector tests and all 6 BudgetCore
  `DebtProjectionTests` under Xcode 27 Beta.
- Insights hydration was measured before refactoring: each ordinary Live snapshot currently issues
  seven detailed report requests before a focused report is opened, followed by category-target and
  account-balance fan-out. The v0.8 plan records lazy-loading request-count acceptance criteria.
- Human Live database, Simulator, attachments, and reconciliation history were not modified.

## Repository checkpoint

2026-09-17 production-readiness continuation: `c7b84c5` establishes the master readiness ledger;
`30eb76f` fixes zero-principal strategy provider parity with a shared failing-then-passing vector.
The next correction closes a demonstrated category-privacy leak in recorded-interest reporting:
68 focused analytics/delegation tests and the full backend suite pass (11 PostgreSQL-gated skips).
No human database or Simulator data was changed; no migration was added. Human acceptance remains
pending / DO NOT RETEST. Demand-loaded Insights remains the next performance workstream.

The next native checkpoint adds an actionable missing-Debt-Terms route and re-evaluates payoff after
editor dismissal using the shared store. Runtime tests caught a lazy-section sheet placement issue;
presentation now belongs to the stable Debt & Interest root. Demo debt history also no longer inherits
Net Worth's tracking-account toggle, aligning loan visibility with Live. Native XCTest 82/82 and the
production terms-recovery XCUITest pass, as do 33 BudgetCore and 45 BudgetAPI tests. Xcode 27 Beta
`27A5252f`, existing Simulator `3ABD861E-D38D-4AFD-A356-959266051564`; no reset or Live data changes.

`98f2a01` publishes that native recovery checkpoint. Subsequent projection hardening guards Int64
overflow in both engines, returns Live 422 validation without mutation, and prevents a Swift dictionary
trap on duplicate custom-order values when a non-custom strategy is chosen. Verification: full backend
284 passed / 11 PostgreSQL-only skips; package 35 BudgetCore + 45 BudgetAPI passed; native 82 passed
with clean `TEST SUCCEEDED`; all 11 shared strategy vectors remain exact. No migration added.

- Current branch: `codex/development`
- Overnight starting HEAD: `f44c38f9a163e32133f3ca4c7108ad488db2f836`
- Latest independently verified pushed checkpoint: `a4aabf0` (focused report read contract)
- Push status: checkpoints through `a4aabf0` are pushed. Later dated entries supersede historical pending notes below.

Focused report read-contract preparation follows this checkpoint. It preserves existing eager
hydration while separating report selection and current-credential resolution for upcoming demand
loading. Next work: activate demand loading with query/mutation invalidation, loading/error/retry
states and production navigation tests. The following filter-reachability fix restores the hub
toolbar entry to its existing shared filter form and adds a production apply/reopen/reset/chart
navigation regression. Do not claim the seven-report
launch fan-out has been removed yet. Human Live migrations and all human data remain untouched.
- Active mission: [Production readiness ledger](PRODUCTION-READINESS.md); finish v0.8 and continue independent engineering toward an App Store release candidate.
- Next task: demand-loaded Insights reports, authoritative invalidation, loading/error states and request-count evidence.
- Human acceptance: **PENDING — DO NOT RETEST** during the autonomous run.
- Human Live database at start: `0020_payee_identity_repair`
- Human Simulator: preserved iPhone 17 Pro Max / iOS 27.0; no erase/reset/uninstall

## v0.5 checkpoint — Payee identity hardening

Status: **ENGINEERING VERIFIED**

Defects reproduced and corrected in the working tree:

- canonical payee names and aliases did not share one deterministic collision namespace;
- a merged source name was discarded, allowing future typed use to create a new identity;
- an archived payee's alias could be recreated as a new active payee;
- scoped members could receive/search household alias metadata for an otherwise visible payee;
- schedules retained only payee text, so rename/merge could disconnect later realization from the
  original canonical identity.

The correction adds collision/privacy enforcement, deterministic merge aliases, 10,000-payee bounded
search characterization, and stable nullable `scheduled_transactions.payee_id` linkage. Payee rename
and merge update linked future schedules; realization resolves the current canonical identity. A new
typed schedule remains text-only until realization unless it matches an existing identity, so merely
canceling or saving forecast metadata does not create a new household payee.

### Migration ledger

| Version | Revision | Previous | Purpose | Data transformation | Automated populated upgrade | Human Live application |
|---|---|---|---|---|---|---|
| v0.5 | `0021_scheduled_payee_id` | `0020_payee_identity_repair` | Add nullable scheduled-payee FK/index and safely link exact normalized active canonical/alias matches | Yes; links only, creates/merges nothing | Focused PASS; full suite pending | REQUIRED/PENDING; do not apply automatically |

### API ledger

- Existing `POST/PUT/GET /api/v1/budgets/{budget_id}/scheduled-transactions` contract gains nullable
  `payee_id`. Authorization and schedule money-neutrality are unchanged.
- Existing payee create/update/alias/merge/search routes now reject deterministic name collisions and
  omit alias metadata/matching for resource-scoped callers.

### Financial ledger

No financial semantics changed. Payee and schedule identity metadata remain money-neutral. Scheduled
realization still routes through the existing authoritative transaction/card engine exactly once.

### Verification

- Focused backend/payee/schedule/attachment/migration: PASS (44 tests).
- Full backend: PASS (189 passed, 9 PostgreSQL-only skipped). The unrestricted run was required only
  for the launcher's intentional loopback-bind test.
- Swift package: PASS (27 BudgetCore + 33 BudgetAPI).
- Native XCTest: PASS (67 tests) on Xcode 27.0 Beta, iPhone 17 Pro Max / iOS 27.0. Xcode executed
  every test successfully, then repeated its existing result-log finalization stall; only the stalled
  finalizer was interrupted.
- `git diff --check`: PASS.

## Human acceptance status

### HUMAN PASSED

- Payee search/filter: Activity → Filter → Payee → search `Meta` → `Metadata test` → Apply returned
  exactly the expected transaction.
- All acceptance evidence listed in `V0.5-CLOSURE-AUDIT.md` before the overnight run remains valid
  unless explicitly listed under invalidation below.

### HUMAN PENDING

- New typed payee creation remains pending; it has not been human-tested.
- Payee rename/alias/archive/merge and one representative schedule realization remain pending.
- Later sections will consolidate remaining browser/bulk/attachment/recovery checks.

### HUMAN ACCEPTANCE INVALIDATED BY LATER CHANGE

None. The overnight identity correction does not alter the already-passed `Metadata test` search/filter
interaction or any accepted financial/clearing/reconciliation behavior.

### DO NOT RETEST

Do not repeat canonical quick clearing, reconciliation invariants, credential rotation, migration 0020
continuity, prior image upload/preview/removal, basic void/reversal, or the accepted `Metadata test`
Payee search/filter unless a later section explicitly records invalidation.

### BLOCKED

None at this checkpoint.

## v0.5 checkpoint — Activity browser scale and lifecycle filtering

Status: **ENGINEERING VERIFIED**

The production transaction browser previously called `_visible_transactions`, hydrating every visible
transaction and every split before applying filters, sorting, and pagination in Python. That made the
API response look paginated while its memory/query work remained proportional to the household's full
history.

The browser now applies authorization, resource, text, amount, date, type, clearing, linkage, flag,
tag, member, and lifecycle predicates in SQL; obtains an authorized count independently; uses stable
keyset cursors for every supported sort; and hydrates only `limit + 1` rows plus their splits. The
production Activity filter now distinguishes clearing state from lifecycle and can explicitly select
Posted, Voided, or Reversal rows. Demo uses the same query semantics.

Verification:

- focused Activity/browser/bulk/payee backend: PASS (20 tests before the final lifecycle additions;
  Activity browser suite PASS with 8 tests afterward);
- 3,000-row scale fixture: PASS, with no more than the requested 25 rows plus one look-ahead row loaded;
- insertion between keyset pages: PASS without a duplicate or skipped older row;
- full backend: PASS (193 passed, 9 PostgreSQL-only skipped);
- Swift package: PASS (27 BudgetCore + 33 BudgetAPI);
- native XCTest before the final parity assertion: PASS (67 tests); focused Demo/Live lifecycle parity:
  PASS (1 test) and Xcode build PASS;
- no migration and no financial-semantic change; `git diff --check`: pending final checkpoint.

Human acceptance remains pending for the consolidated Activity search/filter/sort/load-more journey.
No previously accepted workflow is invalidated.

## v0.5 checkpoint — Restricted-resource mutation parity

Status: **ENGINEERING VERIFIED — pushed in `869a1db`**

The security audit found that list/search correctly hid uncategorized transactions from a
category-restricted member, but several ID-addressed endpoints treated an empty category set as
permitted. A member who knew the opaque transaction ID could therefore attempt bulk mutation, edit,
delete, duplicate, void, Make Recurring, or attachment access against a row absent from their visible
dataset. Scheduled-transaction list/mutation paths had the equivalent inconsistency.

A canonical transaction-resource guard now applies the same account/category visibility rule to all
of those surfaces and returns a non-disclosing 404. Schedule list, create, edit, delete, and realization
now apply the equivalent live resource scope. Bulk mutation locks selected transaction rows so
concurrent metadata additions serialize instead of losing an update.

Verification:

- focused delegated/bulk/scheduled/void/attachment authorization: PASS (45 tests);
- full backend: PASS (195 passed, 10 PostgreSQL-only skipped);
- a PostgreSQL-only race test now proves concurrent bulk tag additions retain both updates when the
  disposable PostgreSQL concurrency environment is supplied;
- no Swift, migration, or financial-semantic change; native evidence from `bdc7d5e` remains applicable;
- `git diff --check`: pending final checkpoint.

No human-accepted workflow is invalidated. Restricted-member privacy remains HUMAN PENDING as one
consolidated production UI journey.

## v0.5 checkpoint — Backup/restore target and archive validation

Status: **SCRIPT-LEVEL ENGINEERING VERIFIED — real-container drill blocked on host tooling**

The destructive restore script previously relied on Docker Compose's implicit project selection. It
now requires `--project-name NAME`, making the target explicit. Backups include versioned metadata with
the source Alembic revision. Restore verifies required components, all SHA-256 manifest entries, and
the supported archive format before issuing its first Docker mutation. Corrupt, incomplete, future-
format, and missing-target inputs are rejected before the target is touched.

Verification:

- shell syntax: PASS;
- script integration with disposable fake `docker`/`age`: PASS (4 tests), including archive contents,
  explicit source/target selection, integrity failure, completeness failure, and incompatible format;
- real Docker/`age` encrypted restore: BLOCKED because neither executable is installed on this Mac;
- the human Live database, attachment store, and Simulator were not addressed.

This improves operator safety but does not claim the v0.9 consumer backup UI, automatic retention, or
a real-container human restore pass.

## Morning build and migration plan (current; final HEAD will supersede)

- Xcode: `/Users/firepika/Downloads/Xcode-beta.app`
- Simulator: existing iPhone 17 Pro Max / iOS 27.0
- Clean build required: NO evidence yet
- Normal Cmd-R build sufficient: expected YES
- Simulator reset required: NO
- Rebuild required: YES after final overnight Swift changes
- Server restart required: YES after final pull/migration
- Migration required: YES, currently `0020_payee_identity_repair` → `0021_scheduled_payee_id`
- Backup before Live migration: recommended as routine safety; migration is additive and its data
  transformation only links unambiguous active Payees to existing schedules.

Exact final commands and consolidated acceptance steps will be updated after the final pushed checkpoint.

## v0.6 checkpoint — server-authoritative income/spending trends

Status: **ENGINEERING VERIFIED**

The existing Income vs. Spending report now returns monthly periods clipped to the report's inclusive
start/end bounds. Every period carries exact integer-minor-unit income, spending, net cash flow, and
the contributing transaction IDs. It reuses the canonical report transaction scope and classification:
transfers are excluded, positive categorized portions net refunds against spending, split portions are
summed exactly, tracking-account behavior follows the report filter, and restricted members cannot gain
new aggregate visibility.

The shared production Insights hierarchy renders those periods as an accessible Swift Charts grouped
bar chart. Demo constructs the same DTO and view path; it no longer risks treating the positive leg of a
demo transfer as income. The implementation plan and remaining net-worth/target-performance work are in
`V0.6-IMPLEMENTATION-PLAN.md`.

Verification:

- focused backend analytics: PASS (6 tests);
- Swift package: PASS (27 BudgetCore + 34 BudgetAPI);
- native XCTest on Xcode 27 Beta, iPhone 17 Pro Max / iOS 27: PASS (68-test full suite plus the new
  focused Demo/report parity test); the Xcode Beta runner
  again stalled only while finalizing the already-complete result bundle and was interrupted afterward;
- full backend: PASS (200 passed, 10 PostgreSQL-only skipped); `git diff --check`: PASS;
- no migration and no mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — plan and target performance

Status: **ENGINEERING VERIFIED**

Insights now includes a bounded Plan Performance section sourced from the same authoritative monthly
planning summary used by Plan. It exposes exact assigned, Ready to Assign, target shortfall, and
overspending values; ranks categories needing attention; explains that targets are non-monetary
planning guidance; and reuses the existing report/category transaction drill-through when activity is
available. Demo and Live use the same production view and server-shaped summary contract.

Verification:

- Xcode 27 Beta build and focused native production-source guard: PASS;
- `git diff --check`: PASS;
- no backend or migration change and no mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — historical net worth

Status: **ENGINEERING VERIFIED**

The server now owns a historical net-worth report with exact monthly observations, assets,
liabilities, total net worth, final account contributions, and contributing transaction IDs. The
report requires both report and account-balance capabilities, applies account-resource restrictions,
rejects hidden-account filters without disclosure, and supports explicit account/tracking scope.
Transfers remain net-neutral because both authoritative legs participate in account balances.

The production Insights hierarchy renders the same report contract for Demo and Live using an
accessible native line chart and exact summary/account rows. Account rows drill into the existing
production account register rather than creating a report-only transaction browser.

Verification:

- focused backend analytics: PASS (8 tests, including tracking, transfer neutrality, exact account
  reconciliation, and restricted-account privacy);
- Swift package: PASS (27 BudgetCore + 35 BudgetAPI);
- Xcode 27 Beta Simulator build for iPhone 17 Pro Max / iOS 27: PASS;
- full backend: PASS (202 passed, 10 PostgreSQL-only skipped);
- native focused regression on Xcode 27 Beta, iPhone 17 Pro Max / iOS 27: PASS (2 tests), including
  Demo exact report reconciliation and the production chart-path guard;
- `git diff --check`: PASS;
- no migration and no mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — report filter security

Status: **ENGINEERING VERIFIED**

Report filters now validate requested accounts and categories against the current budget even for an
otherwise unrestricted owner, closing a cross-budget filter ambiguity. Restricted members cannot use
member filters to probe another household actor, and category-group filters are validated against the
caller's visible category scope before aggregation. Hidden, cross-budget, and nonexistent resource
probes consistently return the existing privacy-preserving not-found response.

Verification:

- focused analytics: PASS (10 tests);
- full backend: PASS (204 passed, 10 PostgreSQL-only skipped);
- `git diff --check`: PASS;
- no schema migration and no mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — bounded long-history net worth

Status: **ENGINEERING VERIFIED**

Historical net-worth aggregation now walks the ordered ledger once instead of rescanning the entire
history for every month. Default responses remain bounded by omitting repeated cumulative transaction
ID arrays; the production drill-through already uses the authorized paginated account register.
Explicit provenance remains available through `include_transaction_ids=true` for diagnostic callers.

Synthetic one-, five-, and eleven-year fixtures (ten transactions per month) verify exact monthly
totals and a bounded default response. PostgreSQL query-plan inspection remains pending because this
host's automated suite is using SQLite and no disposable PostgreSQL service has been provisioned.

Verification:

- focused analytics: PASS (13 tests);
- full backend: PASS (206 passed, 10 PostgreSQL-only skipped);
- no migration and no mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — accessible Insights composition

Status: **ENGINEERING VERIFIED**

Spending, income/spending, and net-worth charts now expose explicit date/total/series summaries instead
of relying on geometry or color. Net-worth account contributions and Plan Performance attention rows
have stable accessibility identifiers and preserve the shared production drill paths.

A production-composition XCUITest launches the deterministic provider through the real active-budget
shell, opens Insights, verifies semantic chart content, drills Net Worth into the canonical account
register, returns, drills an overspent Plan Performance category into its contributing transactions,
and returns with navigation intact.

Verification:

- Xcode 27 Beta / iPhone 17 Pro Max / iOS 27 production XCUITest: PASS (1 journey);
- Xcode build is included in that successful test operation;
- dark-mode contrast and VoiceOver gesture-level human acceptance remain pending and are not claimed;
- no server, migration, Live-data, attachment, or Simulator-data mutation.

The same production Insights composition also passes an automated dark-appearance run at the largest
accessibility content-size category. The test restores the Simulator's prior appearance and verifies
that the chart summary and final Plan Performance rows remain reachable through native scrolling.

## v0.6 checkpoint — interactive trend selection

Status: **ENGINEERING VERIFIED**

Income/spending and net-worth charts now use native horizontal chart selection. A selected period or
point exposes its exact dates, assets/liabilities/net worth, or income/spending/net cash-flow values.
Cash-flow selections can open their contributing records through the shared production transaction
rows/editor; net-worth account contributions retain the canonical paginated register drill-through.

Verification:

- Xcode 27 Beta native source/composition guard: PASS;
- production Insights XCUITest navigation journey: PASS;
- direct synthetic XCUITest taps on Swift Charts' accessibility proxy do not forward to
  `chartXSelection`, so gesture-level chart selection remains a small human acceptance item;
- no backend, migration, or persisted-data mutation.

## v0.6 checkpoint — net-worth ledger correctness

Status: **ENGINEERING VERIFIED**

The historical net-worth contract now has explicit end-to-end regression fixtures for opening
history before the requested range, inclusive end boundaries, liabilities, credit-card purchases and
payments, reconciliation adjustments, and void/reversal pairs. The fixtures prove that card payments
move value between accounts without changing household net worth, post-range records are excluded,
reconciliation adjustments appear exactly once, and a void plus its explicit reversal nets exactly
without special client accounting.

Verification:

- focused analytics: PASS (15 tests);
- full backend: PASS (208 passed, 10 PostgreSQL-only skipped); the unrestricted run was required only
  for the launcher's intentional loopback-bind test;
- no production-code, schema, Swift, migration, Live-data, attachment, or Simulator-data mutation;
- `git diff --check`: pending final checkpoint.

## v0.6 checkpoint — Insights metadata filter parity

Status: **ENGINEERING VERIFIED — commit/push pending**

Spending and income/cash-flow reports now accept reconciled state, flag, and normalized tag filters
in addition to their existing server-authoritative resource and transaction filters. The Swift API
serializes those predicates explicitly, and the shared production Insights filter sheet exposes them.
Demo applies the same query semantics. Transaction-only filters intentionally suppress the Net Worth
section instead of implying that account balances were filtered by transaction metadata.

Verification:

- focused analytics: PASS (15 tests), including intersection of clearing/reconciled, flag, and tag
  predicates;
- full backend: PASS (208 passed, 10 PostgreSQL-only skipped);
- Swift package: PASS (27 BudgetCore + 35 BudgetAPI);
- native XCTest: PASS (69 tests before the added focused parity fixture); focused Demo/Live report
  filter parity: PASS (1 test);
- Xcode 27.0 Beta build on existing iPhone 17 Pro Max / iOS 27.0 simulator: PASS;
- no schema migration or mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — report calendar boundaries

Status: **ENGINEERING VERIFIED — commit/push pending**

Deterministic report fixtures now cover leap-day, calendar-month, and year-rollover clipping. Native
coverage verifies that rolling ranges use local calendar-day arithmetic across the America/New_York
spring DST transition rather than subtracting fixed UTC hours. This preserves the date-only server
contract and prevents the prior class of UTC rollover drift.

Verification: focused analytics PASS (16 tests); focused Xcode 27 Beta native DST/UTC-boundary test
PASS; no production code, schema, or persisted data changed.

## Git hygiene checkpoint

The ongoing autonomous stream now uses `codex/development`; its local and remote refs were created at
`d048b5f` after the verified calendar-boundary checkpoint was published. Before removal, both
`codex/v0.4.0-stabilization` and `codex/v0.3.0-native-experience` had zero commits not reachable from
`codex/development`, and neither was referenced by another worktree. Their local and remote refs were
removed. `main`, `origin/main`, and legitimate release tags `v0.1.0`, `v0.2.0`, and `v0.3.0` remain.
No commit or tag history was rewritten or lost.

Generated Swift build directories, Xcode user data, and the local attachment store are now ignored;
no generated or human attachment data was deleted.

## v0.6 checkpoint — authoritative Debt Insights

Status: **ENGINEERING VERIFIED — commit/push pending**

Debt Insights now comes from a dedicated permission-scoped server report over the exact account
ledger. It includes credit-card and loan debt only, preserves integer minor units, reports opening
and current debt plus principal reduction (or debt increase), provides bounded monthly observations,
and supports authorized account filtering. Hidden account identifiers return the same not-found
response as unknown resources before aggregation, preventing aggregate or filter leakage.

The production SwiftUI composition renders an accessible native history chart and account-ranked
contributions. Account rows drill through the existing shared register. Demo builds the same report
DTO from its exact ledger balances; it does not use a separate presentation. Interest and payoff
projections are explicitly omitted because the current domain has no authoritative APR,
minimum-payment, amortization, or principal/interest inputs.

Verification:

- focused analytics: PASS (18 tests), including payments, new debt, filtering, and restricted scope;
- Swift package: PASS (27 BudgetCore + 36 BudgetAPI after the added debt contract test);
- Xcode 27 Beta production build on the existing iPhone 17 Pro Max / iOS 27 simulator: PASS;
- full backend and native XCTest: pending final checkpoint verification;
- no migration or mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — historical Plan Performance

Status: **ENGINEERING VERIFIED — commit/push pending**

A dedicated server report now walks allocation postings, categorized transaction/split activity, and
credit-card reserve events once to produce exact monthly Plan observations: assigned, actual spending,
carried and ending Available, overspending, and Unassigned. Move Money nets to zero new assignment;
refunds reduce spending; card reserve movement remains visible as category activity but is excluded
from spending so a funded card purchase is never counted twice. Historical points reconcile to the
canonical current-month summary at the same boundary.

Authorization scope is applied before aggregation. Restricted members receive only visible account
and category effects, and household Unassigned remains zero rather than leaking owner cash or hidden
allocation postings. The production Insights screen renders an accessible assigned-versus-spent
history chart with exact monthly values and an explicit empty state. Transaction-only Insights filters
hide the history rather than implying unsupported filtered planning semantics. Demo supplies the same
report DTO to the same production view.

Verification so far: focused analytics PASS (29 tests); Swift package PASS (27 BudgetCore + 38
BudgetAPI); Xcode 27 Beta production build on the preserved iPhone 17 Pro Max / iOS 27 simulator PASS.
Focused native composition and broad checkpoint suites remain pending. No migration or persisted-data
mutation was introduced.

One-, five-, and eleven-year disposable Plan histories at ten categorized entries per month remain
monthly and bounded below 50 KB with a constant query-count guard of 20 statements. SQLite endpoint
test calls on this host were approximately 0.03 s, 0.07 s, and 0.12 s respectively. Focused native
Demo/live contract verification also passes.

## v0.6 checkpoint — transparent Financial Resilience

Status: **ENGINEERING VERIFIED — commit/push pending**

Financial Resilience now reports only deterministic, explainable observations: visible on-budget
checking/savings/cash balance as the cash buffer; active scheduled income and outflows over 30 days;
their expected margin; and the authoritative forecast's current, projected, and lowest on-budget
balances. Transfers remain forecast-neutral and schedules remain forecast-only. The report reuses the
canonical visible-account forecast path and requires both report and balance capabilities.

Essential-expense and emergency-fund coverage remain explicitly null with user-visible reasons because
the domain has no authoritative essential/emergency classification. Scheduled outflows are not called
"required" because the schedule model has no required/optional marker. No composite score, advice,
APR, or emergency-runway assumption was introduced.

Verification so far: focused analytics/resilience/plan tests PASS (6 tests); Swift package PASS (27
BudgetCore + 39 BudgetAPI); Xcode 27 Beta production build on the preserved iPhone 17 Pro Max / iOS
27 simulator PASS. Broad checkpoint suites remain pending. No migration or persisted-data mutation.

## v0.6 checkpoint — Debt Insights hardening

Status: **ENGINEERING VERIFIED — commit/push pending**

Disposable exact-value fixtures now reconcile Debt Insights against Historical Net Worth through a
credit-card purchase, a funded card payment transfer, a void/reversal pair, and a credit-account
reconciliation adjustment. They prove that the payment changes debt and account contribution once
without changing household net worth, the void/reversal nets exactly, the adjustment appears once,
account debt contributions sum to the report total, and assets plus signed liabilities equal net
worth. Existing coverage separately proves loan payments, new card debt, multiple debt accounts,
account filters, tracking debt, zero visible debt, and hidden-account non-disclosure.

One-, five-, and eleven-year disposable histories at ten ledger entries per month produce exactly one
bounded observation per month, a constant query count (guarded at 15 or fewer statements), and JSON
payloads below 25 KB even at eleven years. On this host's SQLite test environment, complete endpoint
test calls were approximately 0.03 s, 0.06 s, and 0.10 s respectively. These are regression
characterization values, not production PostgreSQL service-level guarantees.

Verification: focused analytics PASS (22 tests). No production code, schema, migration, Swift, Live
data, attachment data, or Simulator data changed in this hardening checkpoint.

## v0.6 checkpoint — server-authoritative Spending Trends

Status: **ENGINEERING VERIFIED — commit/push pending**

The production Insights composition now includes monthly Spending Trends switchable among category,
category-group, and payee dimensions without resetting the active date or report filters. The server
applies authorization and account/category/group/member/payee/type/clearing/flag/tag/tracking scope
before exact split attribution and refund netting. Transfers are excluded. Series are deterministically
ranked and bounded to 12 by default (API maximum 25); zero months remain explicit, and partial first
and final months preserve the inclusive requested dates.

The shared native chart exposes a semantic summary plus exact ranked totals and monthly averages.
Category and group rows retain their canonical report drill paths; payee rows open contributing
transactions through the shared production transaction links/editor. Demo emits the same API report
DTO and renders the same production view hierarchy.

Verification so far:

- focused analytics: PASS (24 tests), including split/refund/transfer, every dimension, limit
  validation, cross-budget IDs, and hidden category/payee non-disclosure;
- Swift package: PASS (27 BudgetCore + 37 BudgetAPI);
- Xcode 27 Beta production build on the preserved iPhone 17 Pro Max / iOS 27 simulator: PASS;
- focused native XCTest and the production Insights XCUITest drill journey: PASS;
- full backend and broad native suites: pending final v0.6 closure verification;
- no migration or mutation of Live, attachment, or Simulator data.

## v0.6 checkpoint — open-format report export

Status: **ENGINEERING VERIFIED — commit/push pending**

Insights now provides an authorized CSV export for the selected report date range. The server composes
the file from the canonical Spending, Income vs Spending, Net Worth, Debt, and Plan Performance report
services; monetary observations remain exact integer minor units and all existing report visibility
rules apply before rows are written. The format is intentionally open and human-readable, and the UI
states clearly that it is distinct from the full-fidelity encrypted backup/restore lifecycle.

The export is protected by the `export_data` capability, uses the current Live credential after token
rotation, quotes CSV fields, and prefixes spreadsheet formula leaders in user-controlled labels. Demo
uses the same production Insights UI and emits the same column contract from its canonical report DTOs.
No report export mutates financial state, and no migration or persisted Live/Simulator data change was
introduced.

Verification: focused backend CSV tests PASS (2 tests); full backend PASS (with the 10 expected
environment-gated skips); Swift package PASS (27 BudgetCore + 40 BudgetAPI); focused native Demo
export PASS; and the full native XCTest suite PASS (73 tests). Native verification used Xcode 27 Beta
on the preserved iPhone 17 Pro Max / iOS 27 simulator. The sandboxed backend run could not bind its
launcher test socket; rerunning the identical suite outside that socket restriction passed. No XCUITest
was added for the system share sheet because the native store/composition and API boundary tests cover
the application-owned behavior without automating Apple-owned sharing UI.

## v0.6 checkpoint — report operational hardening

Status: **ENGINEERING VERIFIED — commit/push pending**

All historical report families now reject inverted dates and ranges longer than 600 calendar months,
preserving ten-plus-year analysis while placing a clear upper bound on monthly response growth.
Contributing transaction provenance is deduplicated and capped at 500 IDs per aggregate/period/account;
exact monetary totals still include every authorized transaction. New explicit truncation flags flow
through the API and Swift models, and production drill-through UI explains when its contributor list is
partial instead of implying that the report total is partial.

Transaction ordering now has an ID tie-breaker for deterministic provenance. Regression matrices cover
the 501-transaction boundary across Spending, Income vs Spending, Spending Trends, and opt-in Net Worth
provenance; all report routes reject missing authentication and unknown budgets; every historical route
rejects a 601-month request; and every report/export has a stable zero-data response. Existing cross-
budget resource, hidden member/group, restricted aggregate, archived-history, and filter manipulation
coverage remains in force.

Focused analytics PASS (all tests in `test_analytics.py`); full backend PASS with 10 expected
environment-gated skips; Swift package PASS (27 BudgetCore + 40 BudgetAPI); Xcode 27 Beta production
simulator build PASS; and the full native XCTest suite PASS (73 tests) on the preserved iPhone 17 Pro
Max / iOS 27 simulator. No migration or persisted data was changed.
## v0.6 checkpoint — long-history and PostgreSQL report scale

Status: **ENGINEERING VERIFIED — commit/push pending**

Spending, Income vs Spending, Spending Trends, and CSV export now join the existing Net Worth, Debt,
and Plan Performance one-, five-, and eleven-year scale matrix. Ten categorized ledger entries per
month preserve exact totals and monthly observations; response-size guards cover every family, and
query-count guards permit SQLAlchemy's intentional 500-parent split-loading batches while rejecting
per-month or per-transaction N+1 behavior.

Migration `0022_report_query_indexes` adds composite production indexes for transaction budget/date,
allocation operation budget/date, allocation posting budget/operation, reserve event budget/date, and
active scheduled forecast lookup. A disposable local PostgreSQL 17 database was migrated from empty to
head and loaded with 50,000 synthetic transactions. `EXPLAIN (FORMAT JSON)` selected
`ix_transaction_budget_date_id` for the representative authorized date-range ledger scan. The optional
PostgreSQL regression also verifies the remaining report/planning indexes exist. The complete genuine-
contention PostgreSQL suite and migration graph tests pass.

That broader PostgreSQL run exposed an existing money-safety defect unrelated to reporting: after a
competing transaction released a Budget row lock, SQLAlchemy could reuse the stale Budget already in
the session identity map, letting two Move Money calls accept the same allocation version. Commit
`210fba0` makes the locked read populate the existing identity with the newly committed row; the race
now has exactly one winner. This focused correction was committed and pushed independently.

The PostgreSQL cluster and all synthetic records live only under `/private/tmp`; the human Live database
remains untouched at its existing revision. Full backend PASS with 11 expected PostgreSQL/environment-
gated skips when the disposable URL is absent; the explicitly configured PostgreSQL contention, plan,
and migration run PASS (19 tests). Native code did not change in this checkpoint.
## v0.7 checkpoint — actionable Home quick actions

Status: **ENGINEERING VERIFIED — commit/push pending**

The v0.7 plan is now explicit. Its first production checkpoint adds a compact adaptive Quick Actions
section to Home. Available actions are derived from the active budget's capabilities and usable
resources: Transaction requires transaction creation plus an open account; Move Money requires
authority, a funded source, and a second category; Schedule requires planning authority; Request
requires request authority. Unauthorized or impossible actions are absent rather than failing after a
tap.

Every action opens the existing shared production editor (`TransactionEntryView`,
`AllocationTransferView`, `LiveScheduledTransactionEditor`, or `FundingRequestView`). No duplicate
mutation path, Demo-only behavior, local accounting, or permission substitute was introduced. Editor
saves continue through `BudgetApplicationServices`, and cancellation remains money-neutral.

Focused production XCUITest PASS on Xcode 27 Beta / preserved iPhone 17 Pro Max iOS 27: Home opened
the canonical transaction, Move Money, and schedule editors and canceled each cleanly. The full Swift
package suite PASS and all 73 native `BudgetAppTests` PASS. After XCTest had reported the complete
green result, Xcode 27 Beta remained blocked while saving/cleaning the test-session record; the hung
tool process was interrupted without erasing or resetting the preserved Simulator. `git diff --check`
also PASS. No backend code or schema changed in this checkpoint.

## v0.7 checkpoint — actionable needs-attention rows

Status: **ENGINEERING VERIFIED — commit/push pending**

Home now ranks overspent categories ahead of underfunded targets, bounds the visible list to five,
and explains any remaining count rather than allowing a large plan to overwhelm the daily screen.
Each visible category is a native navigation link into the existing production category detail, where
capability-gated Assign Money, Move Money, target, and category-management actions remain canonical.
Pending funding requests retain their existing server-backed detail path. No allocation, target, or
accounting calculation was moved into the Home presentation.

Focused production-composition XCUITest PASS on Xcode 27 Beta / preserved iPhone 17 Pro Max iOS 27:
the deterministic Home opened the real Dining Out category detail and exposed the existing Assign
Money and Move Money resolution actions. The native app compiled as part of this test, and
`git diff --check` PASS. No backend, migration, or API contract changed.

## v0.7 checkpoint — complete Home context and accessibility

Status: **ENGINEERING VERIFIED — commit/push pending**

Home now distinguishes active schedules from paused records before presentation. When there are no
active schedules, it explains that paused schedules remain outside forecasts; when there are no
posted transactions, it presents an intentional Recent Activity empty state. Empty Needs Attention
sections are omitted. These are presentation-only decisions over authoritative workspace data.

Two focused production XCUITests PASS on Xcode 27 Beta / preserved iPhone 17 Pro Max iOS 27. A fresh
budget renders both explicit zero states without a spurious Needs Attention section. The populated
Home keeps its transaction quick action and category resolution path reachable in dark appearance at
an accessibility text size. This completes the Actionable Home engineering checkpoint; human visual
and VoiceOver acceptance remain separate.

## Product decision integrated — Debt Cost & Payoff Insights

The new requirement is assigned to v0.8, where the authoritative roadmap already places debt/loan
modeling, amortization, and scenarios. Reopening v0.6 would destabilize an engineering-complete
historical-debt baseline, while inserting the full engine into v0.7 would displace its daily and
household experience objective. `V0.8-IMPLEMENTATION-PLAN.md` now defines persisted type-specific
terms, explicit posted-interest classification, exact provider-neutral projections, non-amortizing
outcomes, avalanche/snowball/custom comparison, visible rollover assumptions, privacy-before-
projection, and progressive native UI. No financial assumptions, application code, schema, or Live
database were changed by this planning checkpoint.

## v0.7 checkpoint — personal category favorites and focused Plan

Status: **ENGINEERING VERIFIED — commit/push pending**

Plan now supports persisted, per-member category favorites with stable ordering. Favorite metadata is
stored server-side and is returned only for categories already visible to the authenticated member;
attempts to favorite hidden categories preserve the existing non-disclosing 404 behavior. Favorites
are personal rather than household-global, and adding or removing one leaves allocations, activity,
Available, Unassigned, accounts, and transactions unchanged.

The shared production Plan view adds Favorites alongside its existing underfunded, overspent, funded,
and available focus modes. Category detail uses the canonical Demo/Live command path to add or remove
a favorite, refresh authoritative workspace state, and preserve a stable favorite order. Demo maps its
existing pinned-category state through the same production UI; Live uses the new authenticated
favorite endpoints. Migration `0023_category_favorites` is committed as source only and was not
applied to the human Live database.

Focused backend favorite and migration coverage PASS (9 tests), the full Swift package PASS (27
BudgetCore + 41 BudgetAPI), focused native persistence XCTest PASS, production-composition XCUITest
PASS, and the Xcode 27 Beta simulator build PASS on the preserved iPhone 17 Pro Max / iOS 27
simulator. Human interaction and visual acceptance remain separate.

## v0.7 checkpoint — persistent Hide Amounts privacy

Status: **ENGINEERING VERIFIED — commit/push pending**

Profile & Settings now owns a Hide Amounts preference scoped to the authenticated user and active
budget. Every read-only monetary surface in the unified workspace routes through the shared formatter,
including Home, Plan, Activity, Accounts, Forecast, Requests, Smart Funding, schedules, household
authority, and Insights. Masked strings therefore replace the monetary accessibility output as well as
visible text; editable money fields retain their explicit values only while the user is intentionally
editing a financial operation.

The preference survives workspace reconstruction and app relaunch, does not cross household-member
identities, and is marked privacy-sensitive for supported system capture behavior. When a protected
workspace resigns active state, a full app-switcher shield replaces its content. This repository has no
widget or notification monetary-content target to redact. The preference changes presentation only:
focused native coverage proves Ready to Assign, category activity, account observations, and posted
transactions remain unchanged.

Focused native XCTest and the production-composition relaunch XCUITest PASS using Xcode 27 Beta on
the preserved iPhone 17 Pro Max / iOS 27 simulator. The Xcode Beta result recorder hung during one
superseded run after XCTest had finished; the final rebuilt test-without-building run completed and
saved normally. No backend, schema, migration, Simulator data, or Live data changed.

## v0.7 checkpoint — human-readable household access

Status: **ENGINEERING VERIFIED — `d50aa63` + `3b60b5c`, pushed**

The owner-only Household surface now opens a production member-access editor that maps the canonical
server capability model to View Only, Limited Access, Full Access, and grouped advanced controls.
Account and category visibility can be limited to explicit selections, with validation preventing an
empty restricted scope. Transfer guidance makes the two-account boundary explicit. Full Access does
not transfer ownership, and owner records cannot be edited through the member-profile contract.

The backend adds owner-only access-profile inspection, returns canonical effective legacy access or
persisted custom access, exposes last-change actor/time, and requires an optimistic version on edits.
The profile row is locked and explicitly timestamped so capability-only changes advance the version;
stale submissions return 409 rather than silently overwriting a newer configuration. All long-lived
Live requests resolve the current credential before access reads/writes, while Demo exercises the
same production view with an in-memory authoritative profile.

Focused backend tests prove persistence, stale-write rejection, owner protection, restricted-member
non-disclosure, resource scope, and unchanged monthly/account financial observations. Swift API
contract coverage proves exact budget-scoped GET/PUT payloads. Native credential-rotation coverage
includes access-profile reads, and a production-composition XCUITest covers Household → member →
preset/scope edit → save → reopen. No migration or human Live/Simulator data reset was performed.

## v0.7 checkpoint — recoverable household member lifecycle

Status: **ENGINEERING VERIFIED — commit/push pending**

The owner Household surface now manages active and removed members plus pending, expired, accepted,
and canceled invitations. Owners can create, cancel, and resend single-use invitations, explicitly
remove a member after confirmation, invite a removed member to rejoin, and inspect recent human-
readable access activity. Invitation secrets remain write-only: list and audit responses never expose
their stored SHA-256 token hashes.

Membership removal now deactivates the durable membership instead of deleting financial or access
history. Server authorization still rejects inactive members immediately. Reaccepting an authorized
new invitation reactivates the same membership and recovers its prior budget grant/profile rather
than creating a duplicate identity. The household owner can neither leave nor be removed, Full Access
remains non-ownership, and no ownership transfer is implicit. Invitation create/resend/cancel,
acceptance, member leave/removal, budget-grant change/revocation, and access-profile edits write
durable actor/time events. Backup export includes invitations without token hashes and the access
event ledger.

Migration `0024_member_lifecycle` is source-only and was not applied to human Live. Focused lifecycle,
access-profile, and migration tests PASS (17); the full backend suite PASS with 11 skips; Swift package
tests PASS (27 BudgetCore + 43 BudgetAPI); and the unsigned Xcode 27 Beta simulator build PASS on the
preserved iPhone 17 Pro Max / iOS 27 simulator. The repository's existing provenance xattr required
the established generated-test-bundle ad-hoc-sign workaround. Human interaction acceptance remains
separate.

## v0.7 checkpoint — delegated requests and allowance management

Status: **ENGINEERING VERIFIED — commit/push pending**

Requests now expose their full canonical lifecycle in the production UI. A requester can cancel a
pending request after explicit confirmation or revise and resubmit a changes-requested item without
losing its decision history. New requests carry a 30-day server-authoritative expiration; expiration
is versioned, recorded as a system action (without fabricating a human actor), and prevents later
approval/cancellation. Existing requests remain valid because migration `0025_request_lifecycle`
does not retroactively invent an expiration date. Approval continues to be the only request action
that moves money, atomically transferring exact minor units between authorized categories.

Owners with allowance authority now have a production management surface for creating weekly or
calendar-month plans, choosing rollover/use-it-or-lose-it behavior, viewing exact split destinations
and issuance history, issuing a due plan, pausing it, and reactivating it. Paused plans remain visible
only in the authorized management query, disappear from the recipient's active list, and do not move
money or affect forecast. Creation and status changes are money-neutral; Issue Now calls the existing
allocation application service with optimistic allocation-version protection. Recipient payloads
continue to redact the funding source, while owner selectors derive only from already-authorized
workspace resources.

Focused request, allowance, access, and migration tests PASS (23). The Xcode 27 Beta unsigned build
PASS on the preserved iPhone 17 Pro Max / iOS 27 simulator. Migrations `0024` and `0025` remain
source-only and were not applied to the human Live database.

## v0.7 checkpoint — guided onboarding and product education

Status: **ENGINEERING VERIFIED — commit/push pending**

The production workspace now offers an optional seven-part guide for an owner’s genuinely empty
budget. It teaches accounts as money location, Plan as purpose, posted activity, money movement,
targets/schedules/cards/reconciliation, forecast-versus-current money, and Insights. Every lesson
states its financial consequence before routing to the existing production tab; the guide itself
never creates or changes authoritative accounts, balances, allocations, schedules, or transactions.
Populated and delegated budgets are not interrupted.

Progress is scoped to the member and budget, survives workspace reconstruction, can be skipped and
resumed, and can be restarted after completion from Profile & Settings. Reduced Motion avoids the
lesson transition animation, while native semantic headings, labels, hints, Dynamic Type, scrolling,
and VoiceOver accessibility remain available. A production-composition XCUITest caught and drove a
fix for an initial Continue-versus-Restart wiring error, then passed the complete automatic-present →
advance → skip → Profile resume → production Plan route on Xcode 27 Beta and the preserved iPhone 17
Pro Max / iOS 27 simulator. A native XCTest proves persistence and financial-state neutrality.

## v0.7 engineering closure

Status: **ENGINEERING COMPLETE — human acceptance remains separate**

The final closure audit found no additional application defect. The complete backend suite collected
267 tests and passed 256 with the 11 intentionally PostgreSQL-gated cases skipped. Those 11 cases then
passed against a new isolated PostgreSQL 17 cluster whose schema was built through the complete Alembic
graph. Migration/invariant/golden coverage passed (28 tests), Swift passed (27 BudgetCore + 43
BudgetAPI), native XCTest passed (77/77), and production XCUITest passed (32/32). The latter covered
real workspace/tab composition, dark accessibility text, onboarding, household policy editing,
attachments, browser/bulk operations, schedules, transaction lifecycle, charts, and canonical editors.

The restricted-resource privacy matrix also passed across discovery, selectors, transaction counts,
aggregates/filters, payees, attachments, targets, allowances, delegated actions, and ID-addressed
operations. `V0.7-CLOSURE-AUDIT.md` records the exact evidence and consolidates the remaining human work
into five end-to-end flows. Migrations `0023`–`0025` remain unapplied to the human Live database. No
merge, tag, release claim, Simulator reset, or human-data mutation occurred.

## v0.8 checkpoint — type-appropriate debt-terms contract

Status: **ENGINEERING VERIFIED**

Optional debt planning terms now have a first-class one-to-one account record rather than being
embedded in balances or inferred from account names. Credit cards support exact basis-point APR,
fixed/variable rate, monthly due/cycle data, fixed/percentage/greater-of minimum-payment rules, and an
optional promotional rate/end date. Installment loans support exact basis-point APR, fixed/variable
rate, weekly/biweekly/monthly scheduled payment, due day, original principal, and original/remaining
term. Type validation prevents either product from accepting the other product's fields.

Incomplete terms are valid and return explicit `projection_ready` plus named missing inputs; no APR,
payment, term, or projection is guessed. CRUD uses the existing account capability/resource scope,
hidden accounts remain non-disclosing, and terms are included in structured backup export. Editing or
removing terms does not touch transactions, balances, reconciliation, allocations, card reserves, or
Ready to Assign. Migration `0026_debt_terms` is source-only and was not applied to human Live data.

Account Settings now opens the shared production Debt Terms editor for visible credit-card and loan
accounts. It uses exact editable currency buffers and basis-point conversion, supports partial saves,
states projection readiness without inventing results, and resolves Live credentials at request time;
Demo uses the same view and an isolated in-memory adapter. Focused production XCUITest PASS for
Accounts → Auto Loan → Account Settings → Debt Terms → save → reopen/persist. Swift PASS (27
BudgetCore + 44 BudgetAPI), native XCTest PASS (77/77), the Xcode 27 Beta simulator build PASS, focused
backend/migration PASS (11), and the full backend gate is recorded with the final checkpoint. The
Xcode Beta runner again stalled only while collecting diagnostics after reporting the complete green
native/UI result, so its finalizer was stopped without erasing Simulator data.

Final full backend result: 270 collected, 259 passed and 11 explicitly PostgreSQL-gated skips. The
11 genuine PostgreSQL contention cases were already run and passed against the isolated PostgreSQL 17
closure cluster; no test silently substituted SQLite for concurrency behavior.

## v0.8 checkpoint — authoritative recorded-interest history

Status: **ENGINEERING VERIFIED — commit/push pending**

Actual interest is now an explicit nullable `interest_charge` financial classification on posted
transactions and split portions. Migration `0027_interest_class` leaves every historical row
unclassified, so payee, category, and memo text never manufacture history. Classification is carried
through the canonical create/edit/duplicate/schedule/realization/void/reversal paths and changes no
ledger amount, category activity, Ready to Assign, card reserve, clearing, or reconciliation rule.
Only credit-card and loan activity can be classified.

Debt Insights now separates Recorded Interest from debt balance observations and reports the selected
range, current month, year to date, trailing 12 months, first visible classified date, and authorized
account contributions in exact minor units. Voids net through their classified reversal rather than
double counting. The server filters visible debt accounts before loading or aggregating transactions;
direct hidden account filters continue to return a non-disclosing 404. Transaction search has a
server-authoritative Interest Charges filter. Transaction entry/edit/detail expose the classification,
including split portions, without complicating ordinary cash-account entry.

The deterministic provider contains an explicitly classified fixture and preserves classification
through its canonical mutation, schedule, realization, duplicate, reversal, browser, and report
adapters. Its older loan-payment memo intentionally remains unclassified, proving Demo does not use
text heuristics. Migration `0027` is source-only and was not applied to human Live data. The ordered
unapplied human-Live chain is `0023` → `0024` → `0025` → `0026` → `0027`.

Verification completed on Xcode 27 Beta build `27A5252f` with the preserved iPhone 17 Pro Max / iOS
27 simulator (`3ABD861E-D38D-4AFD-A356-959266051564`): full backend PASS (274 collected, 11
PostgreSQL-only skips), Swift package PASS (27 BudgetCore + 44 BudgetAPI), native XCTest PASS
(78/78), focused production-composition XCUITest PASS, simulator build PASS, the single-head Alembic
graph PASS, and `git diff --check` PASS. The UI regression reaches the real Insights shell and proves
the explicitly classified Demo posting contributes exactly `$32.00`; a text-only historical memo is
still excluded. Human Live data and Simulator data were not reset or migrated.

## v0.8 checkpoint — exact single-debt payoff engine

Status: **ENGINEERING VERIFIED — commit/push pending**

The provider-neutral projection boundary now exists in both the authoritative server domain and
BudgetCore for deterministic/future Local providers. APR is an integer basis-point rate; each period
accrues `principal × basis points / (10,000 × periods per year)`, rounds half-up once to a minor unit,
then applies an end-of-period payment. Weekly uses 52 periods, biweekly 26, and monthly 12. Final
payments are capped to principal plus interest, loops are bounded to 1,200 periods, and payments that
do not exceed accrued interest return `non_amortizing` with no invented payoff date.

The account-scoped server contract reads the authorized account balance and persisted debt terms,
accepts only ephemeral first-payment and extra-payment scenario inputs, and returns incomplete fields,
payoff date/count, projected interest/total cost, and the exact principal/interest/payment trajectory.
Scenario requests write neither ledger nor terms. Golden coverage includes zero and high APR,
insufficient payment, fixed/percentage/greater-of card rules, weekly/biweekly/monthly calendars,
month-end/leap-year boundaries, promotional-rate transition, final partial payment, explicit iteration
bounds, and +$50/+100/+250 scenarios. Focused server and matching BudgetCore vectors PASS.
Full backend PASS (286 collected with 11 PostgreSQL-only skips), Swift package PASS (29 BudgetCore +
44 BudgetAPI), and `git diff --check` PASS.

## Product checkpoint — application appearance

Status: **ENGINEERING VERIFIED**

Profile & Settings now owns an Appearance destination with System, Light, and Dark choices. System is
the default and leaves the root color scheme unset so live iOS changes propagate; Light and Dark are
applied once at the application composition root. The preference is intentionally device-local
presentation state in UserDefaults—not budget data, not user-synced server state—and remains separate
from Hide Amounts and its app-switcher shield. A native persistence test and an isolated production-
composition XCUITest covering Dark → terminate/relaunch → Light → System PASS on Xcode 27 Beta without
changing the human's real preference domain or erasing Simulator data. No migration is required.

## Product checkpoint — friendly Insights hub

Status: **ENGINEERING VERIFIED**

The former all-reports-at-once Insights list is now a concise Financial Snapshot and four native
destinations: Spending & Income, Plan Performance, Net Worth, and Debt & Interest. Detailed charts,
range controls, exact rows, drill-through, empty states, and CSV report export live on their relevant
focused screen. Debt & Interest contains Overview / Interest / Payoff progressive disclosure, so the
remaining v0.8 projection and strategy experience has a bounded home rather than expanding the hub.

`V0.8-INSIGHTS-AUDIT.md` records every current metric/chart, API and authoritative data source,
calculation meaning, filter/date semantics, permission behavior, drill-through, empty state, chart
axes, and cross-report invariants. It also records one honest performance gap: detailed chart views are
no longer constructed at the hub, but the current workspace snapshot still hydrates report payloads
together, so request-count reduction requires a later repository-contract change.

Xcode 27 Beta verification on the preserved iPhone 17 Pro Max / iOS 27 simulator: build PASS, native
XCTest 79/79 PASS, focused hub/report/debt progression XCUITest PASS, recorded-interest focused
XCUITest PASS, accessibility Dynamic Type navigation coverage updated, Swift package PASS (29
BudgetCore + 44 BudgetAPI), and `git diff --check` PASS. No backend or migration changed.

The whole-app source audit found no hardcoded white/black backgrounds or text. The only fixed RGB
values were the shared accent/healthy/attention/danger palette; those now use adaptive system teal,
green, orange, and red while retaining labels and SF Symbols so meaning is not color-only. The focused
Dark Mode + accessibility-size hub navigation test PASS. Hide Amounts remains orthogonal and unchanged.
