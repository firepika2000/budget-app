# Production readiness mission ledger

## Immediate mission override — Beta 1 (2026-09-27)

The user's Beta 1 Production Sample Mission supersedes exhaustive roadmap completion for the
current run. Prioritize Debt P0 stabilization, the visible clean-user budgeting journey, discoverable
core workflows and proportionate verification. Preserve import/advanced work but defer completion
to post-beta where unnecessary. `BETA1-PRODUCT-AUDIT.md` is the concise active product checklist.
Do not interpret older full-roadmap gates below as prerequisites to every Beta 1 checkpoint.
No feature freeze or Beta/TestFlight readiness is declared yet.

First Beta walkthrough checkpoint: focused production UI navigation confirms Home quick actions,
fresh Plan/Accounts actions, global Profile & Settings and the Insights hub. Guided-tour resume was
buried below multiple settings sections; Help & Education now follows Profile and its skip/resume/
route test passes. Core financial journey, Household, Activity, release configuration and human
Live Debt retest remain open. Testing is proportionate; no full universe rerun for this layout edit.

Updated: 2026-09-18. Active branch: `codex/development`.
Mission starting checkpoint: `e3f2922`. Production release readiness: **IN PROGRESS**.
Human acceptance: **HUMAN REQUIRED — HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

Budget-structure history checkpoint (2026-10-08): category groups and categories now append immutable,
actor-attributed snapshots for creation and real metadata or ordering changes; identical no-op writes append
nothing. The snapshot deliberately contains structure and presentation metadata only—group identity, name,
icon, note, order, archive state, resilience classification and delegation—not money or derived financial
observations. Populated hosted and Local Device databases are backfilled without changing posted transactions,
allocations, balances or reconciliation. Complete export and server-to-local transfer preserve the records,
and the shared production category/group views expose bounded paginated history for Live, Local Device and Demo.
Current resource authorization is rechecked before history is returned.

Account-decision history checkpoint (2026-10-08): account creation and real metadata changes now
append immutable, attributed before/after observations. True no-op saves append nothing. Hosted and
Local Device databases migrate populated accounts without changing balances or posted activity;
complete export and server-to-local transfer retain the history. Account Settings exposes one bounded,
paginated production history view shared by Live, Local Device and Demo. The history contains only
name, safe type, budget treatment, open/closed status and payment-category identity—never balance or
transaction values—and remains subject to account visibility authorization.

Scheduled-decision history checkpoint (2026-10-08): schedule creation, editing, pause/resume,
realization and deletion now append attributed immutable revisions instead of leaving only the latest
mutable row. History survives schedule deletion, preserves exact integer-minor-unit snapshots and
posted-transaction lineage, is exported to Local Device, and appears through one bounded paginated
production view shared by Live, Demo and Local Device. Budget Server applies account, destination and
category scope to both the before and after resources before pagination, preventing a move from a
hidden resource into a visible one from leaking its former details. Existing populated schedules are
conservatively backfilled as created observations by migration `0040_schedule_revisions`; no money,
forecast, recurrence or realization semantics change.

Parameterized Quick Entry checkpoint (2026-10-08): the Add ClearPocket Transaction App Intent now
accepts optional payee, exact currency text, memo, transaction date and expense/income type, then opens the existing
production transaction editor with those values prefilled. It never posts money from Shortcuts;
account/category selection, validation and Save remain in the canonical authorized workflow. The
one-shot handoff is length-bounded, consumed on read and expires after five minutes so abandoned
financial drafts do not persist indefinitely. Future dates are rejected with guidance rather than bypassing the
canonical scheduled-transaction workflow. Focused XCTest and production-composition XCUITest pass
on the preserved iPhone 17 Pro Max / iOS 27 simulator under regular Xcode 27.0 (`27A266a`).
The privacy-safe launcher widget's **Add transaction** control now opens that same canonical editor
instead of merely navigating to Activity. Its deep link accepts no payee, amount, memo or other
private query data; unknown or decorated quick-entry routes fail closed.

Plan guidance freshness checkpoint (2026-10-08): group Suggested and Average Spent guidance now
reloads when the authoritative workspace revision or selected Plan month changes, including the
existing bounded foreground polling path used for another-device updates. Overlapping responses are
generation-guarded. Temporary connectivity loss retains the last authorized aggregate, while a
permission/resource denial or invalid response clears it so an aggregate from a former scope cannot
remain visible. This changes presentation freshness only; no assignment or transaction is created.

Workspace continuity checkpoint (2026-10-08): the compact and regular production shells retain the
last valid selected tab per Budget. If SwiftUI reconstructs the workspace during lifecycle or route
rehydration, the user returns to Plan, Activity, Accounts, Insights, or Household rather than being
sent to Home. Explicit test/demo launch routes still override the preference and invalid stored
values fail closed to Home. This persists navigation context only, never an unsaved financial edit.

Funding-request Activity checkpoint (2026-10-08): Activity now includes the newest five authorized
request actions with actor, exact amount, qualified visible category, decision type and note, then
drills into the existing canonical request detail and complete decision history. The shared production
presentation derives from already scoped request observations (Local Device personal budgets currently
have no household-request records); the timeline performs no mutation and cannot reveal an otherwise
invisible request or category. The deterministic sample now includes stable create/approve/reject action records so its
visible status is backed by the same kind of immutable evidence expected from production providers.
The focused production-composition XCUITest passes on the preserved iPhone 17 Pro Max / iOS 27
simulator under regular Xcode 27.0 (`27A266a`).

Allocation-attribution checkpoint (2026-10-08): Plan allocation history now carries the current
server-authoritative display name for the immutable actor user ID. The history UI no longer depends
on the currently loaded active-member list to explain who assigned or moved money, so actions by a
removed member remain understandable without weakening the existing whole-operation category-scope
filter. Demo and Local Device use the same response contract and production view.

Allocation-history scale checkpoint (2026-10-08): Budget Server workspaces now load the newest 50
authorized Plan operations through a bounded page contract and expose an explicit **Load Older
History** action until no page remains. Whole-operation category privacy is applied in SQL before
cursor/limit, so page boundaries cannot reveal a hidden transfer leg, note, actor or the existence of
an otherwise private operation. The original unpaged endpoint remains available for backward
compatibility with older clients; the current production iPhone composition uses the bounded route.

Dropbox completion audit (2026-10-07): the iPhone production path is implemented rather than a
placeholder. It uses PKCE with offline refresh-token rotation, device-only Keychain custody,
least-privilege file scopes, immutable encrypted generations, content-hash verification, bounded
retention, automatic active-app backups, verified download/restore, explicit disconnect/revocation,
and recovery-key warnings. Local Files backup remains available independently. Unit coverage exercises
OAuth state/callback validation, refresh concurrency and rotation, 401 recovery, remote revocation,
chunked upload, pagination, retention, path confinement and corrupt upload/download rejection;
coordinator coverage proves fail-closed behavior while production-composition UI coverage proves the
configured destination remains alongside Local Files recovery. ClearPocket's
registered public app identifier is now included in ordinary Debug and Release build settings; it is
not a client secret. The release helper still requires and verifies the same identifier explicitly,
so an archive cannot silently ship a dead Connect button or an unintended Dropbox application.
The remaining Dropbox gate is external-console/live acceptance: confirm App-folder access and exact
redirect URI `clearpocket://dropbox-oauth`, then complete one real connect, backup, relaunch, restore
and revoke walkthrough. No client secret belongs in the app or repository. This external gate does
not block unrelated roadmap engineering.

Widget checkpoint (2026-10-07): the app now embeds a WidgetKit extension with small and medium
privacy-safe launch surfaces. The widget contains no shared container, credential, balance, budget,
transaction or household access; it displays only static ClearPocket navigation and routes validated
`clearpocket://open` destinations into the existing authenticated active-budget shell. Cold launches
retain the one-shot request until the workspace appears, while an already-running app consumes the
request immediately. Unknown destinations and non-ClearPocket URLs are rejected. The Xcode 27 Beta
app-plus-extension build, embedded extension/plist validation, and focused one-shot routing test pass
on the existing iPhone 17 Pro Max / iOS 27 Simulator. Financial widgets remain intentionally absent
until a separate privacy/authorization contract justifies exposing data outside the app.

Receipt-assistance checkpoint (2026-10-07): New Transaction can select a receipt image through the
system photo picker and run Vision text recognition entirely on the device. ClearPocket derives an
exact integer-minor-unit amount, plausible payee, non-future date and currently visible category,
then presents every proposal for review. Applying suggestions only fills the unsaved editor draft;
the user must still press Save, and the image is not uploaded or attached implicitly. Exact existing
payees are resolved through the bounded first-class-payee search so this does not create a parallel
payee identity path. Xcode 27 Beta production build and focused total/date/category parser tests pass
on the existing iPhone 17 Pro Max / iOS 27 Simulator. Camera capture and automatic receipt attachment
remain intentionally outside this checkpoint; the established post-save attachment workflow handles
retention, encryption and authorization.

Scheduled-reminder checkpoint (2026-10-07): Profile & Settings now offers opt-in, device-local
reminders for active scheduled items. ClearPocket asks for system notification permission only when
the user enables the feature, replaces its own budget-scoped pending requests whenever authoritative
schedules change, excludes paused/past/distant items, and bounds the next 60 days to 50 requests.
Every lock-screen notification is deliberately generic—no amount, payee, account, category, budget,
member or household detail is persisted in notification content. Denied permission leaves the toggle
off and provides a direct explanation; disabling removes the app's pending requests for that budget.

Scheduled skip checkpoint (2026-10-07): an authorized planner can now skip the next occurrence from
the production schedule editor after explicit confirmation. Recurring items advance one exact cadence;
one-time items become paused. The action reuses the canonical schedule update service and preserves
the schedule's account, destination, category, payee, amount, memo and classification. A focused
production-store test proves that no transaction, account balance or Available-to-Assign value changes.

Scheduled end-date checkpoint (2026-10-07): recurring items can now specify an optional inclusive
final occurrence date in the shared production editor. Server and Local Device storage persist it,
forecast expansion honors it, and realization/skip pause the item instead of advancing past it. The
field is metadata-only until an occurrence is explicitly realized, so account balances, category
activity and Available-to-Assign remain unchanged by creation or editing.

Scheduled occurrence-count checkpoint (2026-10-07): recurring items can alternatively specify an
exact remaining count (1–10,000) across Server, Local Device, Demo, portable transfer and the shared
editor. Forecasting caps projected rows without mutating the schedule. Enter Now and Skip Next each
consume one occurrence; an exhausted schedule remains manageable but inactive. Create rejects zero,
one-time items and combined date/count limits; update permits zero only for an inactive item.

Local statement-import durability checkpoint (2026-10-07): on-device statement review/history is
now stored in the Local Device SQLite authority instead of an in-memory dictionary. Unfinished,
approved, cancelled and undone batch metadata survives repository reconstruction and app relaunch,
remains budget/account scoped, and is automatically covered by existing encrypted SQLite backups.
Focused schema-upgrade, private-payload paging and production-provider relaunch tests pass.

Qualified category-selection checkpoint (2026-10-07): production pickers now identify categories as
`Group · Category` across transaction create/edit/splits, schedules, Activity and report filters,
statement-import review, allowance funding/delivery and transaction detail. This closes the ambiguous duplicate-name
beta finding while preserving stable category IDs and all existing authorization boundaries.

Transaction audit checkpoint after `e96701f`: transaction detail now exposes bounded,
actor-attributed change history from the immutable server audit ledger. The route rechecks current
account/category visibility before loading events and returns action, actor, timestamp and changed
field names only; private before/after snapshots remain on the server. Focused backend privacy,
Swift API-contract and native production-composition checks pass.

Complete data export checkpoint: an authorized unrestricted owner can now prepare and share a
`.clearpocketexport` package from Profile & Settings → Data Ownership for either Budget Server or
Local Device authority. Its `data.json` remains the canonical versioned provider export; the iPhone
does not reconstruct household, financial, or audit history. The package adds ordinary copies of
every active attachment plus an integrity manifest. Each payload travels through the existing
authorized provider read path and must match its recorded exact size and SHA-256 before the package
is offered. Detached files are not resurrected, filename/path traversal is normalized, incomplete
generations are removed, and scoped or unauthorized server exports remain denied. The UI identifies
the package as private and unencrypted and keeps operational encrypted backup/restore as the complete
restore workflow. Focused native regressions cover Server and Local Device metadata shapes, active
payload coverage, detached exclusion, collision-safe paths, integrity failure cleanup, and regular
Xcode 27 production compilation.

Shortcuts navigation checkpoint: the existing Add Transaction shortcut is joined by privacy-safe
Open Plan, Open Accounts, and Open Insights actions. Each intent only records a one-shot destination
and opens the existing active-budget production shell; it neither reads private financial values
into Shortcuts nor performs a money mutation. The shell consumes and clears each request on launch
or foreground activation, so a handled shortcut cannot reroute a later session. Focused Xcode 27
Beta intent-compilation, one-shot routing, and production-composition tests pass. A WidgetKit target
and parameterized financial entry remain separate roadmap work.

Apple integration closure checkpoint: Activity and Household now have the same privacy-safe Siri/
Shortcuts navigation as the other primary workspace surfaces, and a parameterized Open ClearPocket
Screen action lets a personal shortcut choose Home, Plan, Activity, Accounts, Insights or Household.
The intent only records a one-shot route into the existing production shell. It does not read private
budget values, create transactions or bypass authentication and budget authorization.

Debt scenario continuity checkpoint: the payoff planner now restores strategy, rollover behavior,
extra-payment choice and custom account order per signed-in user and budget on the current device.
Removed or newly visible debt accounts are reconciled into the saved order safely, and an explicit
reset returns to the read-only default scenario. Persistence changes only projection preferences;
it does not mutate transactions, balances, Plan assignments, schedules or canonical Debt Terms.

Plan group navigation checkpoint: category-group headers are now discoverable destinations rather
than static labels. Group detail keeps the group name visible, summarizes exact current-month Plan
values, lists its categories, and opens the shared production transaction editor scoped to that
group. The editor still uses canonical transaction authorization and mutation behavior.

## STOP FEATURE EXPANSION — human Live Debt P0

Human reports repeated PlatformAlertController presentation conflicts followed by code-9 debugger
termination despite successful report/projection HTTP responses. P0 remains OPEN. Import/roadmap
expansion is paused until Debt stabilization and human-visible product audit address P0/P1 defects.
Priority is P0 crash/data-loss/security/accounting, P1 broken primary workflows, P2 severe UX,
P3 missing user-visible functionality, P4 backend/architecture. Do not prioritize P4 over P0/P1.
See `DEBT-P0-INVESTIGATION.md` for verified evidence/hypotheses and
`HUMAN-VISIBLE-PRODUCT-AUDIT.md` for the incomplete audit inventory. Initial Demo production UI
success and injected-failure dismissal tests PASS but do not reproduce or disprove the Live failure.

Import staging service after `2983d3e`: validates normalized candidates, current view/create
authority and open account scope; persists review data without financial writes. Owner-only reads
check current account authority before loading candidate text. Conditional versioned cancellation
retains history and rejects stale repeats. Six focused staging/review tests PASS including revoked
scope and unchanged month/transaction/payee/audit state. No endpoint/approval yet; no new migration.
Full backend: 510 PASS, zero skips, 116.47s with disposable PostgreSQL gates enabled;
`/tmp/budget-import-staging-service.log`. Diff check PASS; no native changes.

Import staging schema after `69bdd0d`: new source head `0030_import_staging` adds money-neutral
owned/versioned review batches; no financial backfill or endpoint. Populated downgrade refuses
history loss. Ordered migration ledger now appends `0029_cash_rollover_history` →
`0030_import_staging`. Human Live remains `0020_payee_identity_repair`, untouched. Staging service,
approval/replay and native workflows remain open; schema alone does not establish authorization.
Final backend regression: 505 PASS, zero skips, 118.63s including populated PostgreSQL upgrade,
financial preservation, downgrade refusal and encrypted new-destination recovery at revision 0030.
`/tmp/budget-import-staging-final.log`; diff check PASS. Earlier old-schema test fixture was updated
to verify the new table only at revisions where it exists; original financial comparisons retained.

Import observation service after `04dfefa`: production transaction search and import retrieval
share SQL resource-visibility predicates. Review checks current view/create capabilities and
budget/account visibility before bounded posted-row scalar retrieval. Hidden categories, salary
and mixed splits stay out of observations. Fourteen focused review/browser/matcher tests PASS.
No import endpoint/approval yet; full import and broader production readiness remain IN PROGRESS.
Full backend: 504 PASS, zero skips, 117.74s with disposable PostgreSQL enabled;
`/tmp/budget-import-review-backend.log`. Diff check PASS. No native/schema changes.

