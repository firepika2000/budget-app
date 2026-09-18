# Overnight Engineering — Morning Handoff

This is a durable, incrementally updated handoff for the autonomous run beginning 2026-09-16.
It records engineering evidence separately from human acceptance and does not authorize a merge,
tag, or release.

## 2026-09-18 — current production-readiness continuation

Allocation version parity after `1b91b7c`: Demo now starts at zero for a fresh budget, builds its
fixture version from dated operations, and checks assignment/move tokens before mutation (including
stale no-ops). Current no-ops do not add history. Smart Funding validates all targets and both
selected/current prospective projections before one atomic commit, one version increment, and one
balanced logical history operation. Reads retain operation identity and return the current budget
token; restricted history hides the whole compound operation. Golden adapters now use actual
observed versions instead of hardcoded 1. No schema/server change or human data touched.
Verification: **398 backend zero skips, 113 native, 45 Core + 49 API, 3 production UI PASS**;
Beta build/test and diff check PASS. Logs `/tmp/budget-allocation-version-{backend,package,final,native-final}.log`.
Production UI covers month independence, Move Money and Smart Funding cancel/confirm/refresh.

After pushed `f42f262`, monthly summaries/shared Plan now separate dated Unassigned, optional
all-month Unassigned and the authoritative Smart Funding limit. Global observations are omitted for
scoped accounts/categories or missing balance capability; older servers still decode. Future
assignment/release changes current spendable cash without rewriting the historical month. The
shared UI explains later allocations/posted activity rather than equating historical RTA with cash
available now. No migration; adoption eventually requires server restart and app rebuild.
Verification: **399 backend zero skips, 114 native, 45 Core + 50 API, 2 production UI PASS**;
Beta build/test and diff check PASS. Logs `/tmp/budget-month-funding-{focused,backend,package,native-final}.log`.

After pushed `556c8d3`, the classification discrepancy was reproduced: a funded card purchase plus
cash deficit was mislabeled unfunded credit in Demo, while the matching Live case correctly reported
cash. Demo now aggregates signed recorded reserve attribution by selected month/visible category,
not `min(overspent, creditSpent)`. Refund/delete/edit/void/split regressions preserve actual reserves.
Verification: **400 backend zero skips, 115 native, 45 Core + 50 API, 2 production UI PASS**;
Beta build/test and diff check PASS. Logs `/tmp/budget-credit-classification-{backend,package,native-final,native-verified}.log`.
Failing native reproduction and passing matching Live scenario are retained under the same prefix.

After `929a27c`, `0029_cash_rollover_history` adds policy provenance only, with a legacy carry
baseline for existing budgets, effective month/version/source/actor constraints and bounded
500-budget backfill. Baseline-only downgrade preserves financial rows; downgrade refuses to lose
real policy decisions. Recovery fixtures now include nonempty policy history in whole-database
equality, including actual age-encrypted new-destination PostgreSQL restore. **Absorption is NOT
activated; no public policy toggle/new-budget default changed.** Human Live remains at 0020.
Verification: **408 backend PASS, zero skips**, including a populated 502-budget PostgreSQL
0028→0029 backfill and SQLite downgrade/re-upgrade preservation. One short-ID head and diff check
PASS. Logs `/tmp/budget-rollover-history-{focused,batched,backend-final}.log`. No Swift changes;
retain the preceding native/package evidence rather than claiming a new native run.

After `6791157`, Python/Swift pure boundary projections share 17 exact vectors. They use cumulative
signed credit-category activity plus recorded reserve attribution, not current-month report labels.
Cash absorption creates a derived carry increase/Unassigned debit once; prospective policy changes,
later refunds, split attribution, credit carry, sparse long gaps and overflow are tested. The Swift
period projection accepts a complete effect set separately from user Assigned/Activity and rejects
duplicate effects. Known future effects reserve already-spent cash without rewriting dated RTA.
**Normal Live/Demo providers do not supply effects yet; absorption remains inactive.**
Verification: **433 backend zero skips, 48 Core + 50 API, 115 native, 2 production Plan/Smart
Funding UI PASS**; Beta build and diff check PASS. Focused projection checks: 25 PASS. Logs
`/tmp/budget-rollover-projection-{focused-final,package-final,backend,native,ui}.log`.

