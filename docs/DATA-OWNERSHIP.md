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

## Remaining implementation sequence

1. Add the production `LocalDeviceRepository` adapter above `BudgetStorage` and route every mutation
   through the shared accounting-command boundary.
2. Prove account, category, assignment, expense/refund, transfer, reconciliation, schedule, payee,
   attachment, and audit persistence after every repository/service object is destroyed and reopened.
3. Define the provider-neutral portable archive/import schema so Local Device and Budget Server can
   transfer without depending on PostgreSQL SQL or SQLite internals.
4. Add validate-then-commit import into a new destination, preserve stable IDs and attribution, and
   compare canonical financial observations before cutover.
5. Add automatic schedules, visible destination/retention/failure/restore-verification health, and a
   graphical server manager. The developer CLI is not the normal-user v1.0 experience.
6. Add Dropbox OAuth setup/revocation UI without placing provider secrets in the iOS app database or
   logs. Keep Dropbox as a backup destination unless a separately designed synchronization authority
   is approved.