Import matching foundation after `8de36b5`: bounded deterministic exact/possible suggestions and
in-file duplicate warnings, with no automatic consumption or mutation. Forty focused import tests
PASS including 10,000 candidates/50,000 observations. Current code is a pure algorithm, not an
authorized API: scoped observation retrieval, durable staging, approval, identities and native UX
remain open. See `FILE-IMPORT-IMPLEMENTATION.md`; no production completion claim.
Full backend: 503 PASS, zero skips, 117.34s with disposable PostgreSQL gates enabled;
`/tmp/budget-import-matching-backend.log`. Diff check PASS; no native/schema changes.

Funded-card unit-of-work verification after `2e9f532`: new test proves actual reserve events are
created then fully rolled back after a subsequent invalid operation. Complete month observations
and posted register equal their pre-operation values. Thirteen focused unit/card tests PASS; diff
check PASS. Test/docs-only change; latest full backend baseline remains 497 PASS. Import remains open.

Canonical posting prerequisite after `8a72030`: extracted non-committing transaction creation
inside the existing canonical module; HTTP still commits as before. Same authorization, payee,
reserve and audit path; input DTO is no longer mutated. New rollback test exposed and corrected
SQLite payee savepoint escaping outer rollback. Twenty-one focused creation/card tests PASS.
Import approval/idempotency remains open; no schema, native or human-data changes.
Full backend regression: 497 PASS, zero skips, 116.78s with disposable PostgreSQL gates
(`/tmp/budget-canonical-unit-backend.log`); diff check PASS.

CSV mapping after `61f029c`: explicit ISO/MDY/DMY dates, comma/semicolon/tab delimiters and signed
versus separate debit/credit columns. Ambiguous dual amounts and malformed maps fail atomically;
35 focused tests PASS. No routes, posting, schema or native behavior changed. Remaining full import
scope and authoritative currency-scale contract stay open in `FILE-IMPORT-IMPLEMENTATION.md`.
Full backend regression: 496 PASS, zero skips, 116.60s with disposable PostgreSQL enabled
(`/tmp/budget-import-mapping-backend.log`); diff check PASS. No native changes.

File import foundation after `b3257e1`: added bounded, explicitly mapped CSV-to-candidate parsing
with strict dates and exact signed Int64 amounts. No routes, database writes, payee creation or
accounting mutations. Twenty-two focused tests PASS including 10,000 records and malformed input.
`FILE-IMPORT-IMPLEMENTATION.md` tracks remaining adapters, staging/matching, explicit canonical
approval and native UX. Import remains IN PROGRESS; this is not a completed product workflow.
Full backend regression: 483 PASS, zero skips, 120.37s including disposable PostgreSQL gates
(`/tmp/budget-import-foundation-backend.log`). Diff check PASS. No Swift/schema changes.

Demo reconciliation authority after `2559863`: the command used the budget capability captured at
workspace construction, so a changed custom profile could still reconcile. It now checks current
reconciliation authority and current account scope before calling the unchanged reconciliation
engine. Regression proves capability revocation and hidden-account refusal leave balances,
transactions and reconciliation flags unchanged, then proves restored scoped authority reconciles
only the selected account without altering working balances. Existing delegated-persona restrictions
remain; complete role/capability parity, broader observations and planning authorization remain open.
Verification: 142 native tests + production register quick-clearing/reconciled-lockout UI PASS;
Beta Simulator build and diff check PASS (`/tmp/budget-demo-reconcile-authority.log`). Nine backend
reconciliation/balance reference tests PASS (`/tmp/budget-demo-reconcile-reference.log`). No server
or schema changes; latest full backend/package baselines remain 461 / 49+54 PASS.

Demo transfer authority after `fdaa419`: create/edit/delete now require the corresponding current
transaction capability. Existing linked pairs must be balanced, visible on both accounts, owned
by the actor (or explicitly manageable), posted and unreconciled before mutation. New source and
destination accounts are scoped; amounts must be positive and accounts distinct. Strict date
round-trip and injected-today checks reject malformed/future dates instead of defaulting to actual
money today. Existing atomic transfer/credit-reserve engine is unchanged. Regression covers current
capability revocation, hidden destination, non-owner mutation, reconciled refusal, invalid dates,
whole-state atomic refusal and authorized deletion restoring original balances. Planning/report
scope and other authority gaps remain open; no blanket provider authorization claim.
Verification: 141 native + production register transfer create/edit/delete UI test PASS;
Beta build/diff PASS (`/tmp/budget-demo-transfer-authority.log`). Five backend transfer/card-reserve/
scope reference tests PASS (`/tmp/budget-demo-transfer-reference.log`). No server/schema change;
last full backend/package baselines remain 461 / 49+54 PASS. Human data/main unchanged.

Demo schedule input contract after `3d28428`: create/update, stored realization and active forecast expansion validate
cadence vocabulary, 1...365 interval, nonzero amount, bounded name/memo, exact calendar-date
round-trip, transfer shape and debt-interest classification before mutation. Invalid dates no longer
fall back to today during realization, and an unbounded week interval cannot reach integer
multiplication. Tracking accounts cannot receive categorized schedules. Make Recurring rejects
once and delegates to the same creation validator. Regression covers malformed dates/intervals,
transfer/payee/category conflicts, classification, atomic create/update refusal, malformed stored
realization/forecast refusal and valid leap-day/cadence bounds. Make Recurring's past-date advancement and broader
provider clock/identity parity still require audit; no complete scheduling parity claim.
Final verification: 140 native + 2 production realization/Make Recurring UI tests PASS;
Beta build/diff PASS (`/tmp/budget-demo-schedule-validation-final.log`). All 29 backend
scheduling/lifecycle reference tests PASS (`/tmp/budget-demo-schedule-validation-reference.log`).
No server/schema change; latest full backend/package baselines remain 461 / 49+54 PASS.

Demo schedule authority after `1489c63`: create/update/delete require current planning capability;
realization requires current create-transaction capability, matching Live rather than assuming the
original schedule creator's authority. Existing and new account/destination/category scopes are
rechecked before mutation; absent/hidden schedule IDs refuse rather than silently deleting nothing.
Category-restricted users cannot realize uncategorized schedules. Scoped schedule rows are filtered
before forecast expansion. Realization due-date checks use the injected clock and continue through
the existing canonical posting/transfer engine. Regression covers revoked capability, changed
category scope, hidden destination, whole-state refusal and authorized realization without granting
planning authority. Broader summary/report scope and full schedule-shape validation remain open.
Verification: 139 native tests PASS (`/tmp/budget-demo-schedule-authority.log`), production
Enter Now → posted Activity UI test PASS (`/tmp/budget-demo-schedule-authority-ui.log`), Beta
builds/diff PASS. All 18 server scheduled-contract tests PASS (`/tmp/budget-demo-schedule-reference.log`).
No server/schema change; last full backend/package baselines remain 461 / 49+54 PASS.

Demo lifecycle authority after `773a9f9`: duplicate requires current create authority and visible
source/destination resources; void requires delete authority and original creator-or-manager access;
Make Recurring requires planning authority and a visible eligible source. System-linked and
non-posted templates refuse as in Live. Reversal amount/split negation uses checked subtraction,
refusing unrepresentable Int64 values before ledger mutation, and reversal dates use the injected
clock. Regression covers denied capabilities, hidden sources, unchanged money/schedules, overflow
refusal, exact authorized reversal/date and refusal to duplicate the voided original. Other schedule,
transfer, planning and report scope paths remain open; no blanket provider authorization claim.
Verification: 138 native + 2 production duplicate/recurring/reversal UI tests PASS; Beta build
and diff PASS (`/tmp/budget-demo-lifecycle-authority.log`). Eleven server lifecycle/attachment
reference tests PASS (`/tmp/budget-demo-lifecycle-reference.log`). No server/schema changes;
latest full backend/package evidence remains 461 / 49+54 PASS.

Demo ordinary transaction commands after `ff04f33`: create/edit/delete now check current operation
capability before canonical mutation. Existing-row edit/delete enforce full visibility and original
creator-or-manager authority; new destination accounts/categories are scoped and inactive categories
refuse. Non-posted/reconciled/transfer edit/delete paths refuse; deletion also refuses active
attachment metadata/bytes, preserving the explicit reversal alternative. Demo tombstone history
parity remains open. Canonical editing now retains the original creator instead of replacing that
identity with the editor. Regression exercises permission revocation, hidden destination refusal,
unchanged financial state on failure, successful own-row edits/deletion and owner editing without
creator reassignment. Duplicate/void/Make Recurring and other command families remain in the audit.
Verification: full 137 native tests PASS (`/tmp/budget-demo-transaction-command-auth.log`), then
expanded creator-denial native test + production register-delete UI test PASS
(`/tmp/budget-demo-command-auth-ui.log`). Beta builds/diff PASS. All 20 backend budgeting and
transaction-lifecycle reference tests PASS (`/tmp/budget-demo-command-auth-reference.log`).
Server/package source unchanged; latest full baselines remain 461 backend and 49 Core + 54 API.

Demo bulk command authorization after `8d44511`: the repository previously relied on UI admission
and fixed persona checks, allowing custom-permission/ownership bypass and voided/reversal bulk
mutation through a direct call. Bulk preflight now checks current edit capability, unique bounded
selection, whole-resource visibility, posted lifecycle and creator-or-manager authority for every
selected row before any mutation. Existing reconciliation/system-link checks and checked/idempotent
cleared-balance updates remain. Regression asserts precise 403/404/409/422 refusals, whole-batch
atomicity, unchanged accounts/transactions and idempotent authorized clearing. Other command families
still require the same ongoing audit; this is not a blanket Demo authorization PASS.
Verification: 136 native + 2 production register-clearing/Activity-bulk UI tests PASS; Beta build
and diff PASS (`/tmp/budget-demo-bulk-authorization.log`). All 5 backend bulk/clearing reference
tests PASS (`/tmp/budget-demo-bulk-reference.log`). Latest full server/package baselines remain
461 backend, zero skips, and 49 Core + 54 API; neither server nor package source changed here.

Demo transaction observations after `c49cb3d`: snapshot/browser serialization now uses the same
account/category visibility predicate as Payee and attachment observations. A split containing
any forbidden category is excluded as a whole before search/counts/pagination, rather than being
partially serialized. Authorized rows retain their original category/split attribution, including
historical categories not present in the current active-category picker. Missing read capability
omits snapshot transactions and denies explicit browsing. Invalid page limits refuse before range
arithmetic. Regression checks scoped row IDs/counts, hidden mixed splits, exact owner split amounts,
revoked capability, 422 bounds and unchanged stored transactions. Broader Demo financial summaries,
reports and mutation capability enforcement remain open; no full dynamic authorization claim.
Verification: 135 native + 1 production Activity search/filter UI test PASS; Xcode 27 Beta
27A5252f build PASS on existing iPhone 17 Pro Max/iOS 27 UDID
`3ABD861E-D38D-4AFD-A356-959266051564`; diff PASS.
Log: `/tmp/budget-demo-browser-scope.log`. Server/package unchanged from 461 / 49+54 baseline.

Demo Payee privacy after `84b81a2`: search and workspace hydration now share observations built
from authorized transaction history before matching/counts/page selection. Scoped members cannot
discover unused/hidden household identities or aliases; inaccessible default categories are
redacted. Attachments share the same resource-visibility helper. Read-capability removal denies
search, while snapshots omit payee observations. Exact sums use checked minor-unit accumulation.
Search validates 1...50 limits, query length and nonnegative cursors; large out-of-range cursors
return an empty page safely. Stable ordering includes identity as a tie-breaker. A 5,000-payee
native regression checks bounded/disjoint/repeatable pages, hidden names/alias guesses, correct
amounts and defaults, snapshot parity, revoked read capability and unchanged financial state.
This does not close broader Demo summary/report/custom-capability enforcement or persistent storage.
Initial verification: 134 native tests PASS (including the 5,000-payee test in 0.551s), but the
existing Payee alias UI test attempted to tap the off-screen Household row without scrolling.
Both Payee management journeys now wait for Household, scroll until the actual Payees row is
hittable, and retain their creation/alias/persistence assertions. Final rerun evidence follows.
Final verification: 134 native + 2 production Payee UI tests PASS, Beta build PASS, diff check
PASS (`/tmp/budget-demo-payee-scope-final.log`; result `Test-BudgetApp-2026.09.18_19-39-49--0400.xcresult`).
Latest unchanged server/package baselines remain 461 backend (zero skips), 49 Core + 54 API PASS.

Live Payee privacy after `911b437`: a new adversarial regression reproduced discovery of a private
salary payee through search despite its uncategorized income being hidden from category-scoped
transaction search. Payee visibility had treated an empty split set as authorized. Both Payee
search and legacy list now share SQL visibility conditions requiring at least one split with
every category allowed, or an allowed direct category; uncategorized rows remain hidden for
category-restricted users. Filtering happens before counts/ranking/hydration. Responses redact
inaccessible default-category IDs using the caller's category scope, computed once per result page.
Regression covers private identity, visible merchant counts/net amounts, default-category privacy,
canonical transaction-search agreement and unchanged unrestricted owner observations.
No financial storage, migrations or authentication lifecycle changes. Reproduction:
`/tmp/budget-payee-category-scope-before.log`; focused Payee suite: 10 tests PASS.
Full backend: 461 PASS, zero skips, 122.71s, including disposable PostgreSQL concurrency,
migration and encrypted recovery checks (`/tmp/budget-payee-category-scope-backend.log`).
Swift package: 49 Core + 54 API PASS (`/tmp/budget-payee-category-scope-package.log`);
diff check PASS. Last native evidence remains 133 PASS; no Swift changed for this server fix.

Transaction attribution audit after `613a478`: Demo API transaction serialization used the current
viewer as creator, causing member filters to attribute every visible transaction to whichever
persona was browsing. Serialization now uses the stored transaction member, with the canonical
`demo-owner` identity for Rey. Regression checks every seeded creator under both adult viewers,
member-filter row IDs/counts, restricted-user hidden owner results and unchanged stored ledger.
This corrects observation identity only; no money/posting changes or Live API changes.
Verification: all 133 native tests and Beta simulator build PASS; diff check PASS.
Log: `/tmp/budget-demo-transaction-attribution.log`. Prior attachment UI and package evidence
remain recorded below; they were not rerun for this serialization-only checkpoint.

Demo attachment authorization after `9701ab2`: direct repository methods previously checked only
active membership, returned bytes by transaction ID without validating attachment identity, and
could detach a hidden transaction's receipt. A shared attachment admission check now applies
current read/edit capability, visible account/transaction, all split-category scopes, custom
account/category restrictions and creator-or-manager mutation authority. Hidden/mismatched/detached
IDs refuse before accessing bytes; unavailable storage errors instead of returning empty success.
Reversal uploads refuse as in Live. No Live server/storage or financial behavior changed.
This is scoped authorization hardening, not complete Demo attachment lifecycle parity: the Demo
adapter still has a single in-memory attachment slot per transaction; multi-file metadata,
content validation and tombstone parity remain open. Full dynamic Demo authorization elsewhere
also remains open.
Verification: 132 native + 2 production attachment UI tests PASS; Xcode 27 Beta simulator build
PASS on existing iPhone 17 Pro Max. Eleven backend attachment/lifecycle reference tests PASS;
diff check PASS. Logs: `/tmp/budget-demo-attachment-scope-final.log` and
`/tmp/budget-demo-attachment-server-reference.log`. The initial test build caught a test-only
persona enum typo, corrected before this successful run. No data reset or human acceptance claim.

Core sharing admission after `2f65812`: a focused test reproduced the legacy standalone
`BudgetAuthorizer` incorrectly allowing non-owner managers to change sharing. Server grant
upsert/revoke already require household ownership, and no production UI call currently uses this
helper. Non-owner sharing now refuses after the visibility check (hidden remains `notFound`),
while manager budget editing and owner authority remain intact. The helper is explicitly documented
as budget-level admission, not a substitute for provider resource/custom-capability authorization.
Full Swift package: 49 Core + 54 API tests PASS; diff check PASS. Reproduction/final logs:
`/tmp/budget-core-sharing-before.log`, `/tmp/budget-core-sharing-final.log`.
No server, native presentation, schema or financial changes in this checkpoint.

