# ClearPocket Server distribution foundation

This directory is the shared, versioned deployment contract for the future customer installers. It
is intentionally a **preview/advanced self-hosting foundation**, not yet the v1.0 graphical server
manager. It must not be advertised as zero-configuration or safe for direct Internet exposure.

The same immutable multi-architecture API image, PostgreSQL version, persistent volume layout,
health checks, environment contract, and migration entry point are used on all supported container
hosts. That keeps Docker, QNAP Container Station, and Docker Desktop on an always-on Windows PC from
becoming three different servers.

## Generate private configuration

From this directory:

```sh
python3 configure.py --allowed-hosts budget.example.com --version VERSION \
  --database-storage /srv/clearpocket/database \
  --attachments-storage /srv/clearpocket/attachments
docker compose --env-file .env up -d
```

The generator creates independent database, JWT, and 256-bit attachment-encryption secrets without
printing them, writes the file atomically with private POSIX permissions, and refuses to overwrite an
existing configuration. Preserve `.env` in a password manager alongside the separately encrypted
backup recovery material. Never commit it.

The storage arguments may be Docker volume names or absolute host directories. When host directories
are selected, create them on durable protected storage before starting the application. The database
and encrypted attachments are a single recovery unit even though they use separate directories.
The operations storage contains only persistent backup/recovery health documents shown to owners; it
must remain durable across container replacement but is not a substitute for either authority volume.

The default bind address is loopback. Put a supported TLS reverse proxy or private-network overlay in
front of it. `0.0.0.0` is available for protected LAN testing, but the iPhone app deliberately rejects
ordinary remote HTTP; secure pairing/TLS remains a release gate. Never forward raw port 8080 from a
home router to the Internet.

## Safe server management

Linux Docker Engine and QNAP administrators can use the bundled management command after generating
`.env`:

```sh
./manage.py doctor
./manage.py start
./manage.py status
./manage.py diagnostics
./manage.py logs --lines 200
./manage.py backup --output /protected/path/clearpocket-backups
./manage.py restore --project-name clearpocket-recovery /protected/path/budget-generation.tar.gz.age
./manage.py stop
```

`start` validates Docker and the rendered Compose contract, starts the pinned services, and waits a
bounded time for the real API health endpoint. `stop` uses Compose's non-destructive stop operation;
it never removes containers, volumes, database files, attachments, or configuration. `diagnostics`
writes a JSON support report containing only allowlisted runtime/status fields. It excludes secrets,
allowed-host details, host storage paths, container environment, and application data. Review logs
before sharing them because user-entered server activity may still be visible there. `backup` invokes
the bundled, tested coordinated backup path: the API pauses, PostgreSQL and encrypted attachments are
captured as one integrity manifest, the API resumes, and `age` publishes an immutable encrypted
generation. Docker, Python 3, and `age` must be installed on the host. The recovery passphrase or age
identity remains under the household owner's control.

On a package host that keeps private settings outside the replaceable application directory, pass
`--env-file /durable/private/path/.env` before the subcommand. The same explicit path is forwarded to
Compose and the coordinated backup tool; it is never copied into diagnostics.

Restore is deliberately a **new empty deployment** operation, never an in-place overwrite. Configure
this bundle's `.env` and empty database/attachment paths as the recovery destination. Its attachment
encryption secret must match the recovery material captured inside the backup. Set
`BUDGET_APP_BACKUP_AGE_IDENTITY` to the separately retained age identity when recipient encryption was
used; omit it for an interactive passphrase generation. The manager delegates to the bundled restore
tool with an explicit recovery project. It decrypts in private staging, verifies the complete manifest,
database and object payload, checks destination emptiness and the attachment key before stopping its
API, then rechecks emptiness and restores PostgreSQL transactionally. It starts the recovery API only
after success and records owner-visible verification. Failure leaves the recovery API stopped; the
source deployment and encrypted generation are never modified. Preserve both until the recovered
authority has been tested and backed up again.

### Start a new server from a portable household

A portable archive can initialize a newly installed customer server without merging into or
overwriting another household:

```sh
./manage.py portable-import \
  --age-identity /private/path/age-identity.txt \
  /private/path/budget-portable-YYYYMMDDTHHMMSSZ.tar.gz.age
```

The manager stops the API, starts only PostgreSQL, mounts the selected archive read-only into a
one-shot application container, and prompts twice for the new owner password. The importer verifies
the encrypted archive and every active attachment, requires both the database and attachment store
to be empty, commits the complete household in one database transaction, re-encrypts attachments
under this deployment's key, checks exact financial observations, writes owner-visible recovery
health, and starts the API only after success. A failed import never overlays existing data and
leaves the API stopped for inspection. The age identity file is mounted read-only for the one-shot
operation; its contents are never placed on a command line or copied into the authority.

