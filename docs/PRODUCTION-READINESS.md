# Production readiness mission ledger

Updated: 2026-09-18. Active branch: `codex/development`.
Mission starting checkpoint: `e3f2922`. Production release readiness: **IN PROGRESS**.
Human acceptance: **HUMAN REQUIRED — HUMAN ACCEPTANCE PENDING — DO NOT RETEST**.

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
| DATA | IN PROGRESS | Source head is `0029_cash_rollover_history`; human Live remains at `0020_payee_identity_repair`. Effective policy history now drives canonical projections and owner-authorized prospective settings; no migration silently changes legacy policy. Populated migration/concurrency and real age-encrypted new-destination restore cover canonical equality, snoozes, policy history and encrypted attachment integrity. Real Docker/Compose recovery and production Local Device storage remain open. |
| RELIABILITY | IN PROGRESS | Credential authority is shared by long-lived Live services. Native tests distinguish transient failure from definitive access denial and prove late snapshot/report results cannot resurrect denied state. Broader offline, lifecycle, cancellation and release-wide regression remain open. |
| PERFORMANCE | IN PROGRESS | Live core hydration makes zero detailed-report requests instead of seven; native tests cover caching/invalidation/retry. Hub has a bounded scalar response. Monthly summary now streams historical rows in batches; disposable 10k-transaction/split and 10k-allocation fixtures prove bounded ORM hydration and exact observations. Other report/Demo computation, category/account fan-out and release-scale closure remain open. |
| UX | IN PROGRESS | Shared shell, onboarding, scalable payee selection and focused Insights exist. Report filters are reachable again; missing debt terms open the shared editor. Demand-loaded reports have independent loading/error/retry. Full workflow/accessibility closure remains open. |
| ACCESSIBILITY | IN PROGRESS | Historical large-text launch strings were invalid and did not prove the claimed size; corrected tests use UIKit's actual raw value and require the adaptive debt menu. Description/trait audits pass for Cost and debt observations. Full VoiceOver, chart and release-wide accessibility closure remain open. |
| PLATFORM | IN PROGRESS | Xcode 27 Beta and existing iPhone 17 Pro Max/iOS 27 are required. Preserve Simulator data. Release configuration, lifecycle, platform scope and Apple integrations need closure. |
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
Demo month persistence and effective-history rollover remain open, so future-planning parity is not
complete. Next security audit: allocation-history listing checks its capability but appears to lack
category-resource filtering; reproduce before correcting. Evidence `/tmp/budget-future-assignment-full.log`.

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
Next operational gap: coordinate source database/object backup capture against concurrent writers;
do not claim a hot cross-resource snapshot is atomic merely because its manifest is complete.