Demo access-profile contract after `51f65e0`: initial profiles now describe actual seeded manager /
delegated capabilities and resource scopes instead of presenting every member as unrestricted
view-only. Updates validate supported/unique capabilities, unique budget-local resource IDs and
required restriction flags before mutation; stale versions refuse. Custom profiles retain the
underlying manage/contribute grant rather than returning the server-invalid `custom` grant value.
Lists are sorted as in Live. Attribution now uses the actual owner (Rey), injected clock and one
`access_profile_updated` event with member identity, rather than fabricated Alex/September-16 values.
Native regression covers invalid atomic refusal, unchanged history, correct actor/time, stale replay,
and unchanged money. This closes profile contract/audit correctness, not full dynamic custom-scope
enforcement throughout Demo; that broader provider parity remains open.
Verification: 131 native tests + 2 production household UI tests PASS on the existing Xcode 27 Beta
iPhone 17 Pro Max simulator; build PASS. Four backend household/authorization reference tests PASS.
Logs: `/tmp/budget-demo-access-profile-native.log` and
`/tmp/budget-demo-access-profile-reference.log`; `git diff --check` PASS.

Capability contract audit after `1d5d163`: `APIBudget.can` defaulted to true for unlisted capabilities,
making legacy view-only grants appear eligible for edit/delete/payee/export/own-category actions and
accepting unknown capability names. Two shared-vector tests reproduced 25 mismatches. Swift now
uses the exact server legacy view/contribute/manage matrix, preserves explicit custom-capability
replacement and owner authority for known capabilities, and fails closed for unknown names.
A shared 21-capability JSON contract is checked against both the Swift implementation and Python
authorization constants/Pydantic capability vocabulary. Server enforcement was already restrictive;
this was a client presentation/provider-contract mismatch, not proof of a Live server bypass.
Native/package verification: **48 Core + 54 API tests PASS; 130 native + 2 production UI PASS**,
Beta build/diff check PASS. Owner access editing and delegated request cancellation retain their
shared production paths. Logs `/tmp/budget-capabilities-package.log`, `/tmp/budget-capabilities-native.log`;
xcresult `Test-BudgetApp-2026.09.18_19-09-34--0400.xcresult`. Eight focused backend contract/privacy
tests pass. Follow-ups: Demo access-profile attribution/resource validation and the unused Core
sharing authorizer's manager-versus-owner semantics require correction before provider closure.
Full verification: **460 backend tests PASS, zero skips**, including PostgreSQL concurrency,
populated migrations and real encrypted recovery; `/tmp/budget-capabilities-backend.log` (122.97s).
No server behavior/migration change and no human data changes.

Workspace revocation privacy after `7998fec`: two real Live-repository-composition tests first
reproduced retained financial observations after 403/404 and late snapshot/report resurrection.
Core hydration now uses latest-request identity. Definitive core 403/404 clears financial collections,
reports and selected report filters, cancels pending report/browser tasks and advances authority
generation. Old async results cannot republish; known-denied service/report calls refuse locally.
The unified shell replaces financial tabs (and their editors) with an access-unavailable Retry /
Profile & Settings surface. A later successful authoritative refresh restores access; 503/network
failure retains cached state rather than pretending it is revocation. No automatic sign-out,
token-expiration change, server mutation or authentication-lifecycle rewrite.

The first broad test exposed a fixture mismatch: credential-rotation coverage returned blanket
404s for the successful command's required workspace hydration. It now returns valid read responses
and additionally asserts no access-denied/error state, preserving all token-rotation assertions.
Scope is workspace observations/in-flight workspace reads; this is not a claim of secure erasure
of previously exported/downloaded files or universal authority-loss handling in every local cache.
Verification: **130 native XCTest + 2 production XCUITest PASS; 48 Core + 52 API PASS;
459 full backend PASS, zero skips**, including disposable PostgreSQL concurrency, populated
migrations and encrypted recovery. Production UI covers fresh tabs/global profile and dark-mode
accessibility-sized Insights after the shared shell change. Logs
`/tmp/budget-workspace-revocation-{final,package,backend}.log`; backend 125.72s;
xcresult `Test-BudgetApp-2026.09.18_19-00-32--0400.xcresult`. Diff check PASS. No migration/human-data changes.
Docker/Podman discovery still returns no executable; real Compose proof remains open, independently
of the successful real PostgreSQL/encryption recovery tests.

Demo membership revocation after `cc914d8`: removal now retains inactive membership and increments
its authorization version with one attributed access event. Owner/unknown/duplicate targets refuse;
non-owners cannot administer membership or access profiles. Every asynchronous Demo repository
entry checks the current actor's active membership before reads or mutations, including attachments,
reports and command services. Allowance issuance/reactivation and new category delegation recheck
the recipient's membership. Existing transactions, categories, allocations and request history are
not deleted/reallocated; creating a rejoin invitation alone never restores access. Shared removal
uses an explicit Keep Member / Remove Member alert and retains the removed row after refresh.
The prior access-profile test used a nonexistent `demo-member`; it now uses the actual Jordan
membership, while removed/unknown targets refuse. Demo invitation acceptance and full dynamic
custom-capability parity remain open. This does not claim to solve Live client cached-data eviction
after remote revocation; repository denial and stale client presentation are separate concerns.
Verification: **128 native XCTest + 2 production XCUITest PASS**, Xcode 27 Beta build/diff check
PASS on preserved iPhone 17 Pro Max `3ABD861E-D38D-4AFD-A356-959266051564`.
Native tests prove revoked read/write denial, recipient refusal, preserved financial history and
guard coverage across every current async Demo repository entry. UI proves Keep Member cancels,
Remove Member persists after navigation, and existing owner access editing still works.
**20 backend household/allowance reference tests PASS** (collection-confirmed); no server changes,
so the prior 459 full backend and 48 Core/52 API evidence remain applicable, not rerun here.
Logs `/tmp/budget-demo-membership-final.log`, `/tmp/budget-demo-membership-reference.log`;
xcresult `Test-BudgetApp-2026.09.18_18-50-28--0400.xcresult`. No human data/migration changes.

Demo invitation management after `874fa2b`: replaced create/resend/cancel/list/history placeholders
with workspace-retained records and owner-only commands. Emails normalize, existing members and
invalid roles refuse, expiry is seven days, resend preserves recipient/role while replacing identity
and cancelling the prior invitation, and cancellation is idempotent. Summary/history never retain
the one-time simulation code. Event history has stable time/ID order and the server's 200-row bound.
Request and invitation lifecycles share an injectable provider clock; other Demo clocks remain open.
This is ephemeral Demo-provider state, not durable Local Device storage. Demo invitation acceptance,
member revocation and dynamic persona authority remain explicitly unfinished; no Live auth bypass.
Verification: **126 native XCTest + 1 production invitation XCUITest PASS; 48 Core + 52 API PASS**,
Beta simulator build and diff check PASS. Native regression covers normalization, seven-day expiry,
resend rotation, idempotent cancel, partner/child denial, invalid input, the 200-event bound and
unchanged accounts/transactions/allocation version. Production UI now confirms the created row
survives code dismissal and cancellation changes its visible status. Final logs
`/tmp/budget-demo-invitations-native-final.log`, `/tmp/budget-demo-invitations-package.log`;
xcresult `Test-BudgetApp-2026.09.18_18-42-07--0400.xcresult`. Initial compile failed on a missing
function brace, corrected before this final full run. Server unchanged from 459-PASS checkpoint.

Household query audit after `9710981`: both invitation summaries and access-event history loaded the
entire server user directory (including unused password-hash columns) merely to resolve names.
A 2,000-unrelated-user regression reproduced both unrestricted queries. Display names now come
from scalar columns joined to household-authorized invitations/events; no global directory hydration,
password hash selection or per-row name query. Owner authorization, ordering, removed-member names,
nullable subject fallback and the 200-event history bound are preserved. This was unnecessary internal
hydration, not evidence of password hashes appearing in API responses. Invitation-list pagination
remains a separate open scaling gap; this checkpoint does not claim to bound invitation history.
Verification: **11 focused household/family tests PASS; 459 full backend tests PASS, zero skips**,
including disposable PostgreSQL races, populated migrations, golden vectors and encrypted recovery.
Logs `/tmp/budget-household-scope-focused-final.log` and `/tmp/budget-household-scope-backend.log`.
Focused count corrected against pytest collection (previously miscounted as 19); full-suite total
was confirmed directly by pytest's 459-PASS summary and is unchanged.
Diff check PASS. No native code changed after the preceding 125-native/1-UI Beta PASS checkpoint.
Human Live remains untouched at 0020; no new migration, merge or tag.

Household presentation audit after `e45e4d7`: invitation creation previously called `dismiss()`,
awaited a reload, then set a second sheet binding. Network completion did not establish that the
first presentation had finished dismissing. The one-time code now waits in parent state until
SwiftUI's `onDismiss` callback. Creation cannot be interactively dismissed/cancelled while saving,
and duplicate create callbacks are guarded. No arbitrary delay or additional network request.
Demo invitation persistence is still a separate open provider gap; this is shared presentation work.
Final verification: **125 native XCTest + 1 production invitation XCUITest PASS**, Beta simulator
build and diff check PASS, `/tmp/budget-invitation-presentation-final.log`. The UI journey creates,
opens the code only after creation closes, dismisses it, then cancels a second creation without
reopening the previous code. No backend/package source changes; preceding package/backend evidence
retained. An overlapping-presentation warning remains in the separate hosted authentication-form
native test (`testProductionDemoToLiveAuthenticationFormRetainsContinuousInputAndFocus`); this
checkpoint does not claim to eliminate all presentation diagnostics or confirm a platform cause.

Allocation-version investigation corrected a backlog assumption: the Live allocation-list route
intentionally returns the budget's CURRENT optimistic concurrency token on each response, not a
historical operation version. The existing compound-funding contract test caught an attempted Demo
reinterpretation. That experiment was fully withdrawn; no financial/source change was retained.
A future immutable operation-version feature must define a separate contract and migration rather
than silently repurpose `allocation_version`. Operation IDs/postings/dates remain historical.

Demo request lifecycle after `d1ac8f5`: create/revise/cancel/decision now store actual request type,
version, expiry and ordered action provenance rather than deriving version from status or returning
success without mutation. Requester ownership, current destination scope, stale versions, terminal
states and validation are checked before transitions. Approval still uses the canonical dated
allocation projection, recording its operation/source and one version increment. Nonfinancial
transitions never change allocations/accounts/transactions. Visible due requests expire exactly
once under an injected request clock; legacy seed requests explicitly retain nullable expiry.

Shared UI ownership now resolves optional actor identity through the provider contract, falling back
to the authenticated Live profile. There is no Demo-specific screen or downcast. Cancel/Revise were
previously unreachable in Demo because they required a Live profile. Home now includes requests
requiring changes, and a shared Active/History list keeps completed request provenance reachable.
Cancellation requires a native confirmation alert with explicit Keep/Cancel actions.

Verification: **125 native XCTest + 1 production request-navigation XCUITest PASS**, using Xcode
27.0 Beta (27A5252f), existing iPhone 17 Pro Max / iOS 27 device
`3ABD861E-D38D-4AFD-A356-959266051564`. The UI journey cancels dismissal, confirms cancellation,
then reopens the retained history entry. Financial regression covers revision, stale versions,
partial approval, duplicate rejection, scope, batch expiry and unchanged actual balances.
**48 BudgetCore + 52 BudgetAPI tests PASS; 14 backend request reference tests PASS**.
Evidence: `/tmp/budget-demo-request-journey.log`, `/tmp/budget-demo-request-package.log`,
`/tmp/budget-demo-request-reference.log`; diff check PASS. No backend or migration change in this
checkpoint; prior full backend remains 458 passed. Dynamic child custom-approver parity remains
open: Demo conservatively denies that role. Human acceptance remains pending; do not retest.

Request lifecycle hardening after `e80d2b8`: two new regressions first reproduced a resource-scope
leak and short-circuited expiry. `approve_request` alone previously exposed requests targeting hidden
categories and allowed reject/change decisions on those requests. Destination scope now filters SQL
before loading and guards every decision; an otherwise readable request never reveals a funding
source outside the approver's category scope. Hidden decisions return 404 without audit/version change.

Batch expiry previously used `any(generator)`, leaving all due rows after the first untouched.
Every due visible row is now processed. Only due rows are locked/reloaded before rechecking expiry,
so concurrent listing/decision cannot duplicate expiry or fund an expired request, without locking
the whole historical browser. Legacy requests with no expiration retain their existing semantics.
New PostgreSQL races cover concurrent listings and listing versus approval. Demo request revision /
cancellation still require implementation against this corrected contract; no claim of that closure.
Verification: **14 focused delegated/request tests PASS; 458 full backend tests PASS, zero skips**,
including the final due-row-only locking races on real disposable PostgreSQL, golden financial
vectors, populated migrations and encrypted recovery. Diff check PASS.
Final log `/tmp/budget-request-lifecycle-backend-final.log`; focused log
`/tmp/budget-request-lifecycle-focused.log`. No Swift changes or native rerun in this checkpoint.
Human Live/Simulator remain untouched; no migration, merge or tag.

Demo allowance lifecycle after `465f20b`: canonical create/pause/reactivate/issue/history commands
replace silent no-ops. Plans use stable category IDs, ISO issue dates and explicit cadence; the
shared household list now uses the actual Rey/Jordan/Alex/Mia identities. Category creation respects
the selected delegated recipient. The old direct-display allowance mutation helper is removed.
Creation/status changes are money-neutral. Issuance validates dated source funds, expected allocation
version, exact unique splits, active delegated destinations and current recipient visibility; it
preflights one compound projection before publishing one operation/version, history and next date.
Weekly/monthly recurrence and unused-fund reclaim are implemented. Account/transaction/card state
is unchanged. Duplicate dates and stale commands refuse. Operation serialization now includes every
balanced leg instead of dropping all but the first leg of a compound non-Smart-Funding operation.

Seed plans now reference delegated destinations only: Alex's $20 plan sends $12 to allowance and
$8 to savings, rather than $3 to a nondelegated household Giving category. This is a planned Demo
fixture correction, not an existing Live transfer. Recipient views redact source and sibling plans;
owner/partner management honors stored category scope. Child personas remain conservatively unable
to manage allowances even if their Demo custom capability profile is broadened; general dynamic
persona/capability parity remains open alongside membership lifecycle and other request no-ops.
The new month-end regression caught a real Foundation timezone mismatch: parsing August 31 at UTC
but adding months in `America/New_York` produced October 1 instead of September 30. An isolated
Foundation reproduction confirmed it. Allowance recurrence and the shared future-month policy
picker now both use an explicitly UTC Gregorian calendar for their date-only arithmetic.
Verification: **124 native XCTest + 2 production XCUITest PASS**, Beta build and diff check PASS;
**48 Core + 52 API PASS**; **9 server allowance reference tests PASS**. The separate production
household-member access UI regression also passed with Jordan's corrected identity. Server code is
unchanged from the preceding **454-backend-test** checkpoint. Logs:
`/tmp/budget-demo-allowance-utc-final.log`, `/tmp/budget-demo-allowance-final.log` (household UI PASS;
superseded failed date assertion), `/tmp/budget-demo-allowance-package.log`,
`/tmp/budget-demo-allowance-server-reference.log`. No human data, migration, merge or tag.

Allowance authorization checkpoint after `055c74f`: an adversarial regression reproduced a hidden
source leak when a resource-restricted member held `manage_allowances`. Capability alone had
authorized the whole plan. Lists now filter complete destination scope (and manager source scope)
in SQL before serialization. Create, pause/reactivate, deactivate, issuance and history require the
same resource boundary. Recipient-only readers still receive no source identity, and cannot see
partially hidden split totals. Hidden-resource actions return 404 without financial mutation.
Issuance additionally revalidates active recipient membership, current delegated category ownership,
nonarchived categories and recipient visibility before appending allocations. Revoked plans cannot
continue moving money merely because they were authorized when created. Authorized complete-scope
managers continue to issue normally. Demo allowance implementation remains the next provider gap.
Verification: **9 focused allowance tests PASS; 454 full backend PASS, zero skips**, including
PostgreSQL concurrency/migrations/encrypted recovery and financial vectors. Diff check PASS.
Log `/tmp/budget-allowance-scope-backend.log`. No Swift changes in this security checkpoint;
the preceding native/package/build evidence remains valid but was not rerun for server-only edits.
No migration or human-data mutation.

Creation checkpoint after `44a2bc5`: the native new-budget form now recommends Absorb next month
and offers Carry explicitly. AppSession/API pass the choice to the canonical owner-authorized create
route. Budget plus version-zero `budget_creation` provenance are committed atomically, attributed
to the authenticated owner. The baseline covers the new budget's complete history (0001-01-01),
including later imported historical transactions. It generates no financial operation and leaves
the allocation version at zero. Omission/null retains carry for older clients; existing budgets and
seeded Demo fixtures retain their established policies. Invalid choices create no budget.

