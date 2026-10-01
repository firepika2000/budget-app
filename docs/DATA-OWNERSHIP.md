# Data ownership, local operation, and backup destinations

Updated 2026-09-30. This document tracks the v0.14 data-ownership implementation. It does not
claim that incomplete providers are production-ready.

## Authority and destination are separate

- **Budget Server** is currently the production authority for shared households. PostgreSQL and
  the encrypted attachment object store move together.
- **Local Device** is the default single-user, single-writer SQLite authority in the native app. It
  uses the production workspace/application-service path and is neither deterministic Demo data nor
  a SQLite file opened from Dropbox.
- **Dropbox** is an encrypted backup/snapshot destination and migration transport. It is not a live
  database or household synchronization authority.
- **Local directory** is an encrypted backup destination suitable for an external disk, a private
  network mount, or another owner-controlled location.

This keeps the canonical application, money semantics, and repository contracts independent from
where a verified backup generation is stored.

## Implemented Local Device persistence foundation

The `BudgetStorage` package now owns the low-level private SQLite boundary:

- an explicit versioned migration ledger and Budget-specific SQLite application identity;
- WAL journaling, full synchronous durability, foreign-key enforcement, bounded lock waiting, and
  serialized actor access;
- normalized identity, account, category, payee, transaction/split, allocation, reconciliation,
  target, schedule, and attachment-metadata tables;
- signed SQLite `INTEGER` values for exact `Int64` minor units;
- atomic multi-statement transactions with rollback on constraint failure;
- private file permissions and iOS file protection;
- SQLite online backup snapshots, verified with integrity/application-identity checks and protected
  from overwriting a known-good generation.

Focused tests destroy every repository object, reopen the file, and prove exact money/relationship
persistence. They also prove atomic rollback and verified snapshot reopen. Local Device is now a
selectable production provider and deliberately does not duplicate server accounting calculations.

`LocalAuthorityStore` now adds the first typed repository boundary above raw SQLite. It atomically
bootstraps the single-owner authority and persists account, category-group, category, payee, and
complete posted-transaction aggregates, payee aliases, allocations, reconciliations, targets,
recurring schedules, and attachment metadata. Attachment metadata is published only after the caller
has durably stored the encrypted object and removed only after that object enters a recoverable
tombstone lifecycle. `LocalAttachmentVault` now provides the corresponding private object boundary:
AES-GCM authenticated encryption under a caller-supplied 256-bit key, no-overwrite publication,
plaintext SHA-256 verification, path-traversal rejection, recoverable detach/restore, and explicit
retention purge. The native `LocalDeviceKeyManager` generates that key with the system secure random
source and stores it as device-only Keychain data; relaunches reuse the exact key and malformed key
material fails closed rather than silently orphaning encrypted objects. The key is never stored beside
the SQLite database or encrypted objects. Typed metadata updates plus atomic
transaction replacement and deletion preserve immutable
opening/creator facts and refuse missing records. Split totals are checked with overflow-safe integer
math before any write, while balances, activity, reserves, and other accounting consequences remain
the responsibility of the shared application-service layer.
Local schema v4 persists the shared engine's signed per-transaction, per-category credit-card
reserve attribution. Reopen replays the canonical transaction engine and rejects a non-empty durable
attribution set if it differs. Databases migrated from v3 may derive it once and publish it on their
next normal workspace save. This makes the observation explicit in backup and transfer data without
moving reserve calculation into the storage layer.
Local category-group identifiers are likewise carried by the production command model rather than
recomputed from display names or sort positions. Rename, reorder, reopen, backup, and later provider
conversion therefore retain the same group identity and every category reference.
The native target links `BudgetStorage` through `LocalDeviceStorageComposition`. That composition
opens the SQLite authority and encrypted attachment vault together beneath the app's private
Application Support directory and supplies the vault only with the Keychain-held key. The canonical
workspace adapter implements production reads and commands against this durable boundary; Demo stays
an explicitly labelled training/example source.
Destructive-reopen tests prove stable IDs, relationships, lifecycle changes, and exact `Int64` values
survive repository reconstruction.

