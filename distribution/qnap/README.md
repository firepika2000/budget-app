# ClearPocket Server QNAP package source

This directory builds a QDK/QPKG wrapper around the same server bundle used by Docker Engine and
Windows. It follows QNAP's package lifecycle rather than creating a separate server implementation.

The package is currently an engineering preview. It provides App Center install, enable/start,
disable/stop, restart, and status integration. Customer authority is deliberately external to the
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

Before this package is customer-ready it still needs the signed QPKG release pipeline, supported-model
matrix, a no-SSH first-run storage/host/TLS setup screen, and hardware validation on current QTS and
QuTS hero. Until those gates pass, prefer the documented Container Station import path.
