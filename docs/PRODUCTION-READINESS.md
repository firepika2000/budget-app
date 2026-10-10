# Production readiness mission ledger

## Native durable reviewed attachment removal (2026-10-09)

The attachment confirmation captures the selected attachment ID, transaction ID, immutable
SHA256 and filename through the shared transaction application service. Live saves that
intent and a UUID before transport. Ordered replay resolves current credentials, verifies
the server/actor/budget destination and uses the identified removal endpoint. A lost response
retains the original removal across relaunch; stale or revoked intent pauses for review.
Duplicate pending removal of the same attachment is refused. Unreviewed Live removal is refused.

Pending Sync and transaction attachment detail show removal awaiting server approval. The
accepted attachment remains visible until server acceptance; no local tombstone, byte deletion,
financial mutation or synthetic audit is performed. Pending removal details require current
edit/view authority and visibility of the original transaction. Confirmation, separate preview
and remove targets, encrypted storage and the 30-day server tombstone remain unchanged.
Demo/local delegate the same application-service operation to their existing canonical removal.

Executed evidence: production Foundation queue regression passes original target/digest/identity
retention across response loss/relaunch, duplicate refusal, rejection pause, original-intent
retry and acknowledgement cleanup. One focused Swift API test passes current credentials,
exact digest query/identity header, body-free DELETE and legacy omission. Native persistence
coverage is added; the production-composition preview/removal test now asserts rotated
credentials, reviewed digest, stable identity and exactly one removal request. These native
tests are compiled, not runtime-executed. Regular Xcode 27.0 (27A266a),
`/Applications/Xcode.app/Contents/Developer`, passed `build-for-testing` for app/native
targets against preserved iPhone 17 Pro Max simulator
`3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. `git diff --check` passed.
No backend or migration changed in this checkpoint; the preceding server contract is required.
TestFlight remains held; Live, attachments and Simulator data were not modified.

Remaining limitation: server attachment lists are not yet cached for reopening transaction
detail fully offline. Already loaded attachment metadata can be reviewed/removed after a drop;
queued removals remain visible after relaunch through Pending Sync. This checkpoint does not
claim general offline download/preview of previously unstaged server attachments.

Human retest after app rebuild and server update: open a disposable transaction and load
its attachment list, disconnect, tap the separate Remove control and confirm. Verify the
existing file remains alongside a pending-removal notice; cancel must save nothing. Relaunch
offline and inspect Pending Sync, reconnect, then confirm removal clears once with one history
event and no financial change. Preview must still never remove a file. No new migration.

## Identified attachment removal server contract (2026-10-09)

Attachment removal accepts optional `X-Attachment-Operation-ID` UUID and `expected_sha256`
query. Identified removal requires the reviewed immutable file digest. The existing
budget lock serializes removal with other authorized workspace mutations. Current edit
capability, whole transaction resource scope and ownership are checked before receipt
acknowledgement. Changed file observations or reused identities fail closed.

Tombstone, attributed transaction history and removal receipt commit atomically. A lost
response retry acknowledges the original removal without extending its 30-day retention,
adding another audit event or recreating encrypted bytes. The accepted receipt survives
subsequent tombstone purge, while current transaction access remains mandatory. Legacy
unidentified deletion retains its existing missing-attachment 404 behavior. Financial
amounts, balances, allocations and clearing/reconciliation state remain unchanged.

Executed evidence: 60 focused tests pass across removal/upload receipts, transaction
void/schedule/attachment lifecycle and financial golden vectors. The removal cases cover
exact retention, response loss, purge, invalid/rebound identities, failed-commit rollback,
revoked capability/account/category/ownership and legacy compatibility. One isolated
PostgreSQL race passes, proving simultaneous identical removals create exactly one
tombstone/audit/receipt. Retention is asserted as exact UTC elapsed time across DST.
`git diff --check` passed. No Swift or migration changed; server restart is required.

Native durable attachment removal integration remains next. Existing intentional removal
confirmation and preview interaction are untouched; no new UI/runtime acceptance is claimed.
No human attachment, Live database or Simulator data was changed. TestFlight remains on hold.

## Native durable reviewed scheduled realization (2026-10-09)

The production schedule editor passes its captured revision through the shared schedule
application service for Enter Now. Live persists schedule target, observation and UUID
before transport. Ordered replay resolves current credentials, verifies the saved
server/actor/budget destination and sends the identified server realization endpoint.
Response loss retains the original request across relaunch; stale or unauthorized intent
pauses for review without rebasing. A pending change for the same schedule blocks a second
realization, edit or deletion. Unobserved Live realization is refused.

Scheduled and Pending Sync show pending occurrences separately from accepted forecast and
actual activity. No local posting, reserve movement or schedule advancement is synthesized;
the server's existing financial engine realizes the occurrence, followed by authoritative
workspace refresh. Current transaction-creation/account access and visibility of the
original schedule govern pending detail visibility. Demo/local continue through the same
application-service operation using their existing canonical realization engine.

Executed evidence: production Foundation persistence/replay regression passes lost response,
relaunch, duplicate refusal, stale rejection pause, original-intent retry and acknowledgement
cleanup. The focused Swift API regression passes exact original query/header identity,
current credential, body-free POST, returned transaction IDs and legacy omission. Native
persistence regression was added; native runtime and human acceptance remain pending.
Regular Xcode 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`, passed
`build-for-testing` for app/native targets against preserved iPhone 17 Pro Max simulator
`3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. `git diff --check` passed.
No backend or migration changed in
this native checkpoint; deployment requires the preceding identified-realization server
contract. TestFlight remains on hold and Live/Simulator data remain intact.

Human retest after app rebuild and server update: open an overdue schedule in a disposable
budget, disconnect and tap Enter Now. Confirm a separate pending occurrence appears without
local balance/activity changes. Relaunch offline, reconnect, and verify exactly one occurrence
posts and Pending Sync clears. For a daily schedule with several overdue dates, reconnecting
must not post the next date again. A change from another device before acceptance must pause
the saved request for review rather than realize a newly reviewed version. No new migration.

## Identified scheduled realization retries (2026-10-09)

The production realization endpoint accepts an optional `X-Planning-Operation-ID`
UUID and `expected_revision` query. Identified actions require the reviewed schedule
revision. Under the existing budget lock, a fresh stale observation fails with 409;
an accepted retry returns the original immutable realization result rather than posting
the next overdue occurrence. Posting, schedule advancement, history and receipt commit
atomically. Legacy callers remain compatible and retain one occurrence per action.

Acknowledgement checks current transaction-creation authority and the original realized
event's complete account/category resource scope, even after subsequent schedule edits,
realization or deletion. Missing events and changed identity intent fail closed. The
history snapshot now captures remaining occurrences before decrement, preserving the
correct before/after audit observation without changing financial semantics.

Executed evidence: 84 focused backend tests pass across realization receipts, schedule
edit/deletion receipts, schedule contracts and financial golden vectors. Four isolated
PostgreSQL races pass: duplicate identified requests both acknowledge one posting even
while another occurrence is overdue; legacy expense, transfer and credit-card realization
still serialize correctly. Tests cover exact large integer amounts, once-only/inactive
acknowledgement, later deletion, stale observations, revoked capability/account/category,
identity corruption and failed-commit rollback. `git diff --check` passed.

This is the server contract checkpoint; native durable Enter Now queue integration remains
next. No Swift changed, no native runtime or human acceptance is claimed, and no Live or
Simulator data was modified. Deployment needs a server restart, not a new migration.
TestFlight remains on hold.

## Native durable reviewed schedule deletion (2026-10-09)

Confirmed schedule deletion now passes the editor's captured revision through the shared
application service. Live saves target/revision/UUID before transport; canonical ordered
replay resolves current credentials, verifies the server/actor/budget destination and sends
the existing DELETE endpoint with its receipt identity and observation. Lost responses
retain the same request; stale or revoked deletion pauses for review without rebasing.
Pending edits/deletions for the same schedule block a second intent until accepted/discarded.
Unobserved Live deletion is refused rather than using a freshly hydrated revision.

Scheduled and Pending Sync show removal awaiting approval separately from accepted schedules.
No local schedule is removed and accepted forecast, realized transactions and balances remain
unchanged before acknowledgement. Current planning/account access and a visible original
schedule govern pending detail visibility. Delete remains behind its explicit confirmation
dialog; overlapping remove tasks are guarded. Demo/local retain their canonical repository
delete behavior through the same application-service entry point.

Executed evidence: the production Foundation regression passes target/revision/identity
retention after interrupted deletion/relaunch, duplicate/identity rebound refusal, stale
rejection pause, explicit original-intent retry and acknowledgement cleanup. Two focused API
tests pass, covering current credentials, exact query/header, body-free DELETE and legacy
omission, plus inactive management compatibility. Native persistence coverage was added;
runtime execution is not claimed. Source-wiring checks do not prove UI interaction.
No backend code changed in this native checkpoint.
Regular Xcode 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`, passed
`build-for-testing` for app/native test targets against preserved iPhone 17 Pro Max simulator
`3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. `git diff --check` passed.

Human retest after rebuilding and updating the server: disconnect, open a disposable future
schedule and confirm Delete. Verify a separate pending removal appears while its accepted
row/forecast remains. Relaunch offline, reconnect, and verify removal is confirmed once,
Pending Sync clears, and any previously realized transactions remain. If another device
changes the schedule first, the pending request must pause for review instead of deleting
that changed plan. App rebuild and server update/restart required; no migration beyond 0049.
Offline realization and its lost-response retry identity are implemented in the later
identified-realization checkpoints above; human runtime acceptance remains pending. TestFlight stays
on hold; no merge/tag/release.

## Reviewed schedule deletion server boundary (2026-10-09)

Schedule deletion accepts optional UUID header `X-Planning-Operation-ID` and query
`expected_revision`. Identified deletion requires the observed schedule revision. Budget
locking serializes review, deletion history and receipt publication with edits/realization.
Changed metadata, pause state or realization returns 409 before deletion. Legacy requests
retain their existing behavior, including 404 for already missing schedules.

Accepted retries return 204 without another history row. The receipt references retained
deletion history rather than a vanished schedule, allowing current capability and whole
account/destination/category scope checks before acknowledgement. Changed intent/kind fails
409; missing or inaccessible history fails 404. Schedule removal, append-only deletion
history and receipt commit atomically. Realized transactions and financial observations
remain untouched; deletion only removes future planning metadata.

Executed evidence: 72 focused tests passed, including 14 deletion cases, the reviewed edit
suite, scheduled contract and financial golden vectors. Coverage includes lost-response
retry, stale metadata/pause/realization, identity/target/history mismatch, malformed UUID,
missing observation, capability/account/category revocation after deletion and failed-commit
rollback. A real isolated PostgreSQL race passed: simultaneous retries acknowledged one
deletion/history/receipt with no actual transaction. The temporary cluster was stopped.
`git diff --check` passed; no Live data changed.

Server update/restart required; no new migration beyond 0049. No Swift change or native
verification in this server-only checkpoint. Native reviewed deletion queuing remains the
next unfinished slice. TestFlight remains on hold; no merge/tag/release.

## Native durable reviewed schedule editing (2026-10-09)

Live schedule editing now persists complete edited metadata, schedule ID, captured server
revision and stable UUID before transport. Ordered replay resolves current credentials and
checks the destination before calling the existing canonical update endpoint. Interrupted
responses retain the exact intent; stale or revoked edits pause for explicit review without
rebasing onto a newer schedule. A second pending edit for the same schedule is refused until
the first is accepted/discarded. Inactive exhausted occurrence limits remain valid edit shapes.

Scheduled and Pending Sync show edits separately from accepted Upcoming/Due items. Accepted
forecast, actual activity and balances remain unchanged until server approval. Pending details
require current planning/account scope, a visible original schedule and visible edited
resources. The editor captures its initial revision rather than adopting background refreshes.
Skip uses the same reviewed update path and refuses a changed displayed revision. The audit
also found that the editor omitted existing interest-charge classification from its payload;
it now preserves that metadata instead of silently dropping it during unrelated edits.

Executed evidence: the production Foundation regression passes interrupted edit/relaunch,
exact payload/revision/identity retention, duplicate and second-edit refusal, stale rejection
pause, explicit unchanged retry, acknowledgement cleanup and exhausted paused shape. Three
focused Swift API tests pass for identified edit/exact large money/current credentials,
legacy schedule response decoding and creation compatibility. Native persistence coverage was
added; native runtime execution is not claimed. Source-wiring checks are not UI interaction
proof. No backend code changed in this checkpoint.
Regular Xcode 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`, passed
`build-for-testing` for the production app and native tests using preserved iPhone 17 Pro Max
simulator `3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. `git diff --check` passed.

Human retest after rebuilding and updating the server through the reviewed-edit contract:
disconnect, edit an existing schedule amount or pause it, then save. Its accepted row/forecast
must remain unchanged with a separate pending edit. Relaunch offline, reconnect, and verify
one accepted edit replaces the pending item. If another device changes/realizes the schedule
first, the stale pending edit must require review rather than undoing that change. Server
update/restart and app rebuild required; no new migration beyond 0049. Deletion and realization
offline durability remain unfinished. TestFlight remains on hold; no merge/tag/release.

## Reviewed schedule edit server boundary (2026-10-09)

Authorized schedule responses now expose an opaque content revision covering the complete
schedule, including pause state, next occurrence, limits and last realization. Updates accept
optional observed revision and mutation UUID; identified edits require the observation.
Budget locking precedes schedule row locking so review, receipt lookup, metadata/history
updates and receipt publication serialize with financial realization. Stale unaccepted edits
return 409 instead of overwriting newer planning state. Legacy unobserved updates remain
compatible. Command metadata is excluded from model mutation.

Accepted retries return the current authorized schedule without resetting later pause/edit
or realization. Changed identity intent/kind returns 409; deleted or inaccessible schedules
remain 404. Capability and resource scope are checked before acknowledgement. Schedule,
history and receipt commit atomically, with no actual transaction or financial mutation.

Executed evidence: 81 focused backend tests passed before adding two realization cases;
the complete 15-case edit regression then passed, including both realization cases. Coverage
includes exact large money, lost-response retry, later pause preservation, stale metadata/
dates/limits, identity collision, deleted non-resurrection, missing observation, capability/
account/category revocation and failed-publication rollback. Two real isolated PostgreSQL
races passed: same intent acknowledged once, and competing observed edits yielded one winner
and one conflict, with one edit history/receipt and no posted transaction. The temporary
cluster was stopped. `git diff --check` passed; no Live data was changed.

Server update/restart required; no new migration beyond 0049. No Swift changes or native
verification needed for this server-only checkpoint. Native captured edit observations and
durable schedule-edit queuing remain the next unfinished slice. TestFlight remains on hold.

## Native durable Make Recurring (2026-10-09)

The production transaction editor captures its displayed source revision when saving
Make Recurring. Live persists the source ID, reviewed revision, explicit next date,
cadence and stable UUID before any transport. Canonical ordered replay resolves current
credentials and verifies the server/actor/budget destination before sending the existing
Make Recurring endpoint. Lost responses retain the same intent for receipt acknowledgement;
stale source/date and authorization rejections pause for explicit Pending Sync review,
never substitute a fresh revision or generate a local schedule/posted transaction.

Pending Sync and Scheduled expose the saved recurring template separately from accepted
Upcoming/Due items. Known workspace/resource denial hides its details. Saved-but-unaccepted
intent leaves the editor once rather than inviting another creation identity. Save guards
overlapping tasks, and the sheet explicitly inherits the same workspace store. Demo retains
its existing application-service behavior through the same production editor and screens.

Executed evidence: the production Foundation outbox regression passes exact source/revision/
date/identity persistence, interruption/relaunch, duplicate identity refusal, rejection pause,
original-intent explicit retry and acknowledgement cleanup, alongside existing durable
operations. Two focused Swift API tests pass: identified requests preserve all reviewed
fields and rotated bearer credentials, while legacy requests omit the new optional fields.
Native persistence regression coverage was added; execution is not claimed by compilation.
Regular Xcode 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`, passed
`build-for-testing` for the app and native test targets against preserved iPhone 17 Pro Max
simulator `3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. `git diff --check` passed.

Human retest after rebuilding and updating the server: open an eligible posted transaction,
disconnect, choose Make Recurring and save one future occurrence. Confirm its pending row
appears separately in Scheduled, relaunch offline, then reconnect. Exactly one accepted
schedule should replace the pending row, without a new posted transaction or balance change.
For an explicit conflict check, edit the source on another connected device before replay:
Pending Sync should require review, not silently use that changed template. No new migration
beyond 0049. Full offline scheduled editing/deletion/realization remains unfinished.
TestFlight remains on hold; no merge/tag/release.

## Identified Make Recurring server boundary (2026-10-09)

Make Recurring now accepts an optional stable mutation UUID with the observed source
transaction revision and an explicit next date. A budget lock serializes source review,
schedule creation and receipt publication. Changed templates or expired reviewed dates
return 409 instead of silently copying newer metadata or advancing the requested date.
Legacy requests retain their existing behavior.

Accepted retries return the current authorized schedule, preserving subsequent edits or
pauses. Changed intent or command kind returns 409; deleted schedules are not resurrected.
Current capability and source/schedule resource visibility remain mandatory before receipt
acknowledgement. Schedule creation, the existing source audit and receipt commit atomically;
the posted transaction and financial values remain unchanged.

Executed evidence: 66 focused backend tests passed, including 12 new recurring receipt,
observation, date and authorization cases, existing void/schedule/attachment and scheduled
contract coverage, and financial golden vectors. One real isolated PostgreSQL race passed:
two simultaneous identified requests returned the same schedule with one receipt and one
source audit, retaining the original exact large integer amount and sole posted transaction.
The temporary cluster was stopped afterward. No Live data was changed.

This is the server prerequisite, not completed native offline Make Recurring. The current
native caller still needs durable observed intent, identity and Pending Sync integration.
Server update/restart required; no new migration beyond 0049. No Swift changes or native
test execution in this checkpoint. TestFlight remains on hold; no merge/tag/release.

## Native durable schedule creation (2026-10-09)

Ordinary schedule creation now persists its complete typed intent and stable UUID in the shared
Live outbox before transport. The canonical sender resolves current credentials, checks the
server/actor destination and submits the existing creation endpoint with `X-Planning-Operation-ID`.
Reopening preserves exact amount, resources, payee identity, memo, date, cadence, bounds and
active state. Invalid persisted creation shapes fail closed. Rejections pause the saved intent
for explicit review; ordered replay blocks later commands and never rebases or duplicates it.

The Scheduled screen separates pending creations under Awaiting Server Confirmation and links
to the same Pending Sync screen/store for review, retry or discard. Pending creations are not
inserted into accepted schedules, forecast or actual activity. Creation publishes pending status
after authoritative refresh; a saved-but-rejected intent leaves the editor once rather than
offering an accidental second creation. The editor also guards overlapping Save tasks. Pending
details require current planning/account access and visible referenced accounts/categories.

The audit additionally proved a Demo/Live status mismatch: Live creation ignored the Active
toggle because the server create model lacked `is_active`. The additive field now preserves
paused creation; a backend regression proves paused schedules are listed only in management and
produce no forecast occurrence. Active receipt digests retain the earlier implicit-active
definition so already accepted identities remain retryable across this contract extension.

Executed evidence: the production outbox host regression passes schedule persistence, duplicate
identity, interruption/relaunch, rejection pause, explicit original-intent retry, acknowledgement
and invalid-date refusal, alongside the prior durable-operation checks. Three focused Swift API
tests and all 94 API client tests pass, covering stable header/payload, exact large money,
rotated bearer credentials and legacy header omission. All 56 focused backend cases pass
(13 schedule receipt/status/compatibility cases, the existing scheduled contract and 23
financial golden vectors). Regular Xcode 27.0 build 27A266a passed `build-for-testing` for app
and native test targets using preserved iPhone 17 Pro Max simulator
`3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. The first build caught a missing explicit
store initializer at the Pending Sync destination; it was corrected before the passing build.
`git diff --check` passed. A native exact-intent/relaunch XCTest was added but not claimed
executed; runtime and human acceptance remain distinct from compilation.

