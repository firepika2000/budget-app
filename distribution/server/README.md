# ClearPocket Server distribution foundation

This directory is the shared, versioned deployment contract for the future customer installers. It
is intentionally a **preview/advanced self-hosting foundation**, not yet the v1.0 graphical server
manager. The Docker installer now supports an opt-in, guarded public-HTTPS path; the package must not
be advertised as zero-configuration.

The same immutable multi-architecture API image, PostgreSQL version, persistent volume layout,
health checks, environment contract, and migration entry point are used on all supported container
hosts. That keeps Docker, QNAP Container Station, and Docker Desktop on an always-on Windows PC from
becoming three different servers.

## Install on a Docker host

For the normal first run on a Docker Engine or Docker Desktop host, extract the versioned bundle and
run:

```sh
./install-docker.sh
```

The installer requires Docker only. It pulls the exact immutable image, runs the bundled configuration
generator inside that image as the current host user, creates three private durable data directories,
validates Compose, starts the services, and waits for the real health endpoint. Rerunning it preserves
`.env` and every authority directory; it never offers reset or overwrite.

On first run, leave the public hostname blank for a loopback-only installation. To reach the server
from an iPhone over the Internet, enter a fully qualified DNS hostname that already resolves to this
host and allow inbound TCP 80 and 443. The generated `tls` Compose profile starts the pinned bundled
Caddy proxy, obtains and renews a public certificate automatically, configures the exact secure
pairing origin, and publishes only Caddy. The API remains bound to host loopback and PostgreSQL has no
published port. Do not forward port 8080. Caddy certificate issuance requires the hostname and router
port forwarding to be correct before installation.

Create a coordinated encrypted backup with Docker alone:

```sh
./backup-docker.sh
```

The first run asks for separate generation and recovery-key folders, creates an age identity inside
the pinned application container, and stores only its public recipient in `.env`. Capture briefly
quiesces the API, dumps PostgreSQL and encrypted attachments as one manifest, resumes service before
encryption, and atomically publishes a user-owned `0600` generation. It records owner-visible health,
prevents overlapping runs, and retains the newest 10 completed generations by default. Copy the
identity to a different protected device; a backup and its only decryption key on one disk are not a
recovery plan.

Recover that generation only into a newly configured empty Docker destination:

```sh
./restore-docker.sh /protected/budget-YYYYMMDDTHHMMSSZ.tar.gz.age \
  /separate/clearpocket-recovery-key.txt RESTORE
```

The archive and identity are mounted read-only. The pinned container decrypts into private staging,
verifies the complete manifest, and the script refuses database or attachment content both before and
after API quiescence. Only then does the empty destination adopt the authenticated attachment key and
commit SQL transactionally. Pre-commit failures remove only objects staged by that attempt and restore
the prior empty configuration; post-commit activation failures preserve the recovered authority with
the API stopped. Recovery status and real API health are required before success is reported.

Publish, inspect, or retrieve encrypted generations in a least-privilege Dropbox app folder without
installing Python or Dropbox tooling on the host:

```sh
chmod 600 /protected/dropbox.env
./dropbox-docker.sh publish /protected/budget-20261001T030000Z.tar.gz.age \
  /protected/dropbox.env /Backups 10
./dropbox-docker.sh list /protected/dropbox.env /Backups
./dropbox-docker.sh fetch /Backups/budget-20261001T030000Z.tar.gz.age \
  /protected/retrieved-budget.tar.gz.age /protected/dropbox.env /Backups
```

The credential file is declarative, owner-only, mounted read-only, and parsed without shell execution.
Use either `BUDGET_APP_DROPBOX_ACCESS_TOKEN`, or the durable pair
`BUDGET_APP_DROPBOX_REFRESH_TOKEN` and `BUDGET_APP_DROPBOX_APP_KEY` (plus the optional
`BUDGET_APP_DROPBOX_APP_SECRET`). The encrypted generation is verified by Dropbox content hash before
promotion, remote retention is bounded, and downloads are verified before becoming visible locally.
Keep the age recovery identity outside Dropbox and on a separately protected device.

