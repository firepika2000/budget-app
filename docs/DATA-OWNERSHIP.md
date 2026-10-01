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

Native Dropbox setup is not complete yet. The registered public app identity plus connection,
revocation, destination, and retention controls still have to be connected to Backup & Recovery.
No Dropbox credential belongs in SQLite, the encrypted generation, logs, or source control.

The reusable native OAuth credential layer is now implemented beneath that pending UI. It generates
RFC 7636 S256 PKCE authorization requests for offline access with only Dropbox file-content and
metadata scopes, validates the exact callback and unpredictable state, exchanges authorization codes,
and single-flights concurrent refreshes. Refresh-token rotation is committed to a dedicated
device-only Keychain account; access tokens remain memory-only. A 401 invalidates only the rejected
access-token value, and disconnect removes the Dropbox credential without touching the Local Device
authority, attachment key, server login, or encrypted generations. The release build still needs a
registered public Dropbox app key/callback before the connection UI can be enabled.

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

### Unattended macOS server backups

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

## Remaining implementation sequence

The production on-device authority and persistence/reopen coverage are implemented. The iOS app can
also create encrypted, generation-based local backups and export them through the system share sheet;
that share sheet can target Files, Dropbox, or another installed provider without granting the app
ambient access to the user's cloud account.

The repository now includes the first shared customer-server deployment contract under
`distribution/server`: one pinned container image contract, PostgreSQL and attachment persistence,
private secret generation, health checks, and hardened Compose defaults for Docker Desktop, QNAP
Container Station, and other Compose-capable hosts. The GHCR publishing workflow builds the same
image for ARM64 and AMD64. This is a packaging foundation, not yet the promised normal-user setup
experience: the image has not been release-published and QNAP model validation is pending. The
Windows helper now uses built-in PowerShell for cryptographic first-run configuration and selectable
durable storage without Python, but still requires Docker Desktop and lacks the final signed manager.

1. Connect the implemented native Dropbox destination/OAuth core to explicit setup/revocation and
   retention controls after registering the public app key/callback. Dropbox remains a backup
   destination, not a second authority.
2. Build the normal-user server manager around the shared image/config contract: graphical storage
   selection, install/update/rollback, scheduled backup/restore, and actionable health reporting.
3. Validate and package the manager for supported QNAP models and always-on Windows PCs, with signed
   installers and no command-line requirement for the normal path.
4. Add secure pairing and TLS for remote clients. Until that exists, keep the default loopback bind
   and never expose the raw API port directly to the Internet.
