# ClearPocket Server QNAP package source

This directory builds a QDK/QPKG wrapper around the same server bundle used by Docker Engine and
Windows. It follows QNAP's package lifecycle rather than creating a separate server implementation.

The package is currently an engineering preview. It provides App Center install, cryptographic
no-overwrite first-run configuration, enable/start, disable/stop, restart, status integration, and
an administrator-only QTS desktop manager.
Customer authority is deliberately external to the
replaceable QPKG directory: `/etc/config/clearpocket-server.conf` points to a durable QNAP shared-folder
deployment root containing `.env`, PostgreSQL data, and encrypted attachments. Package removal does
not delete that root or its configuration pointer.

## Build on a QNAP with QDK

Install and enable QDK, then run:

```sh
CLEARPOCKET_SERVER_IMAGE_DIGEST=sha256:RELEASE_DIGEST \
  ./build.sh 0.9.0 /path/to/qbuild
```

When the full server version is longer than QDK's ten-character `QPKG_VER` field, provide a distinct,
stable package version without changing the embedded server version or immutable image identity:

```sh
CLEARPOCKET_QPKG_VERSION=0.9.0b1 \
CLEARPOCKET_SERVER_IMAGE_DIGEST=sha256:RELEASE_DIGEST \
  ./build.sh 0.9.0-beta.1 /path/to/qbuild
```

QDK limits `QPKG_VER` to ten characters. The script stages a clean QDK project, inserts the shared
versioned server bundle, embeds the exact published multi-architecture server-image digest, and invokes
QDK's `qbuild`. First start and explicit upgrades pull that digest and only then assign the local tag
used by Compose. An engineering build may omit the digest, but it is not a customer release. Do not
build from a working directory containing a private `.env`.

App Center installation never waits synchronously for the first container-image download. QTS starts
a single tracked background worker, completes the QPKG transaction, and records `queued`,
`downloading`, `starting`, `running`, `stopped`, or `failed` under the private operations directory.
The worker is detached with POSIX shell signal handling and redirected standard streams rather than
depending on the optional `nohup` utility, which is absent on current QuTS hero installations.
It changes into the persistent installed server directory before downloading or launching anything,
and every Compose invocation repeats that anchor. QDK may therefore remove its temporary installer
working directory without invalidating a long-running first start.
QNAP packages publish the API on port `18080` by default because QTS commonly owns port `8080`.
Upgrading a beta installation with the package-generated `8080` setting migrates that setting
atomically to `18080`; custom non-`8080` ports and all private authority data remain unchanged.
The manager's `status` and `logs` commands expose that bounded startup state and log without revealing
secrets. Stopping the package records cancellation so an in-flight download cannot launch containers
after the administrator has requested a stop.

The server-image workflow pins QDK 2.5.3 by immutable commit and, when that independent toolchain build
succeeds, uploads an explicitly named unsigned QPKG for hardware acceptance. A QDK outage cannot block
the Docker/Windows release, and this artifact is never attached to customer GitHub releases. QNAP
signing and real supported-model acceptance remain mandatory before relabeling or publishing it as a
customer download.

