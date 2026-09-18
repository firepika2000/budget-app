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
| FINANCIAL | IN PROGRESS | 23 shared single/multi-debt vectors include paid-off parity, horizon/high-APR boundaries, explicit rate transitions and calendar rounding; checked Int64 arithmetic and HTTP 422 boundaries pass. Current-cost estimates remain distinct from recorded and projected values. Release-wide invariant review remains open. |
| SECURITY | IN PROGRESS | Server capability/resource guards and regression suites exist. Extend adversarial matrix across reports, projections, imports and future providers; rerun relevant PostgreSQL/privacy gates. |
| DATA | IN PROGRESS | Source head is `0027_interest_class`; human Live remains at `0020_payee_identity_repair`. Populated PostgreSQL migration/concurrency and real age-encrypted new-destination restore prove canonical equality and encrypted attachment integrity/wrong-key/tamper handling. Complete manifest preflight passes. Real Docker/Compose recovery and production Local Device storage remain open. |
| RELIABILITY | IN PROGRESS | Credential authority is shared by long-lived Live services. Existing native/backend suites provide regression evidence; concurrency, offline failures, cancellation and release-wide regression remain open. |
| PERFORMANCE | IN PROGRESS | Live core hydration now makes zero detailed-report requests instead of seven; native HTTP tests cover caching/invalidation/retry. Hub uses one bounded scalar summary. Server/Demo computation, category/account fan-out and representative wall-clock measures remain open. |
| UX | IN PROGRESS | Shared shell, onboarding, scalable payee selection and focused Insights exist. Report filters are reachable again; missing debt terms open the shared editor. Demand-loaded reports have independent loading/error/retry. Full workflow/accessibility closure remains open. |
| ACCESSIBILITY | IN PROGRESS | Historical large-text launch strings were invalid and did not prove the claimed size; corrected tests use UIKit's actual raw value and require the adaptive debt menu. Description/trait audits pass for Cost and debt observations. Full VoiceOver, chart and release-wide accessibility closure remain open. |
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

Projection parity expanded with six hand-calculated single-debt vectors consumed directly by
Python and BudgetCore: monthly leap-day/final partial payment, weekly and biweekly leap crossings,
explicit promotional expiry, half-cent rounding, and payment-equals-interest non-amortization.
Every payment date, interest amount, payment amount and remaining principal is asserted, alongside
totals/status. Together with the 11 strategy vectors this gives 17 shared cases. Focused Python
projection/vector tests: 21 passed; full Swift package: 36 Core + 46 API passed. No engine semantics
changed. Broader production UI suite is running separately and its failures are not hidden by this
financial-test checkpoint.

Debt projection privacy coverage now compares the entire visible response before/after removing a
hidden debt's terms: no incomplete status, count, payoff date/order or aggregate changes are allowed.
Hidden, cross-budget and nonexistent IDs are tested through both strategy selector fields and the
individual projection route with indistinguishable resource errors. Revoking balance capability on
the same session blocks both routes despite retained report access. All 19 focused projection tests
pass. No production change was needed for these additional adversarial cases.

Further v0.8 review proved a promotional-rate projection defect: the Live multi-debt adapter
discarded saved promotional terms, yielding 153 cents instead of the hand-calculated 51 cents.
Both engines now apply the explicit promotional APR through its inclusive expiry date, recalculate
avalanche priority per month and avoid prematurely declaring permanent non-amortization before an
explicit future rate transition. Three shared vectors cover expiry, changing priority and a temporary
non-amortizing period. The suite now contains 20 shared single/multi-debt vectors.

The Demo adapter also used an unnormalized raw payment, ignored percentage minimums and treated
partial terms inconsistently. Its fixed monthly scenario budget now uses the same exact first-payment
normalization as Live; readiness reflects missing fields. Shared financial truth remains unchanged.
The UI discloses monthly normalization and known-versus-unknown rate assumptions, labels payoff values
individually as projected, and labels historical debt with its observation date and net debt change
rather than claiming a historical balance is current or a balance difference is principal payments.
Verification so far: 23 focused projection/vector tests; full backend **305 passed, zero skips**
(disposable PostgreSQL enabled); package **37 Core + 46 API passed**. Native final verification:
**86 XCTest + two production debt UI tests passed**, Simulator build and final **TEST SUCCEEDED**.
`git diff --check` passed; no new migration, no human data changes and no human acceptance claim.