The storage package also creates immutable `.clearpocketbackup` generations with SQLite online backup
and the complete encrypted attachment object/tombstone set. Each payload is chunked AES-GCM under an
independent 256-bit recovery key; the authenticated manifest records exact plaintext and ciphertext
sizes and SHA-256 values. Restore authenticates every payload, verifies database integrity and foreign
keys, reopens the authority, and decrypts/verifies every active attachment before publishing to a new
destination. It never overwrites an existing authority.

The native Local Device profile now exposes **Backup & Recovery**. An owner can create one of these
verified encrypted generations, copy its separately generated recovery key, and hand the package to
Files, iCloud Drive, Dropbox, an external drive, or another destination offered by the iOS share
sheet. The clipboard copy is device-local and expires after five minutes. This is manual export of an
immutable backup generation; it does not turn the destination into a live database, move authority,
or delete the local source.

The same production screen can now select an exported package from Files or an installed document
provider and accept its separate recovery key. Restore is validate-then-commit: it authenticates and
decrypts the entire generation into a new private directory, performs database/foreign-key and active
attachment verification, and records a private cutover journal without touching the open authority.
On the next cold app launch, the journal promotes the verified directory before SQLite opens. The
rename sequence is resumable after interruption, the prior authority is retained as a rollback
generation, and its exact attachment key is retained separately in the device-only Keychain. A wrong
key or damaged generation leaves no pending cutover and does not alter the current budget. The beta
workflow currently requires the user to close the app fully and reopen it after verification.

Backup & Recovery also lists retained rollback generations with their retention date and allocated
size. Switching back requires explicit confirmation and schedules the same cold-launch journal; it
does not rename or open SQLite while the app is running, and the version being left becomes a new
rollback generation with its matching device-only key. Permanent cleanup separately confirms before
removing both a retained authority and its key, refuses cleanup while any restore is pending, and
never treats a missing/malformed key as permission to delete data.

The native storage package now also contains the provider-neutral Dropbox destination application
service for these same encrypted `.clearpocketbackup` generations. It deliberately receives a narrow
transport interface rather than OAuth credentials or an open database. Publication uploads into a
private temporary folder, uses bounded 8 MiB upload-session chunks for large ciphertext payloads,
checks Dropbox's size and content-hash metadata for every file, and only then promotes the complete
folder to its immutable generation name. Listing consumes every page and retention deletes only
older `.clearpocketbackup` folders. Download retrieves and verifies the manifest first, requires the
remote file set to match it exactly, verifies every ciphertext size and Dropbox content hash, and
publishes locally only after the whole generation succeeds. Corrupt or incomplete transfers cannot
replace or become a Local Device authority; the existing recovery-key authentication and isolated
restore/cutover path remains the sole activation mechanism.

The destination core now has a production Dropbox API v2 HTTP adapter covering folder creation,
no-overwrite upload and upload sessions, move/delete, paginated listing, and verified download. The
adapter owns no bearer token: each request resolves the current access token through a credential
provider, rejects only the exact value that receives a 401, and retries once after rotation. This
prevents a long-lived backup service from retaining an expired credential.

Native Dropbox setup is implemented behind a registered public app identity. Connection, revocation,
destination, retention, verified upload/list/download, and recovery handoff are connected to Backup &
Recovery. A build without the public Dropbox app key fails closed while keeping local backup usable.
No Dropbox credential belongs in SQLite, the encrypted generation, logs, or source control. Live
Dropbox acceptance still requires registering the production app key/callback and exercising that
external account flow.

The reusable native OAuth credential layer is now implemented beneath that pending UI. It generates
RFC 7636 S256 PKCE authorization requests for offline access with only Dropbox file-content and
metadata scopes, validates the exact callback and unpredictable state, exchanges authorization codes,
and single-flights concurrent refreshes. Refresh-token rotation is committed to a dedicated
device-only Keychain account; access tokens remain memory-only. A 401 invalidates only the rejected
access-token value, and disconnect removes the Dropbox credential without touching the Local Device
authority, attachment key, server login, or encrypted generations. The release build still needs a
registered public Dropbox app key/callback before the connection UI can be enabled.