### Verify an iPhone Local Device backup

Before moving a phone-local household, an administrator can perform a non-mutating compatibility
check with the same versioned customer image:

```sh
./manage.py verify-local-device /private/path/generation.clearpocketbackup
```

The package is mounted read-only and copied into private container staging so its owner-only host
permissions remain intact. The verifier prompts for the separate Local Device recovery key and then
authenticates the manifest, decrypts and authenticates every bounded chunk, checks every size/hash,
and verifies the SQLite application identity, supported schema, integrity, foreign keys, and exact
budget identity. It prints only bounded record counts and destroys plaintext staging on exit. It
does not start PostgreSQL or modify any server authority.

After that preflight, initialize a newly installed, empty server directly from the phone generation:

```sh
./manage.py local-device-import /private/path/generation.clearpocketbackup
```

The manager stops the API, starts PostgreSQL alone, and prompts for the recovery key plus the new
server login email and password. The converter preserves stable household/ledger identities, exact
integer money, balanced allocation postings, opening balances, reconciliation observations, targets,
schedules, Payees, debt terms, and rollover history. It creates linked server payment categories,
reconstructs purchase/refund and card-payment reserve events from durable source facts, decrypts and
authenticates every local attachment before the destination re-encrypts it, and requires an empty
database and object store. It starts the API only after exact post-import financial comparison and
health verification. Keep the phone authority and its backup until the new server is accepted.

## Versioned update safety

A newly downloaded immutable bundle can update an existing advanced Docker/QNAP deployment only after
creating a complete encrypted generation:

```sh
./manage.py --env-file /durable/private/path/.env upgrade \
  --backup-output /protected/path/clearpocket-backups
```

The manager refuses `edge`, validates Docker and the rendered Compose contract, completes the backup,
pulls the exact image named by the bundle's `VERSION`, atomically changes only the private version
setting, starts the new services, and waits for API health. A failed pull leaves configuration and
containers unchanged. If the new image starts migrations but does not become healthy, the manager
does not perform an unsafe image downgrade against a possibly forward-migrated database; it preserves
the pre-update backup and directs recovery into a new deployment. Graphical update/recovery guidance
and release-signature verification remain required for the normal-user manager.

For a Linux Docker host with an owner-controlled age recipient, `tools/backup_schedule.py` can install
a persistent daily systemd user timer. The backup credential file and deployment `.env` must both be
owner-only regular files; the generated unit records only their paths, never their contents:

```sh
python3 tools/backup_schedule.py install-systemd \
  --project-name clearpocket-server \
  --backup-directory /protected/path/clearpocket-backups \
  --environment-file /protected/path/backup.env \
  --compose-env-file .env --hour 3 --minute 0
```

The scheduler uses a nonblocking lock to prevent overlapping captures and records a bounded health
document for every run. Host Python 3 and `age` remain requirements for this advanced path. The
normal-user graphical scheduling experience is not complete.

## Docker Engine

Use this Compose file on a Linux Docker Engine or equivalent host. Pin `CLEARPOCKET_SERVER_VERSION`
to a tested release rather than `edge`. Run `./manage.py start`; after it reports healthy, open
`/admin` through the configured HTTPS endpoint and perform First Setup.

## QNAP NAS

Container Station can import `compose.yaml` as an application. Download and unpack the versioned
server bundle, then generate `.env` with database and attachment paths under the same protected QNAP
shared folder. Import `compose.yaml` and `.env`; do not copy secrets into the Compose file. When SSH
administration is enabled, `manage.py` provides the same non-destructive status/start/stop/diagnostics
contract as a Linux Docker host. Use QNAP's supported reverse-proxy/certificate workflow or a private
VPN. QNAP model architecture must be supported by the
published image (`linux/amd64` or `linux/arm64`). A QPKG-style guided installer, storage-volume picker,
certificate/pairing UI, and tested model matrix remain required before this becomes a
normal-user QNAP package.

The repository also contains a QDK-compatible engineering package under `distribution/qnap`. It adds
App Center lifecycle integration around this exact bundle while keeping customer authority outside
the replaceable QPKG directory. It remains a preview until its documented setup, signing, and
hardware-validation gates are complete. Its service actions include the same guarded empty-destination
restore using the package containers, so recovery does not require host Python, PostgreSQL, or `age`,
plus backup-before-update activation of the immutable version bundled by the QPKG.

## Always-on Windows PC