Next highest-priority planning closure: repository/application-service integration. Build canonical
dated inputs from allocations, direct/split on-budget transactions, payment-category reserve events,
and spending-category reserve attribution. Stream/bound history and use a consistent complete
known-fact horizon (next boundary plus pending policy dates), not the selected screen's month as
global cash authority. Route `ready_to_assign_balance`, `category_available_balance`, monthly/report
carry and Demo production commands through the same effects. No fake user allocation or repeated
posting on read. Prove actual service flows with policies, scopes, refunds/edits, races and unchanged
account/card/reconciliation state before exposing settings. Then append audited next-period choices
under budget locking/version checks, activate explicit new-budget absorb defaults, and expose shared
UI. Fresh budgets created during these gated checkpoints need legacy baselines at activation too.
See `PERSISTENT-MONTH-IMPLEMENTATION.md`. Uniform clocks/remaining roadmap remain open.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST.**

`bed7c93` pushed forecast privacy. Current chronological projection correction is reproduced against
the server: 10,000 start, -8,000 bill, neutral transfer, +9,000 income ends 11,000 but reaches 2,000
in between. Demo previously incorrectly reported 10,000. Sorted occurrences and atomic transfer
measurement now match the server; exact projection overflow throws without posting. Old recurrences
no longer silently truncate at 400 iterations. **398 backend zero skips, 111 native, 45 Core +
49 API, 2 production UI tests PASS**, Beta build/test and diff check PASS, in
`/tmp/budget-forecast-low-{backend,native,package,ui}.log`. Fixed Demo clock anchor unchanged;
clock consistency and remaining report arithmetic are not claimed complete. No human retest.

`1c3b162` pushed opening/split safety. The following forecast audit proved a Live category-scope
leak: a restricted member's list correctly hid schedules but Forecast/Resilience included them.
Shared scoped SQL now filters before projection; Demo excludes uncategorized schedules for
restricted personas too. Before-fix failure: `/tmp/budget-forecast-privacy-reproduction.log`.
**397 backend zero skips, 109 native, 45 Core + 49 API PASS**; focused scope tests, Beta build/test
and diff check PASS. Backend includes disposable PostgreSQL/concurrency/migration/recovery.
Logs `/tmp/budget-forecast-privacy-{focused,backend,native,package}.log`. Server restart will be
needed when the human later adopts this checkpoint; no migration and no human data touched.
Next proven financial gap: Demo forecast lowest balance uses start/end rather than chronological
occurrences. Report/forecast overflow audit remains unfinished. Human acceptance pending, no retest.

`75226d5` pushed transfer hardening. Current opening/legacy-split checkpoint validates aggregate
cash opening before creation, propagates failures through the repository, replaces absolute-value
splitting with signed exact quotient/remainder, and rejects repeated category selections on legacy
writes. **108 native + 1 fresh-account production UI + 5 focused backend account tests PASS**;
Beta build/test and diff check PASS. `/tmp/budget-opening-split-{native-final,backend}.log`.
Remaining report/forecast aggregations still contain unchecked operations; do not claim complete
extreme-value rendering or overall production readiness. Human acceptance pending; do not retest.

`a1656ab` pushed posting/reversal rollback. Next transfer checkpoint stages full account deltas,
including combined reversal/replacement on edit, with exact overflow checks before publication.
Failed creation/deletion preserve both sides; valid final edit cancellation remains possible at
Int64 limits. **106 native + 1 production transfer UI + 3 focused backend tests PASS**;
Beta build and diff check PASS: `/tmp/budget-transfer-overflow-{native,backend}.log`.
Next audit surfaces: account creation, legacy split fallback, reports/forecast; shared authoritative
reconciliation observations, allocation-version parity and broader mission gates also remain open.

`ef90252` is pushed. Next checkpoint checks Demo posting/reversal arithmetic and routes overflow
through financial rollback. Tests cover both Int64 boundaries plus failed deletion/edit with
unchanged observations/transaction identities. **105 native + 23 server financial vectors PASS**;
Beta simulator build and diff check PASS. Evidence in
`/tmp/budget-posting-overflow-native-final.log` and `/tmp/budget-posting-overflow-vectors.log`.
Unchecked account creation, transfers, reports/forecast remain open audit work; do not infer
complete aggregate/arithmetic safety from this focused correction.

`5be09de` pushed reconciliation/clearing corrections. Following checkpoint hardens split validation
against overflowing totals and duplicate category dictionary traps. Reuses the dated projection's
exact accumulator, preserving legitimate mixed-sign cancellation. **45 Core + 49 API, 104 native,
3 focused server split tests PASS**, no server changes; final focused provider rerun PASS.
Logs `/tmp/budget-split-validation-{package,native,backend,native-focused}.log`.
Next: unchecked Demo posting/reversal/transfer/forecast accumulation remains a crash-risk audit,
alongside the broader production-readiness backlog. Do not infer all-money-arithmetic closure.

