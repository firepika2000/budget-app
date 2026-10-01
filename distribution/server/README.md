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
./manage.py stop
```

`start` validates Docker and the rendered Compose contract, starts the pinned services, and waits a
bounded time for the real API health endpoint. `stop` uses Compose's non-destructive stop operation;
it never removes containers, volumes, database files, attachments, or configuration. `diagnostics`
writes a JSON support report containing only allowlisted runtime/status fields. It excludes secrets,
allowed-host details, host storage paths, container environment, and application data. Review logs
before sharing them because user-entered server activity may still be visible there.

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
Python and developer tools are not required. Docker Desktop is still required, and secure remote
pairing/TLS is not yet guided, so this remains a preview rather than the final signed graphical server
manager. Automatic start/update, firewall guidance, and guided backup/restore remain required.

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