On Windows, extract the versioned ZIP and double-click `install-windows.cmd`. The per-user installer
validates the complete immutable bundle, atomically publishes only allowlisted replaceable program
files under `%LOCALAPPDATA%\Programs\ClearPocket Server`, creates Desktop and Start Menu shortcuts,
and opens the manager. It never copies or replaces `.env`, database, attachment, recovery-key, or
backup data. Rerunning a newer installer preserves the stable manager/task path and directs the owner
to the backup-gated version action. No administrator account, Python, or development environment is
required; Docker Desktop remains required.

`start-windows.cmd` is the double-clickable Docker Desktop manager. Its built-in PowerShell
setup asks for a durable data folder and creates independent cryptographic secrets without displaying
them. Its menu can start and health-check the pinned Compose application, open local setup, show
status, stop without deleting data, create a redacted diagnostics report, and display recent logs.
It can also register or remove a limited current-user Task Scheduler entry that waits for Docker
Desktop and starts the server after sign-in; the task contains only the manager path, never private
configuration or credentials. The same menu can initialize a new empty Windows server from an iPhone
Local Device `.clearpocketbackup` folder. The package is mounted read-only, authenticated and converted
inside the version-matched application container, and the API restarts only after exact financial and
attachment verification succeeds. A failed transfer leaves the API stopped for inspection and never
modifies the iPhone package.

The Windows menu can also create a complete encrypted server backup without installing Python,
PostgreSQL tools, or `age` on Windows. On first use it creates an age recovery identity through the
pinned application image, saves the private identity only in the folder selected by the owner, and
stores only its public recipient in `.env`. Copy that identity to a separate protected device or
offline location: losing it makes recipient-encrypted generations unrecoverable. Capture briefly
pauses the API, dumps PostgreSQL, copies the already-encrypted attachment store, resumes the API,
builds the canonical integrity manifest, encrypts into private staging, and atomically publishes the
finished generation. Partial output is removed on failure, and success/failure health is written to
the same owner-visible status contract used on other hosts. The matching Restore menu accepts either
that recovery identity or an interactive passphrase archive. It decrypts and validates entirely in
private temporary staging, refuses a populated database or attachment store before and after pausing
the API, adopts the authenticated attachment key only for that empty destination, and restores SQL in
one guarded transaction. The API is force-recreated with the recovered key and must pass its health
check; otherwise it remains stopped for inspection.

After one successful interactive backup has created the recovery identity, the Windows menu can
install a daily current-user Task Scheduler job. The owner chooses a destination and `HH:mm` time;
the task stores only the manager, environment-file, and destination paths—never the age identity,
database secret, JWT secret, or attachment key. It runs with limited privileges, starts a missed run
when the signed-in PC becomes available, ignores overlapping instances, and has a six-hour ceiling.
The backup script also holds an exclusive filesystem lock, so scheduled and manual captures cannot
overlap. Separate menu actions show its state/last result or remove only the schedule while preserving
all generations and recovery material. Because Docker Desktop runs in the interactive user session,
the user must be signed in and Docker Desktop must be running when the task executes.
Completed generations are bounded to the newest 10 by default. Advanced owners can set a positive
`BUDGET_APP_BACKUP_RETENTION` value in the private `.env`; rotation runs only after a new encrypted
generation has been published successfully and never follows links or removes unrelated files.

For an existing pinned installation, run `install-windows.cmd` from the newer downloaded bundle, then
choose **Apply this downloaded server version**. The manager requires an explicit `UPDATE`, completes the encrypted backup first, pulls the
exact image before atomically changing only the version setting, and requires API health. Pull failure
leaves configuration and running services unchanged. An unhealthy post-migration image is stopped and
never automatically downgraded against a potentially newer database; recover the preserved generation
into a new empty server instead. A signed installer package will eventually wrap this same per-user flow.

Python and developer tools are not required. Docker Desktop is still required, and secure remote
pairing/TLS is not yet guided, so this remains a preview rather than the final signed graphical server
manager. Guided update and firewall guidance remain required.

Rerunning the launcher reuses the existing `.env` and data folders. It never replaces configuration
or deletes data. To move storage, use an exported encrypted backup and the documented restore flow;
do not edit paths while containers are running.

## Data and recovery invariants

- PostgreSQL and the encrypted attachment volume form one authority and move together.
- Startup applies forward migrations before accepting traffic.
- A failed update must preserve both named volumes and the previous image/configuration.
- Backups are encrypted immutable generations; Dropbox is a destination, never the open database.
- Restore targets a new empty deployment and is verified before client cutover.
- Removing containers must not imply removing volumes. Data deletion always requires a separate,
  explicit user choice.
