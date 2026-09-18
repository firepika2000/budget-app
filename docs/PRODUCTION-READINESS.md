# Production readiness mission ledger

Updated: 2026-09-18. Active branch: `codex/development`.
Mission starting checkpoint: `e3f2922`. Production release readiness: **IN PROGRESS**.
Human acceptance: **HUMAN REQUIRED — HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

This ledger tracks engineering evidence separately from release approval. Main remains at
`c5494dd`; historical version tags do not establish acceptance for subsequent development.
Checkpoint completion is followed by the next unblocked engineering task.

| Gate | Status | Evidence and remaining work |
|---|---|---|
| PRODUCT | IN PROGRESS | v0.4–v0.7 history is preserved in existing acceptance/closure documents. v0.8 terms, interest classification, projections, strategies and payoff UI exist. Complete v0.8 review before planning/import/local-provider work. Reconcile older roadmap numbering with the approved mission explicitly. |
| FINANCIAL | IN PROGRESS | Eleven shared strategy vectors now include paid-off parity; checked Int64 projection arithmetic and HTTP 422 boundaries passed backend/native/package regressions. Release-wide financial reconciliation and migration/recovery proof remain open. |
| SECURITY | IN PROGRESS | Server capability/resource guards and regression suites exist. Extend adversarial matrix across reports, projections, imports and future providers; rerun relevant PostgreSQL/privacy gates. |
| DATA | IN PROGRESS | Source migration chain ends at `0027_interest_class`; human Live remains at `0020_payee_identity_repair`. Repeat populated upgrade and encrypted attachment-inclusive restore into disposable destinations. Production Local Device storage remains open. |
| RELIABILITY | IN PROGRESS | Credential authority is shared by long-lived Live services. Existing native/backend suites provide regression evidence; concurrency, offline failures, cancellation and release-wide regression remain open. |
| PERFORMANCE | IN PROGRESS | Live core hydration now makes zero detailed-report requests instead of seven; native HTTP tests cover caching/invalidation/retry. Hub uses one bounded scalar summary. Server/Demo computation, category/account fan-out and representative wall-clock measures remain open. |
| UX | IN PROGRESS | Shared shell, onboarding, scalable payee selection and focused Insights exist. Report filters are reachable again; missing debt terms open the shared editor. Demand-loaded reports have independent loading/error/retry. Full workflow/accessibility closure remains open. |
| ACCESSIBILITY | IN PROGRESS | Existing accessibility-sized/dark-mode navigation tests passed at earlier checkpoints. Repeat on changed report screens; audit VoiceOver amounts, charts, controls and custom ordering. |
| PLATFORM | IN PROGRESS | Xcode 27 Beta and existing iPhone 17 Pro Max/iOS 27 are required. Preserve Simulator data. Release configuration, lifecycle, platform scope and Apple integrations need closure. |
| COMMERCIAL | BLOCKED | HUMAN PRODUCT DECISION REQUIRED: paid download versus free Demo plus non-consumable Lifetime Unlock. Preferred documented hypothesis is the latter; it adds restoration/offline/revocation complexity while allowing evaluation. Paid download reduces entitlement complexity but prevents pre-purchase evaluation. No StoreKit implementation before decision. Independent engineering continues. |
| APP STORE | IN PROGRESS | Commercial strategy includes positioning and draft screenshot narrative. Verify current Apple primary sources when preparing privacy/distribution artifacts. Signing, developer enrollment, final identity/pricing and submission remain human/external actions. |
| OPERATIONS | IN PROGRESS | Developer launcher and advanced server documentation exist. Audit production deployment, migration/recovery, attachment key backup, monitoring and normal-user server management. |
| HUMAN ACCEPTANCE | HUMAN REQUIRED | Preserve prior accepted workflows; consolidate only changed/unverified workflows later. No claim of new human acceptance from automation. DO NOT RETEST during autonomous run. |

## Current execution order

1. Finish v0.8: demand-loaded reports with current credentials, correct cache invalidation and
   visible loading/retry states; exact projection edge cases; report/privacy/accessibility audit.
2. Complete broad v0.8 automated closure, including disposable PostgreSQL migrations/recovery.
3. Reconcile roadmap sequencing with the approved planning/import/local-data mission, preserving
   the existing normal-user server distribution requirement and financial invariants.
4. Continue the highest-priority unblocked engineering gate through release-candidate readiness.

## Human data and migration ledger

Never run migration, destructive, scale or restore tests against human Live. Known unapplied chain:
`0021_scheduled_payee_id` → `0022_report_query_indexes` → `0023_category_favorites` →
`0024_member_lifecycle` → `0025_request_lifecycle` → `0026_debt_terms` → `0027_interest_class`.
Recheck the source graph before migration work. Use disposable populated PostgreSQL databases and
restore to new destinations. Preserve human attachments, transactions and reconciliation history.

Native toolchain: `/Users/firepika/Downloads/Xcode-beta.app/Contents/Developer`.
Preserved Simulator UDID: `3ABD861E-D38D-4AFD-A356-959266051564` (reverify runtime before use).