Verification: **449 backend PASS, zero skips**, including PostgreSQL concurrency, populated migration
and real encrypted recovery; **48 Core + 52 API PASS**; **122 native + 1 production UI PASS**;
Beta simulator build/diff check PASS. Logs `/tmp/budget-policy-creation-{backend,package,native}.log`.
The native creation/session regression retains immediate active-budget routing. No new migration;
policy storage uses 0029, still unapplied to human Live. Human creation/settings acceptance remains
pending. Next highest-priority proven gap: Demo allowance commands still silently return success
without implementing their production lifecycle; implement canonical versioned/atomic allocation
and issuance history rather than reusing the old direct-display mutation helper.

Shared settings checkpoint after `5fd6d8f`: Profile & Settings now exposes owner-only Cash Rollover
through the same workspace store in Live and Demo. It explains cash versus card consequences,
separates current and pending policies, offers the next 24 authoritative months and requires an
explicit native alert confirmation. History loads 50 decisions per page; stale/error paths offer
reload rather than silently changing concurrency tokens. Production XCUITest proves Cancel has
no pending effect, confirmed selection persists across reopening, and current policy stays carry.
Initial UI proof found the confirmation-dialog Cancel absent from accessibility; the final native
alert provides both actions. The current-policy observation now has an explicit VoiceOver value.

Final verification: **122 native XCTest + 1 production XCUITest PASS**, Xcode 27 Beta build PASS,
diff check PASS. Log `/tmp/budget-policy-settings-verified.log`. Existing package evidence is
**48 Core + 51 API PASS**; server unchanged from **446 backend PASS**. New-budget default activation
is the next uncompleted policy gate. No human database migration, reset, merge or tag occurred.

Swift policy-service checkpoint after `aeaa298`: typed BudgetAPI read/selection/history contracts
and provider-neutral planning services now support the server policy API. Every Live operation
resolves the shared current credential at execution; a retained workspace regression exercises
read, selection and history after token rotation. Demo implements the same prospective selection,
optimistic versions, no-op behavior and immutable decision provenance. Candidate projection is
validated before publication; owner-only checks also reject the full-access partner. The Demo
budget now identifies that partner as `manage`, not incorrectly as `owner`.

Verification: **122 native XCTest PASS**, **48 BudgetCore + 51 BudgetAPI PASS**, Beta simulator
test build PASS and diff check PASS. Native log `/tmp/budget-policy-client-native.log`; package
log `/tmp/budget-policy-client-package.log`. Server remains unchanged from the **446-test** backend
checkpoint below. Shared owner settings and explicit new-budget default activation remain pending;
this service checkpoint does not expose a new setting or migrate human data.

Prospective policy API after `09a8ae6`: owner-authorized GET/PUT
`/api/v1/budgets/{budget_id}/cash-rollover-policy` exposes current policy, current month, both
policy/allocation versions and the latest choices for future effective months. GET `/history`
is descending-version cursor-paged (50 default, 100 maximum) with immutable source/actor/timestamp.
Owner-only authority follows existing budget creation and household settings; even a delegated
`manage` budget grant does not confer control over household-wide rollover. Nonvisible budgets
remain 404, visible nonowners 403, unauthenticated requests 401.

PUT requires `policy`, first-day future `effective_month`, `expected_policy_version` and
`expected_allocation_version`. The ordinary budget lock serializes choices; both tokens are checked
before no-op handling. Real changes append provenance and increment the allocation token once,
invalidating assignment/Smart Funding previews without generating financial operations. Revisions
of a pending month preserve earlier decisions. Crossing the effective boundary changes the observed
current policy without background posting. Projection/range failure after flush rolls back history
and tokens together. A previously unstamped legacy budget receives an explicit version-zero legacy
carry baseline on its first actual selection, not a fabricated user action. Reads do not create it.

**Server selection is now functional for an explicit authorized future choice; native settings and
new-budget default activation are still pending.** No human database migration or deployment was
performed; existing public creation still retains legacy behavior. Next implement the provider-neutral
Swift API/application-service/Demo command path, stale-credential tests and shared owner settings,
then activate explicit new-budget defaults with legacy-preserving migration/recovery proof.
Verification: **446 backend PASS, zero skips**, including real PostgreSQL policy concurrency,
post-flush rollback, exact stale Smart Funding/assignment denial, policy boundary observation,
owner/cross-budget authorization, immutable revisions and bounded audit paging. Existing populated
migration and real age-encrypted PostgreSQL recovery suites remain green. `git diff --check` PASS.
Log `/tmp/budget-rollover-policy-backend-final.log`. No Swift source changes in this checkpoint;
native/package/UI/build evidence remains the preceding `09a8ae6` verification, not a new native run.


Historical Plan Performance correction after `e7959aa`: Demo now reports the requested inclusive
Gregorian periods independently of the selected Plan month, with exact partial-period carry,
Assigned/Activity/Available and dated Unassigned. Recorded card-reserve activity affects purpose
availability but not spending; refund-only spending remains negative rather than clamped to zero.
Archived category history remains included. Account/category scope applies before totals and
restricted Unassigned remains zero. The explicit Demo opening bounds available history; earlier
periods are omitted, not fabricated. Ordered ranges are limited to the server's 600-calendar-month
contract before projection. Prepared ledger inputs and ISO dates are reused across periods.

Native service tests and the matching FastAPI reference fixture prove split spending, moves,
funded credit, refunds, partial start/end days, archive preservation, hidden/shared accounts and
category privacy. Rollover tests now cross a partial historical report boundary independently of
the selected Plan month. Empty/pre-opening and invalid/oversized ranges are covered.
This exposed an existing coupling: Demo transaction browsing built a 200-year complete report to
get transaction DTOs. Browsing now shares the same scoped transaction mapper directly with workspace
loading; no report-range workaround or weakened validation. The old report test comparing a cutoff
report to month-end category totals was replaced by cutoff/RTA and carry+assignment+activity checks,
with exact server-shaped expected monetary observations in the new production-service regression.

Next: prospective policy command lifecycle, locking/version invalidation and shared settings, then
explicit new-budget defaults. No public policy setting is activated by this checkpoint. Broad server
report hydration, Demo allowance issuance, clocks, Local Device and other mission gates remain open.
Verification: **439 backend PASS, zero skips; 121 native XCTest; 48 BudgetCore + 50 BudgetAPI;
2 production report XCUITests PASS**. UI verifies at least six distinct historical chart periods
and currency accessibility across Income/Spending, Net Worth and Plan. Beta build and diff check
PASS. Xcode 27.0 `27A5252f` at `/Users/firepika/Downloads/Xcode-beta.app/Contents/Developer`, existing
iPhone 17 Pro Max/iOS 27 `3ABD861E-D38D-4AFD-A356-959266051564`; no reset or human data changes.
Logs `/tmp/budget-plan-history-{server-reference,backend,native-final,package,ui}.log`. Earlier
`focused.log`/`native.log` preserve the scope-fixture and 200-year-browser failures addressed above.


Demo rollover integration after `de9ebd3`: the actual Demo repository accepts effective policy
history (default remains legacy carry) and supplies dated opening, allocation, on-budget direct/
split activity and signed recorded credit attribution to the shared boundary engine. Period reads,
assignment/Smart Funding/move preflights and card purchase funding use the resulting carry and
Unassigned. Additional-allocation previews recompute pending effects before publishing; refund/
deletion recomputation adds no allocation. Request approval no longer mutates displayed category
totals directly: it checks dated ledger availability and validates the complete projection before
publishing the request decision and balanced allocation. Rejection fixtures now create actual
ledger insufficiency/overflow rather than corrupting derived display fields.

Four production application-service/native regressions cover monthly/global observations and
read neutrality, denial/metadata-history preservation, refunds, split coverage/moves/deletion,
unfunded credit versus subsequent funded purchases, and effective/pending policy revisions.
**No public policy command, default activation or human migration yet.** The audit also explicitly
found Demo Plan Performance still emits one selected-month point instead of the server's historical
series. Correct that range/partial-period projection before claiming full report parity or exposing
policy settings. Demo allowance issuance, injected clocks and other recorded roadmap gaps remain.
Verification: **439 backend PASS, zero skips; 119 native XCTest; 48 BudgetCore + 50 BudgetAPI;
2 production Plan/Smart Funding XCUITests PASS**. Beta build and diff check PASS. Native tools use
`/Users/firepika/Downloads/Xcode-beta.app/Contents/Developer`, Xcode 27.0 `27A5252f`, existing
iPhone 17 Pro Max/iOS 27 `3ABD861E-D38D-4AFD-A356-959266051564`; global xcode-select remains
stable but every native invocation explicitly overrides it. No Simulator erase or human-data change.
Logs `/tmp/budget-rollover-demo-{focused,native-final,ui,package,backend}.log`; the initial full native
failure is retained in `native.log` and explains the corrected display-only adversarial fixtures.


Rollover service integration after `f89ee57`: a single repository adapter streams scalar allocation,
on-budget direct/split activity and signed reserve facts, retaining month/category accumulators
instead of transaction objects. It resolves the latest revision of each effective policy month.
Legacy carry-only budgets skip the ledger scan. Dated balance guards, global spendable Unassigned,
monthly carry and Plan Performance now consume those same derived effects. No synthetic assignment,
transaction or read-time write is made. Singleton category guards narrow the scan; scoped reports
filter accounts/categories before deriving effects. An adjacent privacy gap was corrected: existing
monthly/Plan Performance reserve-event reads now enforce the same account scope as transactions.

Production-service regressions cover dated/global agreement, repeat-read neutrality, unchanged
Assigned/Activity/transaction/account/history observations, assignment refusal, policy revisions,
credit debt exclusion, hidden-account/reserve privacy, post-boundary card funding and historical
cash refunds. A real PostgreSQL race proves two allocations cannot spend cash already absorbed.
**Public policy selection/default activation remains gated** on Demo provider integration, command
lifecycle/versioning and shared settings. Existing public budgets remain carry-only. This is not
human acceptance or production closure. Human Live remains untouched at 0020; no new migration
or Swift source change in this checkpoint. Current application code requires the current migrated
schema; the populated migration fixture seeds via current APIs and then downgrades its empty
policy table before testing the real 0028→0029 upgrade, rather than running new code on an old schema.
Verification: **439 backend PASS, zero skips; 48 BudgetCore + 50 BudgetAPI PASS**. Focused
projection/service/PostgreSQL race checks: **31 PASS**. Diff check PASS. Logs:
`/tmp/budget-rollover-consumers-{focused-final,backend-final,package}.log`. No Swift source changed;
native XCTest/UI/build evidence remains the preceding `f89ee57` run, not a new native run.


Rollover projection foundation after `6791157`: Python and Swift consume 17 shared exact vectors
for derived boundary effects, including legacy carry, cash absorption, cumulative prior credit
debt, signed funding/refunds, split categories, policy switches/pending revisions, long sparse gaps,
leap/year limits and integer cancellation/overflow. Effects do not post money. The Swift monthly
projection applies them to carry and Unassigned separately from user Assigned/Activity and rejects
duplicate category/month effects. Future effects reserve already-spent cash consistently with
future allocations, while dated pre-boundary RTA remains unchanged. Historical fact edits recompute
amounts under the historical policy, not a newly selected current enum.
**At this earlier projection checkpoint, repository activation was still gated**: Live/Demo
operations did not supply policy effects. Every balance guard, report and command must integrate before exposing the setting
or changing new-budget defaults. These pure/shared-vector tests are not full production rollover
acceptance, and do not close the financial/product gates. No new migration or human data changes.
Verification: **433 backend PASS, zero skips; 48 BudgetCore + 50 BudgetAPI; 115 native XCTest;
2 production Plan/Smart Funding XCUITests PASS**. Xcode Beta build and diff check PASS. Focused
projection checks: **25 PASS**. Logs `/tmp/budget-rollover-projection-{focused-final,package-final,backend,native,ui}.log`.

Rollover-history persistence foundation after `929a27c` (verified): additive
`0029_cash_rollover_history` records an explicit legacy carry baseline for each existing budget,
bounded 500-budget batches, and constrained effective-month/version/source/actor provenance.
502-budget populated SQLite and PostgreSQL upgrades preserve existing rows and financial API
observations. Baseline-only downgrade/re-upgrade is safe; downgrade refuses to discard real policy
decisions. Complete PostgreSQL dump/restore and actual age-encrypted new-destination recovery now
include nonempty policy history in exact row equality, alongside attachment integrity and finances.
**408 backend PASS, zero skips**; focused migration/constraint tests, one-head/revision-length graph,
`alembic heads/history` and diff check PASS. Logs `/tmp/budget-rollover-history-{focused,batched,backend-final}.log`.
No Swift source changes in this checkpoint; native/package evidence remains the preceding verified
`929a27c` checkpoint. Human Live is NOT migrated. **Absorption/new-budget defaults/settings are NOT
activated**: canonical effective-history projections, every balance guard/report, command lifecycle
and shared UI must integrate before this financial policy is exposed. This is not v0.9 closure.

Cash/card reporting prerequisite after `556c8d3`: native reproduction proved a funded 10,000 card
purchase followed by a 10,000 cash expense was incorrectly reported as unfunded credit in Demo.
Live's matching production API case correctly reports cash overspending. A 3,000 card refund
preserved the same Demo mismatch. The estimate is replaced by visible selected-month transaction
activity plus signed reserve attribution recorded by the canonical posting path. Exact accumulation
and checked deficit conversion avoid introducing trap-prone reporting arithmetic. No posting,
reserve movement, allocation or policy semantics changed. Coverage includes refund deletion,
purchase edit, void/reversal and a split with both funded and unfunded categories.
Reproduction: `/tmp/budget-credit-classification-reproduction.log`; Live reference:
`/tmp/budget-credit-classification-server-reference.log`. This is a prerequisite to prospective
cash rollover, not implementation or acceptance of that remaining policy work.
Verification: **400 backend zero skips, 115 native XCTest, 45 Core + 50 API, 2 production UI PASS**;
Beta build/test and diff check PASS. UI covers Home attention → category resolution and canonical
Make Recurring → void/reversal. Logs `/tmp/budget-credit-classification-{backend,package,native-final,native-verified}.log`.
No new migration/server-code changes in this classification checkpoint; human data untouched.

Dated/current funding explanation after pushed `f42f262` (verified): monthly responses expose
optional canonical all-date Unassigned and the existing Smart Funding limit without changing dated
RTA or assignment semantics. Shared Plan distinguishes these values and explains later allocations,
posted activity and non-spendable scheduled income. Global values are omitted for scoped
accounts/categories or missing balance capability; older servers remain compatible. Server
aggregates use existing SQL sums, not a second ledger or unbounded transaction hydration.
Future allocation/release preserves historical category observations and actual account balances.
**399 backend zero skips, 114 native XCTest, 45 Core + 50 API, 2 production UI PASS**; Beta build
and diff check PASS. UI checks the actual explanation after returning from a future assignment
and exercises Smart Funding cancel/confirm/refresh. Focused backend: **15 PASS**. Logs:
`/tmp/budget-month-funding-{focused,backend,package,native-final}.log`.
Initial test compile failures (Python 3.9 optional annotation and Swift optional test unwrap) were
corrected before the successful suites. No schema migration; eventual adoption needs server
restart/app rebuild. Human Live/Simulator data untouched. Remaining classification/rollover/clock
and broader mission gates are not closed by this checkpoint.

Allocation command parity after `1b91b7c` (verified): Demo no longer hardcodes allocation version 1
or ignores expected versions. Same-token commands have one winner; stale no-ops conflict, current
no-ops do not add operations, and moving money away/back cannot revive an old token. Smart Funding
preflights the complete compound operation/projections before any mutation, advances one version,
and presents one balanced history identity with all category legs. Restricted history excludes the
whole operation. Fresh/fixture version provenance and shared-vector adapters are corrected.
**398 backend zero skips, 113 native XCTest, 45 Core + 49 API, 3 production XCUITests PASS**;
Beta simulator build/test and `git diff --check` PASS. UI covers independent month assignment,
Move Money source context, and Smart Funding cancel/confirm/refresh. Backend retains actual
disposable PostgreSQL same-token and cross-month race coverage. Logs:
`/tmp/budget-allocation-version-{backend,package,final,native-final}.log`.
No server/schema changes. Subsequent Plan cash-reservation explanation, prospective rollover,
uniform clocks and remaining roadmap work are still required; this does not close v0.9.