Human retest after rebuilding and updating the server through this checkpoint: open Scheduled,
disconnect, create one recurring expense, confirm its pending row is separate from Upcoming,
relaunch, reconnect, and verify one accepted schedule replaces it with no posted transaction.
Pending Sync must clear. Existing tested realization/accounting workflows need not be repeated
from zero. Server update/restart and native rebuild required; no new migration beyond 0049.
Make Recurring, schedule edits/deletion/realization, administrative operations and broader
offline completeness remain separate unfinished slices. TestFlight remains on hold.

## Identified schedule creation server boundary (2026-10-09)

Ordinary schedule creation now accepts optional UUID header `X-Planning-Operation-ID`.
The existing actor/budget receipt table binds the complete validated request to one created
schedule. Budget locking serializes receipt lookup and publication; the creation history and
receipt commit atomically. An accepted retry returns the current authorized schedule without
resetting a later pause, edit or realization. Changed intent or command kind returns 409;
deleted or currently inaccessible schedules return 404 rather than being recreated. Current
manage-planning capability is checked before acknowledging any accepted identity. Requests
without the header retain the existing creation behavior.

Executed evidence: 54 focused backend tests passed (11 new receipt cases, the existing
scheduled-transaction contract and 23 financial golden vectors). New coverage includes exact
large integer money, money-neutral creation/retry, preserved later pause/memo, changed intent,
deleted non-resurrection, capability/account/category revocation, malformed UUID, command-kind
collision, legacy behavior and failed-commit rollback/retry. A real isolated PostgreSQL race
passed: simultaneous identified requests returned one schedule, one creation history and one
receipt, without an actual transaction. The disposable test cluster was stopped afterward.
No Live database or customer schedule was changed. `git diff --check` passed.

Server update/restart required; no new migration beyond the existing 0049 receipt table.
No Swift changes or native build in that server-only checkpoint. Native ordinary creation
queuing is covered above; Make Recurring retry identity and observed-edit conflict protection
remain unfinished. Full offline scheduled management is not yet complete. TestFlight remains
on hold; no merge/tag/release.

## Offline pending attachment presentation (2026-10-09)

Transaction detail now renders individual saved-upload rows, with filename, bounded file size
and pending/review status, rather than a floating notice or misleading empty state. An offline
empty view explains that server attachments must be loaded after connecting. Add Attachment
counts locally pending and currently loaded accepted files toward the 20-file UI boundary;
the server remains authoritative for final capacity and authorization.

Pending-file preview reads integrity-checked staged bytes locally, through current workspace
access, visible pending-entry scope and server/actor destination guards. It never calls upload,
download, detach or acknowledgement. Accepted and pending previews share the existing Quick
Look navigation; temporary preview copies now use unique private directories, complete file
protection and mode 0600 instead of filename-shared unprotected temporary copies. Temporary
preview copies still rely on OS temporary-directory cleanup; durable queue data is separate.

Executed evidence: the production Foundation outbox regression passes, including local byte
reads through reopen without acknowledgement, retained interrupted uploads, corruption refusal
and the full existing durable-operation checks. Additional production-wiring assertions verify
local preview has no asynchronous transport/removal path and requires a currently visible
pending entry. Native regression additions cover preview retaining the queue and known workspace
revocation refusing staged-byte access. These source assertions are not UI interaction proof,
and the native cases are not claimed executed.

Regular Xcode 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`, passed
`build-for-testing` for the production app and native tests using preserved iPhone 17 Pro Max
simulator `3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27. `git diff --check` passed.

Human retest extends the previous offline-upload flow: after saving a receipt offline, reopen
the transaction and tap its pending filename. Verify the preview works offline and Back returns
to the still-pending row. Reconnect and verify exactly one accepted attachment replaces it.
No server change or migration; native rebuild required. TestFlight remains on hold.

## Native protected attachment upload replay (2026-10-09)

Photos, Camera and Files continue through the existing transaction attachment application
service. Live now stages validated bytes before publishing a queue entry, using atomic
complete-file-protection writes, directory mode 0700 and file mode 0600. Metadata binds the
transaction, sanitized filename, MIME, byte count, SHA-256 and stable upload UUID. Replay
resolves current credentials and verifies the destination and staged integrity before sending
the existing upload endpoint. Returned transaction, MIME, size, hash and active status must
match before acknowledgement removes queue metadata and then staged bytes.

Pending Sync exposes uploads only with current edit/view permission and visible target
transactions. Interrupted uploads retain bytes and identity; rejected or damaged uploads
remain for review rather than recreating files or synthesizing accepted attachment metadata.
Transaction detail shows a saved-upload notice and reloads accepted metadata when the pending
upload count clears. Ordinary offline opening skips the remote attachment-list request.

Executed checks: production outbox host regression (relaunch, lost response, protected-file
permissions, exact retry bytes, acknowledgement cleanup, corruption pause and invalid signature);
two Swift API tests (legacy header omission and stable identity/binary body with rotated token).
Regular Xcode 27.0 build 27A266a `build-for-testing` passed for the production app and native
test targets on preserved iPhone 17 Pro Max simulator
`3ABD861E-D38D-4AFD-A356-959266051564` (iOS 27). `git diff --check` passed.
These checks do not claim executed native XCTest, human or Simulator UI runtime acceptance.

Limits: staged bytes are protected by iOS file protection, not a second application encryption
format. Server encryption remains unchanged. Failed queue publication or best-effort cleanup
can retain protected orphan files; automatic orphan recovery/pruning is not implemented.
Previously downloaded attachment content is not a general offline cache. Administrative
commands and other unfinished offline work remain outside this checkpoint.

Human retest on an updated server containing the identified-upload receipt support: open an
authorized posted transaction, disconnect networking, select one small valid receipt, verify
the saved-upload notice and Pending Sync entry, relaunch without deleting data, reconnect,
and verify exactly one readable attachment appears and the pending entry clears. A separate
revoked-permission test should retain the pending bytes for review without publishing the file.
Rebuild required; server receipt support through c6c6746 required. No new migration beyond
existing 0049. TestFlight remains on hold; no merge/tag/release.

## Identified attachment upload server boundary (2026-10-09)

The attachment audit found uncertain uploads could be retried as a new upload, consuming
another encrypted object and attachment slot. The existing upload endpoint now optionally
accepts UUID header `X-Attachment-Operation-ID`; actor/budget receipts bind the validated
canonical target, sanitized filename, normalized MIME, byte count and content SHA-256.
The budget lock serializes attachment publication/count checks. Receipt, metadata and audit
commit together, with rollback deleting tentative encrypted storage. Accepted retry checks
current edit permission, ownership and whole-transaction scope before returning the existing
attachment. It verifies decrypted bytes/size/hash before acknowledging: missing/corrupt stored
content returns 500, never a false success. Changed intent/target/kind returns 409. Detached
accepted uploads return 404 without recreating data or undoing the 30-day tombstone.

Also corrected a proven new-audit identity defect: attachment IDs were generated on insertion,
but the audit JSON was captured earlier and therefore recorded `attachment_id: null`. Allocate
the stable attachment ID before capturing the event. Existing immutable audit history is not
rewritten. No new encryption/storage path or accounting semantics were introduced.

Fifty-two focused backend tests passed (14 new upload receipt tests plus attachment lifecycle,
privacy and financial golden vectors). Coverage includes exact-one encrypted object/audit,
correct audit identity, content/name/target/kind collisions, acknowledgement at the 20-file
limit, detached non-resurrection, revoked account/category/capability/ownership, missing/corrupt
storage refusal and failed-commit cleanup. One real isolated PostgreSQL concurrent-upload race
passed: both retries returned one ID with one encrypted object, receipt and audit event.
Disposable PostgreSQL was stopped afterward; no Live/Simulator data touched.
`git diff --check` passed. No Swift changes/native rebuild or full-backend-suite claim.

Server update/restart required. Existing migration 0049 receipt table is required; no new
migration. Native protected staging and upload replay are implemented in the checkpoint above;
human offline acceptance remains pending. TestFlight remains on hold; no merge/tag/release.

## Native durable observed Void with Reversal (2026-10-09)

The shared void editor now captures its displayed transaction revision in state rather than
renewing it during background refresh. A typed provider-neutral operation routes through the
existing transaction application service. Live persists target/reason/revision/mutation UUID
before the first send, resolves current credentials and rechecks destination binding on replay,
then calls the canonical identified void endpoint. Local Device/Demo default to their existing
immediate canonical implementation. Unobserved legacy Live calls fail before network transport.
Only one pending void per transaction is accepted. Uncertain responses retain intent across
relaunch; stale/denied results pause ordered replay without automatic rebasing. Pending Sync
shows authorized target/reason and clearly distinguishes intent from an accepted reversal.
Current delete/view capabilities and whole-transaction visibility gate pending details.
No local reversal, reserve calculation or optimistic financial mutation was introduced.

Production-code host regressions passed for persist/reopen, unchanged target/reason/token/UUID,
lost acknowledgement retention, duplicate submission rejection, stale pause across relaunch,
no automatic paused send, explicit original-intent retry and acknowledgement removal. Two Swift
API tests passed: identified transport with rotated credentials/Codable round-trip and legacy
void/Make Recurring compatibility. Regular Xcode 27.0 (27A266a) production/native-test
build-for-testing passed on preserved iPhone 17 Pro Max/iOS 27 destination
`3ABD861E-D38D-4AFD-A356-959266051564`. No executed native XCTest/XCUITest or human runtime
acceptance is claimed. `git diff --check` passed. The preceding server checkpoint supplies
twelve HTTP regressions and real concurrent-void/reconciliation contention proof.

Minimal new human acceptance: open an ordinary posted transaction online and enter a void reason;
disconnect before confirmation, then confirm and verify Pending Sync holds it while the original
remains posted and balances remain unchanged. Relaunch, reconnect and verify one reversal plus
one original void decision, with the entered reason preserved. In a second test change the
reviewed transaction on another device before reconnect; verify rejection pauses the saved void
without effects. Resolve/discard it explicitly and start a new review. Existing accepted ordinary
void and Quick Clear workflows need not be repeated wholesale.