Reconciliation checkpoint verified from `27b16e5`: date/consent/stale-observation/permission
inputs now reach Demo; only cutoff-eligible cleared entries lock, explicit adjustments retain their
date/reason, and later account activity remains intact. Shared Live/Demo cutoff estimate no longer
uses an all-date or opening-omitting sum. Native regressions exposed and corrected Demo quick-clear
account totals and the legacy vector runner's mismatched default cutoff. No server/migration or
human data changes. Follow-up: bounded authoritative reconciliation observations for partially
visible account histories; current server stale checks are preserved.
**103 native + 2 production UI, 44 Core + 49 API, 7 focused backend tests PASS**; Beta simulator
build and diff check PASS. `/tmp/budget-reconciliation-{native-complete,package,backend}.log`.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`9930a7b` is pushed. Next verified checkpoint integrates dated production reads/commands and all
**15 financial + 7 period scenarios** in the native repository/snapshot runner. Months retain their
own assignments/activity/carry, future reservations consume existing cash, date edits reproject,
card funding/refunds are date-scoped, and failed edits restore exact prior state. Void originals
remain in the ledger with their reversing entries. Last reconciled balance is explicitly nullable.
Production UI found and fixed Previous/Today/Next automatic List-button co-activation; it now proves
September/October independent edits, November and Today navigation. Fresh category creation also
registers its group, preventing the newly exposed snapshot force unwrap.
Final **396 backend zero skips; 44 Core + 49 API; 101 native XCTest + 4 production UI tests pass**;
Beta build/test and diff check PASS. `/tmp/budget-period-integration-{backend,package,native-complete}.log`.
All relevant pre-fix failures are linked in the master ledger. Human data, main and tags untouched.
The subsequent reconciliation checkpoint above corrects dropped Demo inputs and shared cutoff
observation. Server voids retain original AND reversal; both remain in reconciliation/planning.
Allocation-version parity, calendar-independent clocks, later-reservation explanation, prospective
rollover and remaining mission gates stay open. **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

Starting HEAD for this continuation: `17efbcb` (remote matched, clean). Next verified checkpoint
replaces disconnected Demo financial seeds with explicit opening observations plus actual dated
assignments/posted transactions. Ordinary Demo now initializes its September plan through the
shared exact dated projection; card reserves come from the canonical posting path. The fixture
has a supported 2025-10-01 boundary and stable IDs; fresh Demo remains empty. Amount changes are
intentional fixture corrections, not Live migration. **395 backend zero skips; 44 Core + 49 API;
98 native XCTest + 3 production UI tests pass**, Beta build/test and diff check PASS.
Evidence `/tmp/budget-seed-ledger-{backend,package,native}.log` and focused opening-conservation test.
Next: route all month-specific reads/mutations through the dated facts, including date-scoped card
funding and atomic edit rollback; run the six full period vectors through the native provider.
Do not claim this seed checkpoint closes monthly provider parity, request history, or rollover.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**. Human Live remains at 0020, source head 0028.

