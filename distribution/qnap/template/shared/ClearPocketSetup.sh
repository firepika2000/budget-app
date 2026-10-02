#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /share/path/ClearPocketServer" >&2
    exit 2
fi

DATA_ROOT=$1
SHARE_ROOT=${CLEARPOCKET_QNAP_SHARE_ROOT:-/share}
case "$DATA_ROOT" in
    "$SHARE_ROOT"/*) ;;
    *) echo "ClearPocket data must be stored in a QNAP shared folder" >&2; exit 2 ;;
esac

SCRIPT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION_FILE="$SCRIPT_ROOT/server/VERSION"
if [ ! -r "$VERSION_FILE" ]; then
    echo "ClearPocket package version is missing" >&2
    exit 1
fi
SERVER_VERSION=$(tr -d '\r\n' < "$VERSION_FILE")
case "$SERVER_VERSION" in
    ''|*[!A-Za-z0-9._-]*) echo "ClearPocket package version is invalid" >&2; exit 1 ;;
esac

HOST_NAME=$(/bin/hostname 2>/dev/null || hostname 2>/dev/null || true)
case "$HOST_NAME" in
    ''|*[!A-Za-z0-9.-]*) HOST_NAME=localhost ;;
esac

BASE64=$(command -v base64 || true)
if [ -z "$BASE64" ] || [ ! -r /dev/urandom ]; then
    echo "QNAP cryptographic random/base64 tools are unavailable" >&2
    exit 1
fi

random_secret() {
    count=$1
    value=$(dd if=/dev/urandom bs=1 count="$count" 2>/dev/null | "$BASE64" | tr '+/' '-_' | tr -d '\r\n')
    [ "${#value}" -ge "$count" ] || {
        echo "Unable to generate private server secrets" >&2
        exit 1
    }
    printf '%s' "$value"
}

mkdir -p "$DATA_ROOT/database" "$DATA_ROOT/attachments" "$DATA_ROOT/operations"
ENV_FILE="$DATA_ROOT/.env"
if [ -e "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || {
        echo "Existing ClearPocket configuration is not a regular file" >&2
        exit 1
    }
    [ "$(grep -c '^CLEARPOCKET_SERVER_VERSION=' "$ENV_FILE")" = "1" ] || {
        echo "Existing ClearPocket server version configuration is invalid" >&2
        exit 1
    }
    [ "$(grep -c '^CLEARPOCKET_PORT=' "$ENV_FILE")" = "1" ] || {
        echo "Existing ClearPocket port configuration is invalid" >&2
        exit 1
    }
    CURRENT_PORT=$(sed -n 's/^CLEARPOCKET_PORT=//p' "$ENV_FILE")
    case "$CURRENT_PORT" in
        8080) TARGET_PORT=18080 ;;
        *) TARGET_PORT=$CURRENT_PORT ;;
    esac
    MIGRATED="$DATA_ROOT/.env.migrate.$$"
    trap 'rm -f "$MIGRATED"' EXIT HUP INT TERM
    awk -v version="CLEARPOCKET_SERVER_VERSION=$SERVER_VERSION" \
        -v port="CLEARPOCKET_PORT=$TARGET_PORT" '
        /^CLEARPOCKET_SERVER_VERSION=/ { print version; next }
        /^CLEARPOCKET_PORT=/ { print port; next }
        { print }
    ' "$ENV_FILE" > "$MIGRATED"
    chmod 600 "$MIGRATED"
    mv "$MIGRATED" "$ENV_FILE"
    trap - EXIT HUP INT TERM
    if [ "$CURRENT_PORT" = "8080" ]; then
        echo "Existing private ClearPocket configuration preserved; QTS-conflicting port 8080 migrated to 18080."
    else
        echo "Existing private ClearPocket configuration preserved."
    fi
    exit 0
fi

TEMPORARY="$DATA_ROOT/.env.tmp.$$"
trap 'rm -f "$TEMPORARY"' EXIT HUP INT TERM
DATABASE_SECRET=$(random_secret 36)
JWT_SECRET=$(random_secret 48)
ATTACHMENT_KEY=$(random_secret 32)

{
    printf 'CLEARPOCKET_SERVER_IMAGE=ghcr.io/firepika2000/budget-server\n'
    printf 'CLEARPOCKET_SERVER_VERSION=%s\n' "$SERVER_VERSION"
    printf 'CLEARPOCKET_BIND_ADDRESS=0.0.0.0\n'
    printf 'CLEARPOCKET_PORT=18080\n'
    printf 'CLEARPOCKET_DATABASE_STORAGE=%s/database\n' "$DATA_ROOT"
    printf 'CLEARPOCKET_ATTACHMENTS_STORAGE=%s/attachments\n' "$DATA_ROOT"
    printf 'CLEARPOCKET_OPERATIONS_STORAGE=%s/operations\n' "$DATA_ROOT"
    printf 'BUDGET_APP_ALLOWED_HOSTS=%s,localhost,127.0.0.1\n' "$HOST_NAME"
    printf 'BUDGET_APP_DB_PASSWORD=%s\n' "$DATABASE_SECRET"
    printf 'BUDGET_APP_JWT_SECRET=%s\n' "$JWT_SECRET"
    printf 'BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s\n' "$ATTACHMENT_KEY"
} > "$TEMPORARY"
chmod 600 "$TEMPORARY"
mv "$TEMPORARY" "$ENV_FILE"
trap - EXIT HUP INT TERM
unset DATABASE_SECRET JWT_SECRET ATTACHMENT_KEY
echo "Private ClearPocket configuration created without displaying secrets."