Rebuild required; server must include `16961aa` identified-void contract. No new migration,
Live/Simulator data reset, merge/tag or TestFlight upload. Draft persistence and protected offline
attachment bytes remain separate open milestones; this does not claim complete hosted offline use.

## Identified void/reversal server contract (2026-10-09)

The offline audit found native Void with Reversal still calls an unidentified one-way endpoint.
A lost response leaves the caller unable to distinguish its accepted void from unrelated later
state. Before native queue integration, the canonical endpoint now accepts optional mutation UUID
and observed transaction revision (required together for identified commands). The validated
original target, reason and revision are digest-bound to the actor/budget receipt in the same
commit as the normal reversal, card reserve effects and original/reversal audit decisions.

Matching retries acknowledge the existing reversal without financial effects, even if that
reversal was later reconciled. Current capability, original ownership, and original/reversal
resource visibility are rechecked. Wrong payload, target or command-kind identity conflicts;
stale observations reject before posting. Missing/malformed observations return 422. Existing
unidentified callers retain the legacy one-way behavior. No authentication/accounting rules
were weakened and no new receipt table/migration was needed.

Sixty-nine focused backend cases passed across void, attachments/schedules, cards, bulk receipts
and financial golden vectors. Final twelve void-receipt regressions passed, including added
funded-card retry (reserve released exactly once) and cross-kind identity collision. Five bounded
isolated PostgreSQL races passed: identified concurrent voids acknowledged the same single exact
Int64 reversal and two audit decisions; all four reconciliation contention cases remained green.
The private test database was stopped; Live/Simulator data were untouched. `git diff --check`
passed. No Swift change, native build, full-suite claim, release/tag or TestFlight upload.

Server update/restart required; migration 0049 is an existing prerequisite, no new migration.
Native observed void transport and durable queue integration remain the next gap, not completed
or human-accepted by this server checkpoint. Existing human void acceptance need not be repeated
from zero; the new acceptance will target interrupted/retried observed voids specifically.

## Durable reviewed reconciliation — native checkpoint (2026-10-09)

Live reconciliation now uses the existing actor/server/budget-bound protected outbox and
canonical account application service, not a second accounting implementation. It persists
exact Int64 statement/observed balances, cutoff, adjustment consent/reason, the captured
server-reviewed transaction token and stable mutation UUID before network suspension.
Current credential preparation and destination binding run on each replay. Transient failures
retain intent; definitive rejection pauses ordered replay. Retry never refreshes the captured
token or changes consent. Pending Sync shows the account/cutoff/statement and explicitly states
that balances/history remain unchanged until accepted. Current reconciliation/balance capability
and account scope control visibility. Duplicate pending reconciliations for one account are
rejected. Local Device and Demo retain their existing immediate canonical behavior.

The production-code host verifier exercises persistence/reopen, exact large amounts, duplicate
submission rejection, lost acknowledgement retention, stale-review pause, no automatic retry
while paused, explicit retry retaining the original token, and acknowledgement removal. Three
Swift API regressions passed, including exact reviewed token and mutation UUID transport. Twelve
backend observation/receipt cases passed, covering stale-set denial, current authorization and
accepted acknowledgement without duplicate history/adjustments. Regular Xcode 27.0 (27A266a)
production/native-test build-for-testing passed for preserved iPhone 17 Pro Max/iOS 27 simulator
`3ABD861E-D38D-4AFD-A356-959266051564`. Compilation is not executed native XCTest, XCUITest,
or human runtime acceptance. The production-code host verifier executes the real persistence
and replay implementation without touching Simulator/Live data. `git diff --check` passed.

Minimal remaining human flow: open Live reconciliation online and capture the cleared review;
disable connectivity, submit the reviewed statement, and verify Pending Sync retains it without
changing R/history/balances. Relaunch, reconnect and verify exactly one reconciliation (and at
most one explicitly consented adjustment) is accepted. For a stale case, change a contributing
transaction on another device before reconnect; verify the saved intent pauses with no effects
and the original draft/token is not silently replaced. Resolve/discard it explicitly before
starting a fresh review. No repeat of already accepted ordinary Quick Clear is required.

Rebuild required. Existing server receipt/review contracts and migrations are prerequisites;
this checkpoint introduces no server code or migration. TestFlight remains on hold. The broader
offline milestone remains open, including administrative commands and unfinished draft coverage.

## Financial writer lock-order checkpoint (2026-10-09)

Ordinary transaction creation/edit/delete/void, transfer creation/edit/delete,
scheduled realization, and statement approval/undo now acquire the same budget lock
before their account, transaction, schedule or import-claim locks. This serializes
financial writes with reconciliation's review-to-commit critical section within one
budget. Existing accounting rules and permission checks remain unchanged; statement
approval still requires its existing view/create permissions, not reconciliation authority.

The event-coordinated PostgreSQL regression now covers bulk clearing, edit, delete and
void: each backend demonstrably waits on the budget lock, then receives 409 after
reconciliation commits, retaining the cleared/reconciled transaction. Twelve focused
PostgreSQL cases passed, including transfer/reconciliation receipt races, scheduled
expense/transfer/card realization, import approval, bulk tags and target snoozes.
An existing misplaced target-snooze assertion block was restored to its own test;
it previously referenced undefined variables in the import concurrency test.
Another 110 focused backend cases passed, including financial golden vectors.
These checks do not constitute proof of every possible cross-route contention pair.