The Local Device **Backup & Recovery** production screen now hosts the destination controls. A
configured build can connect through the system authentication session, choose bounded retention,
upload the currently displayed encrypted generation, list remote generations, download and verify a
generation into private temporary storage, and hand it to the exact same recovery-key validation and
cold-launch cutover used by Files. Disconnect first asks Dropbox to revoke the grant and only removes
the Keychain refresh token after remote confirmation. Builds without the registered public app key
fail closed with an explicit configuration message while local backup, Files export/import, and
rollback remain available. Temporary Dropbox restore downloads are removed after preparation or when
leaving the screen.

## Implemented personal desktop-local backend

`./budget local` now provides a self-contained local authority for personal/development use through
the same production FastAPI routes consumed by the iPhone app. It creates a private SQLite database,
encrypted attachment key, JWT secret, attachment directory, and exclusive writer lock in the platform
application-data directory; applies the complete Alembic graph; and starts on loopback. `init`,
`migrate`, and `doctor` subcommands accept `--data-directory` for explicit installations and tests.

This mode is not Demo, does not require a separately administered PostgreSQL database, and persists
across server/app relaunch. It remains distinct from:

- the future on-iPhone `LocalDeviceRepository` (no desktop process required);
- shared-household PostgreSQL server deployments with multi-writer concurrency;
- Dropbox, which stores encrypted immutable generations rather than an open SQLite file.

Non-loopback binding fails closed unless the operator explicitly supplies allowed hosts. Consumer
pairing/TLS/discovery and a graphical manager remain required before presenting LAN operation as a
normal-user workflow.

The local server has its own application-consistent backup/restore path:

```sh
./budget local backup --output-directory /private/path
./budget local backup-status
./budget local restore /private/path/budget-YYYYMMDDTHHMMSSZ.tar.gz.age \
  --data-directory /private/new-local-authority
```

Backup takes an online SQLite snapshot while holding the authority lock, checks SQLite integrity and
foreign keys, captures encrypted attachments plus their recovery key, covers every payload with the
archive manifest, then applies age encryption. Restore authenticates/decrypts and validates in private
staging, checks the SQLite snapshot, builds and migrates a separate authority, and only then atomically
publishes the new data directory. It refuses an existing destination. A new JWT secret deliberately
requires clients to reauthorize, while the attachment key is preserved so recovered objects remain
readable.

Every attempt that produces a complete encrypted local generation records private, machine-readable
health in the authority's `backup-status.json`. `./budget local backup-status` reports the last
generation's timestamp, location, exact size/SHA-256, and publication destination. If local capture
succeeds but off-device publication fails, the state is `publication_failed`, the retained local
generation remains identified, and the failure is visible rather than being reported as healthy.
Successful operational restore and portable import also record a private `recovery-status.json` with
the verification time, source-provider kind, source ciphertext SHA-256, database integrity result,
and foreign-key result. `backup-status` includes this as `last_restore_verification`, even before the
new authority has produced its first backup.

When those paths are configured (the personal local server does this automatically), an authenticated
household owner can see the same sanitized backup and restore-verification state in the web Household
Console at `/admin` and in the native app under **Profile & Settings → Backup & Recovery**. The native
surface resolves the current Live credential for every refresh instead of retaining a bearer token,
and it is not exposed for Demo or non-owner budgets. The contract is deliberately owner-only, returns
not-found to non-owners even if they manage a budget, bounds metadata size, rejects symlinks/invalid
documents, and allowlists response fields so credentials or unrelated status-file content cannot leak
through either UI.

The same `BUDGET_APP_BACKUP_DESTINATION`, retention, Dropbox, and age recipient/identity settings used
by shared-server operations apply to `./budget local backup`. Thus a local authority can keep verified
generations on local/external storage or Dropbox without ever running its SQLite file from the cloud
folder.

## Implemented destination foundation

`server/scripts/backup_destination.py` publishes only existing encrypted
`budget-*.tar.gz.age` artifacts. It supports:

- atomic, no-overwrite local-directory publication;
- SHA-256 verification before local publication;
- private file permissions and atomic backup-health metadata;
- bounded generation retention without touching unrelated files;
- bounded Dropbox upload sessions rather than loading a large household backup into memory;
- Dropbox size and content-hash verification before promoting a temporary upload;
- retained Dropbox generations with paginated listing;
- verified temporary-file download before making a restore artifact visible locally;
- access tokens or OAuth refresh credentials supplied only through environment variables.

