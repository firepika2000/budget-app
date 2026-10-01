# ClearPocket Server QNAP package source

This directory builds a QDK/QPKG wrapper around the same server bundle used by Docker Engine and
Windows. It follows QNAP's package lifecycle rather than creating a separate server implementation.

The package is currently an engineering preview. It provides App Center install, cryptographic
no-overwrite first-run configuration, enable/start, disable/stop, restart, and status integration.
Customer authority is deliberately external to the
replaceable QPKG directory: `/etc/config/clearpocket-server.conf` points to a durable QNAP shared-folder
deployment root containing `.env`, PostgreSQL data, and encrypted attachments. Package removal does
not delete that root or its configuration pointer.

## Build on a QNAP with QDK

Install and enable QDK, then run:

```sh
./build.sh 0.9.0 /path/to/qbuild
```

QDK limits `QPKG_VER` to ten characters. The script stages a clean QDK project, inserts the shared
versioned server bundle, and invokes QDK's `qbuild`. Do not build from a working directory containing
a private `.env`.

The installer chooses the QNAP Public share as its initial durable root, generates independent
database/JWT/attachment secrets from `/dev/urandom`, and refuses to replace an existing `.env`.

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
administrator action pending the graphical QNAP setup/restore surface.

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
only completed `budget-*.tar.gz.age` files. Graphical schedule controls and off-NAS/Dropbox publication
remain part of the graphical QNAP management work.

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

Before this package is customer-ready it still needs the signed QPKG release pipeline, supported-model
matrix, a graphical first-run storage/host/TLS setup screen, and hardware validation on current QTS and
QuTS hero. Until those gates pass, prefer the documented Container Station import path.