Private disposable PostgreSQL was stopped after verification. No Live or Simulator
data was touched. No Swift changes or native rebuild required. Server update/restart
required; no new migration. TestFlight publication remains on hold. Regular Xcode
27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`, replaces Beta for future
native verification. Offline reconciliation remains outside the native outbox.

## Proven Quick Unclear / reconciliation race correction (2026-10-09)

An event-coordinated real PostgreSQL regression reproduced Quick Unclear committing after
reconciliation's reviewed-set calculation and before its commit. Reconciliation's account lock
did not protect bulk metadata/clearing, which locked transactions but not the account. The test
failed before correction: the bulk action completed inside the reconciliation critical section.

Bulk transaction mutation and reconciliation now both acquire the existing budget row lock
before account/transaction locks and retain it through commit/receipt publication. This avoids
introducing opposite account/transaction lock order. After reconciliation commits, the waiting
bulk action reloads the transaction and receives the existing 409 reconciled protection; the
row remains both cleared and reconciled. Financial calculations, permissions, amounts, reserve
rules, reconciliation history semantics and native UI behavior are unchanged. This serializes
these two paths within one budget, not globally across households.

Four bounded isolated PostgreSQL races passed (the new race plus nearby reconciliation and
transfer receipt checks), and 60 focused observation/receipt/bulk/credit/golden cases passed.
The final regression explicitly observes the bulk backend waiting on a PostgreSQL Lock for
the budget query through pg_stat_activity, rather than treating a synthetic swipe or elapsed
delay as proof. Disposable private-socket PostgreSQL only; no Live/Simulator data touched.
The test cluster is stopped after verification. `git diff --check` passed.

This closes the proven quick-clearing race, not every other overlapping transaction mutation.
Ordinary edit/delete/void, transfer, scheduled realization and import lock ordering still require
the corresponding audit before offline reconciliation is claimed safe. Reconciliation remains
outside the native outbox. Server update/restart required; no new migration/native rebuild,
merge/tag or TestFlight upload.

## Real PostgreSQL checkpoint and migration 0040 portability fix (2026-10-09)

A bounded three-case concurrency run used a newly initialized PostgreSQL 17.11 cluster under
`/private/tmp/clearpocket-pg-review.KxngBJ`, private Unix socket only (no TCP listener), never the
human Live database. The migration-built fixture initially failed at 0040: the explicit index
`ix_scheduled_transaction_revisions_before_destination_account_id` exceeds PostgreSQL's
63-character identifier limit. SQLite had accepted it. The historical migration now marks
convention-derived index names with `op.f` for deterministic SQLAlchemy truncation, identical to
ORM `index=True` names. Upgrade/downgrade use the same mapping; SQLite names remain unchanged.
No new revision or alteration of already-stamped customer databases is introduced.

After the fix, empty PostgreSQL upgrade through current head and all three selected races passed:
legacy concurrent reconciliation creates one adjustment; identical identified reconciliation
requests both acknowledge one history/receipt/adjustment; identical identified transfer creation
requests both acknowledge exactly two balanced legs and one receipt, preserving Int64 values
beyond Double precision. The existing direct reconciliation test now supplies Settings explicitly
as required by the review-token implementation. Two migration checks passed: real PostgreSQL
DDL compilation for all 11 index upgrade/downgrade names matching ORM identifiers, and populated
SQLite schedule history backfill through head preserving exact money. `git diff --check` passed.

This proves these specific receipt/contention paths, not every command collision, hosted replay,
or reconciliation-versus-clearing isolation. The latter remains a required pre-outbox audit; do not
claim safe offline reconciliation yet. The disposable cluster was stopped after the run; temporary
test data/logs remain available locally. No Live, attachment or Simulator data was reset. No Swift
changes/native build necessary, no merge/tag/TestFlight upload. Fresh server installations must
include the migration fix; already-current installations do not require a new migration.

## Native reconciliation reviewed-set integration (2026-10-09)

The production Live account repository now loads the dedicated reconciliation-observation endpoint
through current credentials. The API rejects mismatched account/cutoff or malformed review tokens.
The provider-neutral account service returns one balance/token observation; Local/Demo use the
existing local observation through a default repository implementation, with no invented server
token. Live overrides that implementation and refuses reconciliation without a reviewed token.

The production reconciliation editor stores observed balance, cutoff and token together in State.
Only explicit recheck/cutoff reload replaces the token; ordinary workspace refresh does not. Access
denial clears all observations. Existing observation-generation/cancellation guards discard stale
asynchronous replies. Save passes the captured token through the canonical service/request; stale
server rejection preserves the statement/adjustment draft instead of automatically reviewing a
new set or changing accounting locally. The request DTO supports optional receipt identity for
the subsequent durable-queue work; this checkpoint does not enqueue reconciliation or claim
offline reconciliation complete.

Two executed Swift API cases cover real mocked observation-to-mutation payloads with exact Int64
values, current bearer headers and captured token, plus wrong account/date/malformed token denial.
Production-source guards cover the actual Live override, fail-closed mutation and editor token
capture. They are structural checks, not executed SwiftUI runtime acceptance. The production host
verifier and `git diff --check` passed. Regular Xcode 27.0 (27A266a) build-for-testing passed on the
existing iPhone 17 Pro Max / iOS 27 simulator 3ABD861E-D38D-4AFD-A356-959266051564; native
XCTest/UI runtime execution is not claimed. Server must include c392800; app rebuild and server
update/restart required, no new migration or customer-data reset. TestFlight remains on hold.

Minimal human acceptance: on a disposable Live account open Reconcile, then change a reviewed
transaction on another device without changing the cleared total. Save must reject while retaining
the draft. Explicitly Recheck, review and save must succeed. Verify ordinary Local Device/Demo
reconciliation still works. No already-human-passed clearing/reconciliation lifecycle repetition
is required beyond these new changed-set paths.

## Server-issued reconciliation reviewed-set token (2026-10-09)

GET account `reconciliation-observation?through_date=...` requires current reconcile capability
and account scope. It returns exact cleared balance plus an opaque HMAC review revision bound
to actor, budget, account, cutoff, last reconciliation observation and the ordered cleared
transaction IDs/revisions. Observation streams batches of 500 with split preloading instead of
materializing a complete historical transaction list. No transaction details/counts are returned.
The optional `expected_review_revision` on reconciliation rejects changed reviewed state before
any mutation, even where the cleared balance remains identical. Legacy balance-only clients stay
compatible; identified receipts still acknowledge previously accepted work before stale guards.

Seven HTTP cases exercise offsetting additions, same-balance cleared-set replacement, metadata
changes, cutoff changes, exact Int64 acceptance, receipt retry after reconciliation, actor binding,
and capability/account revocation. All 51 focused observation/receipt/ledger/financial-golden
cases passed; `git diff --check` passed. These are inter-request mutation checks, not proof of isolation
against every overlapping PostgreSQL writer. Content revisions are not monotonic ABA counters.
Native reconciliation must adopt the new observation/expected token; it is not in the outbox yet.
Reviewed-set checks and receipts are necessary but not sufficient to claim the entire hosted
offline-write milestone complete. No migration, native build or human-data modification required.
Server update/restart required; TestFlight remains on hold.

## Identified reconciliation acknowledgement (2026-10-09)

Reconciliation now optionally accepts `mutation_operation_id`, requiring the existing observed
cleared-balance precondition when identified. The canonical route binds account/request/actor/
budget to the immutable reconciliation history ID. Receipt, adjustment if any, reconciled flags,
actual audits and account reconciliation observation commit together. A matching retry returns
the accepted history result without repeating reconciliation, creating another adjustment,
changing a later reconciled balance/timestamp or adding another history row. Different identity
reuse returns 409. Current reconcile capability and account visibility are checked before
receipt acknowledgement. Legacy callers retain the existing contract and financial calculation.

Five actual HTTP cases cover matched and adjusted reconciliation, lost-ack-shaped retries after
later reconciliation, unchanged account timestamp/history/audits, missing/stale observation,
different-payload identity reuse and account/capability revocation. Focused ledger, credit-card
and financial golden suites passed with these tests: 60 cases total. `git diff --check` passed.
Real overlapping PostgreSQL proof is not
claimed. Reconciliation remains outside the native outbox: a cleared-balance-only observation
does not identify the full reviewed transaction set (offsetting concurrent changes can preserve
that total). A stronger reviewed-set precondition is required before claiming safe offline
reconciliation; receipts alone do not finish this milestone. No Swift changes, app rebuild or
new migration required. Server update/restart required. Human data remains untouched and
TestFlight remains on hold.

## Durable native account transfers and observed edits (2026-10-09)

Live transfer creation/editing now persists an exact typed transfer command with mutation UUID
before its first authenticated send. Edits capture both leg revisions at editor opening in stable
SwiftUI state, not at refresh/save time. The ordered production outbox resolves the current
credential and endpoint binding before calling the existing transfer API. Connectivity failures
retain intent; definitive rejection pauses automatic replay without replacing either observation.
Pending Sync shows source/destination and exact amount only when both accounts and, for edits,
both currently visible posted legs are authorized. Pending transfers never synthesize posted
balance, category activity, income/spending, liability or reserve changes locally. Local/Demo
continue using their existing application-service implementation; missing Live observations
fail before enqueue rather than submitting an unguarded edit.

Executed host checks use the actual production outbox and typed transfer operation: persist and
reopen exact Int64 creation/edit payloads, preserve logical transfer target and both observations,
acknowledge ordered creation then pause a stale edit without rebasing. Source guards verify
canonical create/update sender wiring, binding checks and editor observation capture. Two Swift
API tests passed with actual mocked HTTP encoding for identified edits and legacy omission/roundtrip.
The host production verifier passed. Regular Xcode 27.0 (27A266a) build-for-testing passed on
existing iPhone 17 Pro Max / iOS 27 simulator 3ABD861E-D38D-4AFD-A356-959266051564.
`git diff --check` passed. Native compile verification is separate from runtime acceptance; no claim of executed
UI tests or real PostgreSQL concurrent lost-response proof is made. Required server contracts are
34e75d7 / 8246895 with existing migration 0049. App rebuild and server update/restart required;
no new migration, customer-data reset, merge/tag or TestFlight upload.

Minimal remaining human transfer acceptance on a disposable Live budget:
1. Disconnect the server, save one cash-to-cash transfer, confirm Pending Sync and unchanged
   posted balances; relaunch, reconnect, verify exactly one pair of legs and matching balances.
2. Separately open an existing transfer, disconnect and save an edit. Change that transfer on
   another device before reconnecting: verify rejection preserves newer posted values and the
   original pending intent. Discard/recreate after review; never silently rebase.
3. Verify a permitted funded credit-card payment through the same flow and its one canonical
   reserve effect. Reconciled transfers remain non-editable. Human acceptance is outstanding.

## Observed account-transfer edit contract (2026-10-09)

PUT transfers accepts optional `expected_revisions` keyed by both actual leg IDs. Identified
edits additionally require `mutation_operation_id` and both observations. A changed revision on
either leg returns 409 before mutation; malformed/missing observations return 422. Legacy
unidentified callers remain compatible. New edits retain reconciled-transfer protections and
the existing balanced transfer/credit-card reserve calculation, with no local accounting path.

Accepted edits persist the actor/budget-scoped receipt with both legs, reserve effects and actual
change audits in one commit. Identical retries acknowledge current authorized state before stale
or reconciliation guards, never reapply an edit. Identity reuse for another payload/target/kind
returns 409. Current capability, ownership and both account scopes are checked before any receipt
acknowledgement. Collision rollback re-enters those checks; real concurrent PostgreSQL proof
remains outstanding.

Actual HTTP regressions cover either-leg conflicts, missing/incorrect two-leg observations,
exact Int64 amounts, accepted retry after later reconciliation/metadata, changed-payload/new-ID
rejection and account/capability revocation. The focused edit/creation/ledger/credit/golden suite
passed 67 cases; final edit coverage includes nine cases. This is a server contract checkpoint,
not completed native offline transfers. Native transfer editors still need captured observations
and durable queue integration. Server restart required; no new migration or Swift build,
no changes to human Live/Simulator data. TestFlight remains on hold.

## Identified account-transfer creation receipts (2026-10-09)

POST transfers now accepts an optional `mutation_operation_id`. An actor/budget-scoped receipt
binds the validated original request to its transfer identity and commits with both account legs
and any canonical credit-card reserve event. Exact retries acknowledge the currently authorized
existing transfer without recreating either leg, reverting later metadata, or repeating reserve
effects. Different payload reuse returns 409; a deleted accepted transfer returns 404 rather than
being recreated. Current create capability and both original/current account scopes are checked
before acknowledgement. Legacy callers retain existing behavior.

Five actual HTTP cases cover exact Int64 values beyond Double precision, cash and credit-to-cash
reserve retries, later reconciliation/metadata, changed-payload rejection, deleted transfers, and
account/capability revocation. Existing ledger, credit-card and financial-golden tests are included
in the focused checkpoint verification: 60 tests passed, followed by five receipt cases passing
again after removing the acknowledgement's unnecessary leg lock. `git diff --check` passed.
A real overlapping PostgreSQL/lost-response race remains
unverified; the collision path rolls back and re-enters current authorization checks. This does
not yet provide observed transfer-edit preconditions or durable native transfer queueing, so the
hosted offline milestone remains incomplete. No Swift changes or native testing are required for
this server-only checkpoint. Server restart required; no new migration beyond existing 0049,
no customer database changes, no simulator reset. TestFlight remains on hold.

## Durable native Assign and category Move Money (2026-10-09)

Live planning commands now assign a mutation UUID and persist typed exact intent plus observed
allocation version before any authenticated request. Assignment/move share the ordered creation,
edit and bulk queue; each uses its canonical server route with current credential/endpoint binding.
Pending plan intent does not become authoritative Available, RTA or account money. Subsequent
commands keep the captured version: an earlier accepted plan change may make a later item stale,
which must pause rather than silently rebase. Definite rejection keeps the editing flow/draft and
review entry, while connectivity failure retains the pending change. All queue payloads are
exclusive typed commands; malformed/mixed disk payloads fail closed. Current category scope guards
planning review and retry/discard. Pending Sync labels plan changes and uses generalized lifecycle
wording instead of calling every queued item a transaction. Local Device/Demo behavior is unchanged.

Actual production host execution passed exact Int64 assignment and move persistence, reopening,
ordered acknowledgement and retained stale-version review without rebasing, plus prior queue checks.
Two Swift API tests passed including actual assignment/move HTTP payload identities, captured
versions and exact amounts beyond Double precision, plus the legacy move contract. Regular Xcode 27
build-for-testing passed on the preserved iPhone 17 Pro Max/iOS 27 destination; no executed native
runtime/human acceptance claim. Backend unchanged in this checkpoint;
server must include `f450303` allocation receipts and migration 0049. App rebuild required; update/
restart server if behind that checkpoint. No data reset, merge, tag or TestFlight publication.

Remaining new acceptance: on a disposable loaded Live budget, disconnect, save one assignment,
confirm a pending plan change with unchanged authoritative Available/RTA, relaunch and reconnect.
Expect one allocation effect. Repeat for one category move. In a separate case, another authorized
device changes the plan before reconnect; expect paused review preserving the newer plan. Review
can retry the same immutable intent or discard it and let the user recreate after reviewing fresh
state; it does not currently edit/rebase a queued conflicting plan command.

## Identified Assign and category Move Money receipts (2026-10-09)

Both canonical allocation routes now optionally accept a mutation UUID, requiring the observed
allocation version. They use the existing actor/budget-scoped 0049 receipt table; digest-bound
receipt and allocation postings commit atomically. Matching assignment retries return current
monthly assigned totals, preserving later plan changes; matching moves return the accepted
allocation operation without appending another pair of postings. Accepted assignment no-ops also
record receipts. Changed payload/identity reuse and fresh stale commands reject. Authorization,
category scope and delegated ownership/reallocation checks precede acknowledgement; actual new
commands retain real-RTA/source funds, version and delegated rule enforcement. Budget row locking
refreshes authoritative allocation state. Cross-command receipt collisions roll back and re-enter
the guarded path. Legacy unidentified clients remain compatible.

Ten new HTTP cases passed: both route retries, changed payload, later plan preservation, no-op
receipt, missing observation, revoked category/capability and revoked delegated reallocation.
Allocation ledger/archive/history privacy, delegated access and financial golden suites also passed.
The first focused run caught an unmaterialized move operation ID; it was corrected by flushing the
canonical operation before constructing its receipt, within the same transaction. Diff checks pass.
These SQLite HTTP tests are not proof of concurrent PostgreSQL/lost-response behavior; that gate
remains open. No Swift changes or native rerun. Server update/restart required, no new migration
beyond 0049. Native offline Assign/Move integration remains next; TestFlight remains held.

## Preserve newer queues across workspace ownership changes (2026-10-09)

Persistence audit reproduced the risk of multiple outbox instances: a stale owner's array could
atomically overwrite newer saved entries because atomic replacement alone does not prevent lost
updates. Each owner now retains its successfully persisted snapshot. Replay-start and every write
compare that snapshot against current decoded disk entries; mismatches fail before replacement.
Compare/replace is synchronous on MainActor across in-process owners. A stale in-flight sender cannot
acknowledge by removing another workspace's newer intent. The error directs reopening and explicitly
warns that a request may already have reached the server; server receipts remain the once-effect
boundary. No automatic merge, financial synthesis or external-process locking is implied.

Production host checks passed stale append rejection with byte-identical file preservation, no stale
replay sends, concurrent-owner append during sender execution, rejected stale acknowledgement with
both intents retained, and ordered replay after reopening. Prior legacy adoption, creation/edit/bulk,
exact money, scoped privacy and persisted-rejection checks also passed. A matching native XCTest
was added; regular Xcode 27 build-for-testing passed on the preserved iPhone 17 Pro Max/iOS 27
destination. Native runtime/human acceptance remains unclaimed.
No server, schema, data or simulator change. Rebuild required. TestFlight remains held.

## Durable native bulk and quick-clearing commands (2026-10-09)

The Live bulk repository now assigns an immutable mutation UUID and persists the typed exact bulk
request plus complete selection-time revision map before any send. Account-register/Activity quick
Clear/Unclear and all four Activity bulk actions use this shared canonical path. Creation, ordinary
edits and bulk commands share insertion-order replay; a paused rejection blocks later commands.
Typed bulk entries carry no made-up transaction amounts or categories. Unknown/missing observations
reject locally, rather than permitting unguarded offline overwrite. The sender resolves current
credentials and endpoint scope before the canonical bulk API call. No offline flags/tags/clearing
are applied to authoritative posted rows. Pending Sync labels the action/count and requires every
target in the current authorized workspace window before revealing details or permitting local
retry/discard; out-of-window/restricted intents remain intact. Definite rejection retains selection
and the review entry; pending counts update even on thrown rejection. Older creation/edit queues
remain readable by the new app; older app versions do not understand new bulk entries (downgrade
replay is not promised). Transfers, allocations, reconciliation and attachments are not queue-enabled.

Production host checks passed persisted typed bulk payload, omitted unrelated fields, timeout/reopen
exact replay and missing-observation rejection, plus prior creation/edit/privacy/review checks.
Three Swift API tests passed including actual bulk HTTP encoding, action-specific omissions and
identified payload Codable round-trip. Regular Xcode 27 build-for-testing passed on the preserved
iPhone 17 Pro Max/iOS 27 destination; no executed native runtime or human acceptance claim.
No backend changes this checkpoint. Server must include `66c380e` identified bulk receipt support and
migration 0049; update/restart if it does not. App rebuild required. TestFlight remains on hold.

Remaining new acceptance: disconnect a loaded Live workspace, Clear one disposable eligible row,
confirm it remains posted/uncleared with a saved pending action, relaunch, reconnect, and confirm a
single authoritative Clear with unchanged working balance. A separately changed/reconciled target
must pause rather than overwrite. This does not require repeating already accepted online clearing.

## Identified bulk-command acknowledgements (2026-10-09)

Audit found that bulk metadata/clearing updates had content preconditions but no immutable accepted
command receipt. Optional `mutation_operation_id` now requires a complete `expected_revisions` map.
The existing 0049 receipt table binds the actor/budget UUID to command kind, first target and a digest
of the full validated request (all selected IDs/order, action, values and observations). Receipt and
batch effects share one commit, including accepted no-ops. Identical retries acknowledge current
authorized rows without reapplying actions or reverting later values; changed/cross-kind reuse is
409. Current capability, per-row ownership and whole-resource scope are checked before receipt reads.
Later reconciliation does not invalidate acknowledgement of an accepted command, but still prevents
new mutations. Rows are locked in ID order. Receipt collisions roll back tentative batch effects
and re-enter the guarded acknowledgement path. Ordinary legacy requests remain compatible.

Nine new HTTP regressions cover all four actions, immutable retries, later-state/reconciliation,
identity reuse, revoked account/category/capability, missing observations and no-op receipts with
cross-kind reuse. Focused bulk/edit/card/financial-golden suites passed; `git diff --check` passed. Real concurrent
PostgreSQL overlap/lost-response proof remains outstanding; SQLite tests are not that proof.
No Swift changes or native rerun required. Server update/restart required; no new migration beyond
0049. Native bulk identity/durable queue integration remains unfinished. No data reset, merge, tag
or TestFlight publication.

## Durable ordinary transaction edits (2026-10-09)

Live ordinary editing now persists a separate mutation UUID, target transaction ID, exact draft and
captured server revision before any authenticated send. Creation and edits share insertion-order
command replay; edits use the canonical update endpoint/current credential binding, not creation.
Missing observations reject locally instead of silently disabling conflict protection. Definite
rejection retains the editor/draft and persists rejection review; uncertain connectivity retains the
queued edit. No optimistic posted amounts or ledger effects are synthesized. Pending Sync labels
edits and restricts details if the current workspace cannot authorize the target/proposed resources.
Older creation queue files remain decodable. Bulk/transfer/allocation/reconciliation queueing is
still incomplete; this does not close the hosted offline-write milestone.

Production host execution passed target/identity/revision persistence, timeout/reopen exact replay,
cross-target identity-reuse rejection and missing-observation rejection, plus prior queue safeguards.
Five backend identified-edit HTTP tests passed (one effect, later-edit preservation, stale rejection,
reconciliation protection and revoked authority). The focused Swift API edit-identity encoding test
passed. Regular Xcode 27 build-for-testing passed on the preserved iPhone 17 Pro Max/iOS 27
destination. Native compilation is not executed native runtime or human acceptance.
No new backend schema or server change; server must already include migration 0049 and command
receipts. App rebuild required. Human disconnected-edit/relaunch/reconnect acceptance remains open.
No human data reset, merge, tag or TestFlight publication.

Remaining Live acceptance: with a disposable ordinary posted transaction loaded, disconnect from
the server, edit its memo, save, and reopen the app. Confirm Pending Sync retains a labeled edit
without changing authoritative posted values. Reconnect; expect one accepted edit and an empty queue,
then confirm the memo persists after refresh. In a separate case, change the server transaction from
another authorized device before reconnecting: expect preserved server state and paused review,
not an overwrite. This is new offline-edit acceptance, not repetition of accepted quick clearing.

## Persisted rejection review for transaction sync (2026-10-09)

Definitive creation rejections previously remained saved but were retried by every refresh. The
queue now atomically persists an optional review flag for HTTP 400/403/404/409/422, without storing
server error text or changing the immutable transaction payload/identity. Automatic replay stops
before a paused item and preserves ordering of later changes. Pending Sync shows the paused state
and a separate explicit per-item retry, guarded by existing current whole-resource visibility.
Retry durably clears the flag; subsequent requests still use current credentials and server authority.
401/session failures, transport failures and retryable server failures do not become permanent
transaction rejection flags. Older queues decode without the optional flag; no data migration/reset.

Production host checks passed for pause persistence after reopening, zero sends on automatic retry,
later-operation blocking, and explicit exact-payload retry in insertion order. Existing scope,
legacy adoption, uncertain-send durability and failed-write checks also passed. Regular Xcode 27
build-for-testing passed on the preserved iPhone 17 Pro Max/iOS 27 destination; native runtime
acceptance is not claimed. Backend unchanged; no server restart required.
App rebuild required. TestFlight remains on hold. Durable edit/bulk submission remains unfinished.

## Import review excludes impossible amount matches (2026-10-09)

Statement review loaded every authorized posting in the date span before applying the matching
limit. Unrelated amounts could therefore make a small statement fail with “Narrow the import
review date range,” even though neither exact nor possible matching could use those transactions.
The production adapter now passes the bounded set of exact signed candidate amounts into the
authorized SQL observation query. Amount filtering happens before retrieval/limit; dates, account,
posted state, whole-resource visibility and alias privacy still apply. General helper callers that
omit amounts retain their previous behavior. The actual matching cap is unchanged, not bypassed.

An actual HTTP 10,000-unrelated-posting regression failed before correction. It uses a reduced
100-observation cap to exercise the production rejection branch efficiently, rather than claiming
a default-cap 50,001-row benchmark. After correction it stages with no false duplicate suggestions.
A relevant over-cap history still returns 422, leaves no failed staging batch, and posts no money.
Restricted amount-filtered observations remain scoped and expose no private aliases.

All 24 focused import routes/review/matching/staging tests passed; diff checks passed. No Swift or
native rerun, schema migration, customer-data reset or TestFlight publication. Server update/restart
required; no app rebuild for this checkpoint. Broad-span matching with many genuinely relevant
observations can still hit the explicit cap; this is not a claim of unlimited import history.

## Searchable focused statement review (2026-10-09)

Statement review previously required scrolling every recognized row without a way to find a payee,
memo or date or isolate potential duplicates. The shared Live/Local Device/Demo production flow
now provides native search plus All, Selected, Skipped and Duplicates focus modes. Search is
case/diacritic-aware, whitespace-trimmed and limited to existing authorized staged observations.
It never creates payees, changes choices or approves rows. The view computes its filtered set once
per render and shows matching/total counts, clear whole-batch posting wording and a reset action
for no matches. Search appears only after staging, not in format/column setup.

Posting still submits every staged candidate with its retained post/skip/category decision, including
rows hidden by the current search. Current resource/authority boundaries and staging limits remain
unchanged. This is UI navigation over the existing bounded 10,000-row payload, not server pagination
or durable draft-decision storage; neither is implied by the new controls.

Nine direct host Swift checks executed the actual production predicate, covering focus combinations,
accent/case/whitespace, memo/date and no-match behavior. Native tests add equivalent predicate cases
and a production-source assertion that filtered rendering still uses complete-batch approval.
Final regular Xcode 27.0 build-for-testing passed on the preserved iPhone 17 Pro Max destination;
native cases compiled, not executed. Diff checks passed.
Native runtime and human visual acceptance remain unverified. App rebuild required; no server
restart, migration, Simulator reset or customer-data change. TestFlight remains held.

## Bounded transaction-list editor attribution (2026-10-09)

The transaction response helper described itself as bounded but hydrated every edit-history entity
and its snapshots for each displayed transaction, then discarded all except the latest. An actual
HTTP list regression with 10,000 edits on one transaction reproduced 10,000 ORM history loads.

The helper now ranks eligible editor observations in SQL by existing timestamp/ID ordering and
returns only transaction ID, actor ID and timestamp for the latest row per displayed transaction.
No historical before/after snapshot is selected or hydrated. Existing action eligibility, returned
transaction order, creator attribution and current authorized-transaction scope remain unchanged.
Database work still depends on history size; this bounds returned data/application hydration rather
than claiming constant-time queries or fixing whole-workspace transaction hydration.

Verification: 40 focused provenance/browser/history/bulk/delegated-access tests passed. The enhanced
scale regression also passed independently and instruments the real HTTP request: exactly one
scalar attribution row returned, zero history entities hydrated, correct editor/time, and a newer
non-editor observation excluded. Diff checks passed. No Swift changes or native test rerun; no
migration, app rebuild, history rewrite or customer-data change. Server update/restart required.
This is a focused performance checkpoint, not release-wide acceptance. TestFlight remains held.

## Transfer metadata preserves original payment observations (2026-10-09)

Following the card-purchase correction, an actual HTTP regression proved unchanged and metadata-only
card-payment transfer saves replaced the original reserve-event identity and manufactured two
`updated` decisions. Unlike the purchase regression, the reproduced transfer balances stayed correct;
the defect is unnecessary observation replacement and false edit attribution, not a demonstrated
payment-balance change.

Transfer updates now retain payment reserve events when source/destination accounts, amount and
date are unchanged. Memo and clearing changes still update both legs and record actual decisions;
unchanged saves append none. Genuine financial edits still rebuild through the existing payment
engine. Existing row locks, account validation, ownership, resource authorization and reconciliation
protections run before this distinction. Local Device/Demo already performs exact net transfer
deltas, and its persisted transaction audit skips unchanged snapshots; no Swift change was needed.

The new production HTTP case failed on reserve identity before correction. After correction, 55
focused card, advanced-ledger and financial golden-vector tests passed, including the existing
payment amount/date edit and deletion lifecycle. Diff checks passed. No native rerun was necessary
for this server-only change; the previous regular Xcode 27 compile evidence is unchanged, not new
runtime evidence. Server deployment/restart required; no migration or app rebuild for this checkpoint.
No historical records were rewritten and no customer/Simulator data was touched. TestFlight remains held.

## Metadata-only transaction edits preserve payment money (2026-10-09)

Actual production HTTP reproduction proved that an unchanged resave or metadata-only edit to the
first of two same-day card purchases deleted its original $100 funded-purchase reserve and
recomputed it as $0 against the later spending. This changed payment Available without an amount,
account, category or date change. Both unchanged and changed-metadata cases failed before the fix.

Hosted updates now rebuild reserve events only when account, category, signed amount, date,
financial classification or split financial attribution changes. Memo, payee, tags, flag, clearing,
attachment metadata and split-memo edits preserve the original reserve observation. Unchanged
saves append no transaction decision; real metadata changes remain attributed. Split metadata
updates preserve existing split identities. Authorization, target-resource validation and reconciled
immutability still precede mutation; financial edits retain their existing recomputation path.
Local Device/Demo likewise updates metadata and checked cleared totals without reversing/reposting
the purchase or replacing its original creator and transaction identity.

Verification: 69 focused backend credit-card, transaction history, bulk, advanced ledger, provenance
and golden-vector cases passed. Four new HTTP cases cover direct/split purchases with unchanged
or edited memo/tags/flag/clearing; reserve identities, attribution, monthly observations and split
identities remain intact. An existing advanced-ledger exact-response assertion was brought up to
date with the previously introduced optional `through_date: null` balance contract. Regular Xcode
27.0 build-for-testing passed using the preserved iPhone 17 Pro Max destination. The new native
Local/Demo equivalent compiled but was not executed; no runtime or human acceptance is claimed.
Diff checks passed. This focused run is not a full backend/native-suite claim.

App rebuild and server update/restart required; no migration, historical reserve rewrite or data
reset. Previously affected customer observations are not silently repaired. Optional human retest
on disposable records: fund $100, make two $100 card purchases on the same day, edit the first
purchase's memo/tag, and confirm payment Available stays $100 while history records the metadata
change. Saving unchanged should add no history. TestFlight remains held.

## Truthful bulk metadata history and tag capacity (2026-10-09)

Actual HTTP regressions reproduced two canonical bulk-operation defects: unchanged clearing,
flag, add-tag and remove-tag requests appended misleading `bulk_updated` history, and combined
tag lists over 20 silently discarded requested tags. Five regression cases failed against the
previous implementation before correction.

Bulk updates now compare exact transaction snapshots and append history only for real changes.
All existing authorization, resource, reconciled and system-linked checks still run before no-op
detection. Existing history is not rewritten. Tag additions preflight every selected transaction
after authorization and reject the entire batch with 422 if any resulting list exceeds 20;
existing tags retain order, and adding an already-present tag to a full list remains a valid no-op.
Local Device/Demo uses equivalent bounded, normalized, ordered tag validation before mutation.
No financial amounts or accounting rules change; this does not enable hosted offline edits.

Executed verification: 23 backend bulk/history/provenance/browser tests passed, including six
new regression cases (four parameterized no-op actions, atomic overflow, mixed no-op/boundary).
Four existing Swift bulk DTO, single quick-clear request and local audit tests passed. Regular
Xcode 27.0 (27A266a) build-for-testing passed on preserved iPhone 17 Pro Max destination
`3ABD861E-D38D-4AFD-A356-959266051564`. The new native Local/Demo tag lifecycle case compiled,
but was not executed; compilation is not runtime acceptance. Diff checks passed.

App rebuild and server deployment/restart required to receive both corrections; no migration,
customer-data deletion, Simulator reset, release, tag or TestFlight upload. Optional next human
spot-check: repeat an unchanged bulk metadata action and confirm no new Edited history; use
disposable test transactions for a 20-tag overflow attempt and confirm an error with neither row
changed. Previously accepted ordinary quick-clearing does not require a full repeated acceptance.

## Pending Sync current-scope privacy (2026-10-09)

Pending Sync previously exposed raw retained outbox entries regardless of the current workspace
capabilities and resource scope. A transaction queued before revocation could continue exposing its
payee, date and amount after its account or one split category became inaccessible. Queue detail
projection now requires current workspace access, `view_transactions`, the account and every direct
or split category. Mixed-scope entries are hidden whole, not misleadingly partially redacted.

The original queue bytes and operation identities are preserved. Hidden pending entries produce
a neutral access/reconnect state instead of incorrectly saying everything synchronized. Retry stays
available and uses the unchanged canonical replay/server authorization. Discard rechecks current
visible-entry membership and workspace access; authority changes dismiss stale confirmation state.
Destination adoption remains an explicit local binding, never an authorization grant.

The actual production outbox/visibility host harness verifies capability, account and whole-split
scope rejection plus byte preservation, alongside the prior adoption/replay/recovery regressions.
Native coverage adds whole-resource scope cases. Regular Xcode 27 build-for-testing passed on the
preserved iPhone 17 Pro Max / iOS 27 destination. Native cases were compiled, not executed; source
wiring and host checks do not establish rendered runtime acceptance. Diff checks passed. App
rebuild required; no server change, migration or customer-data deletion.

**Confirmed remaining offline write gap:** hosted new-transaction creation is durable/idempotent,
but transaction edits, quick clearing, allocations, reconciliation, transfers and authority changes
remain online-only. They must not be blindly queued against potentially stale server observations.
Broader hosted offline editing requires an explicit optimistic-conflict and replay-safe mutation
contract before application-service/outbox integration. Local Device remains locally writable;
this privacy checkpoint does not fulfill all hosted offline-update requirements. TestFlight is held.

## Full-range signed money editing and presentation (2026-10-09)

The split checkpoint's separate signed-magnitude gap is corrected. Transaction and schedule
editor buffers used `abs(Int64)`, which traps for a valid Int64.min expense. They now render
unsigned magnitude through Decimal and apply expense/income direction before checking signed
minor-unit bounds. Creation, editing and expense splits share that parser; income/transfer values
still cannot exceed Int64.max, negative magnitude input remains invalid, and the amount field's
validation follows the same direction-aware range. No financial storage uses Double.

Home attention sorting now compares UInt64 magnitudes, and Home/Plan attention, debt change and
payoff comparison presentation use an exact magnitude formatter honoring Hide Amounts. Existing
labels retain increase/decrease or overspent meaning without signed absolute-value traps.
This is not a claim that every arithmetic operation throughout the product is overflow-safe.

The executable production CurrencyText harness passes minimum/maximum editable round trips in
USD, JPY and KWD, exact minimum-magnitude display, invalid sign/precision, expression parsing,
and the prior split-overflow cases. Source wiring checks cover creation/edit/schedule paths and
reject reintroduced unchecked monetary abs at these sites. Native tests add equivalent cases and
workspace Hide Amounts coverage. Final regular Xcode 27.0 (27A266a) build-for-testing passed on
the preserved iPhone 17 Pro Max / iOS 27 destination after an unintended allowance-parser edit
was removed. Request and allowance rules remain unchanged. Native cases were compiled, not
executed; the executed host regression does not prove rendered UI/runtime acceptance.

App rebuild required; no server change or migration. Human financial records and Simulator data
remain untouched, and TestFlight remains on hold. Normal human spot-check can use an existing
transaction/schedule: open, verify unchanged amount, cancel, then perform an ordinary small edit.
Do not create extreme-value customer postings merely to exercise an automated boundary case.

## Split-entry arithmetic validation (2026-10-09)

Production transaction creation and editing summed split amounts with unchecked Int64 arithmetic.
Individually valid large portions could overflow their sum, and subtracting the sum from an inflow
could overflow the remaining amount. Both paths now share checked sum/remainder helpers; unsupported
results return validation failure, disable Save, and show a correction message rather than trapping.
Valid totals and minor-unit precision are unchanged; no operation is sent for invalid splits.

`scripts/verify-split-input-arithmetic.sh` executes the actual CurrencyText implementation and checks
production creation/edit wiring. Valid balanced/unbalanced amounts, Int64 endpoint sums, positive
and negative overflow, subtraction overflow and exact money beyond Double precision pass. Added
native XCTest covers the same boundary cases. Regular Xcode 27 build-for-testing passed for app
and native-test targets on the preserved iPhone 17 Pro Max / iOS 27 destination. Native cases were
compiled, not executed; host checks are not rendered UI or network acceptance.

App rebuild required; no server restart, migration or customer-data change. TestFlight is held.
At that checkpoint, signed-magnitude editor/report paths remained open; the full-range signed
money checkpoint above supersedes that finding without expanding the split-aggregation claim.

## Net Worth history hydration bound (2026-10-09)

Net Worth retained every historical transaction entity and rescanned that list for each account.
The production route now consumes ordered scalar postings in 500-row batches, accumulating exact
per-account balances once. Monthly snapshots preserve the existing cumulative cutoff semantics;
optional account/series drill-through retains an ordered unique prefix of 500 IDs plus one
truncation sentinel rather than all historical IDs. Account authorization, tracking inclusion,
transfer/liability/reversal observations and the response contract remain unchanged.

Two disposable HTTP fixtures cover 10,000 postings with and without drill-through: exact monthly
totals are 4,000 then 10,000 minor units, final account balance is 10,000, and peak resident ORM
objects is three. The bound is an entity-hydration regression, not proof of production PostgreSQL
performance or constant total memory across arbitrary account/month cardinality. All 70 analytics
and report-scale cases passed, including existing privacy, reconciliation, void/reversal, transfer,
tracking, empty-state and calendar-boundary coverage. Diff checks passed.

Server deployment/restart is required to use this improvement; no migration or app rebuild.
No customer database, Simulator or attachment data was touched. TestFlight remains on hold.

## Spending-report object hydration bound (2026-10-09)

Income vs Spending follow-up: the repeated-pass path measured 30,002 resident ORM objects for
10,000 transactions/20,000 splits. It now consumes the same bounded iterator once and feeds the
existing canonical classification into exact total/month accumulators. The fixture peaks at 2,002
objects with unchanged 30,000 minor-unit spending and -30,000 net cash flow; total/month ID prefixes
and truncation stay bounded. Calendar partial periods, refunds, income, transfers and tracking
semantics remain covered by the existing HTTP analytics regressions. No separate financial formula,
API shape, Swift change or migration was introduced. Older notes below describing Income as
materialized are historical and superseded by this checkpoint.
The focused analytics, delegated privacy and scale run passed 84 cases, zero failures; diff checks
passed. Server update/restart only; no redundant native build, data reset or TestFlight publication.

Follow-up: Breakdown category IDs and Trends series/month IDs now accumulate an ordered unique
prefix of at most 501 identities: 500 returned plus one sentinel proving truncation. Duplicate
split portions retain first-seen ordering and cannot falsely mark a page truncated. Aggregation
continues across the entire authorized history; only explainability identifiers are bounded.
The 10,000-transaction HTTP fixtures assert the existing 500-ID/truncated contract in both reports
and trend points. A separate accumulator regression proves exact-prefix/deduplication behavior and
the internal bound after 10,000 inputs. This closes ID-list growth, not category/period cardinality
or every remaining report's memory use. No schema/native/customer-data changes.
The combined analytics and scale suite passed 67 cases, zero failures, with diff checks green.
This server-only follow-up requires an update/restart but no migration or app rebuild.

Disposable HTTP scale fixtures with 10,000 transactions and 20,000 split rows measured 30,006
resident ORM objects in both Spending Breakdown and Spending Trends. These single-pass consumers
now request a filtered iterator backed by 500-row transaction batches with select-in split loading.
The same fixtures peak at 2,004 objects, retain the exact selected-category total of 10,000 minor
units, and enforce a machine-independent object-count regression below 3,000.

Capability/resource validation completes before iteration; the existing whole-split visibility and
report filters remain unchanged. Income's repeated-pass consumer still receives a materialized list.
This is an ORM hydration improvement, not a claim of constant total memory: report dimensions and
contributing-ID collections remain accumulated, and PostgreSQL production scale remains unverified.
No native, schema, financial mutation or customer-data change; server update/restart only.
TestFlight remains on hold.

### Durable-before-send transaction creation — 2026-10-09

The canonical Live creation repository now saves the immutable request and operation identity before
the first authenticated network attempt. Submission shares the existing ordered queue replay path;
acknowledgement is persisted before removing the in-memory item. A failed disk write prevents sending.
Uncertain sends and definite server rejections retain the exact intent; rejected items surface for
Pending Sync review without synthesizing posted ledger activity. Explicit persisted blocked states
and durable edit submission remain outstanding; this is not full offline mutation completion.

The production outbox host-execution checks passed: persisted intent visible inside the first sender,
exact large Int64 amount/metadata, timeout/reopen survival, ordered retry plus next submission,
acknowledgement removal, retained rejection, and no send after persistence failure. Source wiring
assertions bind these checks to the canonical repository submission and current-credential sender.
A matching native XCTest was added. Regular Xcode 27 build-for-testing passed against the preserved
iPhone 17 Pro Max/iOS 27 simulator, compiling production and test targets; native runtime tests were
not executed and human acceptance is outstanding. The previously stalled runner was not retried.
No backend change, migration, server restart, simulator reset or human-data modification is required.
App rebuild required. TestFlight remains on hold.

### Immutable creation request receipts — 2026-10-09

Actual HTTP regression first proved different-amount reuse of a creation UUID returned success.
Creation now atomically stores a versioned request digest and accepted transaction identity under
the actor/budget/UUID key. Matching original retries after later edits do not repost or revert edits;
changed-payload reuse rejects with 409. Deletion retains the receipt and later retries return neutral
404 instead of recreating the purchase. Current resource authorization is preserved in both normal
and uniqueness-collision return paths. Migration 0048 reserves existing identities with unknown
digests; legacy retries require review rather than fabricating original request evidence.

51 focused backend tests passed covering creation replay/privacy, transaction bulk, financial golden
vectors, migration graph constraints, 0017-to-head empty upgrade and populated 0047-to-0048 upgrade/
downgrade. The populated migration preserves every transaction column, including financial values.
A supplemental rejected-create/unknown-legacy-receipt test was added and checked separately.
No Swift changes or rebuild. Server migration/update/restart required; no customer database was
migrated or reset here. Real PostgreSQL concurrent overlap/lost-acknowledgement remain unverified.

Broader migration audit also found seven older populated-upgrade tests failing before reaching 0048:
0042 account-history backfill indexes owner membership by budget, but the historical fixtures have
household owner identity and no owner membership row. Adjacent 0043 uses the same assumption. These
pre-existing historical-upgrade gaps are NOT claimed green; they require a subsequent correction.
TestFlight remains on hold and overall offline-edit completion remains false.

### Historical owner attribution and migration closure — 2026-10-09

The preceding seven populated-upgrade failures are now corrected. Migrations 0042 and 0043 resolve
backfill attribution through budgets → households.owner_user_id, the stored canonical owner, rather
than relying on a separately mutable/missing membership role row. They do not grant membership,
change account/category data, or alter finances. Two new populated 0041-to-head tests verify missing
owner membership and a conflicting membership-role owner: both use the canonical household owner
and preserve account rows and memberships exactly. Already-stamped installations are not rewritten.

The cash-rollover migration test also incorrectly compared current-schema history IDs after explicitly
downgrading through the migrations that remove those tables. Its comparison now projects the initial
rows onto every surviving historical table/column; all old-schema rows and independent financial API
observations remain exact. New history IDs after backfill are not mistaken for old ledger mutations.

All 21 tests in allocation migrations, creation-receipt migration and cash-rollover migration pass,
including populated legacy upgrades/downgrades, unchanged financial observations, graph validation
and 0017-to-current-head. `git diff --check` passes. SQLite verification only: no PostgreSQL/hardware
upgrade is claimed. No Swift changes or rebuild. Server distribution must include the corrected
migration files; normal startup upgrades through 0048 when needed. No customer database was touched.
TestFlight remains on hold; durable offline editing/replay work continues.

### Identified ordinary transaction edit receipts — 2026-10-09

Optional `mutation_operation_id` UUIDs require an observed revision. Migration 0049 adds immutable
actor/budget command receipts containing kind, target identity and original validated request digest,
committed atomically with canonical edit effects. A same-command retry acknowledges current authorized
state without another audit event or financial effect, rather than failing against its own stale
observation. Later edits remain intact. A later reconciliation may be acknowledged but cannot be
mutated: a fresh command is still rejected. Different-payload UUID reuse rejects with 409. Rejected
stale/observation-less commands create no receipt. Authorization, ownership and current whole-resource
visibility precede acknowledgement. Tentative cross-resource uniqueness collisions roll back before
re-entering the same guarded acknowledgement path with the original, pre-payee-resolution request.

First focused batch: 59 tests passed covering edit receipts, bulk, credit cards and financial golden
vectors. Final batch: 27 tests passed covering expanded edit receipts (actual amount edit, exact retry,
later edit preservation, reconciliation acknowledgement vs immutable new edits, capability/account/
category revocation), creation replay, migration graph/populated upgrade/downgrade and receipt migration.
These batches overlap and are not a combined unique-test count. `git diff --check` passes. Server
migration/update/restart required; no Swift change or rebuild. No customer database was modified.

This checkpoint does NOT integrate native durable edit UUIDs/outbox replay, implement other command
receipts, prove real PostgreSQL concurrent requests, or complete offline editing. Native and provider
acceptance gates remain. TestFlight stays on hold; no merge or release tag.

### Native identified-edit contract and submission audit — 2026-10-09

RecordTransactionOperation and its canonical API translation now carry optional mutation_operation_id
separately from immutable creation client_operation_id. The focused Swift DTO test verifies the UUID,
exact minor-unit amount and omission of the creation identity. Regular Xcode 27 production app/native
test build-for-testing passed against the preserved iPhone simulator; runtime tests were not executed.
`git diff --check` passes. No server change in this checkpoint and no new customer-visible queue mode.

The existing creation repository was inspected: sendTransaction happens before enqueue and persistence
occurs only after a transient connectivity error. Termination while awaiting the initial request can
lose its replay identity. Durable-before-send submission remains an actual implementation gap, not
merely additional test coverage. Typed creation/edit persistence, current-scope visibility and explicit
blocked/review state must be implemented before claiming offline-edit closure. The edit UI does not
yet generate/persist this optional identity. TestFlight remains on hold; no data reset or release.
The focused analytics, delegated privacy and report-scale suite passed 82 cases, zero failures;
diff checks passed. No redundant native build was run for this server-only change.

## Split spending-filter correction (2026-10-09)

A production HTTP regression proved a category-filtered Spending Trends request counted other
portions of the same split: expected 6,000 minor units after refund, returned 9,000. Inspection
also confirmed group-filtered Spending Breakdown and Local Device/Demo report portions lacked
the corresponding selection guard. Parent-transaction matching alone does not select its portions.

Breakdown and Trends now intersect selected categories and groups at each canonical portion,
including refunds, for category/group/payee dimensions. Server routes share one selected-category
definition; Local Device/Demo uses the same intersection for both report projections. Whole-split
visibility authorization is unchanged, transfers remain excluded, and no transaction, allocation,
reserve, balance or income-report formula changes. Native regression covers the same mixed purchase,
refund and disjoint category/group selection fixture through the production Demo data source.

All 61 analytics tests passed; a further 42 delegated-privacy, shared financial-vector and report-scale
tests passed using disposable test databases. Native runtime acceptance remains unverified while
the existing runner is unavailable. TestFlight is held. Server update/restart and app rebuild are
required to use the correction; no migration or customer-data reset is required.
Regular Xcode 27 build-for-testing passed for the app and test targets after correcting omitted
memo fields in the new split fixture. The native parity case was compiled, not executed. Diff
checks passed; no repeated UI runner or broad redundant backend run was performed.

Human spot-check, when acceptance resumes: filter an existing cross-group split purchase/refund to
one category, then one group, in Spending & Income; Breakdown and Trends must count only the selected
portions. Do not create or reset customer test data merely for this check.

## Reconciliation observation foundation (2026-10-09)

Confirmed open scale/scope gap: the production reconciliation screen still derives its cutoff
estimate by subtracting later transactions from a downloaded workspace snapshot. The server
account-balance endpoint now accepts optional `through_date=YYYY-MM-DD`, aggregating cleared and
uncleared ledger postings through that date in SQL without downloading transaction history.
Absent date retains the original all-date contract. Existing account-balance capability, budget
visibility and resource authorization are unchanged. Last reconciled balance remains its stored
observation, not recalculated at the cutoff. No reconciliation mutation semantics changed.

The Swift API exposes the same optional date query and preserves exact Int64 decoding. Twenty-one
backend budgeting/privacy cases and the focused Swift contract case passed; new coverage proves
default compatibility, inclusive cutoff, empty period, invalid dates, unauthenticated and cross-budget
denial, unchanged account observations after reads, and a value beyond Double's exact integer range.

**Incomplete integration:** the shared account application service/repository and reconciliation UI
must next consume the server observation with date/scope generation guards and explicit stale-read
handling. This checkpoint is not user-capability completion or permission to reduce hydration.
Local Device/Demo must retain equivalent exact provider observations; submission must preserve the
observed balance rather than quietly refresh away a stale expectation. No human data was touched.
No migration is needed; server restart/deployment is needed to expose the new optional API behavior.
TestFlight remains on hold.

### Production reconciliation integration

The shared account application service and Live repository now request the bounded, authoritative
date-cutoff observation with the current session credential. Local Device/Demo share the same
provider-side cleared calculation as their reconciliation mutation, including explicit fixture
openings and checked Int64 arithmetic. The shared reconciliation screen no longer calculates
its estimate from downloaded workspace transaction rows. Selected-date requests are generation-
guarded; changing date immediately makes the former value unusable, and workspace revocation
discards it. Failed reads show a retry action rather than inventing a balance.

Submission forwards the exact displayed observation instead of quietly recomputing it from a
new workspace snapshot. Existing stale-balance rejection remains authoritative, including when
the user permits an adjustment. Recheck Cleared Balance is explicit; the screen does not silently
replace a reviewed value while a user decides. Save is disabled until a current-date observation
exists and while it is loading/saving. No hydration reduction or reconciliation accounting change.

Eight backend reconciliation/protection cases passed. Native regressions now cover provider reads
with an empty workspace transaction cache, expected-observation preservation/refusal and production
UI date/scope wiring. Their execution remains unverified while the Simulator runner is unavailable;
source assertions are not runtime evidence. Human acceptance remains open: change cutoff date,
confirm the observed cleared amount, then make a second-device cleared posting before submission;
the old observation must be rejected, followed by explicit recheck and normal reconciliation.
Use a disposable test account, not an unintended adjustment to human financial records.

Final integration verification: regular Xcode 27 build-for-testing passed for app/native test targets;
13 focused backend cutoff/privacy/reconciliation cases passed; the Swift API test proves exact large
money, cutoff echo, old-server rejection and legacy all-date decoding. Production source-wiring
assertions and diff checks passed. Native runtime execution and human interaction are not claimed.
The cutoff response now explicitly echoes `through_date`; the API refuses a dated observation from
an older server that silently ignores unknown query parameters, with clear upgrade/recheck guidance.
Rebuild the app and deploy/restart the updated server before this hosted acceptance flow; no migration.

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
Developer-console configuration was directly verified on 2026-10-09: ClearPocket Backup uses the
registered public key in both Debug/Release, Scoped App (App Folder) access, exact redirect URI
`clearpocket://dropbox-oauth`, public clients/PKCE allowed and the required file scopes enabled.
The remaining Dropbox gate is live acceptance: complete one real connect, backup, relaunch, restore
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