Broad UI investigation: 35/37 selected cases passed initially. The debt-terms test appended values
to newly prefilled fields; it now explicitly replaces and verifies different persisted values. The
unmodified Plan relaunch test timed out at the exact start of host Maintenance Sleep. Both focused
reruns passed (49 seconds combined), and Xcode finalized **TEST SUCCEEDED**. Initial failure evidence
is retained, not retroactively reported as a green broad run. Two preference-changing UI cases were
excluded to preserve human state. A temporary test-process idle-sleep assertion changes no permanent
power settings. QuartzCore diagnostics remain visible; this sleep correlation does not establish a
new application defect or a blanket explanation for every runtime warning.

Single-debt rate-transition follow-up: a new shared fixture first reproduced a premature permanent
`non_amortizing` result while an explicit saved rate drop would permit repayment. Both engines now
continue through a known rate transition, retaining the 1,200-period bound; unchanged-rate insufficient
payments still return non-amortizing. The 21st shared vector asserts every date, payment, interest and
remaining balance. Verification: 23 focused Python tests, full backend **305 passed / zero skips**,
Swift **37 Core + 46 API**, native **86 XCTest**, Simulator build and **TEST SUCCEEDED**. No UI,
schema, migration, authorization or posted accounting behavior changed in this follow-up.

Estimated current cost is now a separate Cost section in the shared Debt & Interest destination.
`GET reports/debt-cost` uses canonical current visible balances, explicit effective APR (including
promotional expiry), and the same exact half-up APR/12 helper as the monthly strategy engine. It is
labelled an unchanged-balance approximation, not a charge prediction; daily balances, grace periods,
fees, actual weekly payment timing and unknown future rates are not fabricated. Unknown APR remains
null; zero APR is an exact zero. Missing payoff payment/due inputs do not prevent this limited estimate.
Visible cash-only filters return an empty debt list; hidden/cross-budget/missing IDs return equivalent
404s, absent grants are denied and revoked balance capability returns 403. Canonical balances are
batched rather than loading transaction history or one query per account. No persistence is changed.

Demo shares the exact helper and fixture clock. Live uses the current credential after rotation.
The UI provides loading/error/retry, empty/unknown states, a shared authorized terms editor, account
drill-through and explicit estimated accessibility labels. Changing report kinds is now part of the
loading task identity, avoiding an unloaded destination after switching modes. Verified: 26 focused
backend/domain tests; 38 Core + 47 API; 87 native XCTest; three production debt UI cases. The final
Cost UI rerun also passed Apple's sufficient-description/trait accessibility audit without filtering
issues. This is not comprehensive human VoiceOver acceptance. Final backend: **308 passed, zero
skips**, including disposable PostgreSQL. Simulator build and `git diff --check` pass.
Matching app/server deployment is required for the new route; no new migration, no human Live update.

Production chart checkpoint: the Debt Overview now includes the canonical recorded-history chart;
the old chart was stranded in an unused view. Runtime UI coverage navigates the real workspace,
verifies the rendered chart, expands exact observations and audits description/traits. Currency
axes and bounded real-date ticks replace raw minor-unit/default ticks on five time-series reports.
Debt marks announce exact dated currency values; chart accessibility respects Hide Amounts.
Final screenshot and accessibility hierarchy confirm this behavior. Final native run: **87 XCTest
+ four production UI tests PASS**, build and `git diff --check` PASS. No backend/package changes;
the latest **308 backend / zero skips, 38 Core + 47 API** remain applicable.

Accessibility evidence correction: earlier tests used an invalid literal content-size argument,
which did not actually select accessibility text size. Those prior results must not establish
large-text acceptance. UIKit's real accessibility-extra-extra-extra-large value now drives both
Home and Insights tests, which pass without weakening reachability assertions. The debt selector
uses a native menu at accessibility sizes. An ancestor DisclosureGroup identifier also masked
individual observation identifiers in XCTest; removing it restores distinct exact-row targets.
These are automated results, not human VoiceOver acceptance. **DO NOT RETEST** remains in effect.