Chronological forecast correction after pushed `bed7c93` (verified): the same
outflow/transfer/later-income scenario reproduced a Demo low of 10,000 versus the server's correct
2,000 minor units. Demo now expands permitted active schedules, sorts occurrences by date/ID like
the server, applies both transfer legs before measuring totals, and carries the true intermediate
minimum into Forecast and Resilience. Checked exact arithmetic refuses unrepresentable projection
amounts without changing actual accounts/transactions/Unassigned. A silent 400-step recurrence
cutoff is replaced with bounded expansion and explicit failure; a daily schedule started in 2025
now correctly emits all 91 in-horizon dates, and paused schedules remain excluded.
Reproduction: `/tmp/budget-forecast-low-reproduction.log`; authoritative matching case:
`/tmp/budget-forecast-low-server-reference.log`. **398 backend zero skips, 111 native, 45 Core +
49 API, 2 production XCUITests PASS**; Beta build/test and diff check PASS. UI verifies scheduled
entry remains distinct from actual activity and Enter Now realizes through the production path.
Logs `/tmp/budget-forecast-low-{backend,native,package,ui}.log`. No server code or migration changes.
Demo's fixed September 2026 forecast anchor is deliberately unchanged in this focused correction;
uniform injected provider/test clocks and unrelated report aggregate overflow remain open.

Forecast privacy correction after pushed `1c3b162` (verified): a new Live-shaped
regression proved that management listed one permitted bill while Forecast exposed that bill,
a hidden-category household bill, and uncategorized future salary on the same visible account.
Resilience also inherited the hidden schedules in its aggregates. Schedule reads now share a
SQL-scoped query (source/destination accounts and category scope) before hydration/expansion;
category-restricted users cannot receive uncategorized household schedules. Demo management and
projection apply the same exclusion. Tests cover names/IDs, projected/lowest balances, Resilience
income/outflow/margin, empty scope after revocation, explicit unrestricted access and unchanged
actual money. Owner behavior and active/inactive defaults remain unchanged. No migration.
Reproduction: `/tmp/budget-forecast-privacy-reproduction.log` (failed before correction).
Verification: `/tmp/budget-forecast-privacy-{focused,backend,native,package}.log`.
**397 backend tests PASS, zero skips**, including disposable PostgreSQL/concurrency/migration/
recovery; **109 native + 45 Core + 49 API PASS**, Beta build/test and diff check PASS. Server restart
is needed when adopting this code later; no migration. Human acceptance remains pending.
The read audit also identified a separate Demo forecast issue: lowest balance currently uses only
the start/end minimum rather than chronological occurrences. That and unchecked report/forecast
arithmetic remain open; do not fold an untested financial-definition change into this scope fix.

Opening/legacy-split hardening after pushed `75226d5` (verified): account creation
checks the resulting Unassigned balance before inserting either account or opening transaction,
and the production Demo repository propagates refusal. Legacy split attribution uses signed
quotient/remainder arithmetic instead of `abs`, supporting Int64.min without a trap and conserving
the total even for repeated legacy category references. Legacy write helpers reject duplicate
category selections. Tests exercise both opening limits, valid cancellation/retry, signed extrema,
deterministic remainder order, uncategorized minimum-value entry, and refusal of duplicate edits.
No server or migration changes. Report/forecast aggregation remains a separate open crash-risk
surface; this checkpoint does not establish safe rendering for all extreme-value datasets.
Evidence: `/tmp/budget-opening-split-{native-final,backend}.log`.
**108 native XCTest + 1 fresh-account production XCUITest + 5 focused backend account tests PASS**;
Beta build/test and diff check PASS. Shared package code unchanged from 45 Core + 49 API PASS.
The UI creates a $2,000 account and preserves its balance across rename and safe type editing.

Transfer arithmetic continuation after pushed `a1656ab` (verified): creation, editing
and deletion stage both account legs and cleared/card-reserve deltas before publication. Edits
accumulate old/new legs together with exact wide sums, so a valid final result is not rejected
merely because reversing the original first would overflow. Tests cover failed creation/deletion
without mutation, valid extreme-value edit cancellation, unchanged IDs and tracking-transfer
Unassigned neutrality. Existing payment-reserve funding guard remains. No server semantics or
human data changed. Evidence: `/tmp/budget-transfer-overflow-{native,backend}.log`.
**106 native XCTest + 1 production transfer XCUITest and 3 focused backend transfer tests PASS**;
Beta build/test and diff check PASS. The UI test exercises production create/edit, continuous
amount/memo input, and register refresh. Package code unchanged from 45 Core + 49 API PASS.
Account creation, legacy splitting, report and forecast arithmetic remain open audit surfaces.

Posting/reversal arithmetic checkpoint after pushed `ef90252` (verified): Demo account,
cleared, category, Unassigned and card-reserve mutations now use checked exact arithmetic. Deletion
and edit reversal throw into the existing financial checkpoint rollback rather than trap after a
partial mutation. Credit purchase magnitude comparison avoids negating Int64.min, and refund
attribution uses the shared exact accumulator. Boundary tests cover positive/negative posting
overflow and a deletion/edit whose reversal would overflow; all financial observations and
transaction identities must survive refusal. This does not certify transfer, creation, forecast,
or report arithmetic, and conservative rejection of an unrepresentable intermediate edit state
remains possible at extreme values. No server contract or human data changes.
**105 native XCTest and 23 server financial vectors PASS**, Beta simulator build/test and diff
check PASS. Logs `/tmp/budget-posting-overflow-{native-final,vectors}.log`. Shared package tests
remain 45 Core + 49 API PASS from `ef90252` (no package changes in this checkpoint).

Transaction input hardening after pushed `5be09de`: the shared application service previously
summed split amounts with trapping Int64 addition, and the Demo adapter constructed a unique-key
dictionary before rejecting duplicate categories. Both malformed inputs now produce validation
errors without mutation. The exact two-word accumulator already used by dated planning is reused
through `Money.sumMinorUnits`; valid mixed-sign cancellation is preserved, not rejected merely
because an intermediate Int64 sum overflows. Core boundary/cancellation tests, shared-service
rejection and direct-provider guards are covered. **45 Core + 49 API, 104 native, 3 focused backend
split tests PASS**; no server changes. Native build and strengthened direct-provider test rerun
PASS. Logs `/tmp/budget-split-validation-{package,native,backend,native-focused}.log`.
This is input-boundary hardening, not a claim that every provider mutation/report accumulator is
overflow-safe. Demo posting/reversal, transfer and forecast arithmetic remain the next exact-money
audit surface; preserve rollback and financial invariants when correcting them.

Reconciliation continuation (verified): Demo now forwards and enforces cutoff,
expected cleared observation, explicit adjustment consent and restricted-persona refusal. Only
cleared postings through the cutoff are locked; later cleared/uncleared postings remain unchanged.
Adjustments use the selected date and trimmed reason through the canonical transaction path.
The shared workspace now date-scopes its expected balance and displayed estimate, including
explicit opening observations. Server reconciliation remains authoritative and unchanged.
Native testing exposed a related Demo quick-clearing defect: account cleared totals were not
updated when flags changed. The correction stages checked totals before publishing mutations.
Tests now assert those totals, not just flags and working balance. A legacy golden-vector runner
also incorrectly reconciled today's opening balance through September 1; its unspecified cutoff
now matches the server runner's current day. Explicit period-vector dates remain unchanged.
Open follow-up: the shared cutoff estimate depends on the current complete visible transaction
snapshot. A bounded, server-authoritative reconciliation observation is needed before reducing
hydration or guaranteeing estimates for partially visible accounts. Server stale checks remain
in force; this checkpoint does not claim that broader scope/performance gate is closed.
Verification: **103 native XCTest + 2 production XCUITests PASS**, including register clearing
through reconciliation lockout and Activity clearing; **44 Core + 49 API PASS**; **7 focused server
reconciliation tests PASS** (no server changes); Xcode Beta build/test and diff check PASS.
Logs: `/tmp/budget-reconciliation-{native-complete,package,backend}.log`.
Initial stronger-native failures: `/tmp/budget-reconciliation-native{,-final}.log`.
Preserved iPhone 17 Pro Max / iOS 27, Xcode 27.0 27A5252f; same UDID recorded below.
Human acceptance remains pending. No Live migrations, reset, merge, or tags.

This ledger tracks engineering evidence separately from release approval. Main remains at
`c5494dd`; historical version tags do not establish acceptance for subsequent development.
Checkpoint completion is followed by the next unblocked engineering task.

Production monthly-provider checkpoint: exact dated facts now drive Demo month summaries,
assignment replacement, Move Money date guards, Smart Funding and dated card funding/refunds.
All **15 financial + 7 period scenarios** run through both full adapters. Failed transaction edits
restore the original reserve events; voids retain original plus reversing postings. Last reconciled
balance no longer aliases cleared balance. A fresh-category group crash and a real production
Previous/Today/Next List-button interaction were exposed by stronger integration coverage and fixed.
Verification: **396 backend (zero skips), 44 Core + 49 API, 101 native XCTest + 4 production UI tests
pass**, Xcode 27 Beta 27A5252f on preserved iPhone 17 Pro Max/iOS 27
`3ABD861E-D38D-4AFD-A356-959266051564`; build/test and diff check PASS.
Logs `/tmp/budget-period-integration-{backend,package,native-complete}.log`.
Before-fix evidence: `/tmp/budget-period-native-reproduction-values.log`,
`/tmp/budget-period-ui-month-reproduction.log`, `/tmp/budget-period-void-reproduction.log`.
No human migration/data reset. This is not v0.9 closure: prospective rollover, allocation-version
parity and reservation explanation remain open. Reconciliation input/date correction is described
above. Existing Simulator frame/QoS
diagnostics were not suppressed or declared resolved by these passing tests.

Deterministic opening-ledger checkpoint: production Demo financial seeds are now derived from
explicit 2025-10-01 openings, chronological allocations and actual posted transactions, including
canonical card reserve events. Independent hardcoded category Activity/Available and card reserves
are removed. The shared exact dated projection initializes current Plan observations. Native proof
reconstructs account Working/Cleared, every category and cash/purpose/reserve conservation; a fresh
Demo contains no fixture history. Demo display amounts intentionally change to match actual facts;
Live data is untouched. **395 backend (zero skips), 44 Core + 49 API, 98 native XCTest + 3 production
UI tests pass**, Beta build/test and diff check PASS. Logs `/tmp/budget-seed-ledger-{backend,package,native}.log`.
Full month-specific read/command routing and historical request metadata parity remain open;
see PERSISTENT-MONTH-IMPLEMENTATION.md. Human acceptance remains pending, not requested now.

Request-approval parity checkpoint: a native reproduction proved Demo ignored the chosen source
category and allowed a second approval to allocate again. The repository now checks capability,
pending state/version and decision inputs; the mutation helper validates both active categories,
positive bounded amount, available funds and checked arithmetic before changing anything. Actual
approval history uses the selected source and approval kind. Twelve invalid/unauthorized cases
preserve all observed state; duplicate approval preserves the first result. **97 native XCTest pass**,
Beta build/test PASS; four focused server request/approval cases also pass. Logs:
`/tmp/budget-request-approval-{reproduction,native-verified,server}.log`. No server production or
migration changes. Full Demo request revision/action-history parity is not claimed by this fix.

Allocation-history checkpoint: Demo no longer invents assignment rows from global totals or a $50
transfer on every read. Actual command events preserve identity/date/actor; whole-operation scope
prevents private-source disclosure. Opening fixtures remain separate from user history. **95 native
XCTest + 2 production assignment/Move Money UI tests pass**, Beta build/test and diff check PASS;
`/tmp/budget-allocation-journal-native-verified.log`. Package/backend unchanged from the verified
counts below. This does not close dated provider parity or make incomplete seeds a complete ledger.

Refund parity checkpoint: three new shared command vectors prove and correct Demo cross-card
reserve attribution, repeated refund release, and split-refund over-release (previously producing
a negative reserve). Attribution now nets prior releases within the same card/category/date scope;
ordered refund splits share one reserve cap. Server behavior remains unchanged. **395 backend,
44 Core + 49 API, 94 native XCTest + 2 production UI tests pass**, Beta build/test PASS.
Evidence: `/tmp/budget-refund-attribution-{full,package,native-verified}.log`; pre-fix failures in
`/tmp/budget-refund-attribution-native-reproduction-expanded.log`. No migration or human-data change.
Full dated provider/seed reserve parity remains open; this is a focused financial correction.

Current monthly migration characterization: six new provider-neutral, fixed-clock operation vectors
pass through the real server HTTP adapter, covering independent/future periods, date edits, cash
carry, credit/refund reserve continuity, splits/transfers and scheduled realization/reconciliation.
Repeated period reads and rejected assignments preserve every financial row. Full backend **392
pass, zero skips**, `/tmp/budget-period-vectors-full.log`. Original twelve shared vectors unchanged.
Demo parity and prospective rollover are still incomplete; this checkpoint establishes the contract
for the next dated-domain implementation, not release acceptance.

Exact dated projection foundation is verified by **44 Core + 49 API** and **94 native XCTest** on
the approved Beta toolchain. It consumes canonical posted activity/balanced allocations and keeps
dated versus spendable cash separate; it does not post accounts or calculate card reserves. This
component is not yet wired into Demo, whose incomplete seed/global state still requires migration.
No claim of provider parity from package-only projection tests. See PERSISTENT-MONTH-IMPLEMENTATION.md.

| Gate | Status | Evidence and remaining work |
|---|---|---|
| PRODUCT | IN PROGRESS | v0.4–v0.7 history is preserved; v0.8 automated closure and mission sequencing are documented. v0.9 planning/rollover and Demo allowance/request/invitation management have automated evidence above. Uniform clocks, Demo invitation acceptance/full dynamic capability parity, import/local-provider and later mission scope remain open. |
| FINANCIAL | IN PROGRESS | 23 shared single/multi-debt vectors include paid-off parity, horizon/high-APR boundaries, explicit rate transitions and calendar rounding; checked Int64 arithmetic and HTTP 422 boundaries pass. Current-cost estimates remain distinct from recorded and projected values. Release-wide invariant review remains open. |
| SECURITY | IN PROGRESS | Allocation/export scope, request/allowance authority, household query minimization and Demo membership revocation have focused adversarial evidence. Swift/server capability contracts, owner-only Core sharing and Demo attachment scope/identity now have regressions. Live Payee visibility excludes category-hidden income before ranking/counts and redacts hidden default-category IDs. Live core access denial evicts financial observations and invalidates late workspace results. Extend the matrix across all retained caches, reports, imports and future providers; no release-wide security PASS yet. |
| DATA | IN PROGRESS | Effective policy history now drives canonical projections and owner-authorized prospective settings; no migration silently changes legacy policy. Production Local Device uses encrypted SQLite storage, persists future-month planning and statement-import review/history, and supports encrypted/versioned local and Dropbox backup plus verified new-destination restore. Populated migration/concurrency and age-encrypted recovery cover canonical equality, snoozes, policy history and attachment integrity. Human Live migration, real Docker/Compose recovery, and complete lossless Server-to-Local transfer for server-only audit/household records remain open. |
| RELIABILITY | IN PROGRESS | Credential authority is shared by long-lived Live services. Native tests distinguish transient failure from definitive access denial and prove late snapshot/report results cannot resurrect denied state. Broader offline, lifecycle, cancellation and release-wide regression remain open. |
| PERFORMANCE | IN PROGRESS | Live core hydration makes zero detailed-report requests instead of seven; native tests cover caching/invalidation/retry. Hub has a bounded scalar response. Monthly summary now streams historical rows in batches; disposable 10k-transaction/split and 10k-allocation fixtures prove bounded ORM hydration and exact observations. Other report/Demo computation, category/account fan-out and release-scale closure remain open. |
| UX | IN PROGRESS | Shared shell, onboarding, scalable payee selection and focused Insights exist. Report filters are reachable again; missing debt terms open the shared editor. Demand-loaded reports have independent loading/error/retry. Full workflow/accessibility closure remains open. |
| ACCESSIBILITY | IN PROGRESS | Historical large-text launch strings were invalid and did not prove the claimed size; corrected tests use UIKit's actual raw value and require the adaptive debt menu. Description/trait audits pass for Cost and debt observations. Full VoiceOver, chart and release-wide accessibility closure remain open. |
| PLATFORM | IN PROGRESS | Regular Xcode 27 and the existing iPhone 17 Pro Max/iOS 27 are the current native verification environment; preserve Simulator data. The Add Transaction App Intent accepts optional payee, exact currency text, memo, a non-future transaction date and expense/income type, then opens the shared authorized editor without mutating money in the intent. Widgets and workspace navigation intents are embedded; release configuration and broader platform scope still need closure. |
| COMMERCIAL | BLOCKED | HUMAN PRODUCT DECISION REQUIRED: paid download versus free Demo plus non-consumable Lifetime Unlock. Preferred documented hypothesis is the latter; it adds restoration/offline/revocation complexity while allowing evaluation. Paid download reduces entitlement complexity but prevents pre-purchase evaluation. No StoreKit implementation before decision. Independent engineering continues. |
| APP STORE | IN PROGRESS | Commercial strategy includes positioning and draft screenshot narrative. Verify current Apple primary sources when preparing privacy/distribution artifacts. Signing, developer enrollment, final identity/pricing and submission remain human/external actions. |
| OPERATIONS | IN PROGRESS | Developer launcher and advanced server documentation exist. Audit production deployment, migration/recovery, attachment key backup, monitoring and normal-user server management. |
| HUMAN ACCEPTANCE | HUMAN REQUIRED | Preserve prior accepted workflows; consolidate only changed/unverified workflows later. No claim of new human acceptance from automation. DO NOT RETEST during autonomous run. |

