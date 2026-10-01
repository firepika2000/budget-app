#!/bin/sh

QPKG_NAME=ClearPocketServer
SYSTEM_CONFIG=/etc/config/clearpocket-server.conf
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
SERVER_ROOT="$QPKG_ROOT/server"

log_error() {
    /sbin/log_tool -t 2 -a "ClearPocket Server: $1" >/dev/null 2>&1 || echo "$1" >&2
}

if [ ! -r "$SYSTEM_CONFIG" ]; then
    log_error "persistent deployment configuration is missing"
    exit 1
fi

# Parse the single allowed setting instead of sourcing shell content into this privileged process.
CLEARPOCKET_DATA_ROOT=$(sed -n 's/^CLEARPOCKET_DATA_ROOT=//p' "$SYSTEM_CONFIG")
[ "$(grep -c '^CLEARPOCKET_DATA_ROOT=' "$SYSTEM_CONFIG")" = "1" ] || {
    log_error "persistent deployment configuration is invalid"
    exit 1
}
# The installer creates this root outside the QPKG so an upgrade/removal cannot erase customer data.
case "$CLEARPOCKET_DATA_ROOT" in
    /share/*) ;;
    *) log_error "persistent data root is invalid"; exit 1 ;;
esac

ENV_FILE="$CLEARPOCKET_DATA_ROOT/.env"
if [ ! -r "$ENV_FILE" ]; then
    log_error "first-run setup is incomplete; private .env is missing from the persistent data root"
    exit 1
fi

find_docker() {
    command -v docker 2>/dev/null && return 0
    CONTAINER_ROOT=$(/sbin/getcfg container-station Install_Path -f /etc/config/qpkg.conf)
    [ -n "$CONTAINER_ROOT" ] || CONTAINER_ROOT=$(/sbin/getcfg ContainerStation Install_Path -f /etc/config/qpkg.conf)
    for candidate in "$CONTAINER_ROOT/bin/docker" "$CONTAINER_ROOT/usr/bin/docker"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

DOCKER=$(find_docker) || {
    log_error "Container Station Docker command is unavailable"
    exit 1
}

compose() {
    "$DOCKER" compose --project-directory "$SERVER_ROOT" --env-file "$ENV_FILE" \
        -f "$SERVER_ROOT/compose.yaml" "$@"
}

wait_healthy() {
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        if compose exec -T api python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/v1/health', timeout=3)" \
            >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

local_device_package() {
    PACKAGE=$1
    case "$PACKAGE" in
        /share/*) ;;
        *) log_error "Local Device backup must be inside a QNAP shared folder"; return 1 ;;
    esac
    if [ ! -d "$PACKAGE" ] || [ -L "$PACKAGE" ] || [ ! -f "$PACKAGE/manifest.json" ] || [ -L "$PACKAGE/manifest.json" ]; then
        log_error "Local Device backup must be a complete regular non-linked package folder"
        return 1
    fi
    printf '%s' "$PACKAGE"
}

verify_local_device() {
    PACKAGE=$(local_device_package "$1") || return 1
    compose run --rm --no-deps --user root \
        --volume "$PACKAGE:/import/package:ro" api sh -c \
        "cp -R /import/package /tmp/local-device-package && \
         chown -R budget:budget /tmp/local-device-package && \
         exec su -s /bin/sh budget -c 'python scripts/local_device_transfer.py /tmp/local-device-package'"
}

import_local_device() {
    PACKAGE=$(local_device_package "$1") || return 1
    [ "$2" = "IMPORT" ] || {
        log_error "Local Device import requires the explicit final argument IMPORT"
        return 1
    }
    compose stop api || return 1
    compose up -d database || return 1
    if compose run --rm --no-deps --user root \
        --volume "$PACKAGE:/import/package:ro" api sh -c \
        "cp -R /import/package /tmp/local-device-package && \
         chown -R budget:budget /tmp/local-device-package && \
         exec su -s /bin/sh budget -c 'alembic upgrade head && \
         python scripts/local_device_transfer.py /tmp/local-device-package --server-environment'"; then
        if ! compose up -d || ! wait_healthy; then
            compose stop api >/dev/null 2>&1 || true
            log_error "Imported authority committed, but the API did not become healthy and remains stopped"
            return 1
        fi
        echo "Local Device household imported; ClearPocket Server restarted."
    else
        log_error "Local Device import failed; the API remains stopped and the phone backup was not changed"
        return 1
    fi
}

case "$1" in
    start)
        compose config --quiet && compose up -d
        ;;
    stop)
        # Stop is intentionally non-destructive and never removes persistent volumes.
        compose stop
        ;;
    restart)
        compose stop && compose config --quiet && compose up -d
        ;;
    status)
        compose ps
        ;;
    verify-local-device)
        [ "$#" -eq 2 ] || { echo "Usage: $0 verify-local-device /share/path/generation.clearpocketbackup" >&2; exit 2; }
        verify_local_device "$2"
        ;;
    import-local-device)
        [ "$#" -eq 3 ] || { echo "Usage: $0 import-local-device /share/path/generation.clearpocketbackup IMPORT" >&2; exit 2; }
        import_local_device "$2" "$3"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|verify-local-device|import-local-device}" >&2
        exit 2
        ;;
esac