Payoff boundary review proved `iteration_limit` fell through to the completed-payoff UI, mislabelling
partial payments as total payoff cost. It now has an explicit horizon-reached section with only
modeled-period interest/payments and no full-payoff date or savings comparison. Unknown future statuses
also fail closed rather than looking complete. A production UI regression edits real Demo terms to
zero APR / one-cent payment, disables rollover and verifies this state. A shared 1,201-cent horizon
vector and a high-valid-APR exact final-payment vector bring the shared fixture total to **23**.
Focused Python **23 pass**, Swift **38 Core + 47 API pass**, native **87 XCTest pass**, ordinary
payoff UI pass and final horizon UI pass/build **TEST SUCCEEDED**. The initial new UI attempt tapped
the switch label without toggling it; targeting its native control fixed the test while retaining
the same value assertion. Existing invalid-frame diagnostics during keyboard focus remain visible
and unproven, not suppressed. No backend engine, financial persistence, migration or human data changed.

Multi-series chart accessibility follow-up: captured Swift Charts hierarchy proved grouped ranges
still announced raw minor-unit numbers despite individual mark labels. Native `AXChartDescriptor`
currency axes plus exact virtual point children now cover all five time-series report families.
Derived Double values are confined to audio/visual geometry; exact labels use original Int64 values.
Descriptor tests cover positive/negative values, Int64.max labels, non-finite geometry rejection and
removing stale data on privacy/context updates. A production UI journey verifies currency values on
Income, Spending Trends, Net Worth and Plan charts; the debt observation/audit test also passes.
Final result: **88 native XCTest + two UI tests PASS**, Beta build and TEST SUCCEEDED. Full backend
closure run: **308 passed, zero skips**, including PostgreSQL recovery/migrations/concurrency. Latest
package **38 Core + 47 API** remains unchanged. Initial UI failures exposed wrapper identifier scope
and the test's incorrect report traversal order; corrected tests retain all currency assertions.
Apple's native [audio graph documentation](https://developer.apple.com/documentation/accessibility/representing-chart-data-as-an-audio-graph)
and the installed Beta SDK contract informed the descriptors. Human VoiceOver remains pending.

Recovery preflight review reproduced a real defect: a backup whose checksum manifest omitted
`database.sql` still reached restore. The archive helper now requires one digest for every payload
file, validates safe member names/types, rejects duplicates/links/special files and collisions, checks
staging capacity, and writes only a private empty staging directory before any destination contact.
Backup hashing includes nested/hidden objects without fallback; encryption failures publish no final
archive, and atomic publication refuses an existing backup name. Python 3.10+ standard-library
preflight is now an explicit advanced-host prerequisite. Focused regressions also preserve a sentinel
outside staging and prove nonempty destinations are not overwritten. Real outer age proof is the next
step: age 1.3.2 was installed as a development dependency; Docker remains unavailable. No human data
was accessed or restored. These preflight checks do not yet prove cross-resource atomic replacement
of an existing database plus attachment volume; prefer new-destination recovery and retain that gate.
Verification: **319 backend tests passed, zero skips**, including disposable PostgreSQL; 18 backup
script cases, shell syntax and `git diff --check` pass. Swift/native code did not change in this checkpoint.

Real encryption checkpoint: actual age 1.3.2 passphrase operations now run through a disposable
controlling terminal, without an unsupported secret environment bypass. Roundtrip, incorrect
passphrase and ciphertext corruption are covered; failures never contact the recovery target.
The populated PostgreSQL recovery fixture now also packages real plain SQL, ciphertext objects,
key recovery and a complete manifest, encrypts/decrypts with age, validates with the production
helper, and restores into a generated new database. All rows, canonical API observations and
attachment download/hash equality pass. Both plaintext and encrypted recovery variants pass.

This real test exposed macOS tar manufacturing unmanifested AppleDouble files. Per-command
`COPYFILE_DISABLE=1` prevents those archive-only sidecars; source attributes are untouched. The
ordinary script test now validates its own output, not merely a separately assembled archive.
One terminal hang was confined to the Docker test double reading stdin for commands that consume
no input; it was corrected without a production delay/workaround. Final **323 backend tests pass,
zero skips**, including 21 age/script cases and both real PostgreSQL recovery variants. Shell syntax
and diff check pass. Docker remains a double for orchestration, so no Compose execution is claimed.
Next: ensure replacement failure cannot expose a database/attachment mismatch; enforce the mission's
new-destination recovery safety rather than erase an existing destination's objects.