Create the encrypted full-fidelity server backup with the coordinated backup script first. Then
publish the resulting ciphertext to one or more destinations:

```sh
cd "/path/to/Budget App"
server/scripts/backup.sh --project-name budget-server

./budget storage publish \
  --destination local \
  --directory /Volumes/Household-Backups \
  --keep 10 \
  server/backups/budget-YYYYMMDDTHHMMSSZ.tar.gz.age
```

For unattended jobs, configure an owner-controlled age recipient and a destination. The coordinated
backup then encrypts without a terminal prompt, publishes only after the complete source capture is
available, and leaves the local encrypted generation intact if off-device publication fails:

```sh
export BUDGET_APP_BACKUP_AGE_RECIPIENT='age1...'
export BUDGET_APP_BACKUP_DESTINATION='local' # or dropbox
export BUDGET_APP_BACKUP_LOCAL_DIRECTORY='/Volumes/Household-Backups'
export BUDGET_APP_BACKUP_RETENTION='10'

server/scripts/backup.sh --project-name budget-server
```

For recipient-encrypted recovery, set `BUDGET_APP_BACKUP_AGE_IDENTITY` to the private identity-file
path before invoking `restore.sh`. Keep that identity outside the repository and separately from the
backup destination. Losing the only identity means losing access to those encrypted generations.

### Unattended macOS and Linux server backups

The coordinated PostgreSQL/attachment backup can be scheduled with a per-user LaunchAgent. Put only
the allowlisted backup settings in an owner-only file outside the repository:

```sh
mkdir -p "$HOME/Library/Application Support/Budget App Server"
chmod 700 "$HOME/Library/Application Support/Budget App Server"

touch "$HOME/Library/Application Support/Budget App Server/backup.env"
chmod 600 "$HOME/Library/Application Support/Budget App Server/backup.env"
# Edit this file without committing it.
```

Required content includes an `age` recipient so the unattended job never waits for or stores a
passphrase. Add either a local destination or Dropbox credentials:

```text
BUDGET_APP_BACKUP_AGE_RECIPIENT=age1...
BUDGET_APP_BACKUP_DESTINATION=dropbox
BUDGET_APP_BACKUP_RETENTION=10
BUDGET_APP_DROPBOX_REFRESH_TOKEN=...
BUDGET_APP_DROPBOX_APP_KEY=...
BUDGET_APP_DROPBOX_FOLDER=/Backups
```

Install a daily 03:00 schedule and inspect its latest run:

```sh
./budget backup-schedule install-launchd \
  --project-name budget-server \
  --backup-directory "$HOME/Library/Application Support/Budget App Server/backups" \
  --environment-file "$HOME/Library/Application Support/Budget App Server/backup.env" \
  --hour 3 --minute 0

./budget backup-schedule status \
  --backup-directory "$HOME/Library/Application Support/Budget App Server/backups"
```

The installer validates ownership and `0600` permissions, embeds only the environment-file path in
the plist, and uses a nonblocking file lock to prevent overlapping captures. Each invocation records
`healthy`, `failed`, or `already_running` state without copying credentials into logs or health data.
The coordinated capture briefly pauses the named API while PostgreSQL and attachment objects are
captured consistently, then resumes it before archive encryption/publication.

The versioned customer bundle ships the same scheduler for Linux Docker Engine. Its
`install-systemd` command installs a persistent daily user timer. An external Compose `.env` (as used
by packaged/NAS deployments) can be supplied with `--compose-env-file`; both private files must be
regular, owner-only files, and only their paths enter the unit. QNAP App Center and the Windows manager
provide their corresponding no-terminal schedule controls.

For Dropbox, create a least-privilege app-folder Dropbox application. Configure either a temporary
access token or, for durable operation, its refresh credentials outside the repository:

```sh
export BUDGET_APP_DROPBOX_REFRESH_TOKEN='...'
export BUDGET_APP_DROPBOX_APP_KEY='...'
export BUDGET_APP_DROPBOX_APP_SECRET='...'

./budget storage publish \
  --destination dropbox \
  --dropbox-folder /Backups \
  --keep 10 \
  server/backups/budget-YYYYMMDDTHHMMSSZ.tar.gz.age
```