### Saved payoff-plan request validation parity — 2026-10-09

Local Device/Demo previously accepted malformed saved scenarios that the hosted Pydantic model
rejected. The shared typed request now validates supported strategies, nonnegative exact extra
payment, bounded/unique debt selections (at most 100), complete custom ordering, and valid ISO
target dates before local persistence or Live transport. Scope and authorization remain in the
existing application services/server. Invalid input neither replaces the saved plan nor normalizes
it into a different strategy; no network mutation is sent for a locally invalid request.

Verification: three focused Swift API tests pass, including valid leap day, zero/Int64 maximum,
duplicate/over-limit selections, incorrect strategy/order/date, and zero transport calls. Five
focused native tests pass on regular Xcode 27 / the preserved iPhone 17 Pro Max iOS 27 simulator,
covering rejection without changes to the previously saved scenario, accounts, transactions or
categories, alongside actor privacy, current capabilities and Local Device reopen/removal.
Four hosted payoff-plan tests pass; the new malformed-input matrix proves the Live saved scenario
also stays unchanged. The production app compiles in the native test build; `git diff --check`
passes. No server behavior/schema change, migration, user data reset or TestFlight upload.

### Dropbox publication commit-point correction — 2026-10-09

Audit found two post-commit failures could falsely report a verified encrypted upload as failed:
retention pruning in the destination, and listing the generations in the production coordinator.
The verified remote move is now an explicit commit point. Cleanup failure returns a successful
publication marked retention-cleanup-pending; the coordinator records success before listing and
preserves the known committed generation if listing fails. The backup screen shows a non-fatal
maintenance warning, not an upload error/retry prompt. Older-generation cleanup is attempted again
by the next backup. Genuine pre-publication upload/integrity errors still throw, retain the local
encrypted generation under the existing recovery workflow, and never mark a successful backup.

