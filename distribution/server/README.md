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

The versioned bundle also includes `tools/restore.sh`. Restore is intentionally not a routine manager
menu action: it accepts only a brand-new empty recovery deployment, verifies the encrypted archive and
attachment key before mutation, and requires an explicit `--yes --project-name` target. Follow the
recovery runbook and preserve the source authority until the restored destination is verified.

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
certificate/pairing UI, upgrade safety, and tested model matrix remain required before this becomes a
normal-user QNAP package.

The repository also contains a QDK-compatible engineering package under `distribution/qnap`. It adds
App Center lifecycle integration around this exact bundle while keeping customer authority outside
the replaceable QPKG directory. It remains a preview until its documented setup, signing, and
hardware-validation gates are complete.

## Always-on Windows PC

`start-windows.cmd` is an early double-clickable Docker Desktop manager. Its built-in PowerShell
setup asks for a durable data folder and creates independent cryptographic secrets without displaying
them. Its menu can start and health-check the pinned Compose application, open local setup, show
status, stop without deleting data, create a redacted diagnostics report, and display recent logs.
It can also register or remove a limited current-user Task Scheduler entry that waits for Docker
Desktop and starts the server after sign-in; the task contains only the manager path, never private
configuration or credentials. Python and developer tools are not required. Docker Desktop is still required, and secure remote
pairing/TLS is not yet guided, so this remains a preview rather than the final signed graphical server
manager. Guided update, firewall guidance, and backup/restore remain required.

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