## Current execution order

### Allocation-history and export privacy correction

Direct HTTP reproduction showed a member limited to one category receiving a private category's
assignment plus a mixed transfer's hidden counterpart, actor/date and free-text medical note.
The allocation-history query now requires at least one visible category and no hidden category
postings before ORM loading. Empty scopes return no operations. Complete authorized operations
remain balanced; mixed-scope operations are omitted rather than exposing a misleading half-record.
Owners and users authorized for every involved category retain those records. Capability revocation,
missing authentication and inaccessible budgets remain denied. Canonical history is never modified.

A related regression proved `export_data` could bypass explicit account/category restrictions in
full JSON export, exposing whole-budget/household administration data. That artifact now requires
unrestricted account AND category scope in addition to the export capability. Existing scoped CSV
exports remain available under their own report authorization. Unrestricted delegated export is
preserved, consistent with specification §24.8; an initial test draft incorrectly required Owner
even for explicitly delegated unrestricted export and was corrected before the production fix.
No new global Owner-only rule was invented. These fixes do not establish full export fidelity or
release-wide privacy closure. Reproduction logs: `/tmp/budget-allocation-privacy-reproduction.log`,
`/tmp/budget-export-privacy-reproduction-final.log`.
Final verification: **365 backend passed, zero skips**, including disposable PostgreSQL gates,
golden vectors and encrypted recovery. Focused history/export/allocation/delegation **24 pass**;
later cross-budget/CSV assertions included in the full run. `/tmp/budget-history-export-privacy-full.log`.
`git diff --check` passes. No Swift, migration or human data change. The unchanged native/package
checkpoint remains 94 XCTest + one UI, 39 Core + 49 API. Next: verify archived category/group
assignment guards; source audit found manual assignment lacks the active-resource check used by targets.

Follow-up reproduction refined that suspicion: the central `append_operation` service already
rejects individually archived categories; the missing check is the parent group's archived state.
It now validates active budget-owned groups in one bounded query before adding any postings or
incrementing the allocation version. This protects assignment, moves and other canonical allocation
callers without duplicating endpoint-specific guards. Regression covers archive category versus
archive group, attempted increases/decreases, both move directions, unchanged account/audit state,
then restoration and successful assignment. No historical data is rewritten or erased.
Verification: **367 backend pass, zero skips**; focused allocation/delegation/allowance cases **22
pass**. `/tmp/budget-archived-allocation-{reproduction,focused,full}.log`. No native/schema changes;
diff check passes. Next reliability audit: month-boundary arithmetic constructs year 10000 for
valid December 9999 input, and report loops advance after their terminal month. Reproduce before
changing the shared calendar behavior.

Calendar endpoint reproduction found seven actual exceptions: all five monthly report families
overflowed at December 9999, debt's trailing window underflowed at January 0001, and future
assignment constructed year 10000. A shared inclusive Gregorian month-period helper now clips
partial periods and stops at the requested end without stepping past it. Planning uses inclusive
month-end comparisons, preserving prior date-only semantics without requiring next year's January.
The trailing-interest window clips at the earliest representable date. No money formula changes.
Regressions cover both calendar endpoints, leap/non-leap century years, partial months, year
transition, reversed ranges and exact assignment/Smart Funding through the last supported month.
The first expanded funding test omitted the required optimistic version; its request was corrected,
not the server validation. Reproduction: `/tmp/budget-calendar-boundary-reproduction.log`.
Final full backend **384 passed, zero skips**, including disposable PostgreSQL, financial vectors,
migration/recovery and privacy cases. Focused calendar/report/allocation rerun passes; diff check
passes. `/tmp/budget-calendar-boundary-{focused-final,full}.log`. No Swift or migration changes.
Next performance audit: monthly summary currently materializes all historical transactions and
allocation rows. Measure a disposable large history and bound hydration without changing exact sums.

Monthly-summary scale reproduction measured **20,011 live ORM objects** for 10,000 transactions
plus 10,000 split rows. Bounded 500-row streaming now peaks at **1,506** with identical RTA,
Assigned/Activity/Available/carry and a 1,081-byte response. A second fixture adds 10,000 balanced
allocation operations / 20,000 postings; peak remains **1,506**, response 1,085 bytes. Allocation
reads select only scalar columns, not operation objects with auto-loaded posting relationships.
Account scope is applied in SQL before transaction hydration. Exact Python integer accumulation,
credit reserve handling and authorized category output semantics are retained; no floating-point
SQL aggregation or financial approximation was introduced.

Measured SQLite times are evidence, not machine-dependent gates: original 0.4582 seconds, final
0.4055 seconds without large allocations and 0.4852 with them. These are disposable read-path scale
fixtures, not a new import/mutation path or a claim of production PostgreSQL scale performance.
Logs: `/tmp/budget-month-scale-reproduction.log`, `/tmp/budget-month-scale-focused-final.log`.
Full backend **386 passed, zero skips**, including PostgreSQL concurrency, populated migrations,
plain/encrypted recovery, privacy and golden vectors: `/tmp/budget-month-scale-full.log`.
`git diff --check` passes. Swift/native sources unchanged since the verified funding-limit sheet.

Highest-priority continuation: persistent monthly Demo/provider parity and prospective cash
overspending policy history remain genuine financial/product gaps. Re-read specification §§7.1–7.4
and APPLICATION-ARCHITECTURE.md before changing them. Do not invent a second ad-hoc Demo money
engine or treat the old quarantined MonthlyBudget calculator as authoritative. Current/future
spendable RTA presentation must also distinguish dated observations from cash reserved in later
months. Other open gates include report-scale hydration beyond monthly Plan, full structured export
fidelity, real Docker/Compose recovery, production Local Device storage/import and later roadmap
scope. Commercial choice and final Apple release credentials remain external, but independent
engineering is not blocked. Mission remains active; **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

1. v0.8 automated checkpoint is recorded in V0.8-CLOSURE-AUDIT.md; human acceptance remains pending.
2. Recovery hardening now includes complete archive validation, real encrypted PostgreSQL recovery,
   fresh-target guards and coordinated source capture. Actual Docker execution remains open.
3. Proceed with V0.9-PLANNING-POWER-PLAN.md: reproduce and correct recurring-target cadence, then
   scoped snooze and planning closure. Preserve the normal-user server distribution requirement.
4. Continue the highest-priority unblocked engineering gate through release-candidate readiness.

### Cross-month allocation safety checkpoint

Historical Smart Funding could reuse cash assigned in a later month: reproduced 201 with current
RTA becoming -30000. Preview and commit now cap date-scoped observations by all-date unassigned
real money; commit computes inside the budget lock after version validation. An explicit funding
limit keeps historical RTA truthful without presenting it as all currently spendable. Hidden scopes
remain bounded by the authorized summary. Full backend **359 pass, zero skips**, including real
PostgreSQL competing assignment/Smart Funding, populated migrations, encrypted recovery and golden
vectors. Swift **39 Core + 49 API pass**. No migration or human data operation.
See V0.9-PLANNING-POWER-PLAN.md for reproduction and evidence. Next independent gap: specification
§7.2 permits future assignment of existing cash, but Live rejects it and Demo ignores assignment
month. Prospective overspending-policy history (§7.4) is also not implemented. Neither is declared
complete or deferred by this safety correction. **HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

Live future assignments now use the existing dated allocation service and real-cash/version guards
without its obsolete future-month rejection. Fixed-clock regression covers independent months,
edit/reload, forecast exclusion, no double-use, balanced history and unchanged account observations.
**360 backend pass, zero skips**, including disposable PostgreSQL; no Swift or migration change.
Local Device/Demo month persistence was subsequently proven through the production repository and
SQLite reconstruction; effective-history rollover remains open, so future-planning parity is not
complete. Next security audit: allocation-history listing checks its capability but appears to lack
category-resource filtering; reproduce before correcting. Evidence `/tmp/budget-future-assignment-full.log`.

### Local Device future-month planning persistence — 2026-10-07

A focused production-repository regression closes the stale claim that Local Device future-month
assignments were only in-memory. It creates real on-budget cash, assigns a portion to the following
month through the canonical service, verifies current/future observations and the all-date funding
limit independently, then reconstructs the workspace from SQLite and verifies the dated assignment
and account balance survive. One Xcode 27 Beta native test passed on the preserved iPhone 17 Pro Max
/ iOS 27 Simulator. Product code was unchanged, so no repetitive broad suite was run. Prospective
cash-overspending policy history remains a separate genuine financial gap.

### Coordinated source backup checkpoint — 2026-09-18

Following `c08867d`, backup requires an explicitly named source project and briefly pauses its API
while capturing the database and attachment objects. Recovery keys are validated before pausing;
the API resumes before the passphrase prompt, with failure cleanup attempting recovery of running
state. No zero-downtime or external-writer snapshot guarantee is claimed. Focused script/crypto tests:
**31 passed**; full backend including disposable PostgreSQL: **334 passed, zero skips**
(`/tmp/budget-coordinated-backup-full.log`). Docker command sequencing is tested with doubles;
actual Compose runtime remains unverified. Human Live and Simulator data were not touched.

### Recurring target guidance checkpoint — 2026-09-18

After `431de33`, reproduced annual-target overstatement (120000 rather than 10000 after due month)
is corrected in server summaries and Demo via a provider-neutral exact helper. Immutable anchor,
selected-month effective due, leap/clamp/no-drift, skipped cycles and Int64 ceiling cases share
14 Python/Swift vectors. Live HTTP reload/preview and Demo store tests prove guidance is money-neutral.
Full backend **350 pass, zero skips**; focused planning/golden **45 pass**; Swift **39 Core + 47 API**;
native **89 XCTest + one Plan UI test pass**, Beta build/test success. Initial native failure caught
legacy non-ISO seed dates; corrected fixtures passed the rerun. No migration or human data changes.
Next proven-source audit: incremental Smart Funding over-proposal and Demo command parity.

### Incremental Smart Funding checkpoint — 2026-09-18

Following `627b957`, a failing HTTP repeat-preview regression proved already-funded monthly amounts
were proposed again. Fixed to use underfunding only; negative RTA remains intact and stable tie ordering
is deterministic. Demo consumes canonical target guidance and rejects stale/repeated/restricted commits.
Full backend **351 pass, zero skips**; Swift **39 Core + 47 API**; native **90 XCTest + two production
UI tests pass**, including actual preview/cancel/confirm/reopen. Beta Simulator build succeeds.
No migration, human data mutation, merge or tag. Planning still needs priority/shortfall UX and snooze;
broader mission gates remain open and human acceptance remains pending.

### Priority and shortfall checkpoint — 2026-09-18

Following `5a44d93`, reproduced priority inversion is corrected and preview explicitly reports exact
remaining need and unfunded category count. Authorized categories are selected before aggregation;
scoped regression proves hidden high-priority needs cannot leak through either new field. Overflow
fails with validation, not truncation. Older-server Swift decoding remains supported. **352 backend
pass, zero skips; 47 final focused planning/privacy/golden; 39 Core + 48 API; 91 native XCTest + one
production UI test pass**, Beta build/test successful. No migration or human data changes. Next:
month-specific snooze under the documented planning contract, then remaining planning closure.

### Month-specific snooze native checkpoint — 2026-09-18

Server checkpoint `f0cb4c1` is followed by the shared native month-scoped Snooze/Resume action, explicit
paused Plan rows, Demo parity and current-credential Live request. **39 Core + 49 API; 92 XCTest +
three production UI tests pass**, Beta build/test success. Prior backend **356 pass, zero skips**
includes metadata migration/recovery. No accounting mutation or human data changes. New migration
0028 remains unapplied to human Live. Next: checked Monthly plan cost aggregation and planning closure.

### Exact monetary presentation checkpoint — 2026-09-18

After `ac5dd07`, Plan cost uses checked Money aggregation with an explicit range state, verified in
the production workspace with individually valid overflowing targets. The shared currency formatter
no longer rounds exact Int64 values through Double; native Decimal formatting passes endpoint and
multi-currency tests. **94 native XCTest + four production UI tests; 39 Core + 49 API pass**, Beta
build/test successful. Backend unchanged (356 pass). A new test's inadvertent Demo privacy toggle was
diagnosed from retained hierarchy and restored to its known prior state; tests now use unique identities
and clean up only their own keys. No Live financial data changes. Next: cross-month funding safety and
the remaining planning/provider parity audit. Human acceptance remains pending.

## Human data and migration ledger

Never run migration, destructive, scale or restore tests against human Live. Known unapplied chain:
`0021_scheduled_payee_id` → `0022_report_query_indexes` → `0023_category_favorites` →
`0024_member_lifecycle` → `0025_request_lifecycle` → `0026_debt_terms` → `0027_interest_class` →
`0028_target_snoozes` → `0029_cash_rollover_history` (additive policy provenance; absorption not activated).
Recheck the source graph before migration work. Use disposable populated PostgreSQL databases and
restore to new destinations. Preserve human attachments, transactions and reconciliation history.

Current native toolchain: `/Applications/Xcode.app/Contents/Developer` (Xcode 27.0, build `27A266a`).
Preserved Simulator UDID: `3ABD861E-D38D-4AFD-A356-959266051564` (iPhone 17 Pro Max / iOS 27;
reverify availability before use and never erase it). Earlier checkpoint entries below retain the
beta toolchain names and build numbers that produced that historical evidence.

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

Recovery lifecycle correction now enforces a new/schema-only database and empty object store,
refusing populated destinations before service stop. A PostgreSQL guard takes bounded locks and
is repeated after quiescence and inside the final SQL transaction. Objects are copied before SQL
as the normal non-root service user, never deleted in place; failure keeps the recovery API stopped.
Failed startup attempts stop again rather than treating a failed start as a ready server. The image
now creates its attachment mount directory owned by the service user instead of relying on a
root-owned empty path. Existing volume ownership is not automatically rewritten. Real Compose
ownership/startup verification is still open, not established by the command-double tests.

Regression evidence: populated-destination refusal leaves every PostgreSQL row unchanged; both
real plain/encrypted new-destination recoveries pass; copy/SQL/start failures and preflight refusals
have explicit command-order assertions. Full backend **329 passed, zero skips**, shell syntax and
diff check pass. No native changes. This intentionally removes destructive in-place restore; the
documented mission requires new-destination recovery and preserves the original deployment/backup.

Source-capture follow-up now proves the cross-resource relationship rather than relying on a hot-file
manifest. Every Docker, Windows, and QNAP backup stops all Compose API service instances before the
PostgreSQL dump and encrypted-object copy, validates the copied objects against every attachment row
while the API remains stopped, and only then resumes service. Validation authenticates each encrypted
object with the authority key and checks its recorded plaintext byte count and SHA-256, including
detached objects retained during the tombstone window. Any missing, linked, corrupted, or mismatched
database object aborts publication and the cleanup path resumes only the source it paused. The later
manifest still provides complete ciphertext/archive coverage. Focused capture, recovery-script, and
distribution tests pass; real Docker/QNAP/Windows runtime acceptance remains separate.

### Windows graphical manager foundation — 2026-10-01