Verification: all seven Dropbox destination tests pass, including post-commit list failure with
verified ciphertext still available, exact download, normal pruning, bounded upload sessions,
integrity rejection and scoped deletion. The focused production coordinator native test passes on
regular Xcode 27 / the preserved iPhone 17 Pro Max iOS 27 simulator: success timestamp persistence,
non-fatal warning, exactly one list attempt, no duplicate known generation and warning reset on a
later successful completion. The native test build compiles the app; `git diff --check` passes.
Tests use deterministic transports, not the user's live Dropbox. No backend/schema changes,
migration, data reset or TestFlight upload. External Dropbox console confirmation and live-provider
acceptance remain open and are not inferred from this checkpoint.

### Dropbox interrupted-publication retry recovery — 2026-10-09

An ambiguous move response previously turned a committed backup into a permanent already-exists
failure on Retry. The destination now resolves the ambiguity only by comparing the complete remote
file set with the retained immutable package: every manifest/ciphertext path, exact size and Dropbox
content hash must match. A same-name generation with different, missing or extra files remains a
conflict and is never overwritten. Successful recovery removes only its temporary upload, returns
the original generation and defers retention cleanup with the established non-fatal warning. It
does not evict a newer generation to protect an older retried package.

All eight Dropbox destination tests pass. The new deterministic paginated-transport case commits a
move then loses its response, retries the identical package successfully, proves no duplicate final
generation or temporary upload remains, preserves a newer backup under retention one, and rejects
changed ciphertext while preserving the original remote bytes. Existing integrity, normal retention,
download, deletion and large-upload checks remain green. A regular Xcode 27 production Simulator
build verifies integration; this storage-only checkpoint does not rerun unrelated native/UI suites.
`git diff --check` passes. No live Dropbox account was changed; external provider acceptance remains
pending. No migration, server restart, user-data reset or TestFlight upload.

