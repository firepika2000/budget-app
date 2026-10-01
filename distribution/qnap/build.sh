#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 VERSION [QBUILD]" >&2
    exit 2
fi

VERSION=$1
QBUILD=${2:-qbuild}
QPKG_VERSION=${CLEARPOCKET_QPKG_VERSION:-$VERSION}
case "$VERSION" in
    *[!A-Za-z0-9._-]*|'') echo "Invalid QPKG version" >&2; exit 2 ;;
esac
case "$QPKG_VERSION" in
    *[!A-Za-z0-9._-]*|'') echo "Invalid QNAP package version" >&2; exit 2 ;;
esac
if [ "${#QPKG_VERSION}" -gt 10 ]; then
    echo "QDK QPKG versions must be at most 10 characters" >&2
    exit 2
fi
command -v "$QBUILD" >/dev/null 2>&1 || {
    echo "QDK qbuild was not found" >&2
    exit 2
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
IMAGE_DIGEST=${CLEARPOCKET_SERVER_IMAGE_DIGEST:-}
if [ -n "$IMAGE_DIGEST" ]; then
    case "$IMAGE_DIGEST" in sha256:*) ;; *) echo "Invalid server image digest" >&2; exit 2 ;; esac
    DIGEST_VALUE=${IMAGE_DIGEST#sha256:}
    case "$DIGEST_VALUE" in *[!0-9a-f]*) echo "Invalid server image digest" >&2; exit 2 ;; esac
    [ "${#DIGEST_VALUE}" = "64" ] || { echo "Invalid server image digest" >&2; exit 2; }
fi
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/clearpocket-qpkg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

mkdir -p "$STAGE/shared/server"
awk -v version="$QPKG_VERSION" '{ gsub(/@VERSION@/, version); print }' \
    "$SCRIPT_DIR/template/qpkg.cfg" > "$STAGE/qpkg.cfg"
cp "$SCRIPT_DIR/template/package_routines" "$STAGE/package_routines"
cp "$SCRIPT_DIR/template/shared/ClearPocketServer.sh" "$STAGE/shared/ClearPocketServer.sh"
cp "$SCRIPT_DIR/template/shared/ClearPocketSetup.sh" "$STAGE/shared/ClearPocketSetup.sh"
cp "$SCRIPT_DIR/template/shared/ClearPocketBackup.sh" "$STAGE/shared/ClearPocketBackup.sh"
cp "$SCRIPT_DIR/template/shared/ClearPocketRestore.sh" "$STAGE/shared/ClearPocketRestore.sh"
cp "$PROJECT_ROOT/distribution/server/compose.yaml" \
   "$PROJECT_ROOT/distribution/server/Caddyfile" \
   "$PROJECT_ROOT/distribution/server/Caddyfile.qnap" \
   "$PROJECT_ROOT/distribution/server/configure.py" \
   "$PROJECT_ROOT/distribution/server/manage.py" \
   "$PROJECT_ROOT/distribution/server/.env.example" \
   "$PROJECT_ROOT/distribution/server/README.md" \
   "$STAGE/shared/server/"
mkdir -p "$STAGE/shared/server/tools"
cp "$PROJECT_ROOT/server/scripts/backup.sh" \
   "$PROJECT_ROOT/server/scripts/restore.sh" \
   "$PROJECT_ROOT/server/scripts/backup_archive.py" \
   "$PROJECT_ROOT/server/scripts/backup_destination.py" \
   "$PROJECT_ROOT/server/scripts/backup_schedule.py" \
   "$PROJECT_ROOT/server/scripts/require_empty_restore.sql" \
   "$STAGE/shared/server/tools/"
printf '%s\n' "$VERSION" > "$STAGE/shared/server/VERSION"
if [ -n "$IMAGE_DIGEST" ]; then
    SOURCE_COMMIT=${CLEARPOCKET_SOURCE_COMMIT:-$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)}
    printf 'version=%s\ncommit=%s\nimage=ghcr.io/firepika2000/budget-server@%s\n' \
        "$VERSION" "$SOURCE_COMMIT" "$IMAGE_DIGEST" > "$STAGE/shared/server/RELEASE-METADATA.txt"
fi
chmod 755 "$STAGE/shared/ClearPocketServer.sh" "$STAGE/shared/ClearPocketSetup.sh" \
    "$STAGE/shared/ClearPocketBackup.sh" \
    "$STAGE/shared/ClearPocketRestore.sh" \
    "$STAGE/shared/server/manage.py" \
    "$STAGE/shared/server/configure.py" "$STAGE/shared/server/tools/backup.sh" \
    "$STAGE/shared/server/tools/restore.sh"

(cd "$STAGE" && "$QBUILD")
mkdir -p "$SCRIPT_DIR/build"
cp "$STAGE"/build/*.qpkg "$SCRIPT_DIR/build/"
echo "QPKG written to $SCRIPT_DIR/build"