`BUDGET_APP_DROPBOX_APP_SECRET` is optional for a Dropbox PKCE/native app whose refresh token is
issued without a client secret. Server-managed confidential apps should provide it.

Retrieve a generation into a new local path before passing it to the existing isolated restore
workflow:

```sh
./budget storage list --destination dropbox --dropbox-folder /Backups

./budget storage fetch-dropbox \
  /Backups/budget-YYYYMMDDTHHMMSSZ.tar.gz.age \
  /private/path/budget-restore.tar.gz.age

server/scripts/restore.sh \
  --yes --project-name budget-recovery \
  /private/path/budget-restore.tar.gz.age
```

Downloading does not weaken restore safety: age authentication, archive hashes, completeness,
schema compatibility, destination emptiness, and attachment-key compatibility are still verified
before the recovery deployment is changed.

## Provider-neutral encrypted export

An owner can create an open, provider-neutral archive through the authenticated production API:

```sh
export BUDGET_APP_ACCESS_TOKEN='short-lived-owner-access-token'
export BUDGET_APP_BACKUP_AGE_RECIPIENT='age1...'
./budget portable-export \
  --server-url http://127.0.0.1:8000 \
  --budget-id BUDGET-UUID \
  --output-directory ./exports
```

The access token is accepted only through the environment and is never written into the archive.
Plain HTTP is accepted only for loopback servers; remote exports require HTTPS. The tool validates
the structured export's per-section manifest, downloads every active attachment through the same
authorized application-service route used by the app, checks its exact byte count and SHA-256, and
then encrypts the data and attachment payloads with `age`. Detached attachment lifecycle metadata is
preserved, but tombstoned payload bytes remain an operational-backup concern.

Verify a generation before retaining or transferring it:

```sh
export BUDGET_APP_BACKUP_AGE_IDENTITY=/private/path/to/age-identity.txt
./budget portable-verify ./exports/budget-portable-YYYYMMDDTHHMMSSZ.tar.gz.age
```

Verification decrypts only into private temporary staging, rejects links, traversal, unexpected or
duplicate members and oversized payloads, then checks the archive manifest, v2 section manifest,
and exact active-attachment coverage/hashes. It does not write any application authority.

Import into a **new path only** (the destination must not exist):

```sh
export BUDGET_APP_BACKUP_AGE_IDENTITY=/private/path/to/age-identity.txt
./budget portable-import \
  ./exports/budget-portable-YYYYMMDDTHHMMSSZ.tar.gz.age \
  --data-directory "$HOME/Library/Application Support/Budget App Imported"
```

The importer prompts twice for a new owner password; passwords and tokens are never accepted on the
command line or copied from the source. It validates and decrypts in private staging, migrates a
separate SQLite authority to the current schema, preserves stable household/financial/audit IDs and
exact integer minor units, gives non-owner accounts new unusable credentials pending reauthorization,
re-encrypts active attachments under the new authority key, checks database integrity and foreign
keys, compares transaction/allocation/card-reserve observations, and atomically publishes the new
directory only after all gates pass. The source authority is never modified.

Portable import currently targets the personal desktop-local Budget Server authority. Import into
the on-device iPhone authority remains gated on the production `LocalDeviceRepository`; the archive
is not a substitute for same-provider operational backup because detached tombstone payload bytes
and deployment configuration remain intentionally provider-local.

The same validated portable archive can now initialize a **new empty customer Docker/QNAP server**.
The customer manager stops the API, brings up PostgreSQL alone, mounts the archive read-only into a
one-shot version-matched application container, and prompts interactively for a new owner password.
The database and attachment store must both be empty. All rows commit in one transaction, active
attachments are re-encrypted with the destination key before commit, financial observations are
compared exactly, and any failure removes newly written objects without overlaying an existing
household. Recovery verification becomes visible through the existing owner-only health contract.
This is an initialization/migration path, not an in-place merge.