### Private saved payoff-plan history — 2026-10-09

Saved scenario creation, changes and reset retain immutable author-owned before/after observations.
Identical saves and repeated reset do not manufacture duplicate decisions. History reads enforce
current report/balance capabilities and account scope before returning bounded pages. Money remains
Int64 minor units; these planning observations never create transactions or change balances.
Hosted revision `0047_payoff_plan_history` and Local Device schema 23 backfill existing plans without
rewriting them. Complete export retains history; server-to-local transfer carries only the owner's
personal observations and rejects foreign-member scenarios. Local reconstruction, candidate staging
and encrypted backup/restore retain reset history. Demo uses the same author-scoped contract.

The shared Payoff screen links to Saved Plan History outside the edit-permission-disabled section.
Ten-row pages have readable dates, author attribution, expandable before/after settings, exact money,
selected account names, custom priority, rollover and goal date, plus empty/loading/retry states.

Verification: 22 backend migration/export/payoff tests, 20 local database tests, seven transfer
projection tests, eight strengthened backup/candidate tests, and two native provider/reconstruction
tests pass. The prior API checkpoint passed three focused Swift tests. Native verification used
regular `/Applications/Xcode.app` Xcode 27.0 (27A266a), preserved iPhone 17 Pro Max simulator
`3ABD861E-D38D-4AFD-A356-959266051564`, iOS 27.0 (24A5423a).
A production-composition UI regression was added, but its single execution stalled before launching
the app: process inspection found no UI runner and a screenshot showed the Simulator home screen.
That attempt was cancelled rather than repeatedly retried; it is NOT recorded as a passing UI test.
The final production Simulator build and `git diff --check` pass.
Human visual acceptance remains pending. No Simulator/Live reset, merge, tag or TestFlight upload.

Human retest after rebuilding: Insights → Debt & Interest → Payoff; change strategy/extra and wait
for the save indication; open Saved Plan History and expand the newest observation. Confirm exact
before/after values, then reset the saved plan and verify reset history survives app relaunch.
For hosted testing, update/restart the server through its normal migration-enabled startup first.

### Explainable target decisions and history privacy — 2026-10-09

The Target History summary previously omitted changes to recurrence and minimum contribution.
Authoritative snapshots already preserved them; the shared view now expands all seven target
settings as changed-field before/after observations. Removed optional settings show Not set,
creation/removal expose the recorded values, and month-specific snooze/resume shows the guidance
transition even when the underlying target snapshot is unchanged. This is presentation only.

The audit also found Debt Terms expanded currency text bypassed Hide Amounts. Both target and debt
history now redact present monetary values before rendering accessible text, while preserving
non-money assumptions, explicit unset values and the fact a money field changed. Exact Int64 money
is formatted without binary floating-point conversion. No server, migration or financial engine
changes are required. Human visual acceptance remains separate; the stalled XCUITest runner was
not retried for this checkpoint.

Human retest after rebuild: Plan → category → Target History; expand an edited target with changed
cadence/minimum and a snooze/resume observation. Enable Hide Amounts and inspect expanded Target
History and Debt Terms history: currency values must be masked; dates/rates/cadence remain readable.

Verification: three focused native XCTest cases pass on regular Xcode 27 and the preserved iPhone
17 Pro Max/iOS 27 Simulator. Coverage includes exact amounts beyond binary floating-point precision,
cadence/minimum/date changes, deletion, unchanged suppression, month-specific snooze/resume,
Hide Amounts redaction without losing changed-field labels, and production-store money neutrality.
The production iOS app compiles as part of that run; `git diff --check` passes. No unrelated full
suite or UI-runner retry was performed for this presentation-only checkpoint.

### Statement-import review privacy — 2026-10-09

Staged and completed statement-import review rows bypassed Hide Amounts by directly formatting
their monetary values. They now use the same workspace formatter as other production screens.
Selection, duplicate detection, category approval, posting and accounting are unchanged.

Two focused native XCTest cases passed using regular `/Applications/Xcode.app` Xcode 27 and the
preserved iPhone 17 Pro Max/iOS 27 Simulator: production review composition references the canonical
formatter, and positive/negative/zero values redact without changing transaction amounts. The
production app compiled in this run; `git diff --check` passed. No backend or migration changes.
Human visual acceptance remains pending: enable Hide Amounts, open statement-import review and
confirm candidate amounts are masked; disable it and confirm amounts return. Rebuild required;
no server restart required. TestFlight remains on hold.

### Automatic Dropbox interrupted-upload recovery — 2026-10-09

Previously, retaining a failed upload disabled all later automatic runs until the owner intervened.
When automatic backups are enabled, active-app delivery now retries that same encrypted generation
after a persisted 30-minute cooldown. It does not capture another snapshot while one is pending.
Explicit retry remains available, failures restart the cooldown, disabling automatic backup prevents
automatic retry, and overlapping activation is still protected by the single-run claim. No guarantee
of execution while iOS suspends the app is made. Successful cleanup uses the application service's
designated pending-directory check, not deletion of an arbitrary preferences-recovered path.

The existing immutable verified publication path, content-hash conflict protection, recovery key,
authorization and retention contract are unchanged. Live Dropbox acceptance is still outstanding.
Human retest: enable automatic backups; interrupt an upload; restore connectivity; reopen
the app after the cooldown and confirm the retained generation publishes without another snapshot.
Manual Retry Pending Upload remains the immediate alternative. Rebuild required; no server restart
or migration required. TestFlight remains on hold.

Verification: the strengthened native scheduling/reconstruction test passes with regular Xcode 27
on the preserved iPhone 17 Pro Max/iOS 27 Simulator, and the production app compiles. Eight shared
Dropbox destination tests pass, covering encrypted exact download, bounded upload, failed integrity,
publication recovery/conflicts, retention failure and selected deletion. Source-composition assertions
check pending-package reuse and guarded cleanup; these are not a live-provider end-to-end acceptance
claim. `git diff --check` passes. No backend changes or unrelated full-suite reruns.

### Explainable schedule decisions — 2026-10-09

Immutable schedule snapshots were already durable across providers, but the shared history screen
displayed only the latest name, amount and cadence. Native expandable Decision details now expose
changed names, authorized resources, exact amount, next date, recurrence/interval, end date,
remaining entries, memo, classification, active/paused state and last realization date. Creation
and deletion retain explicit Not set boundaries. Changed resource identities are detected even
when display names match; unavailable resources receive neutral labels rather than raw identifiers.
Money changes remain visible as changes when Hide Amounts masks both values. No accounting is
recomputed and no schedule or posted transaction is mutated by this view.

Older-history requests remain bounded and guarded against overlapping loads; the Load More action
disappears after a short/final page. Failed requests preserve already loaded observations.
Human retest after rebuild: Scheduled Transactions → Schedule History; expand an edit, pause,
deletion and Enter Now decision. Confirm dates/limits/status advancement, toggle Hide Amounts,
and load older history through the final page. No server restart or migration is required.
Human visual acceptance remains pending; no TestFlight publication is authorized.

Verification: two focused native tests pass on regular Xcode 27 and the preserved iPhone 17 Pro
Max/iOS 27 Simulator: changed-field presentation covers exact negative values beyond binary
floating-point precision, identical resource display names, removed end dates, occurrence limits,
realization, pause, deletion, no-op suppression and amount privacy; the existing production schedule
composition/store contract remains green. The production app compiles. All 20 backend schedule
contract tests pass; `git diff --check` passes. Two initial compile attempts exposed a SwiftUI
type-checking limit and an incorrect payee display-property reference; both are corrected in the
final green build. No claim of human visual acceptance or a passing UI automation run is made.

### Explainable household authority and bounded account history — 2026-10-09

Authority History's previous rule-count summary could not explain which category rule, limit or
permission changed. Expandable native details now show immutable before/after pool identity,
authority amount, category-creation/reallocation permissions and added/changed/removed category
rules with minimum/maximum limits. Names come from current authorized workspace resources;
unavailable categories receive neutral labels. Change detection precedes amount formatting so
Hide Amounts masks limits without concealing that they changed. No permission or money mutation
is performed by this presentation; the owner-only canonical history authorization remains intact.

Authority and Account History now determine continuation from the most recent page size, not the
total number of rows accumulated. Empty final pages stop continuation; overlapping older-page
requests are guarded. Account History also preserves loaded observations after an older-page error
and retries that page rather than discarding context. Human retest after rebuild: Household → member
authority → history; expand rule and permission changes with Hide Amounts on/off. For an account
with more than 25 metadata decisions, load to the end and confirm continuation disappears. No
server restart, migration, merge, tag or TestFlight upload is needed/authorized for this checkpoint.

Verification: three focused native XCTest cases pass using regular Xcode 27 and the preserved
iPhone 17 Pro Max/iOS 27 Simulator. They cover exact authority/rule explanations, added/removed
rules, permission changes, no-op suppression, amount redaction, existing canonical funding and
atomic rejection of stale/unauthorized edits. The production application compiles; the focused
backend exact/attributed/private/no-op-safe authority-history contract test passes. `git diff --check`
passes. Account-history pagination is source-reviewed and compiled; final-page and failure-retry
human interaction is not claimed as automated UI verification. Human visual acceptance is pending.

### Direct receipt camera assistance — 2026-10-09

New Transaction now offers Take Receipt Photo alongside Scan Receipt Photo. It reuses the native
camera bridge used by attachments, asks for camera permission only on request, and explains denied,
restricted or unavailable access with an existing-photo alternative. Captured JPEG data feeds the
same on-device Vision OCR and explicit suggestion review only after the camera sheet dismisses.
No image is written to Photos or uploaded/attached implicitly, and no transaction is posted until
the owner reviews the draft and presses canonical Save. Photo-library OCR waits until picker state
is closed and guards duplicate processing. Suggested categories now show their group-qualified
names rather than ambiguous category names alone.

Human retest after rebuild on iPhone: New Transaction → Take Receipt Photo, allow camera, capture
a receipt, review and apply suggestions, then Cancel once to confirm nothing posts. Repeat and Save
explicitly. Camera cancellation and permission denial must leave the draft intact and photo selection
available. Confirm same-named categories display their group in review. Actual camera capture cannot
be proven on the Simulator; real-device visual/lifecycle acceptance remains pending. No server restart
or migration is required. TestFlight stays on hold.

Verification: three focused native XCTest cases pass with regular Xcode 27 on the preserved iPhone
17 Pro Max/iOS 27 Simulator; the production app compiles. Tests cover existing exact OCR suggestions,
future-date rejection, and production source-composition assertions for shared camera capture,
permission handling, dismissal-driven review, qualified categories and absence of implicit posting,
upload or Photos writes. Source assertions are not end-to-end camera/modal runtime proof. No backend
changes or repetitive full-suite reruns; `git diff --check` passes.

### Receipt image-orientation correctness — 2026-10-09

Receipt OCR decoded a UIImage but discarded its rotation/mirroring metadata when passing raw
CGImage pixels into Vision. It now maps all eight UIImage orientations explicitly to Vision's
image orientation. This applies to both selected Photos images and newly captured receipt JPEGs;
the PDF statement page renderer remains separate and unchanged. Recognition still runs on-device
and only proposes unsaved fields through the existing review path. No financial parsing, posting,
attachment storage or authorization semantics change.

Human retest after rebuild: scan receipts captured in portrait and landscape and an existing rotated
Photos image; confirm recognizable payee/total suggestions appear and nothing posts before Save.
No server restart or migration is required. TestFlight remains on hold.

Verification: three focused native XCTest cases pass under regular Xcode 27 on the preserved iPhone
17 Pro Max/iOS 27 Simulator. All eight orientation mappings are asserted. An actual generated JPEG
with 180-degree rotated pixel data and matching EXIF orientation passes through production Vision
recognition and yields FRESH MARKET and exact 1,950 minor units; existing total/subtotal suggestion
parsing remains green. The production app compiles and `git diff --check` passes. Real-device camera
acceptance remains separate; no backend/full-suite rerun was needed.

### Conservative receipt category suggestions — 2026-10-09

Receipt suggestions previously chose the first category whose name occurred anywhere as a substring.
That could choose an arbitrary same-named category from another group or match Gas inside Vegas.
Suggestions now require one distinct active category identity matched as a whole phrase, with
case/diacritic and whitespace normalization. Multiple matching identities produce no category
suggestion and leave the owner's manual selection intact. Duplicate entries of the same identity
are harmless, archived categories are excluded, and only the already-authorized supplied category
list is considered. This affects unsaved guidance only, not posting or classification semantics.

Human retest after rebuild: scan a receipt mentioning a duplicate category name and confirm no group
is guessed; choose the group-qualified category manually. A receipt containing only one unambiguous
category phrase should still offer it. No server restart/migration is required; TestFlight stays on hold.

Verification: two focused native XCTest cases pass under regular Xcode 27 on the preserved iPhone
17 Pro Max/iOS 27 Simulator. Coverage includes substring false positives, duplicate names in either
ordering, multiple category phrases, archived/empty names, case/diacritic/whitespace normalization,
an empty authorized scope, repeated identical identities and existing exact-total suggestions.
The production app compiles; `git diff --check` passes. Human visual acceptance remains pending.

### Allowance plan history closure — 2026-10-09

Production Allowance Detail now offers bounded 25-row earlier-plan loading instead of silently
stopping at the default first 50 decisions. It guards overlapping requests, ends continuation after
a short/final page and retains loaded observations when a page fails. Expandable Funding rule details
explain changed recipient, source, exact amount, date/cadence, rollover, pause state and added/removed
destination splits. Change detection uses original values before redaction; names use current authorized
household/category data and qualified group names. Existing Issue Now and pause/reactivation remain
on the canonical application-service path. No money is synthesized by history presentation.

Human retest after rebuild: Household → allowance → Plan changes; expand a pause/issue decision,
toggle Hide Amounts, and load older plan changes through the final page. No server restart or migration.
Issuance history remains an explicitly open unpaged-contract scale gap in `V0.12-CLOSURE-AUDIT.md`;
this checkpoint does not declare the entire milestone complete or authorize TestFlight publication.