`6ff6ad4` is pushed. Next verified correction prevents repeated Demo request approval and honors
the selected funding source (previously hardcoded to buffer). Capability/state/version/category,
amount, availability and overflow guards precede mutation. Approval events retain actual source/kind.
Pre-fix native reproduction fails for both defects; final **97 native XCTest pass**, Beta build/test
PASS, four focused server request cases PASS; `/tmp/budget-request-approval-{reproduction,native-verified,server}.log`.
Latest full backend remains **395 pass, zero skips**; package **44 Core + 49 API**; last focused
production assignment/Move Money UI **2 pass**. No migration/Live data change. Full Demo request
revision/history parity remains open. Continue dated provider/seed migration, not roadmap closure.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`bdfa497` is pushed. The next verified correction replaces fabricated Demo allocation-history rows
with actual command events. Refresh/month/persona changes preserve operation IDs, dates and original
actors; restricted visibility filters entire operations. Seed observations are not invented history.
Native **95 XCTest + 2 production assignment/Move Money XCUITests pass**, Beta build/test PASS:
`/tmp/budget-allocation-journal-native-verified.log`. Shared golden assertions now check balanced
allocation postings after every observation, including spending/refunds. Latest package **44 Core +
49 API** and unchanged backend **395 pass, zero skips** remain current. Diff check PASS.
This does not implement monthly assignment persistence, seed reconstruction or optimistic-version
parity. See the explicit boundary in PERSISTENT-MONTH-IMPLEMENTATION.md. No Live migration/data reset.
Next: complete dated deterministic provider inputs/opening fixture before routing the projection.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`33c6c1f` is pushed. The next focused correction reproduces and fixes three Demo card-refund
defects against the unchanged production server: cross-card attribution, repeated release of
previously refunded attribution, and split refunds releasing more than the remaining payment reserve.
Refund attribution is now net, card/category/date scoped; splits share one remaining-reserve cap
and retain command order. Shared command vectors increase from 12 to 15. Pre-fix native failures
are retained in `/tmp/budget-refund-attribution-native-reproduction-expanded.log`.
Final verification: **395 backend (zero skips), 44 Core + 49 API, 94 native XCTest + 2 production
XCUITests pass**, Beta simulator build/test PASS; `/tmp/budget-refund-attribution-{full,package,native-verified}.log`.
No backend production code, migrations, Live data or Simulator reset. Dated Demo integration and
seed attribution remain incomplete; these targeted fixes do not claim complete monthly parity.
Next: continue the complete dated provider/seed migration. **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`c47b709` is pushed (six dated server operation vectors, backend 392 pass). Next verified foundation
adds exact BudgetCore dated projection, snapshot-bound replacement assignment intent and explicit
opening boundaries. **44 Core + 49 API; 94 native XCTest pass**, final Beta build/test succeeds.
`/tmp/budget-dated-projection-{package,native}-verified.log`. Not yet a production Demo integration:
no account posting, credit-reserve generation or authorization is delegated to this read projection.
Next reproduce Demo's suspected cross-card/repeated-refund attribution mismatch with shared command
vectors, then continue complete dated ledger/fixture integration. **DO NOT RETEST**.

`4ace09b` is the starting checkpoint for this continuation. Six fixed-clock monthly operation
vectors now pass through the server adapter, alongside the original twelve. Full backend **392 pass,
zero skips**, `/tmp/budget-period-vectors-full.log`. Fixture vocabulary includes selected months,
dated transaction edits, expected insufficient-funds refusal, exact clearing/reconciliation state
and separate funding limit. Every observation reload and refused assignment preserves financial
tables. Next: exact dated projection foundation, then production deterministic integration. Demo
does not yet pass these new period vectors; do not claim parity or rollover completion. **DO NOT RETEST**.

Latest verified implementation is pushed at **`aecf712`**. Working tree/remote equality checked;
main remains `c5494dd`. `PERSISTENT-MONTH-IMPLEMENTATION.md` now records the next concrete delivery
boundary, seed-ledger mismatch, dated-versus-spendable cash contract, shared vectors and prospective
rollover requirements. Start with characterization at the canonical service boundary, not a Demo-only
date dictionary or the quarantined calculator. This design is not implementation/acceptance closure.

`53ecc7f` is pushed. Next verified performance checkpoint streams monthly Plan history in 500-row
batches and uses scalar allocation rows. Disposable 10k transactions + 10k splits: peak ORM objects
**20,011 → 1,506** with identical exact financial observations. Adding 10k allocation operations /
20k postings retains the 1,506 bound. **386 backend pass, zero skips**, including real disposable
PostgreSQL gates; `/tmp/budget-month-scale-full.log`. No Swift or migration changes. Latest native
evidence remains **94 XCTest + one production Smart Funding UI**, Beta build/test; **39 Core + 49 API**.
Human Live stays at 0020, source migration head 0028; no autonomous human migration/retest.

Continue with persistent monthly provider parity and effective-history cash-overspending rollover
(product specification §§7.1–7.4). Demo still ignores assignment month; Live future assignments are
now supported but dated RTA versus globally spendable cash must remain explicit. Do not wire the
quarantined legacy calculator into production or claim full planning closure. Master ledger records
remaining export fidelity, report scale, Docker, Local Device/import, roadmap and external gates.
No merge/tag; main remains c5494dd. **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`a83a9b2` is pushed. Next verified reliability checkpoint removes calendar overflow/underflow in
monthly planning and all five monthly report families. Shared inclusive periods preserve partial
months, Gregorian leap rules and exact money; final-month funding still requires its version.
**384 backend pass, zero skips**, `/tmp/budget-calendar-boundary-full.log`; focused rerun passes.
No Swift or migration changes. Next: measure/bound monthly-summary hydration on a large disposable
history. Persistent-month Demo parity and rollover policy history remain open. **DO NOT RETEST**.