Customer server packages can also perform a non-mutating preflight of a native iPhone Local Device
`.clearpocketbackup`. The version-matched container accepts the package read-only, prompts for its
separate recovery key, authenticates the HMAC manifest and every chunk/hash, and verifies the local
SQLite application identity, schema, integrity, foreign keys, attachment-key presence, and budget
identity entirely in disposable plaintext staging. Only bounded table counts are reported. This
proves cross-language package readability without activating or mutating a server.

The same manager can now initialize an empty customer server from that authenticated generation.
The canonical converter preserves stable source identities and exact ledger rows, expands local
allocation commands into balanced server postings, materializes nonzero local account openings as
explicit opening-balance transactions, creates linked system payment categories for credit accounts,
and reconstructs both purchase/refund attribution and card-payment reserve events. It also carries
reconciliation observations, targets/snoozes, schedules, first-class Payees/preferences, debt terms,
rollover history, and favorites. Local attachment objects are authenticated and decrypted only in
private disposable staging, then re-encrypted by the destination attachment service. Import still
requires an empty database and object store, compares exact financial observations after commit,
records owner-visible recovery health, and leaves the source authority untouched.

## Remaining implementation sequence

The production on-device authority and persistence/reopen coverage are implemented. The iOS app can
also create encrypted, generation-based local backups and export them through the system share sheet;
that share sheet can target Files, Dropbox, or another installed provider without granting the app
ambient access to the user's cloud account. Backup & Recovery now presents the same generation as a
guided server-transfer handoff: the owner shares the package, copies the separately retained key,
imports into a new empty server through its canonical verifier/converter, and connects the phone only
after that server reports healthy. The connection screen explicitly refuses to imply that changing an
address migrates data, defaults to an HTTPS origin, and retains the original phone authority throughout.

The repository now includes the shared customer-server deployment contract under
`distribution/server`: one pinned container image contract, PostgreSQL, attachment and operations
status persistence, private secret generation, health checks, and hardened Compose defaults for
Docker Desktop, QNAP Container Station, and other Compose-capable hosts. The GHCR publishing workflow
builds the same image for ARM64 and AMD64 and ships the canonical coordinated backup/restore tools.
A data-preserving manager validates, starts, health-checks, stops, diagnoses, creates encrypted
database-plus-attachment generations, and restores them only into an explicitly configured empty
recovery deployment through the bundled verify-before-mutate tool. It never offers in-place
overwrite. Backup capture success/failure and restore verification are
persisted inside a dedicated operations volume and exposed through the existing owner-only API/UI.
For advanced Docker/QNAP administration, a versioned bundle can now apply its immutable image only
after completing a coordinated encrypted backup. Pull failure leaves configuration unchanged; the
version setting changes atomically before activation; and an unhealthy post-migration deployment
never triggers an unsafe automatic image downgrade. The preserved generation instead anchors the
new-destination recovery workflow.

Tagged server builds now publish separately labeled Windows/Docker customer archives rather than a
generic workflow artifact. Each bundle records the immutable version, source commit, and exact
multi-architecture image digest; a release-level SHA-256 manifest covers both downloads, while the
container build retains provenance and an SBOM. The released Docker and Windows installers verify the
extracted file manifest, pull the recorded registry digest rather than trusting a mutable version tag,
and only then assign the local tag consumed by Compose. This supplies reproducible release identity
and download-integrity checks, but does not claim the platform code-signing still required for final
normal-user installers.