Verification: focused native changed-field coverage passes for exact large amounts, cadence/date,
pause, rollover, added/removed qualified splits, no-op suppression and Hide Amounts. The existing
production Demo allowance golden-vector test passes for atomic/versioned issuance, server-equivalent
rollover and restricted-member policy history denial, using the built app without recompilation.
All ten backend allowance contract tests pass; the production app compiles under regular Xcode 27
on the preserved iPhone 17 Pro Max/iOS 27 Simulator and `git diff --check` passes. Pagination is
source-reviewed/compiled, not claimed as an automated production UI interaction pass.

### Bounded allowance issuance history — 2026-10-09

The existing issuance endpoint now accepts optional `limit` (1–100) and nonnegative `offset`.
Omitting the limit preserves older clients' unpaged read contract. Budget/member/capability and
whole-plan resource authorization are checked before the SQL page is read. Ordering is deterministically
newest issued date, created timestamp and ID. The current iPhone loads 25-row pages, offers Load Earlier
Issuances, guards overlapping reads and stops at a short/final page; failures retain prior rows.
Demo follows the same ordering/paging after its existing authorization checks. Live still prepares
the canonical current credential on every request. Local Device personal budgets do not gain artificial
household issuances or a new allowance accounting engine.

Verification: all 11 backend allowance tests pass, including legacy/read-page equivalence for owner and
recipient, final empty page, invalid bounds, restricted-resource denial and unchanged financial summaries.
The strengthened native allowance golden vector passes for both rollover policies, exact issuance-page
equivalence, money neutrality of reads and restricted history access. Production app compilation passes
using regular Xcode 27 on the preserved iPhone 17 Pro Max/iOS 27 Simulator. Swift request coverage verifies
explicit bounds, unchanged legacy query behavior, current bearer credential and exactly one request per
read. An initial assertion expecting nil rather than the client's existing empty query string was corrected.
`git diff --check` passes. No full-suite loop or stalled UI-runner retry was performed.

Human retest after rebuild: open an allowance with older issuance/plan decisions and load both sections
to the end; confirm pages retain chronology and money does not move merely by viewing history.
Server restart is required to use the new bounds; no migration or data reset is required. An older server
may ignore unknown query parameters, so deploy the matching server before scale acceptance.
Human visual acceptance remains pending; TestFlight remains on hold.

### Complete category/group change explanation — 2026-10-09

The shared Category/Group History previously summarized only the first detected field, making
simultaneous decisions and moves/classification/delegation changes difficult to inspect. Expandable
Change details now show every changed authoritative metadata field with before/after values, including
removed notes/symbols/delegation. Group/member names resolve only from current authorized workspace
data; missing identities receive neutral labels, never raw IDs. Comparison precedes label resolution,
so two unavailable identities cannot silently conceal a move. The disclosure remains independently
accessible and history reads reject overlapping requests. No endpoint, migration, ledger or financial
semantics change.

Focused native regression checks all nine simultaneous fields, creation, unset values, no-op snapshots
and unavailable-identity redaction passes, including the final accessibility correction. Production
app compilation passes using regular Xcode 27.0 (27A266a) on the preserved iPhone 17 Pro Max/iOS 27
Simulator. The existing backend category/group attributed/bounded/no-op-safe history contract passes.
`git diff --check` passes. These tests do not substitute for human VoiceOver or visual acceptance.
Human retest after rebuilding: open Category or Group History, expand Change details for an existing
multi-field decision and inspect the before/after observations, including VoiceOver disclosure access.
No server restart or migration is required. Human visual/accessibility acceptance remains pending;
TestFlight remains on hold.

### Complete payee decision explanation — 2026-10-09

Payee History previously explained only the first name/category/alias observation, omitted archive
and merge-target detail and displayed only one changed alias. The shared production history now
expands all returned changes: name, archive state, merge destination, qualified category suggestion,
and all added/removed aliases with stable ordering. Resource identity comparisons precede authorized
label resolution, so same-label/unavailable resources cannot conceal an identity change. Missing
payees/categories receive neutral labels, not raw IDs or an unbounded directory request. Redacted
snapshots do not invent aliases or private fields. VoiceOver retains access to the disclosure and
overlapping history reads are guarded. No payee mutation, normalization, merge, accounting or server
contract changes.

All 12 backend payee tests pass, including immutable/bounded attributed history, no-op suppression,
free-text identity creation, restricted history alias redaction and scoped search privacy. A focused
native regression covers multi-field edits, all four alias differences, qualified suggestions,
unavailable merge targets, creation, unchanged and privacy-redacted snapshots and passes. Production
app compilation passes using regular Xcode 27.0 (27A266a) on the preserved iPhone 17 Pro Max/iOS 27
Simulator; `git diff --check` passes. These tests are not human visual or VoiceOver acceptance.
Human retest after rebuilding: inspect an existing rename,
alias or merge in Payee History and expand Payee decision details. No server restart or migration
is required. Human visual acceptance remains pending; TestFlight remains on hold.

### Dropbox automatic pre-capture retry safety — 2026-10-09

Audit of the real automatic workspace path found that only failures with an already-created encrypted
generation received a retry cooldown. A credential/disconnection or capture failure without a package
could therefore be attempted again on each scene activation. The coordinator now persists a separate
automatic-attempt cooldown on completion unless verified publication succeeded during that attempt.
The existing 30-minute retry interval also covers pre-capture failures, survives relaunch, and contributes
to the displayed Next due time. Retained-package retry still reuses the immutable encrypted generation;
manual Back Up Now remains available and verified success clears the automatic cooldown. No token,
encryption, remote retention or restore contract changes; no backup file is removed by this state change.

Focused native coverage checks pre-capture failure without inventing a package, repeated activation,
relaunch persistence, cooldown expiry, verified-success reset and the existing retained-generation
schedule/overlap contract. Both native tests and production app compilation pass using regular Xcode
27.0 (27A266a) on the preserved iPhone 17 Pro Max/iOS 27 Simulator; `git diff --check` passes.
No live Dropbox authorization or customer backup was changed. One permission-review timeout occurred before the test process started;
the permitted single retry started the focused native run. External Dropbox connect/backup/restore/revoke
acceptance remains open. No server restart or migration is needed; TestFlight remains on hold.

### History recovery/export verification — 2026-10-09

Expanded the real encrypted backup fixture to populate seven newer history families and compare the
entire source authority snapshot with its restored copy, not just money and attachment metadata.
Account/category decisions, payee merge history, deleted target and debt-term observations, schedule
realization transaction IDs and reset payoff history retain original attribution/timestamps and exact
large integer money. Authenticated attachment content verification remains in place. Low-level fixture
inserts do not create application-service history, so explicit records ensure nonempty coverage.

The export contract plus nine populated history migration suites pass together (24 backend tests).
Older target/schedule fixtures now include the owner membership required by a valid household and
later backfill migrations; their exact-money vectors use odd values beyond Double precision and both
focused final migrations pass. No production migration or accounting code changed. Four encrypted
backup tests exercise restoration, wrong-key/tampered data, path mismatch and no overwrite. This
checkpoint changes tests/documentation only; no app rebuild, server restart or migration is needed.
SQLite/native evidence does not claim PostgreSQL/QNAP or real Dropbox human acceptance.

### Fail-closed history transfer and overflow validation — 2026-10-09

The typed server-to-phone transfer decoder previously omitted account/structure/target/schedule/debt
history from its mixed-budget guard and validated duplicate IDs for only a subset of histories.
It now checks every decision-history family, rejects duplicate history IDs and refuses another
member's decision attribution instead of attempting to flatten it into the single-owner authority.
Existing private payoff ownership validation remains. All financial observation accumulation uses
checked Int64 addition/subtraction and throws a clear snapshot error on overflow, including
Int64.min subtraction; malformed input cannot trap before staging validation. No money is normalized,
rounded or changed to Double, and older projections with absent history sections remain valid.

All nine Swift transfer-projection tests pass, covering valid/legacy reads, each of seven history
families with wrong-budget/duplicate/foreign-actor mutations, and transaction/allocation/reserve
overflow. Both native production transfer regressions pass for current credentials and rejection of
a concurrently changed authority, with production app compilation on regular Xcode 27.0 (27A266a)
and the preserved iPhone 17 Pro Max/iOS 27 Simulator. `git diff --check` passes. Server behavior and deployed
database schema are unchanged. Rebuild is required for the strengthened native decoder; no server
restart, migration or customer transfer/reset is required. TestFlight remains on hold.

### Dropbox developer-console gate verified — 2026-10-09

Direct authenticated read-only inspection of ClearPocket Backup in Dropbox's developer console
verified app key `961plkfyok8kf8z`, Scoped App (App Folder) access, folder name ClearPocket Backup,
exact registered redirect `clearpocket://dropbox-oauth`, and public clients (PKCE) allowed. Permissions
show files.content.read/write and files.metadata.read/write enabled, matching the four scopes explicitly
requested by the native OAuth configuration. The console also has mandatory account_info.read enabled;
the native request does not ask for it. Account-info write, sharing, file-request, contact and OpenID
scopes were unchecked. No settings, permissions or credentials were changed; app secret stayed hidden
and no generated access token was requested.

The app remains in Development with 0/500 linked development users at inspection time. Production
approval remains a separate distribution gate; do not infer it from correct native configuration.
The console setup gate is now VERIFIED rather than asking the owner to register it again. No native
test run is needed for this documentation-only evidence checkpoint.

Minimized remaining live acceptance: on an explicitly disposable local test authority, use Backup &
Recovery to connect with normal Dropbox consent; retain the recovery key separately, publish one
encrypted generation, relaunch and confirm the generation/key remain usable. Download/verify it and
restore only into a new empty test destination, never over the human's current budget. Finally revoke
the connection and verify later provider access requires reconnection while Local Files recovery stays
available. Scope consent and any real-data upload require the owner's informed action/approval. Do not
use a development-console generated token as a shortcut. This walkthrough has NOT been performed or
human accepted. No software rebuild, migration or server restart is needed for the console evidence;
use a current development build when conducting the remaining live workflow. TestFlight remains on hold.

### Hosted edit precondition foundation — 2026-10-09

Actual HTTP regressions first reproduced stale ordinary and bulk edits succeeding against changed
transactions. Optional authorized content preconditions now reject these requests with 409 before
mutation; a stale member of a bulk selection rejects the whole batch. Fresh ordinary preconditions
succeed. Strict format/identity-set validation rejects malformed or incomplete bulk observations.
Ordinary edits also preserve immutable creation retry identity rather than overwriting it with the
update DTO's default null or a replacement UUID. Native integration and durable edit replay are NOT
implemented by this checkpoint; identical-content ABA and immutable replay receipts remain distinct
requirements, as documented in DATA-OWNERSHIP.md.

70 focused backend tests pass across transaction bulk, credit cards, browser, history, provenance
and financial golden vectors. Existing no-op comparisons remain exact; clearing metadata comparisons
exclude only clearing state and its necessarily changed derived revision. `git diff --check` passes.
No Swift or migration changes: no app rebuild/native rerun required; deploying server changes requires
a server update/restart. No customer data was changed. Regular Xcode 27.0 (27A266a) at
`/Applications/Xcode.app/Contents/Developer` is confirmed and replaces Beta for future native operations.
TestFlight remains on hold; no human acceptance or real PostgreSQL concurrency proof is claimed.

### Native observed transaction edits — 2026-10-09

APITransaction now decodes and caches the server's optional revision. The production transaction
editor captures that original observation in State alongside its draft and forwards it through the
canonical operation/service/API request; a background view refresh cannot silently substitute a
new revision for an old draft. Save conflicts retain the editor and draft and use existing error
presentation. Quick clearing includes the current transaction revision while still omitting all
unrelated metadata. Local/Demo and older server payloads without revisions remain compatible.
Multi-selection bulk observation capture and durable offline edit replay are not complete yet.

90 Swift API tests passed, then the additional actual PUT/409 regression passed independently:
original revision and draft sent, exactly one request, no conflict retry. Encoding/decoding tests
cover preconditions, exact Int64 input, absence of unrelated clearing fields and legacy omission.
Native adapter coverage was added and compiled, not executed. Regular Xcode 27 build-for-testing
passed against existing iPhone 17 Pro Max `3ABD861E-D38D-4AFD-A356-959266051564`/iOS 27.0.
The known stalled native runtime runner was not retried or reset. `git diff --check` passes.
Rebuild required for native integration; server must include the preceding precondition checkpoint.
No migration or customer-data reset. TestFlight remains on hold.

Remaining targeted human check (disposable transaction, two authorized devices): open its editor
on device A, change a metadata field on device B and save, then attempt A's stale save. Expect a
changed-transaction message with A's draft still open and B's server value preserved. Cancel and
reopen from a refreshed observation, then save successfully. This is not yet human accepted.

### Activity bulk observation capture — 2026-10-09

Activity uses a reusable bounded selection model retaining only transaction IDs and observed
revisions, never full transaction metadata. Selection-time observations survive page loads and
background refresh. All four existing bulk actions use deterministic sorted IDs and the complete
captured map; a conflict leaves selection intact rather than silently renewing it. Deselect/reselect
explicitly captures a fresh observation. Done, successful save and access-revocation discard the
selection. At most 200 entries can be selected; the 201st is rejected without losing prior intent.
All-legacy/local selection is compatible; mixed revision-bearing/legacy selection requires review.

Three focused selection tests passed (all four actions, deterministic ordering, explicit reselection,
legacy/mixed handling, the 200 limit and deselection at that limit). The actual bulk HTTP contract
test passed with the selection-produced revision map and unchanged tag payload. The server's preceding
stale-batch atomic rejection regression remains applicable; this checkpoint changes no backend code.
Native runtime human acceptance and durable offline bulk replay remain outstanding. TestFlight stays
on hold. No customer data, simulator reset, migration or additional server change is needed.
Regular Xcode 27 build-for-testing passed for the production composition and native test targets
against the preserved iPhone simulator; this confirms compilation, not executed runtime acceptance.
`git diff --check` passes. App rebuild required to use the captured bulk observations.

### Creation replay resource-authorization correction — 2026-10-09

Actual HTTP regressions reproduced an authorization leak: create with an operation UUID while
authorized, revoke account/category access (including only one split category), then retry the UUID.
The previous route returned 201 and exposed the now-hidden transaction, despite current resource
restrictions. Revoking create capability already returned 403. Both the ordinary existing-identity
return and post-IntegrityError collision return now recheck current create capability and canonical
whole-transaction resource visibility, returning neutral 404 for hidden resources. No replay applies
new ledger effects. Four HTTP cases verify denial and unchanged authoritative owner transaction data.

55 focused backend tests passed across creation idempotency, transaction browser/bulk and financial
golden vectors. The collision-return guard was code-audited; no real concurrent PostgreSQL race was
executed in this checkpoint. `git diff --check` passed. Server update/restart required; no migration,
Swift changes, app rebuild, simulator reset or customer-data changes. This does not supply immutable
command receipts or reject same-UUID/different-payload reuse; those replay-contract gaps remain.
TestFlight remains on hold.