## Checkpoint evidence

- `50ec90a`, `4b6f5be`, `bfeff14`: exact multi-debt engine, authorized projection endpoint and
  shared native scenario UI. Earlier verification is recorded in the development handoff;
  it is not a fresh release-wide result.
- `d7a702d`: shared strategy vectors; focused Python 18 passed, Swift projection 6 passed.
- `e3f2922`: strategy evidence and static Insights hydration baseline documented.
- Paid-off strategy boundary correction: the new shared `all_debts_already_paid` fixture first
  reproduced Python returning `non_amortizing`/1,200 payments while Swift returned paid off.
  Python now returns paid off, zero payments, zero cost and the scenario start date. Eleven shared
  vectors pass; focused Python 18 passed, Swift projection 6 passed on Xcode Beta; full backend
  suite passed with the 11 explicitly PostgreSQL-gated cases skipped. No migration required.

Engineering-controlled gates are not all PASS. This is not yet an App Store release candidate.

Recorded-interest privacy checkpoint: the HTTP regression reproduced hidden-category and mixed-split
interest contributing to a restricted member's totals (13,000 instead of 1,000 minor units). The
report now applies transaction category visibility before every interest aggregate and coverage date,
while preserving independently authorized account balances. Analytics/delegation tests: 68 passed.
Full backend regression passed; 11 PostgreSQL-only concurrency tests remain explicitly skipped in
this run and require the disposable PostgreSQL closure gate. No Swift or migration changes.

Payoff recovery checkpoint: the production screen now opens the shared Debt Terms editor from
missing inputs and account actions, then recalculates after dismissal. Native UI verification
exposed and corrected a lazy-section sheet presenter and Demo's accidental inheritance of Net
Worth's tracking filter. Debt reporting now includes authorized tracking loans and stable history
regardless of that toggle, matching Live. Native XCTest: 82 passed, including money-neutral terms
recovery and tracking parity; production recovery XCUITest: 1 passed; Swift package: 33 BudgetCore
and 45 BudgetAPI passed. Simulator test builds succeeded with Xcode 27.0 (`27A5252f`) on the preserved
iOS 27 iPhone 17 Pro Max. Human acceptance remains pending. No migration required.

Projection input-hardening checkpoint: checked Swift arithmetic now rejects overflowing statements,
payments, accumulated totals and rollover pools with a localized error. Python enforces the same
Int64 money boundary and the Live API returns 422 without mutation. Maximum-value zero-rate payoff
remains exact. Duplicate unused custom-order values no longer trap the non-custom Swift strategies.
Verification: 20 focused backend projection/vector tests; full backend 284 passed, 11 PostgreSQL-only
skips (295 collected); full package 35 BudgetCore + 45 BudgetAPI passed; native 82 passed with Xcode
`TEST SUCCEEDED`; diff whitespace check passed. No migration or human data changes.

Focused-report contract preparation: selected report kinds now have a provider-neutral read
contract. Live requests only those endpoints and resolves current credentials for each read;
Demo retains its canonical report definitions and explicit workspace planning-month context.
The native regression verifies empty selection performs no requests and debt-only reads use
token A then rotated token B on the same workspace, without loading other reports or core data.
Ordinary hydration STILL requests all reports: demand activation, cache invalidation, independent
loading/error states, and measured launch-request reduction remain IN PROGRESS. This preparatory
checkpoint is not evidence of completed lazy loading.
Verification: native XCTest emitted 83 passes/zero failures on the preserved iOS 27 simulator;
Xcode's result-finalization process remained pending after tests completed (not reported as a clean
command exit). Full package passed 35 BudgetCore + 45 BudgetAPI using isolated temporary build
output; the first workspace-build attempt failed code signing on Finder metadata. No backend
code changed. Whitespace checks passed.

Insights filter reachability correction: the hub refactor left the existing Report Filters form
without a presentation trigger. Restored a labeled native toolbar action, active-filter icon,
and sheet using the same workspace store. No accounting/filter contract changed. Production
XCUITest verifies opening the form, applying a tag, reopening with the same context, resetting,
and reaching the sector chart through normal navigation. This is automated evidence, not human
acceptance; human acceptance remains consolidated and pending.

Demand-loading activation (supersedes the preparatory eager-hydration note): core Live workspace
activation now issues zero detailed report calls. Screens load selected authoritative payloads;
cache scope includes date/filter query, planning month, core refresh revision and credential
revision. Concurrent same-kind reads share an in-flight task; results from obsolete contexts are
not published. A failed report has an explicit retry and cannot block core workspace hydration.
Report-backed destination identity is retained while its readiness is invalidated after refresh.
The Insights hub still loads four detailed payloads on entry, and Demo still calculates local
canonical snapshot reports before selecting its payload. A lightweight summary and Demo CPU
optimization remain open; no claim of completed performance gate or production readiness.
Verification: 84 native XCTest cases and three production XCUITests passed on final source
(hub navigation, filter apply/reopen/reset, and missing-terms editor recovery). An old UI assertion
still expected the removed payoff placeholder; it now verifies the actual strategy control and
Avalanche option. Swift package remains 35 BudgetCore + 45 BudgetAPI passed. Filter-sheet typing
is suspended from report loading; hidden loading content has hit testing disabled. Payoff task
identity now includes workspace and credential revisions. No financial semantics or migrations
changed. Xcode result-finalization delays remain separately recorded, not claimed as test failures.

