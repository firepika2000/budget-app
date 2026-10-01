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
python3 configure.py --allowed-hosts budget.example.com --version VERSION
docker compose --env-file .env up -d
```

The generator creates independent database, JWT, and 256-bit attachment-encryption secrets without
printing them, writes the file atomically with private POSIX permissions, and refuses to overwrite an
existing configuration. Preserve `.env` in a password manager alongside the separately encrypted
backup recovery material. Never commit it.

The default bind address is loopback. Put a supported TLS reverse proxy or private-network overlay in
front of it. `0.0.0.0` is available for protected LAN testing, but the iPhone app deliberately rejects
ordinary remote HTTP; secure pairing/TLS remains a release gate. Never forward raw port 8080 from a
home router to the Internet.

## Docker Engine

Use this Compose file on a Linux Docker Engine or equivalent host. Pin `CLEARPOCKET_SERVER_VERSION`
to a tested release rather than `edge`. After both services report healthy, open `/admin` through the
configured HTTPS endpoint and perform First Setup.

## QNAP NAS

Container Station can import `compose.yaml` as an application. Upload this directory, generate or
enter the `.env` values, and store both named volumes on protected NAS storage. Use QNAP's supported
reverse-proxy/certificate workflow or a private VPN. QNAP model architecture must be supported by the
published image (`linux/amd64` or `linux/arm64`). A QPKG-style guided installer, storage-volume picker,
certificate/pairing UI, upgrade safety, and tested model matrix remain required before this becomes a
normal-user QNAP package.

## Always-on Windows PC

`start-windows.cmd` is an early double-clickable Docker Desktop launcher. It checks Docker, creates
configuration once, starts the pinned Compose application, and opens the local admin page. It still
depends on Docker Desktop and Python for first configuration, so it does **not** satisfy the roadmap's
final no-development-infrastructure requirement. The production Windows deliverable will wrap this
contract in a signed graphical installer/manager with secure secret storage, automatic start/update,
firewall guidance, backup/restore, diagnostics, and explicit data-preserving uninstall.

## Data and recovery invariants

- PostgreSQL and the encrypted attachment volume form one authority and move together.
- Startup applies forward migrations before accepting traffic.
- A failed update must preserve both named volumes and the previous image/configuration.
- Backups are encrypted immutable generations; Dropbox is a destination, never the open database.
- Restore targets a new empty deployment and is verified before client cutover.
- Removing containers must not imply removing volumes. Data deletion always requires a separate,
  explicit user choice.
