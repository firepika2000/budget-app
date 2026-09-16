# Overnight Engineering — Morning Handoff

This is a durable, incrementally updated handoff for the autonomous run beginning 2026-09-16.
It records engineering evidence separately from human acceptance and does not authorize a merge,
tag, or release.

## Repository checkpoint

- Current branch: `codex/development`
- Overnight starting HEAD: `f44c38f9a163e32133f3ca4c7108ad488db2f836`
- Current/remote HEAD: `d048b5fa0f427d0e4c21901d162cff9e07d169e8` before the Git-hygiene checkpoint
- Push status: all v0.6 checkpoints through report calendar boundaries are pushed
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

Status: **ENGINEERING VERIFIED — commit/push pending**

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

Status: **ENGINEERING VERIFIED — commit/push pending**

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