App Center asks which storage volume should host the package and supports later package migration
through the [QDK volume-selection contract](https://github.com/qnap-dev/QDK/blob/master/docs/QDK-Developer-Guide.md#version--platform-gating).
For a fresh install, ClearPocket creates a private `ClearPocketServerData` directory directly on that
selected volume rather than placing financial authority inside the NAS Public share. The durable path
remains outside the replaceable QPKG directory, is recorded in the owner-only system pointer, and is
not removed with the package. Existing installations continue using their recorded data root without
an implicit move. Setup generates independent database/JWT/attachment secrets from `/dev/urandom`
and refuses to replace an existing `.env`.

An administrator can copy an iPhone `.clearpocketbackup` package into a protected QNAP shared folder
and authenticate it without touching the server authority:

```sh
/etc/init.d/ClearPocketServer.sh verify-local-device \
  /share/Private/generation.clearpocketbackup
```

To initialize a **new empty** QNAP server from that verified phone authority, repeat with the explicit
`IMPORT` confirmation:

```sh
/etc/init.d/ClearPocketServer.sh import-local-device \
  /share/Private/generation.clearpocketbackup IMPORT
```

Both operations mount the source package read-only and perform authentication/decryption in disposable
container staging. Import stops the API, starts only PostgreSQL, requires empty database and attachment
destinations, compares exact financial observations, and restarts the server only after success. A
failure leaves the API stopped for inspection and never modifies the phone backup. This remains an
administrator action while the graphical import/restore workflow is completed.

## QTS management interface

Open **ClearPocket Server** from the QTS administrator desktop. Like other server applications, its
manager opens in a normal browser tab rather than a QTS desktop iframe. Every request validates the
current QTS session through QNAP's local authentication endpoint and requires `isAdmin=1`; a direct
anonymous request is rejected before the manager reads its CSRF token or invokes any service command.
Validation uses QNAP's documented SID-login contract without attempting to bind the check to the
CGI peer address, which may be a QuTS reverse-proxy address rather than the administrator's client.
Session validation discovers QNAP's available HTTPS client at runtime and supports native `curl`,
native `wget`, or the firmware's BusyBox `wget`; it does not weaken authentication when one particular
binary path is absent.
The package declares HTTP unsupported and uses the QTS system HTTPS port, preventing App Center from
constructing an unreachable or downgrade-prone plain-HTTP management link on HTTPS-only systems.
Because current QuTS hero may nevertheless construct an external App Center link on its HTTP port,
the CGI performs an immediate no-cache redirect to the same NAS's HTTPS endpoint before reading any
session or management state. Secure QTS session cookies are therefore never requested over HTTP.
The manager shows the installed
server version, NAS host, container status, health output, recent bounded logs, and backup schedule
state. It can create an encrypted backup or restart the ClearPocket containers. Its terminal-style
command field deliberately accepts only these exact commands:

```text
help
status
health
version
logs
backup
restart
backup-schedule-status
```

It is not a general NAS shell. The CGI never evaluates user input, POST actions require an
installation-specific CSRF token, command output is HTML-escaped, responses are not cached, and the
QPKG is registered as visible to QTS administrators only. Use SSH for NAS administration outside
ClearPocket. QTS/QuTS hero hardware acceptance must confirm the platform's administrator-session
enforcement at the `/cgi-bin/qpkg/ClearPocketServer` boundary before the package is promoted beyond
beta.

A provider-neutral encrypted archive from another ClearPocket Server can initialize the same empty
QNAP destination. Use the separately retained age identity, or `-` for a passphrase archive:

```sh
/etc/init.d/ClearPocketServer.sh import-portable \
  /share/Private/budget-portable-YYYYMMDDTHHMMSSZ.tar.gz.age \
  /share/Private/portable-age-identity.txt IMPORT
```

The archive and identity are mounted read-only. Decryption, completeness validation, password prompts,
empty-destination enforcement, attachment re-encryption, exact financial observation comparison, and
the final health gate all execute in the version-matched application container. Failure leaves the API
stopped and does not alter either source file.

The QPKG can create a coordinated encrypted backup without installing Python or `age` on the NAS:

```sh
/etc/init.d/ClearPocketServer.sh backup
```

The first run generates `recovery/clearpocket-recovery-key.txt` under the durable data root and stores
only its public age recipient in `.env`. Copy the identity immediately to a separate protected device
or offline location; keeping its only copy on the NAS does not protect against disk or NAS loss. The
backup helper prevents overlapping captures, briefly pauses the API, captures PostgreSQL and encrypted
attachments under the canonical integrity manifest, resumes the API, encrypts and atomically publishes
to the durable `backups` directory, and records owner-visible health. It removes partial output and
records failure if capture or publication does not finish. Completed local generations retain the ten
newest by default; an administrator may set `BUDGET_APP_BACKUP_RETENTION` to another positive count in
the private `.env`. Rotation runs only after the new generation and health record succeed and touches
only completed `budget-*.tar.gz.age` files.

The command-line package path can publish every completed generation off-NAS to a least-privilege
Dropbox app folder. Create a regular `0600` file named `dropbox.env` in the durable data root selected
during install. It must contain either `BUDGET_APP_DROPBOX_ACCESS_TOKEN`, or
`BUDGET_APP_DROPBOX_REFRESH_TOKEN` plus `BUDGET_APP_DROPBOX_APP_KEY` and the optional app secret.
The file is mounted read-only and parsed without shell execution. Set `BUDGET_APP_DROPBOX_FOLDER` in
the private server `.env` to change `/Backups`. Manual and scheduled capture retain the local encrypted
generation first, verify Dropbox size/content hash before promotion, and apply the same bounded
retention remotely. Publication failure records `publication_failed`, preserves the local generation,
and makes the scheduled action fail visibly. Keep the age identity off the NAS and outside Dropbox.
Graphical Dropbox setup remains part of the normal-user QNAP manager work.

After one successful manual backup has created and validated the recovery identity, an administrator
can install a persistent daily QNAP schedule. For example, run at 03:15:

```sh
/etc/init.d/ClearPocketServer.sh install-backup-schedule 3 15
/etc/init.d/ClearPocketServer.sh backup-schedule-status
```

Remove only the schedule—never its generations or recovery identity—with:

```sh
/etc/init.d/ClearPocketServer.sh remove-backup-schedule
```

The installer validates the hour/minute and recovery setup, replaces only the marked ClearPocket cron
entry, keeps credentials out of cron, atomically updates `/etc/config/crontab`, and restores the prior
file if QNAP rejects the reload. The entry calls the package by absolute path and becomes harmless if
that executable is absent. The backup's own lock prevents overlaps after delayed boots or long runs.
Remove the schedule before uninstalling the preview QPKG so the marker does not remain in QNAP cron.

Restore is intentionally limited to a newly installed, empty QNAP authority. Copy both a completed
generation and its separately retained age identity into a protected QNAP share, then invoke:

```sh
/etc/init.d/ClearPocketServer.sh restore \
  /share/Private/budget-YYYYMMDDTHHMMSSZ.tar.gz.age \
  /share/Private/clearpocket-recovery-key.txt RESTORE
```

The helper mounts both inputs read-only, decrypts and validates the complete integrity manifest in
private durable staging, and refuses a populated database or attachment store both before and after
stopping the API. Only an empty destination adopts the authenticated attachment key. Attachment
objects and the SQL guard/restore are then installed through the version-matched containers, recovery
health is recorded, and service resumes only after the real API health check passes. Any failure keeps
the API stopped for inspection and never modifies the source archive or identity. No host Python,
PostgreSQL client, or `age` installation is required.

When a newer signed/versioned QPKG has replaced the package files, apply its pinned server image with:

```sh
/etc/init.d/ClearPocketServer.sh upgrade UPGRADE
```

The service refuses an unpinned or unchanged version, completes an encrypted generation first, pulls
the exact new image before atomically changing only the version setting, and then requires the real API
health gate. Pull failure leaves both configuration and running services untouched. If a new image has
run forward migrations but fails health, the API remains stopped and the version is not silently
downgraded against the newer database; recover the preserved generation into a new empty authority.

Before this package is customer-ready, the hardware-acceptance artifact still needs QNAP signing,
a supported-model matrix, graphical first-run host/TLS and import/restore workflows, and validation
of the new manager on current QTS and QuTS hero. Until those gates pass, prefer the documented
Container Station import path.