`323afa2` is pushed. Next verified ledger checkpoint rejects allocations into/out of categories
whose parent group is archived. Individual category archival was already protected centrally; the
reproduction refined the diagnosis, and the fix extends that same shared service with one group
query. Archive/restore history and money remain unchanged. **367 backend pass, zero skips; focused
22 pass**, `/tmp/budget-archived-allocation-full.log`. No Swift/migration changes. Next audit:
calendar upper-bound input currently constructs year 10000 in planning/report paths. **DO NOT RETEST**.

`d8567e9` is pushed. Next verified security checkpoint prevents allocation history exposing hidden
category operations/counterparts/notes and prevents full JSON export bypassing explicit resource
restrictions. Whole-operation SQL filtering preserves balanced authorized history; scoped CSV and
explicitly delegated unrestricted export remain available. **365 backend pass, zero skips**,
`/tmp/budget-history-export-privacy-full.log`. No Swift/migration changes. Next reproduce missing
archived category/group allocation guards, then resume persistent-month planning work.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`753fa39` is pushed. Next verified server checkpoint allows future-month assignments of existing
cash through the canonical dated ledger. Fixed-clock regression proves independent periods, edits,
forecast exclusion, no duplicate spending and unchanged account observations. **360 backend pass,
zero skips**, `/tmp/budget-future-assignment-full.log`; no Swift/migration changes. Demo period
persistence and prospective rollover remain open. Next: reproduce suspected allocation-history
category-scope leakage before continuing planning expansion. **DO NOT RETEST**.

`985d660` is pushed. Next verified checkpoint prevents historical Smart Funding from reusing money
assigned in later months, with an explicit spendable limit and locked/versioned recomputation.
**359 backend pass, zero skips; 39 Core + 49 API pass; 94 native XCTest + production Smart Funding
UI pass**, final Xcode 27 Beta build/test successful. Logs `/tmp/budget-cross-month-full.log`,
`/tmp/budget-cross-month-package.log`, `/tmp/budget-cross-month-native-final.log`. No migration.
Next: future-month assignment/persistent period parity, explicitly authorized by product spec §7.2;
Demo currently ignores the month and Live rejects manual future assignment. Rollover policy history
is another open planning dependency. Human Live/data remain untouched. **DO NOT RETEST**.

`ac5dd07` is pushed. Next verified checkpoint makes Monthly plan cost checked/explainable and fixes
proven Double-based currency display loss using exact Decimal formatting. **94 native XCTest + four
production UI tests pass; 39 Core + 49 API pass**, Beta build/test successful. Backend unchanged
(356 pass). A new native test briefly changed Demo Hide Amounts; retained hierarchy identified it,
the exact prior false state was restored, temporary repair code removed, and tests isolated to unique
privacy identities. No Live financial data changed. Evidence `/tmp/budget-plan-cost-exact-verified.log`.
Next priority: reproduce cross-month Smart Funding historical-RTA double use; audit Demo/Live future
assignment semantics. Do not declare planning closure yet. **DO NOT RETEST**.

`f0cb4c1` is pushed (server snooze + migration). Next verified native checkpoint adds shared month-
labelled snooze/resume, explicit paused Plan rows, Demo month metadata, current-credential Live
command and authoritative refresh. **39 Core + 49 API; 92 native XCTest + three production UI tests
pass**, Xcode 27 Beta build/test succeeds. Prior backend checkpoint: **356 pass, zero skips**.
No extra migration. Human Live stays at 0020; do not migrate/retest now. Next: remove the unchecked
Int64 sum from Monthly plan cost, then remaining focused planning/closure audit. Initial Section
initializer compile failure was corrected; final evidence `/tmp/budget-snooze-native-verified.log`.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`ce4cef1` is pushed. Next verified server checkpoint adds month-specific snooze with additive
`0028_target_snoozes`, exact guidance suppression only, idempotent scoped command, target-row locking,
and cleanup on target deletion. **356 backend pass, zero skips** including populated migration,
PostgreSQL concurrent snooze and actual encrypted new-destination restore containing snooze metadata.
Focused target/migration/planning **44 pass** plus expanded lifecycle checks pass. One valid migration
head; human Live remains at 0020 and was not migrated. No Swift changes in this checkpoint. Next:
shared native/API/Demo snooze/resume workflow with current credentials, month isolation and UI proof.
Evidence: `/tmp/budget-snooze-server-full.log`, `/tmp/budget-snooze-server-focused-final.log`.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`5a44d93` is pushed. Next verified checkpoint honors target priority and exposes exact remaining
need/category count in Smart Funding, with an explicit production shortfall explanation. It rejects
combined need overflow; API decoding remains compatible with older servers. **352 backend pass,
zero skips; 47 focused planning/privacy/golden; 39 Core + 48 API; 91 native XCTest + one production
UI test pass**, Xcode Beta build successful. No migration. Next: month-specific snooze per the
implementation contract in V0.9-PLANNING-POWER-PLAN.md. Human Live remains at 0020, untouched.
**HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`627b957` is pushed. Next verified correction fixes reproduced Smart Funding duplicate need:
after 70000 target funding, preview wrongly proposed another 30000. Live now uses only underfunding;
Demo uses canonical monthly guidance and denies stale/repeated/restricted commit. Negative RTA
remains negative; previews never manufacture money. **351 backend pass, zero skips; 39 Core + 47 API;
90 native XCTest + two production UI tests pass**, Beta build successful. No migration/Live changes.
Next: target priority and insufficient-funding explanation, followed by month-specific snooze.
Keep **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**; production readiness remains in progress.