Disposable PostgreSQL closure progress: a newly initialized PostgreSQL 17 cluster on a private
temporary Unix socket (no TCP listener) passed all 11 concurrency tests, including Alembic migration
to the current head. No human database connection was used. Full backend with these gates enabled
and populated restore proof continue separately.

Restore key-safety correction: a failing regression proved the script previously accepted a
destination with a different attachment key and mutated data before its misleading post-restart
warning. Restore now compares validated recovery configuration to the explicit destination before
SQL/object writes, never sources/prints secret material, and refuses a mismatch. SQL runs in one
transaction with stop-on-error. Matching dedicated and legacy JWT-derived configurations remain
supported. Focused script tests: 7 passed, including malformed material and mismatch/no-write.
Full backend after the correction: 296 passed, zero skips with disposable PostgreSQL enabled;
two further test-only recovery cases passed in the focused rerun. Shell syntax and diff checks
passed. Docker and age are not installed in this environment: real encrypted Compose recovery
remains unproven; fake-tool script tests are not represented as end-to-end encryption proof.
The earlier full backend before this correction also passed all 295 tests, zero skips.

Real recovery proof added: `test_pg_recovery.py` dumps the migrated disposable PostgreSQL source
and restores into a newly generated database, then compares every model-table row and financial
API observations. Fixture includes assignments, funded credit reserve, transfer, reconciliation,
payees, schedule, member grant, debt terms and encrypted receipt. Restored receipt hash matches;
wrong-key and tampered-ciphertext reads fail authentication, while the source copy is unchanged.
The generated destination is removed after verification; no existing destination is overwritten.
This is real PostgreSQL/AES-GCM evidence, not a claim about the unavailable Docker/age envelope.
Final verification for that checkpoint: full backend **299 passed, zero skips**, including all
12 PostgreSQL concurrency/recovery cases; focused populated recovery passed; diff checks passed.

Hub summary checkpoint: `/reports/summary` consolidates the four hub payloads into six fields,
reusing canonical authorized income/net worth/debt/resilience calculations rather than duplicating
financial definitions. No transaction IDs, chart points, account/category names or counts are
returned. The fixture response is under 512 bytes; hidden account filters reject, category-scoped
interest stays private, and balance-dependent fields are null without balance permission. This
reduces transport and decoding, not yet internal server report computation. Demo derives identical
observations from its canonical report snapshot. Native cache/request-count coverage confirms a
single summary route and no detailed income/net-worth payload on hub entry. API tests preserve
9,007,199,254,740,993 minor units exactly and forward all applicable filters/current credentials.
Updated server and app must be deployed together for this endpoint; no new migration is introduced.
Human Live remains unchanged and acceptance remains pending—DO NOT RETEST during this run.
Verification: focused analytics 57 passed; full backend 300 passed/zero skips with disposable
PostgreSQL; package 35 BudgetCore + 46 BudgetAPI passed; native 84 passed; three production UI tests
passed (focused navigation, filter context, Dark Mode/accessibility-sized report reachability).
Simulator build succeeded; Xcode result finalization was pending after test completion. No human
acceptance or comprehensive VoiceOver sign-off is claimed.

Representative summary baseline (`test_report_scale.py`, disposable SQLite, same production HTTP
route): 10 posted transactions over the selected multi-year range produced 150 bytes / 44 SQL
statements / 0.0193s; 10,000 produced 156 bytes / 82 SQL statements / 0.8025s on this Mac. The test
gates bounded payload and absence of per-transaction SQL fan-out, not elapsed time. Select-in split
batches explain bounded query growth; no machine-independent latency guarantee or PostgreSQL load
benchmark is claimed. Source data was synthetic and never written to human Live.

Debt-report completeness correction: the previously listed all-recorded interest metric was
missing from the contract. It now sums only authorized explicit classifications through the
selected end date, including prior years; future-to-that-observation rows are excluded. Demo's
coverage date now respects the same cutoff. The UI labels this “All recorded through [date]” and
retains the incomplete-history disclosure, not a claim about unrecorded lifetime finance charges.
Debt Overview/Interest now expose the shared period selector. Custom dates use draft state until
Apply; period changes load reports without rehydrating unrelated workspace resources. Report
errors offer an explicit range/filter reset, proven money-neutral, so invalid selections have a
recovery path. Legacy debt JSON omitting the new field decodes as unknown, never fabricated zero.
Verification: analytics 58 passed; full backend 302 passed/zero skips (PG enabled); package 35 Core
and 46 API; final native 85 passed and three production UI cases passed. Xcode finalization remained
pending after suite completion. No new migration and no human data changes.