The versioned Windows customer bundle now installs a native WPF manager instead of making the
numbered PowerShell menu its ordinary entry point. Fresh installs choose durable authority storage
and an optional HTTPS hostname in the graphical surface; everyday start/open, status, safe stop,
recent-log, redacted-diagnostics, and coordinated encrypted-backup actions invoke explicit
non-interactive operations in the same
hardened engine. Configuration is published only after the immutable release image has downloaded,
so a failed first-run pull cannot leave a half-configured authority that later resolves a mutable tag.
No stop path deletes volumes, configuration, backups, or financial data. Graphical backup selects the
generation and separate recovery-key locations, warns about key loss, and confirms before adopting an
existing identity; the canonical capture, encryption, health, retention, and optional Dropbox
publication engine remains singular. Restore, phone transfer, portable import, scheduling, update,
and Dropbox configuration remain singular too; recipient-encrypted restore is now available in the
graphical manager with native file selection and explicit confirmation, while the canonical two-stage
empty-destination checks remain mandatory. Identity-encrypted portable import is now graphical as
well: native archive/identity selection and masked replacement-owner fields feed the same importer,
with passwords carried only by redirected standard input. Sources stay read-only and no merge is
possible. Passphrase recovery/import remains terminal-bound so its secret continues directly to `age`.
The iPhone Local Device transfer has also moved into the graphical manager. Masked recovery-key and
new-owner password fields are sent to the container converter through redirected standard input only;
they are absent from process arguments, environment variables, temporary files, output, and
diagnostics. The exported package remains a read-only mount, the phone authority remains intact, and
the server API still starts only after canonical conversion and financial/attachment verification.
Windows Dropbox backup setup now uses the graphical manager, masked credential fields, and the same
private standard-input channel. A live create/list preflight of the intended least-privilege app folder
must pass before replacing the user-only credential file. Disconnect preserves local and remote
generations. Browser-based public-app OAuth and Windows runtime acceptance remain open.
Windows daily encrypted-backup scheduling is now graphical too. It still requires a verified manual
generation/recovery identity first and retains the limited current-user task, start-when-available,
IgnoreNew, six-hour limit, capture lock, and success-only retention behavior. Status and disable work
without a running Docker daemon and never delete backup or recovery material.
The downloaded-version update path is now graphical. It collects the mandatory encrypted-backup and
recovery locations, refuses to proceed without explicit confirmation, then preserves the existing
backup-before-pull-before-pin-before-health order. Pull failure leaves the active version untouched;
post-migration failure stops the API and preserves the generation rather than risking an automatic
binary downgrade against a newer schema.

All focused distribution/import contract tests pass, including the graphical composition, hidden-process
output/error handling, immutable-image-before-configuration ordering, installer allowlist, and
non-destructive command assertions. The complete backend run was also attempted from its required
working directory; unrelated clock-bound September 2026 fixtures now fail on October 1, the sandbox
blocks a loopback socket and real `age` controlling terminal, and existing financial tests fail in
those shifted periods. No application/backend financial code changed in this checkpoint. WPF runtime,
Windows accessibility, Docker Desktop, and signed-installer acceptance require a Windows test host and
remain open; source assertions are not represented as that acceptance.

### QNAP private-volume installation correction — 2026-10-01

The QPKG no longer defaults a fresh household authority beneath the NAS Public share. It declares
QDK App Center volume selection and migration support, applies bounded start/stop timeouts, and creates
the durable `ClearPocketServerData` authority as a private `0700` directory on the selected volume,
outside the replaceable package tree. Its `/etc/config` pointer remains owner-only and authoritative;
an upgrade never relocates an existing installation. Database, attachment, and operations subtrees
remain `0700`, private configuration remains `0600`, and uninstall still preserves the authority.
The focused 58-case distribution suite and QNAP shell syntax pass. Actual App Center volume-selection,
package migration, Container Station, QTS/QuTS permissions, and supported-hardware acceptance remain
required before customer release.

The immutable server-image workflow now also pins upstream QDK 2.5.3 by commit and builds one QPKG
against the exact published multi-architecture image digest. Full server identity remains embedded;
QDK's separate ten-character package version uses an explicit, validated mapping (for example,
`0.9.0-beta.1` → `0.9.0b1`) rather than truncation. On a successful independent QDK build, the file and
SHA-256 are uploaded only as an explicitly named **unsigned hardware-acceptance artifact** and are
deliberately excluded from customer GitHub release assets. QDK availability cannot block the
Docker/Windows customer downloads. This enables real NAS testing without weakening the signing gate.
Release retries after image publication are now safe and recoverable: the workflow inspects the
existing AMD64 image configuration and reuses its index digest only when the embedded OCI source
revision exactly equals the current commit. A different commit can never reuse or overwrite that
version. This lets a same-commit packaging or upload retry finish without weakening immutable tags.

### Household visibility usability refinement — 2026-10-03

A production-composition visual review on the iPhone 17 Pro Max / iOS 27 simulator confirmed that
Household is directly reachable from the custom bottom navigation and uses the same live/demo view
hierarchy. The owner member-access screen now promotes the five decisions families need most—budget
access, account visibility, account balances, category availability, and whole-household Ready to
Assign—into a plain-language section instead of hiding them among advanced custom capabilities.
Account/category scope selectors remain available immediately below those controls, dependent choices
stay internally consistent, and selected-only scopes explicitly explain why household Ready to Assign
is unavailable. Member summaries now distinguish “no access” from a misleading zero-resource count.
Server authorization and persisted permission-profile semantics are unchanged. Focused native source
coverage and production-composition XCUITests pass; this records engineering verification, not human
acceptance.

### Household invitation usability — 2026-10-03

Removed-member re-invites now prefill the known normalized email address and prior adult/child role,
while a new invitation still starts blank. The one-time invitation screen retains explicit copy
behavior and adds the native share sheet with the seven-day expiry warning. Access profiles, server
authorization, and invitation-token semantics are unchanged. The Xcode 27 Beta simulator build,
Swift package suite, and focused native source regression pass. Native interaction still requires the
ordinary human acceptance pass; this checkpoint does not claim it.

Follow-up production-composition verification found that the member-lifecycle link could sit at the
unstable lower edge of the dynamically populated People section and fail to navigate when activated.
Household management now has a dedicated section ahead of People, keeping member and invitation
actions visible with a stable native hit target. Re-invitation presentation is item-backed so the
known email and prior role are the sheet payload rather than state mutated beside a Boolean sheet.
The focused XCUITest now passes the complete Household-tab flow: open management, cancel removal,
confirm removal, verify retained history, open a prefilled re-invite, return, and reopen management.

### Atomic statement-import undo — 2026-10-07

Approved statement imports can now be undone from their existing review screen without deleting
ledger history. The authorized command row-locks the actor-owned batch, checks its optimistic
version and current account scope, validates every posted row, then uses the canonical transaction
void/reversal service for the complete batch in one database transaction. If any source transaction
is reconciled or otherwise ineligible, no row is changed. Successful reversal identities are stored
with the import candidates, the batch version advances, and replay is rejected. Live requests use
the current rotating credential; Demo and Local Device use the same production UI and canonical
void/reversal semantics. Focused backend atomicity/accounting tests, Swift request-shape tests, and
the Xcode 27 Beta native accounting test pass. This is engineering verification, not a claim of
human acceptance.

### Dedicated allocation history — 2026-10-07

Plan now exposes the existing authoritative allocation ledger as a dedicated history destination
instead of stranding it inside individual category details. Each operation shows its date, type,
actor, source, note, and exact balanced postings; category rows include their group name so repeated
category names remain unambiguous. The browser consumes the same server-filtered operations already
loaded by the production workspace, so restricted members cannot infer hidden counterpart postings,
notes, or actors. Pull-to-refresh reloads authoritative state. This adds no mutation path and changes
no account, allocation, target, forecast, or transaction semantics. Focused production-composition
verification covers discovery through the real Plan menu and rendered ledger content.

### Hidden-category lifecycle closure — 2026-10-07

Plan now includes a searchable category manager that lists both active and archived categories by
group. This closes the prior one-way lifecycle where archiving removed a category from Plan without
leaving a discoverable way to restore it. Authorized owners can open the canonical category editor
from the manager, hide or reactivate a category, and retain its complete financial history; delegated
category managers see only categories assigned to them. The existing server mutation and capability
checks remain authoritative. No allocation or transaction values change when visibility changes.

### Persistent Plan focus — 2026-10-07

The shared production Plan now remembers the selected All, Favorites, Underfunded, Overspent,
Funded, or Available view per user and budget. Switching tabs or returning to the budget restores
the user's working context without changing shared financial data. The preference remains
device-local and contains only the focus name; category visibility and amounts continue to come
from the authoritative scoped workspace. The existing production favorite/filter journey now also
covers shell reconstruction and resets its deterministic preference after verification.

### Exact arithmetic money entry — 2026-10-07

All shared monetary entry surfaces now expose Add, Subtract, Multiply, and Divide controls above the
native keyboard and accept parenthesized expressions. Evaluation uses Foundation `Decimal`; it never
converts source-of-truth money through `Double`. A result is accepted only when it converts exactly
to the currency's integer minor-unit scale and fits `Int64`. Incomplete expressions, division by
zero, non-terminating precision, unsupported characters, and overflow remain validation failures and
cannot mutate the budget. This reusable path covers transaction and split amounts, assignments,
moves, requests, reconciliation, targets, allowances, delegated authority, and debt scenarios.
Focused native tests cover operator precedence, parentheses, Unicode operator labels, exact division,
invalid syntax, division by zero, fractional minor-unit results, and overflow.

### Conservative category suggestions — 2026-10-07

Selecting a saved payee with no explicit default category now offers a category only when the same
active category occurs in at least two of that payee's last three eligible posted purchases. The
history excludes transfers, reversals, voided entries, inflows, splits, archived categories, and
anything outside the already permission-filtered workspace. Explicit payee defaults still take
precedence. The suggestion is visibly labelled and requires the user to tap Use; it never silently
changes or saves a transaction. A focused provider-shaped test covers a qualifying merchant plus
income and unknown-payee refusals.

### Selectable forecast horizons — 2026-10-07

The shared production Forecast screen now supports 30, 60, and 90 days, six months, and one year.
Live workspaces request each range from the existing authorization-scoped server forecast endpoint;
Demo and Local Device expand the same visible active schedules with exact integer-minor-unit money.
Changing the horizon is read-only: it neither posts scheduled activity nor changes balances,
transactions, allocations, or available money. Offline Live workspaces retain the latest visible
forecast and show the existing unobtrusive sync status instead of clearing the screen. The Xcode 27
Beta build and a focused native regression covering short/annual expansion and unchanged actual
state pass. The subsequent scenario checkpoint completes the remaining v0.15 engineering scope.

### Ephemeral what-if scenarios — 2026-10-07

Forecast now links to an explicit scenario comparison for temporary monthly income reduction,
monthly recurring-cost increases, and a one-time major purchase. The calculator consumes the
current permission-filtered authoritative forecast and uses `BudgetCore.Money` exact minor-unit
arithmetic; it never derives or rewrites actual balances. Assumptions are deliberately ephemeral,
remain on the scenario screen, and cannot post transactions, alter schedules, change allocations,
or make anticipated income spendable. The selected forecast horizon bounds the number of monthly
assumptions. Focused BudgetCore tests cover combined assumptions, validation, and overflow; the
production Xcode 27 Beta build passes. This closes v0.15 engineering scope without claiming human
acceptance.

### Explainable Smart Funding — 2026-10-07

Smart Funding now preserves the structured evidence behind every proposed category amount: target
type, priority, full monthly recommendation, amount fundable from current real Unassigned money, and
the category's remaining shortfall. The shared production sheet renders those reasons and clearly
identifies partial funding instead of showing an unexplained amount. Live, Demo, and Local Device
use the same response contract and presentation; older server responses remain decodable. The
existing priority order, exact integer-minor-unit calculations, delegated authorization, optimistic
version check, and atomic canonical commit are unchanged. Preview and cancellation remain strictly
non-mutating. Focused backend Smart Funding tests, Swift compatibility/contract tests, and an Xcode
27 Beta production build pass. This closes v0.16 engineering scope without claiming human
acceptance.

### Household scope readability closure — 2026-10-07

Restricted household members can now open their Profile & Settings access summary and inspect the
exact authorized account and category names behind the previous numeric counts. Category entries
include their group to disambiguate repeated names; the searchable lists are built only from the
already server-scoped workspace and explicitly explain that hidden resources are neither downloaded
nor displayed. Account balances remain governed by their independent capability and are not exposed
by this browser. Owners retain the existing per-member presets, exact resource selectors, visibility
preview, actor-attributed change record, invitations, requests, allowances, and delegated policy
tools. This adds no permission or data-fetch path and changes no financial state. Together with the
existing revocation, cache invalidation, query-minimization, resource-scope, request/allowance, and
adversarial privacy evidence above, this closes v0.17 engineering scope without claiming human
acceptance.

### Native iPad workspace slice — 2026-10-07

The shipping iOS application and privacy-safe launcher widget now support both iPhone and iPad.
Regular-width iPad windows use an adaptive two-column production shell: all six destinations remain
visible in a native sidebar, the selected destination retains its existing `NavigationStack`, and
Profile & Settings plus the active budget remain directly discoverable. Narrow iPad multitasking
and iPhone continue to use the existing compact bottom navigation, so Demo, Local Device, and Live
providers still share one view hierarchy and application-service path. An Xcode 27 Beta build and
direct deterministic production launch on the iOS 27 iPad Pro 11-inch simulator pass; the captured
runtime showed the sidebar and real Home content together. A focused XCUITest was added for sidebar
destination and settings reachability, but the local UI-test runner stalled after launch and was
stopped at the bounded cutoff rather than repeatedly retried. Human iPad acceptance, macOS, web,
and Android remain open and must not be inferred from this engineering slice.

### Classified resilience coverage — 2026-10-07

The two remaining unavailable resilience observations now have an explicit source of truth instead
of inferred labels. Category editing can mark an item as an essential expense or an emergency fund;
fresh starter plans classify the obvious baseline categories without adding money. The authorized
report nets direct and split essential activity, including refunds, over the existing trailing
90-day window, then derives essential coverage from visible cash and emergency-fund coverage from
the canonical current Plan Available amount. Transfers, voids, hidden accounts, and hidden
categories remain excluded by the existing report scope. Live, Demo, and Local Device use exact
integer minor units and the same definitions. Existing Local Device databases migrate in place to
schema 10 with false defaults, and older API/local snapshots remain compatible. Focused backend
analytics and migration tests, Swift API/storage tests, and the Xcode 27 Beta production build pass;
human acceptance remains separate.

### Statement-import transfer portability — 2026-10-07

Owner-authorized Server-to-Local Device transfer now preserves durable statement-import review and
undo history instead of treating ordinary bank-import use as a permanent portability blocker. The
typed projection carries exact candidate dates, integer-minor-unit amounts, source text, decisions,
posted/reversal identities, version ordering, and batch state into the encrypted Local Device SQLite
authority. Server-derived transaction-match suggestions are cleared because they are recomputable
cache data, not financial authority. Existing transfer envelopes without import history remain
decodable, and later Local Device workspace publications retain imported history. Focused backend
transfer tests, Swift projection tests, and the Xcode 27 Beta production build pass. Legacy monthly
assignment rows retained after migration `0006` no longer block transfer because their financial
effect already exists in the canonical allocation ledger; they are never projected twice.
Household/server-only attribution remains fail-closed.

### Scheduled-realization transfer portability — 2026-10-07

Server-to-Local Device transfer now preserves each realized transaction's immutable schedule lineage
and each schedule's last-realized observation. Local schema v11 stores the provenance independently
of the schedule row so deletion does not erase history, matching the production server contract.
The local workspace exposes the same lineage to the shared UI, retaining protections against editing,
quick-clearing, or bulk-changing realized occurrences. Existing transfer envelopes remain compatible;
focused server projection, Swift decoding/persistence, and production-composition verification cover
the new field without changing any transaction, allocation, or balance amount.

### Merged-Payee transfer portability — 2026-10-07

Server-to-Local Device transfer now carries archived merged Payee identities and their canonical
redirect IDs instead of rejecting any budget that has used Payee cleanup. Local schema v12 retains
that audit lineage while normal search and entry continue to omit merged sources. The local merge
command now mirrors production by retaining the source as an archived redirect, moving transaction
and schedule identity to the destination, and preserving useful source names as destination aliases.
No financial values change.

### Detached-attachment transfer portability — 2026-10-07

Detaching a file no longer makes an otherwise single-owner budget permanently ineligible for
Server-to-Local Device transfer. The projection carries the immutable filename, type, size, digest,
creation, actor, detach, and purge observations in a separate tombstone collection; removed content
is not downloaded or resurrected. This matches the established portable-archive contract. Local
Device schema v13 persists that lifecycle metadata through candidate publication, relaunch, encrypted
backup, and complete workspace replacement. A Local Device detach now atomically moves active
metadata into the same retention ledger after the encrypted object enters the vault tombstone
directory, restoring the object if the metadata commit fails. On-device authority startup now
removes expired encrypted tombstones and their metadata idempotently, while imported server
tombstones without local payloads expire from metadata without inventing file content. Cleanup
failures remain retryable on the next authority load. Active attachment limits and UI lists remain
based only on active files. Focused server export, Swift projection, schema migration,
candidate-import, and Xcode 27 Beta production-build verification pass. Shared household identity,
authorization/delegation records, non-owner attribution, and unsupported many-to-many allocation
history remain deliberately fail-closed rather than being flattened.