`431de33` is pushed (coordinated source backup capture). Next verified checkpoint corrects recurring
target monthly guidance on Live and Demo using immutable anchor/cadence and 14 shared exact vectors.
Backend **350 pass, zero skips**; focused planning/golden **45 pass**; package **39 Core + 47 API**;
native **89 XCTest + one Plan XCUITest pass**, Beta build successful. Initial native failure exposed
non-ISO Demo seed dates; fixtures corrected and full rerun passed, evidence retained. No migration.
Next: reproduce/fix Smart Funding over-proposal and Demo's separate legacy full-balance calculation.
Invalid-frame warning on amount clear remains observed, not resolved. **DO NOT RETEST**.

`c08867d` is pushed. Coordinated source capture now requires an explicit Compose project, reads
recovery material from the running API, pauses that API while copying SQL and objects, and resumes
it before interactive encryption. Failure cleanup attempts to resume only a source it attempted to
pause. Focused tests: **31 pass**; full backend: **334 pass, zero skips**. Actual Docker execution
remains an open gate; command doubles are not runtime proof. External writers must be excluded.
No human data or Swift changes. Next: recurring-target cadence correctness. **DO NOT RETEST**.

`87e3146` is pushed (real encrypted PostgreSQL recovery). Next verified correction restricts restore
to a new/schema-only database and empty object store, with bounded locked guards, quiesced recovery
API, non-root object copying, no object deletion and stopped-on-failure behavior. Real populated-target
refusal preserves all rows; full backend **329 pass, zero skips**, shell syntax/diff pass. The image
provisions a service-owned attachment directory; actual Compose runtime remains unverified. No human
data touched. Next: source backup capture consistency during concurrent writes, then the proven
recurring-target cadence gap. **DO NOT RETEST** remains in effect.

`26ff835` is pushed (complete safe archive preflight). Next verified checkpoint proves actual age
passphrase encryption, wrong-passphrase/corruption denial and a populated real PostgreSQL recovery
through the encrypted envelope. Final **323 backend passed, zero skips**; real crypto + command-double
script tests: 21 pass; real PostgreSQL recovery variants: two pass. The proof caught macOS tar adding
unhashed AppleDouble members; per-command metadata packaging is disabled without changing source
attributes. Docker itself remains absent, not falsely treated as verified. No Swift changes.
Next: harden destination replacement against database/object partial failure, then recurring-target
cadence. Human Live/Simulator untouched; **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

`f1a5c68` is pushed (currency-aware charts and v0.8 engineering audit). Current recovery checkpoint
fixes a reproduced omitted-manifest-member acceptance bug, validates safe complete archives before
destination contact, covers all regular objects, and publishes encrypted backups only on success
without overwriting an existing name. New host prerequisite: Python 3.10+ standard library. Age 1.3.2
was installed for real cryptographic recovery proof next; Docker is still absent. Human data untouched.
Do not conflate preflight/script-double tests with full Compose or atomic database/volume replacement.
Final backend for this checkpoint: **319 passed, zero skips**, shell syntax and diff check pass.

Latest pushed: `1c70163` (explicit mission/roadmap sequencing), following `43da26f` (partial payoff
horizon correction). Next verified checkpoint closes raw-minor-unit chart accessibility: all five
time-series reports now supply currency-aware native audio graphs and exact dated values. Final
**88 native + two production UI tests PASS**, Beta build TEST SUCCEEDED; full backend **308 passed,
zero skips**, package remains **38 Core + 47 API**. See `V0.8-CLOSURE-AUDIT.md` for scope/evidence.
No migration or human data changed. **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

