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
    *)
        echo "Usage: $0 {start|stop|restart|status}" >&2
        exit 2
        ;;
esac