The generic versioned Docker bundle now has a one-command first-run installer. It requires only a
running Docker/Compose v2 installation, uses the exact immutable application image to execute the
configuration generator under the host user's identity, creates private durable authority directories,
starts Compose, and requires API health. The safe default keeps the API loopback-only. An explicit
public-hostname setup adds the bundled Caddy profile, automatic HTTPS, canonical pairing origin, and
trusted-proxy boundary without exposing the raw API port; reruns refuse to replace an existing `.env`
or authority.
The same generic bundle now performs coordinated encrypted backup entirely through the pinned
containers, including age identity creation, PostgreSQL dump, attachment capture, canonical manifest,
atomic publication, health reporting, overlap exclusion, and bounded post-success retention. The
generation and identity remain owner-selected host paths and the resulting files are returned to the
invoking host user; no host Python, PostgreSQL client, or age binary is required.
Its paired Docker-only restore mounts both source files read-only, verifies in private container
staging, checks destination emptiness before and after quiescence, adopts the authenticated attachment
key only for that empty destination, restores SQL in one transaction, records recovery health, and
serves only after API health. Pre-commit failure rolls back only that attempt's key/object staging;
post-commit failure preserves the recovered authority and leaves its API stopped.
The generic Docker bundle can now publish, list, and retrieve those encrypted generations in a
least-privilege Dropbox app folder using the pinned container. Its small owner-only credential file is
mounted read-only and parsed as data rather than shell code; only the four supported Dropbox OAuth
settings are accepted. Uploads retain the existing bounded-session, content-hash-before-promotion,
no-overwrite, and remote-retention guarantees, while downloads are verified before atomic visibility.
The host still needs only Docker, and the recovery identity remains deliberately separate from the
Dropbox destination.
The coordinated Docker backup accepts the same owner-only credential file as an optional publication
target. It completes and retains local capture before attempting Dropbox, records only verified and
allowlisted remote metadata on success, and records `publication_failed` with the retained local
generation on network/OAuth failure. This preserves a recoverable generation while still making an
unattended scheduler failure visible.

The versioned Windows ZIP now includes a double-click per-user installer. It validates and atomically
publishes an allowlisted manager payload to a stable `%LOCALAPPDATA%` program path, adds Desktop and
Start Menu shortcuts, and preserves private configuration and every authority/recovery path on rerun.
The Windows helper uses built-in PowerShell for cryptographic first-run configuration and selectable
durable storage without Python, and now provides start/open, status, data-preserving stop, redacted
diagnostics and log actions. It can register a limited current-user Task Scheduler entry that waits
for Docker Desktop and starts the server after sign-in without embedding credentials.
The Windows menu can also activate an authenticated iPhone Local Device backup through the same
version-matched converter used by the shared manager. It requires explicit `IMPORT` confirmation,
mounts the source package read-only, starts only PostgreSQL during conversion, and serves the API only
after destination observation checks pass. Failure leaves the API stopped and the phone backup intact.
It can likewise activate a provider-neutral encrypted portable archive in an empty destination, with
the archive and optional age identity mounted read-only and all validation/password/observation gates
executing inside the version-matched container.
It now creates full PostgreSQL-plus-attachment encrypted generations using only PowerShell and the
pinned server containers. First use generates an owner-held age recovery identity and persists only
its public recipient in server configuration. Capture uses the canonical manifest, atomic publication,
and backup-health contract; no Windows Python, PostgreSQL client, or age installation is required.
The paired guided restore accepts the separately retained identity or an interactive passphrase,
verifies in isolated staging, refuses nonempty database/object destinations twice, replaces the empty
destination's attachment key with the authenticated recovered key, restores PostgreSQL in one guarded
transaction, and serves only after a force-recreated API passes health. Failure leaves the recovery
API stopped and never modifies the source archive.
After the first successful interactive Windows generation, the same manager can install, inspect, or
remove a daily limited-user Task Scheduler job. Only script/configuration/destination paths enter the
task; credentials and the recovery identity do not. Start-when-available, IgnoreNew, an execution limit,
and the backup process's exclusive lock prevent missed wakeups and overlapping manual/scheduled capture.
The newest 10 completed Windows generations are retained by default (owner-configurable with a positive
`BUDGET_APP_BACKUP_RETENTION` setting); rotation occurs only after successful atomic publication and
matches regular ClearPocket generation files only.
The Windows manager can also apply the immutable version in a newly downloaded bundle over an existing
manager folder. It requires explicit confirmation, completes the encrypted backup first, pulls the exact
image before atomically pinning the new version, and serves only after health. Pull failure changes
nothing; failed post-migration activation stops the API and never attempts an unsafe automatic downgrade.
The Windows manager now provides hidden-input Dropbox backup configuration using either temporary or
durable refresh credentials. It writes a user-only ACL credential file that upgrades preserve, mounts it
read-only, and copies it to a private in-container file before the same strict parser and verified
publication engine run. Manual and scheduled jobs retain their local encrypted generation before remote
publication; failure records `publication_failed`, while success stores only allowlisted verification
metadata. Disconnect removes the local grant without touching any generation.
`distribution/qnap` contains a QDK-compatible package foundation that
wraps the same Compose bundle in App Center lifecycle hooks while keeping authority outside the
replaceable QPKG directory. Its install routine chooses a durable QNAP shared-folder root, creates
separate database/attachment/operations directories, generates independent kernel-random secrets,
and atomically creates but never overwrites the private configuration. QNAP administrators can now
preflight or activate a phone Local Device generation directly through the package service without
host Python: the source must be a regular package under `/share`, is mounted read-only, and import
restarts the API only after the same canonical conversion and observation verification succeeds.
The service also accepts a provider-neutral encrypted archive plus an age identity (or interactive
passphrase) through the same canonical empty-authority importer, so server-to-server migration does
not depend on host Python, PostgreSQL, or age tooling.
The QPKG service also performs coordinated encrypted database-plus-attachment capture entirely through
the pinned containers, generates an owner-held age identity on first use, prevents overlap, publishes
atomically to durable QNAP storage, and updates the owner-visible backup-health contract without host
Python or age. Completed generations have bounded post-success retention that never touches partial or
unrelated files. After the first successful manual generation, an administrator can atomically install,
inspect, or remove a daily QNAP cron entry containing only the absolute package action and no credentials;
failed crontab reload restores the prior system file, while the capture lock prevents overlap. The identity
must still be copied off the NAS. The package can restore a
generation with that separately retained identity into a new empty QNAP authority without host tools:
both inputs are mounted read-only, integrity is checked in private staging, emptiness is checked before
and after API quiescence, the authenticated attachment key is adopted only for that empty destination,
and the service returns only after recovery health and the API health gate succeed.
When the QNAP durable data root contains a strict owner-only `dropbox.env`, both manual and scheduled
capture publish the completed encrypted generation to the configured least-privilege Dropbox app
folder. The credential file is mounted read-only and parsed as data in the pinned container. Remote
promotion follows size/content-hash verification and bounded retention; failure retains the local
generation, records `publication_failed`, and returns an error to QNAP scheduling rather than claiming
healthy off-NAS protection.
After a newer versioned QPKG is installed, its explicit package update action applies the same shared
manager invariant: create the encrypted generation first, pull the exact immutable image before changing
the version setting, atomically pin it, and require API health. Pull failure changes nothing; unhealthy
post-migration activation keeps the API stopped and never attempts an unsafe automatic downgrade.
These remain previews rather than the promised normal-user setup: release images/packages are
unsigned and QNAP hardware validation is pending. Docker and Windows packages can opt into bundled
Caddy automatic HTTPS and canonical pairing. QNAP uses its QTS-managed certificate/public 443 path
and an internal loopback bridge to the application proxy, avoiding a competing listener on the NAS.