Next priority changed on evidence: a recovery-script preflight test is reproducing acceptance of
files omitted from the manifest. Fix this data-safety gap before the documented recurring-target
cadence defect. Neither task requires human Live, Simulator reset or a commercial decision.

`9142cfd` is pushed (production debt chart/accessibility correction). Next verified checkpoint fixes
payoff horizon presentation: partial bounded totals no longer claim full repayment cost. Unknown
statuses also fail closed. Twenty-three shared vectors now include the default 1,200-month limit
and high-valid-APR exact final payment. Focused Python 23, package 38 Core + 47 API, native 87 and
both ordinary-payoff/horizon UI cases pass; final focused run TEST SUCCEEDED. The horizon UI uses
the real terms editor, not a test-only result. No migration or human data change. **DO NOT RETEST**.
Next: reconcile approved roadmap sequencing and remaining v0.8 closure gaps, then continue the
highest-priority independent production-readiness work.

Latest pushed: `d9a64cd` (estimated current cost). The next verified checkpoint restores recorded
debt history in the actual Overview rather than its unused predecessor. Five time-series reports
now format monetary axes as currency and select bounded ticks from real observation dates. Debt
marks expose exact date/currency accessibility values and expandable exact observations.
Final Xcode Beta run: **87 XCTest + four production UI tests PASS**, build PASS, final TEST SUCCEEDED.
The final screenshot and accessibility hierarchy were inspected. No backend changes since the
**308 passed / zero skips** result; package remains **38 Core + 47 API**.

An important test-evidence correction: previous largest-text tests passed an invalid literal launch
argument, so those runs proved dark mode but not accessibility text size. They now use UIKit's
actual accessibility-extra-extra-extra-large raw value. Home and Insights pass at that real size;
the debt section selector becomes a native menu to keep all four destinations reachable. A failing
exact-row test also exposed DisclosureGroup ancestor identifiers replacing child identifiers; that
ancestor identifier was removed, preserving unique observation targets. No assertions were weakened.
Human acceptance remains **PENDING — DO NOT RETEST**. Next: correct payoff horizon presentation so
bounded partial results cannot be mistaken for complete payoff cost, then continue readiness work.

Latest pushed: `f2e7608` (single-debt explicit rate-transition correction). Next checkpoint adds
Estimated Current Cost as a distinct shared production screen and authorized read-only route, with
current credential resolution, explicit approximation/unknown-rate semantics and batched balances.
Native verification: 87 XCTest, three focused debt UI cases; final Cost rerun includes an unfiltered
description/trait accessibility audit. Package 38 Core + 47 API and focused backend 26 pass. Full
backend final run: **308 passed, zero skips**. No migration or human data changes; **DO NOT RETEST**.
Next audit finding: the old debt-history chart still exists in an unused view; the actual Overview
currently renders only scalar observations. Restore it through the production composition and add
runtime coverage rather than relying on source-string presence. Review monetary chart axis labels.

`9964f24` is pushed: promotional strategy terms, Demo normalization/readiness, dated debt labels,
explicit scenario assumptions and verified UI recovery. The immediately following single-debt
rate-transition correction adds the 21st shared vector after reproducing premature non-amortization.
Full verification remains green: 305 backend / zero skips, 37 Core + 46 API, 86 native XCTest and
Beta Simulator build. No migration or human data change. Next: estimated current debt cost and
remaining v0.8 accessibility/closure review.

Latest pushed checkpoint: `a5216c2` on `codex/development` (projection privacy/revocation coverage),
following `65c7704` (17 shared single/multi-debt exact vector cases) and `315d5f7` (all-recorded
interest/date recovery). Current full backend: **303 passed, zero skips**, including disposable
PostgreSQL concurrency, migration and encrypted-object recovery. Swift package: **36 Core + 46 API
passed** using an isolated temporary build directory; a workspace `.build` attempt failed signing
because of Finder/resource-fork metadata, not a test assertion.

The broad production UI run completed 37 selected cases: 35 passed, two failed (five assertions).
Two preference-changing cases were deliberately excluded to preserve human Simulator state.
One failed test appended inputs to now-prefilled Demo Debt Terms; the correction explicitly replaces
the existing values. The other timed out synthesizing a Plan tap at 07:14:15, coincident with host
Maintenance Sleep starting 07:14:14 (557 seconds), then another 900-second sleep at 07:23:37.
Both focused awake reruns passed and finalized **TEST SUCCEEDED**, with serial native tests and
process-scoped idle-sleep prevention.
Do not report this broad run as green or a new app defect without those results. The earlier final
native run did finish with **TEST SUCCEEDED**, 85 XCTest + three focused UI cases.

