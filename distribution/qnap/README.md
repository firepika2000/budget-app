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

Before this package is customer-ready it still needs the signed QPKG release pipeline, supported-model
matrix, a graphical first-run storage/host/TLS setup screen, and hardware validation on current QTS and
QuTS hero. Until those gates pass, prefer the documented Container Station import path.