The first secure-pairing foundation is implemented behind an explicitly configured canonical
HTTPS origin. Authenticated users can generate one active five-minute, high-entropy pairing secret
whose hash alone is persisted; atomic one-time redemption consumes it and creates the same rotating refresh session
used by password sign-in and assigns a device label. Users can list and revoke only their own active
refresh sessions. Insecure non-loopback requests and deployments without a canonical pairing origin
fail closed. The production iOS settings now render the QR locally, offer native camera scanning plus
manual fallback, enter the canonical Live application route after redemption, and provide labeled
device-session listing and confirmed revocation. Supported customer packages now establish their
deployment-specific HTTPS edge and canonical pairing origin; real-network/hardware human acceptance,
certificate-domain operational guidance, and immediate invalidation of already-issued short-lived
access tokens remain open; see `PAIRING-SECURITY.md`.

1. Register the production Dropbox public app key/callback and complete live external-account
   acceptance. Dropbox remains a backup destination, not a second authority.
2. Continue the normal-user server manager around the shared image/config contract: graphical storage
   selection, install/update/rollback, scheduled backup/restore, and actionable health reporting.
3. Validate and package the manager for supported QNAP models and always-on Windows PCs, with signed
   installers and no command-line requirement for the normal path.
4. Complete real-network acceptance of secure pairing/TLS across Docker, QNAP, and Windows, while
   preserving loopback-only raw API binding and never exposing that port directly to the Internet.