### Category guidance transfer fidelity — 2026-10-07

Server-to-Local Device transfer now emits the category icon, explanatory note, essential-expense
classification, and emergency-fund classification that the native projection already understood.
Previously the decoder and its synthetic fixture supported these fields while the real server
projection silently omitted them, so a successful provider move could lose user-authored planning
guidance and resilience classifications. The focused authenticated export regression now creates
real metadata through the production category command and asserts it in the returned transfer
contract; the Swift projection compatibility suite confirms both complete and legacy envelopes.
No financial observations or authorization rules change.

### Local Device transaction-history visibility — 2026-10-07

Transaction detail now reads the preserved Server-to-Local audit rows from the encrypted Local
Device authority instead of replacing them with a synthetic creation entry. The query is scoped to
the active budget and transaction, newest-first, and bounded to 50 entries. The UI receives only
the action, actor identity, timestamp, and changed field names; raw before/after values and internal
attachment, digest, and schedule-lineage identifiers remain confined to storage. Focused storage
tests cover persistence, query scoping, and value redaction, and the Xcode 27 Beta production build
passes.

Local Device command publication now also appends privacy-preserving `created`, `updated`, and
`deleted` audit rows by comparing canonical transaction snapshots before the command with the
validated projection afterward. Generated storage timestamps are excluded, unchanged transactions
produce no history noise, and imported server history is retained. Amount changes include the
corresponding split projection, matching the exact accounting mutation. Focused delta tests cover
create, update, delete, unchanged records, and field-name projection; the production app build
passes without invoking the known-broken remote/native test runner.

### Many-to-many allocation transfer fidelity — 2026-10-07

Balanced allocation operations with multiple source and destination categories no longer block a
personal Budget Server authority from moving to Local Device. The transfer projection now performs
a stable posting-id-ordered flow decomposition into directed local rows, retains the original
operation identifier and audit metadata, and preserves every category's exact integer-minor-unit
net posting. Unbalanced or directionless records still fail closed. Focused backend projection and
authenticated transfer tests pass, as do all five native transfer-envelope/observation tests.

### Split classification transfer fidelity — 2026-10-07

Server-to-Local Device transfer and later on-device publications now preserve each split's optional
financial classification instead of retaining only its category, amount, and memo. This closes a
semantic loss for classified finance-charge splits that could otherwise change debt reporting after
a provider move. Encrypted Local Device SQLite migrates in place from schema 13 to 14, legacy
transfer envelopes decode with a nil classification, and canonical audit snapshots include the
field. The focused authenticated export regression, 13 storage/migration tests, six transfer decoder
tests, and the Xcode 27 Beta production build pass.

### Local Device complete data export — 2026-10-07

Owner Profile & Settings now offers the same discoverable Prepare/Share Complete Data Export flow
for Local Device budgets that was previously limited to Budget Server. The versioned, sorted JSON
artifact contains the full typed Local Device authority—including exact ledger records, planning,
schedules, import review, audit and attachment metadata. The later shared `.clearpocketexport`
package layer adds verified readable copies of active attachment bytes while encrypted backup remains
the complete restore mechanism. All authority records now support a verified Codable round trip;
13 focused storage/export tests and the Xcode 27 Beta production build pass. The UI explicitly warns
that the JSON is private financial data and is not a replacement for encrypted recovery backups.

### Explicit CSV number conventions — 2026-10-08

Statement import now handles the two common grouped decimal conventions through an explicit user
choice: `1,234.56` or `1.234,56`. Budget Server and Local Device normalize the selected convention
into exact integer minor units before the existing money-neutral review boundary; neither guesses
from device locale or file contents. Mixed separators, malformed grouping, excessive precision and
overflow fail closed without including private payee/memo text in errors. The typed Swift client
transmits the selection to the authenticated server route, while on-device import uses the same
mapping and shared production UI. Focused backend parser/route, Swift API transport and native parser
tests pass under regular Xcode 27. No migration or existing financial data changes.

### Common bank date separators — 2026-10-08

Explicit CSV date order now accepts slash, dash, or dot separators in Budget Server and Local Device
imports. The user still chooses year-month-day, month-day-year, or day-month-year; ClearPocket never
infers an ambiguous order from statement contents or device locale. A single row must use one
consistent separator and a four-digit year, so mixed or shortened forms fail with private-safe
validation before staging. Focused backend parser/route tests and the production Local Device parser
test pass on the preserved iPhone 17 Pro Max / iOS 27 simulator under regular Xcode 27. No migration
or financial-state change is involved.

### Statement-import approval concurrency gate — 2026-10-08

The real PostgreSQL concurrency suite now includes simultaneous approval of one reviewed statement
batch. Its independent final-state assertions require one winner, one `409`, one approved version,
and exactly one cleared canonical transaction with the selected category and exact amount. The test
collects alongside the existing race harness and the equivalent canonical approval integration test
passes locally. This Mac has neither Docker nor a configured disposable PostgreSQL test URL, so the
new race remains an explicit local skip until the PostgreSQL CI/test environment runs it; no Live
database was used and no concurrency PASS is claimed from SQLite.

### UTF-16 statement export compatibility — 2026-10-08

Delimited statement import now accepts UTF-8 plus BOM-marked UTF-16 little- and big-endian files in
both Budget Server and Local Device modes. The BOM is required so ClearPocket never guesses byte
order or falls back through locale-dependent decoders. Malformed or unmarked UTF-16 fails before
staging with a private-safe validation message. This widens spreadsheet/bank export compatibility
without changing mapping, money parsing, approval, or ledger semantics. The production column mapper
now reads headers through that same decoder, closing the parser-only gap that would otherwise leave
UTF-16 files unable to reach Preview.

### Statement-review category suggestions — 2026-10-08

Statement review now preselects the current budget-specific default category when an expense row
exactly matches an active first-class payee name or alias. Budget Server and Local Device derive the
same review-only hint and the user can replace or remove it before approval. Refunds and income are
left uncategorized, staging remains money-neutral, and no payee is created from imported text.
Resource-scoped household members receive no suggestion, preventing the submitted payee text from
revealing private aliases or category preferences. Focused backend authorization/money-neutrality,
Swift transport, and native Local Device parity tests cover the contract.

### Explainable transaction change history — 2026-10-08

The immutable transaction audit now projects useful before/after explanations into the production
Change History screen. Amounts cross the API as exact integer-minor-unit strings and are formatted by
the native currency presenter; clearing, reconciliation, dates, tags, memo, Payee, account, category,
status and split-count changes receive human-readable values. The raw stored snapshots, attachment
metadata, digests, transfer IDs, schedule lineage and reversal IDs are never returned.

Privacy is evaluated against both historical sides before projection. If a transaction snapshot used
an account, category, or split category outside the viewer's current scope, every value from that side
is rendered as `Private or unavailable`; this prevents a later move into a visible category from
revealing the old payee, memo, amount, or resource identity. Identity lookup is batched once for the
bounded history page. Focused backend tests cover exact values, raw-snapshot exclusion and historical
scope redaction; the Swift API contract and regular Xcode 27 iPhone Simulator build pass.

### Durable reconciliation history — 2026-10-08

Reconciliation is no longer represented only by the latest balance on an account. Budget Server now
appends an immutable checkpoint for every completed reconciliation with exact statement and prior
cleared balances, statement date, actor, affected transaction count, optional adjustment identity and
timestamp. The account-scoped read is permission-filtered and bounded. Existing reconciled accounts
are migrated to one explicitly conservative legacy checkpoint without changing any transaction,
balance, allocation, reserve or reconciliation result.

The iPhone account register provides Reconciliation History with explicit older-page loading. Live,
Demo and Local Device compositions use the same view; Local Device retains each checkpoint in its
existing durable reconciliation table. Local schema 15 and the Server-to-Local projection now retain
actor identity, prior cleared balance, and affected transaction count across transfer, relaunch,
encrypted backup, and restore. Older snapshots and databases migrate without inventing unavailable
history. Focused backend lifecycle/privacy tests, populated migration
backfill, Swift package tests, typed API contract tests, and the regular Xcode 27 iPhone 17 Pro Max
Simulator build pass. Human presentation acceptance remains pending.

### Activity reconciliation audit feed — 2026-10-08

Activity now includes the five newest reconciliation checkpoints visible to the current member and
opens the existing canonical account Reconciliation History screen for full detail. Budget Server
uses one bounded budget-level query, filters authorized accounts before ordering and limiting, and
batches actor-name resolution; a private account therefore cannot consume a result slot or leak
through metadata. Local Device and Demo produce the same view from their existing durable authority,
without changing balances or ledger state.

Focused backend ordering/privacy coverage, Swift API request coverage, Local Device persistence and
attribution coverage, and a production-composition XCUITest all pass. Native verification used Xcode
27.0 (27A266a) and the preserved iPhone 17 Pro Max / iOS 27.0 simulator. Human presentation
acceptance remains pending.

### Explicit Dropbox generation management — 2026-10-08

The production Local Device Backup & Recovery screen now supports intentional deletion of one
encrypted Dropbox generation. Restore selection and deletion remain separate hit targets; deletion
requires a visible confirmation and is also exposed as a named accessibility action. The storage
boundary accepts only a direct `.clearpocketbackup` child of the configured backup folder, preventing
stale or compromised presentation state from deleting unrelated Dropbox content. On success the app
reloads the remote generation list; the live SQLite authority and every other backup are untouched.

Six focused Dropbox destination tests pass, including exact selected-generation deletion, sibling
preservation, path-boundary rejection, atomic publication, integrity failure, pagination and bounded
large-file upload. The production iPhone target builds successfully with regular Xcode 27.0
(27A266a) for the preserved iPhone 17 Pro Max / iOS 27 simulator. Live Dropbox provider acceptance
still requires the external app-console configuration and is not claimed by this checkpoint.

### Paged household access audit — 2026-10-08

The owner-visible Members screen no longer silently shows only 20 access events from a server list
that itself stopped permanently at 200. Household access activity now loads deterministic newest-first,
owner-authorized pages on demand across Budget Server and Local Device/Demo. Each request is bounded
to 200 rows; invalid limits and offsets fail validation. A failed older-page request preserves every
event already displayed and offers an explicit retry. Invitation and membership authority is
unchanged. Focused server coverage proves 125 events across three non-overlapping pages, and the
typed Swift API contract proves explicit limit/offset transport. Human presentation acceptance
remains pending.

### Attachment-inclusive complete data export — 2026-10-08

The production Data Ownership action now shares one `.clearpocketexport` package rather than a lone
JSON file. Server and Local Device retain their canonical versioned JSON authority document and use
the same package builder to add every active attachment through the existing authorized download
service. The package manifest records stable identity, original filename, content type, exact size,
SHA-256 and a collision-safe relative path. Payloads must match their authority metadata before the
package is exposed; detached files remain history-only, unsafe path components cannot escape the
package, and cancellation or corruption removes the incomplete generation. The custom package type
lets the iOS share sheet treat the readable folder as one export artifact. It remains explicitly
private and unencrypted, while `.clearpocketbackup` remains the encrypted restorable artifact.

Two focused native tests pass for Server and Local Device shapes, active/detached coverage, path
normalization, exact payload verification and cleanup. Regular Xcode 27.0 (27A266a) compiles and runs
the tests on the preserved iPhone 17 Pro Max / iOS 27 simulator. Human share-destination acceptance
remains separate.

### Legacy Local Device transfer normalization — 2026-10-08

Server-to-Local Device candidate creation no longer rejects a valid legacy-compatible snapshot merely
because an absent optional history collection reopens from current SQLite as an explicit empty
collection. Target history, schedule history and personal debt-plan collections are normalized at the
typed snapshot boundary and again before the final losslessness comparison. All actual records,
financial observations, attachment metadata and integrity checks remain exact and fail closed.

The complete 51-test BudgetStorage target passes, including encrypted backup/restore, Dropbox OAuth
and generation management, attachment encryption/tombstones, transfer projection, database migration,
and all four candidate-import publication/failure cases.

### Debt Terms decision history — 2026-10-09

Debt planning assumptions now retain immutable created/updated/deleted observations with exact
before/after values and actor attribution. The shared Debt Terms editor reads bounded history pages;
hosted reads enforce account scope and balance-visibility permission. Complete export and
server-to-local transfer preserve removed assumptions as history, not as current terms. Alembic
`0046_debt_terms_history` and Local Device schema 22 add baselines for existing assumptions without
changing balances, posted transactions, interest observations or payoff calculations.

Local Device terms were already persisted by normal workspace refresh. Commands now persist before
returning rather than depending on that refresh. Native regression caught and corrected an initial
implementation error using a demo actor identity in Local Device history: durable records now use
the actual local owner identity. Repeated identical saves add no duplicate observation.

Verification: 48 focused backend tests pass (terms/history, populated migration, graph, export,
debt projection and payoff plans); all 55 BudgetStorage tests pass; the focused typed API test
passes. The production native store reconstruction test passes after the actor correction, covering
save, no-op save, reopen, removal and a second reopen. Stable Xcode 27.0 (27A266a),
`/Applications/Xcode.app`, builds the production app and runs that test on preserved simulator
`3ABD861E-D38D-4AFD-A356-959266051564` (iPhone 17 Pro Max / iOS 27.0). An initial stalled
runner was stopped; the completed focused run is the verification evidence. `git diff --check`
passes. No Live or Simulator data was erased and no TestFlight upload was performed.

Human presentation acceptance remains pending: open a credit-card/loan Debt Terms editor, save an
assumption, reopen it to see history, edit it, then remove the terms and verify the history remains
available while posted balances are unchanged. Deploying the hosted change requires the normal
Alembic upgrade through 0046; Local Device migration is automatic at database open.

### Explainable Debt Terms history — 2026-10-09

The production history row now expands using native DisclosureGroup to show changed planning fields
with explicit Before/After values. Creation and removal show set/unset assumptions; an update shows
only changed fields. Currency values use the existing exact minor-unit formatter, and percentage
values derive from integer basis points through decimal arithmetic, never binary floating point.
All fifteen authoritative snapshot fields are represented; no terms, balance or projection is
recalculated by this presentation. Native accessibility combines each field and its values without
combining away the disclosure control.

Two focused native tests pass on stable Xcode 27 / the preserved iPhone 17 Pro Max simulator:
presentation of exact money above 2^53, rate changes, zero-to-unset promotion, creation/removal and
unchanged suppression; plus production Local Device save/reopen/removal persistence. The native
test build compiles the production SwiftUI composition. `git diff --check` passes. No backend or
storage changes, additional migration, TestFlight publishing or data reset in this checkpoint.
Human visual acceptance remains pending: expand a Debt Terms history observation and inspect its
Before/After values at normal and enlarged text size.

### Saved payoff-plan provider privacy parity — 2026-10-09

Audit found that Live's saved plans were user-owned, but Demo held one workspace-wide plan. That
could reveal another persona's account selection and reset their personal scenario. Demo now keys
plans by actor identity, reads only the actor's own plan, and filters account IDs/custom ordering
against current debt-account scope. Read requires both reports and account-balance visibility;
save requires planning management and balance visibility; delete requires planning management.
These mirror the existing Live route contracts. The save response does not implicitly grant report
read access. Plans remain non-spendable scenarios, not ledger/accounting mutations.

Local Device uses its real owner identity, preserves the stored update timestamp across hydration
and ordinary refresh, and still persists save/removal at the command boundary. Previously its
response used a demo owner ID and a fixed timestamp while snapshot refresh rewrote the stored time.
No schema or server change is needed.

Four focused native tests pass on regular Xcode 27 / the preserved iPhone 17 Pro Max iOS 27 simulator:
actor isolation and current account scope, revoked balance visibility, separate command/read
capabilities, and Local Device save/reopen/delete with stable owner/timestamp. Three existing Live
backend payoff-plan contract tests also pass. The final native test build compiles the production
app; `git diff --check` passes. No user data reset or TestFlight upload.

Human acceptance remains separate: save a Demo owner's payoff scenario, switch to Partner and
confirm it is not loaded; save/reset Partner's own scenario and return to Owner to confirm theirs
remains. Existing Local Device saved plans should remain intact after adopting this build.