To make each coordinated Docker backup publish off-device automatically, pass that credential file
and optional app-folder path after the two local paths:

```sh
./backup-docker.sh /protected/local-generations /separate/recovery-key \
  /protected/dropbox.env /Backups
```

Capture and encryption always complete locally first. A Dropbox failure retains that local generation,
records `publication_failed` in owner-visible backup health, and exits unsuccessfully so a scheduler can
alert; it never reports the capture as absent or deletes the recovery artifact. Successful publication
records only allowlisted remote path, size, hashes, and verification time—never OAuth credentials.

Advanced administrators may instead generate configuration directly from this directory:

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

The default bind address is loopback. The guided `--public-host budget.example.com` path enables the
bundled TLS proxy; advanced administrators may instead place a private-network overlay or their own
trusted TLS proxy in front of the API. `0.0.0.0` is available only for protected LAN testing, but the
iPhone app deliberately rejects ordinary remote HTTP. Never forward raw port 8080 from a home router
to the Internet.

Advanced deployments that already terminate trusted HTTPS may set
`BUDGET_APP_PAIRING_PUBLIC_URL=https://budget.example.com`. This enables the one-time pairing API only
for that canonical origin; it does not configure certificates, open firewall ports, or make raw HTTP
safe. Pairing secrets expire after five minutes, are stored only as hashes, redeem once into ordinary
rotating sessions, and can be revoked through the session API. The native app displays and scans the
versioned QR enrollment payload and uses the ordinary rotating session after redemption.

In bundled TLS mode, the API trusts forwarded scheme information because only the Caddy service on
the private Compose network can reach its container port and the host-published API port remains
loopback-only. Do not attach untrusted containers to this Compose network or change the API binding to
a public interface while `BUDGET_APP_FORWARDED_ALLOW_IPS=*` is configured.

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
generation. Docker, Python 3, and `age` must be installed on the host for these advanced manager backup
commands. The guided installer and `backup-docker.sh` path require Docker only. The recovery passphrase or age
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

First-time setup also accepts an optional fully qualified public DNS hostname. When supplied, it
activates the same pinned Caddy profile as the Docker installer, binds the raw API to PC loopback,
publishes only TCP 80/443, obtains and renews the certificate, and configures native device pairing.
The hostname must resolve to the PC and the router/firewall must allow those two ports. Leaving it
blank remains PC-only. Existing `.env` files are preserved rather than silently changing network
exposure; moving an existing install to public HTTPS remains an explicit administration task.

The Windows menu also accepts the provider-neutral encrypted portable archive produced by another
ClearPocket Server. It mounts the archive and optional age identity read-only, prompts inside the
version-matched container for a new owner password, and invokes the same validate-then-commit importer
used by the shared manager. The destination database and attachment store must be empty; failure keeps
the API stopped and never changes either source file.

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

The Windows manager also configures encrypted Dropbox publication without echoing private values.
It supports a temporary access token or durable refresh-token/app-key credentials, restricts the
resulting `dropbox.env` ACL to the signed-in Windows user, and preserves it across manager upgrades.
Docker Desktop receives that file read-only and copies it to a private in-container file before the
strict shared parser uses it. Manual and scheduled backups then retain the completed local generation,
verify Dropbox content before promotion, and report either verified remote metadata or
`publication_failed` without recording OAuth material. Disabling Dropbox removes only the local grant;
existing local and remote generations remain. Public-app OAuth onboarding is still required before this
can become a one-click consumer flow.

For an existing pinned installation, run `install-windows.cmd` from the newer downloaded bundle, then
choose **Apply this downloaded server version**. The manager requires an explicit `UPDATE`, completes the encrypted backup first, pulls the
exact image before atomically changing only the version setting, and requires API health. Pull failure
leaves configuration and running services unchanged. An unhealthy post-migration image is stopped and
never automatically downgraded against a potentially newer database; recover the preserved generation
into a new empty server instead. A signed installer package will eventually wrap this same per-user flow.

Python and developer tools are not required. Docker Desktop is still required. Secure remote
pairing/TLS is guided for a new installation, but automatic router/firewall configuration and a signed
graphical server manager remain open product work.

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
