# Data ownership, local operation, and backup destinations

Updated 2026-09-27. This document tracks the v0.14 data-ownership implementation. It does not
claim that incomplete providers are production-ready.

## Authority and destination are separate

- **Budget Server** is currently the production authority for shared households. PostgreSQL and
  the encrypted attachment object store move together.
- **Local Device** will be a single-user, single-writer SQLite authority. It is not implemented yet
  and must not be represented by deterministic Demo data or a SQLite file opened from Dropbox.
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
persistence. They also prove atomic rollback and verified snapshot reopen. This is storage
infrastructure, not yet a selectable product provider: it deliberately does not duplicate server or
Demo accounting calculations.

`LocalAuthorityStore` now adds the first typed repository boundary above raw SQLite. It atomically
bootstraps the single-owner authority and persists account, category-group, category, payee, and
complete posted-transaction aggregates, payee aliases, allocations, reconciliations, targets,
recurring schedules, and attachment metadata. Attachment metadata is published only after the caller
has durably stored the encrypted object and removed only after that object enters a recoverable
tombstone lifecycle; the encrypted on-device object vault remains part of the application-service
adapter work. Typed metadata updates plus atomic transaction replacement and deletion preserve immutable
opening/creator facts and refuse missing records. Split totals are checked with overflow-safe integer
math before any write, while balances, activity, reserves, and other accounting consequences remain
the responsibility of the shared application-service layer.
Destructive-reopen tests prove stable IDs, relationships, lifecycle changes, and exact `Int64` values
survive repository reconstruction. This boundary is not yet wired into the app's data-source selector;
the remaining domain records and application-service adapter must be completed first so users cannot
enter a partially functional Local Device mode.

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

1. Add the production `LocalDeviceRepository` adapter above `BudgetStorage` and route every mutation
   through the shared accounting-command boundary.
2. Prove account, category, assignment, expense/refund, transfer, reconciliation, schedule, payee,
   attachment, and audit persistence after every repository/service object is destroyed and reopened.
3. Extend the implemented validate-then-commit desktop-local import to the production on-device
   repository, and compare the complete canonical workspace/report projections before cutover.
4. Add a graphical server manager and pairing/TLS workflow. Scheduling plus backup/restore health are
   implemented, but the developer CLI is not the normal-user v1.0 server experience.
5. Add Dropbox OAuth setup/revocation UI without placing provider secrets in the iOS app database or
   logs. Keep Dropbox as a backup destination unless a separately designed synchronization authority
   is approved.