Human Live remains at the recorded `0020` checkpoint and is untouched. No new migration in these
checkpoints. Human acceptance remains **PENDING — DO NOT RETEST**.

The next correction proved and fixed ignored promotional APR in the strategy endpoint (153 versus
51 cents), carried expiry through both engines/adapters, and added three shared vectors (20 total).
Demo also now normalizes weekly/biweekly/percentage payments into the same monthly scenario budget
as Live and reports partial terms consistently. UI debt observations are dated, net debt change is
not described as principal payments, and payoff values are explicitly projected with monthly/rate
assumptions disclosed. Final verification: **305 backend / zero skips, 37 Core + 46 API, 86 native
XCTest + two production debt UI tests**, final **TEST SUCCEEDED**, `git diff --check` green.
The two earlier recovery UI cases also passed. No new migration or posted-money mutation.

Next: finish v0.8 estimated-current-cost/VoiceOver and remaining financial boundary review, then
reconcile the larger approved roadmap. Native verbose sysdiagnose collection was disabled only on
the final focused rerun using Xcode's documented `-collect-test-diagnostics never`; normal console
output, test assertions and result bundles remain enabled. No release readiness, merge or tag claimed.

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
- Latest independently verified pushed checkpoint: `dcc871f` (large-history summary baseline)
- Push status: checkpoints through `dcc871f` are pushed. Later dated entries supersede historical pending notes below.

Focused report read-contract preparation follows this checkpoint. It preserves existing eager
hydration while separating report selection and current-credential resolution for upcoming demand
loading. Next work: activate demand loading with query/mutation invalidation, loading/error/retry
states and production navigation tests. The following filter-reachability fix restores the hub
toolbar entry to its existing shared filter form and adds a production apply/reopen/reset/chart
navigation regression. Do not claim the seven-report
launch fan-out has been removed yet. Human Live migrations and all human data remain untouched.

Subsequent demand-loading activation supersedes that preparation note: Live core activation now
makes zero detailed-report calls. Selected screens load/cache by query, planning month, workspace
refresh and credential revision; reports have separate error/retry states. Concurrent reads share
their in-flight task, and obsolete responses cannot overwrite current reports. Hub entry still
loads four detailed payloads, so lightweight summary, account/category fan-out and Demo computation
remain performance work. Next: finish report performance/accessibility and disposable PostgreSQL
migration/backup closure. No human Live migrations, resets, merge or tags.

Recovery follow-up: disposable PostgreSQL 17 (private Unix socket, no TCP listener) passed all
11 concurrency tests and full backend 295/295. Restore-key mismatch was then reproduced and fixed
with pre-mutation key validation and transactional SQL; full backend passed 296/296 and focused
script tests passed 7/7 after two extra test-only cases. Docker/age are absent, so real encrypted
Compose backup/restore remains an explicit gap. Native demand loading passed 84 XCTest and three
production UI tests; final Xcode processes stalled after test completion and were terminated,
not reported as clean finalizer exits. Previous combined run emitted TEST SUCCEEDED.

Real PostgreSQL recovery checkpoint follows: generated destination database, all persisted row
equality, financial API equality, copied AES-GCM attachment digest, wrong-key/corruption rejection,
and unchanged source ciphertext. Full backend **299 passed, zero skips**, including 12 PG cases.
The shared PG fixture now uses temporary attachment roots. Outer age/Docker recovery still requires
those tools; the new proof does not substitute for it. Human Live was not used.

2026-09-18 summary transport checkpoint: hub entry now uses one bounded `/reports/summary`
payload rather than four detailed reports. It delegates to canonical authorized report functions;
internal server/Demo report computation remains open performance work. Full backend 300/300,
package 35 Core + 46 API, native 84 and three production UI cases passed. Summary requires app and
server update together, with no additional migration. Existing unapplied human Live migrations
remain unapplied. Next: representative report computation/fan-out measurement, accessibility
review, and remaining v0.8 closure before the broader mission backlog. DO NOT RETEST yet.

Debt-report follow-up: all-recorded interest through the observation date, historical Demo coverage
cutoff, Debt period selector, draft custom dates and money-neutral report-error reset. Full backend
302/302, package 35+46, final native 85 and three production UI cases passed. No migration. Remaining
v0.8 review includes broader scenario interaction/accessibility and authorization/golden-vector
coverage reconciliation; do not mark product or human closure merely from this checkpoint.
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
