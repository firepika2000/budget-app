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

upgrade_server() {
    [ "$1" = "UPGRADE" ] || {
        log_error "QNAP update requires the explicit final argument UPGRADE"
        return 1
    }
    VERSION_FILE="$SERVER_ROOT/VERSION"
    [ -f "$VERSION_FILE" ] && [ ! -L "$VERSION_FILE" ] || {
        log_error "Versioned QNAP server bundle is incomplete"
        return 1
    }
    VERSION=$(cat "$VERSION_FILE")
    case "$VERSION" in ''|edge|*[!A-Za-z0-9._-]*) log_error "QNAP server version is not an immutable release"; return 1 ;; esac
    [ "${#VERSION}" -le 63 ] || { log_error "QNAP server version is invalid"; return 1; }
    CURRENT=$(sed -n 's/^CLEARPOCKET_SERVER_VERSION=//p' "$ENV_FILE")
    [ "$(grep -c '^CLEARPOCKET_SERVER_VERSION=' "$ENV_FILE")" = "1" ] || {
        log_error "Private configuration has an ambiguous server version"
        return 1
    }
    [ "$CURRENT" != "$VERSION" ] || {
        echo "ClearPocket Server is already configured for version $VERSION."
        return 0
    }
    IMAGE=$(sed -n 's/^CLEARPOCKET_SERVER_IMAGE=//p' "$ENV_FILE")
    [ "$(grep -c '^CLEARPOCKET_SERVER_IMAGE=' "$ENV_FILE")" = "1" ] && [ -n "$IMAGE" ] || {
        log_error "Private configuration has an ambiguous server image"
        return 1
    }
    [ -x "$QPKG_ROOT/ClearPocketBackup.sh" ] || { log_error "QNAP backup helper is missing"; return 1; }
    echo "Creating the required encrypted pre-update generation."
    "$QPKG_ROOT/ClearPocketBackup.sh" "$CLEARPOCKET_DATA_ROOT" "$DOCKER" "$SERVER_ROOT" || return 1
    "$DOCKER" pull "$IMAGE:$VERSION" || {
        log_error "Version $VERSION could not be downloaded; configuration and running services were not changed"
        return 1
    }
    TEMP_ENV="$ENV_FILE.update.$$"
    awk -v replacement="CLEARPOCKET_SERVER_VERSION=$VERSION" '
        BEGIN { count = 0 }
        /^CLEARPOCKET_SERVER_VERSION=/ { print replacement; count += 1; next }
        { print }
        END { if (count != 1) exit 42 }
    ' "$ENV_FILE" > "$TEMP_ENV" || {
        rm -f "$TEMP_ENV"
        log_error "Private server version could not be updated"
        return 1
    }
    if ! chmod 600 "$TEMP_ENV" || ! mv "$TEMP_ENV" "$ENV_FILE"; then
        rm -f "$TEMP_ENV"
        log_error "Private server version could not be published"
        return 1
    fi
    if ! compose up -d || ! wait_healthy; then
        compose stop api >/dev/null 2>&1 || true
        log_error "Version $VERSION did not become healthy. The pre-update backup was preserved; automatic downgrade is disabled after migrations."
        return 1
    fi
    echo "ClearPocket Server updated and healthy at version $VERSION."
}

find_crontab() {
    command -v crontab 2>/dev/null && return 0
    [ -x /usr/bin/crontab ] && { echo /usr/bin/crontab; return 0; }
    [ -x /bin/crontab ] && { echo /bin/crontab; return 0; }
    return 1
}

update_backup_schedule() {
    mode=$1
    hour=${2:-}
    minute=${3:-}
    CRON_FILE=/etc/config/crontab
    CRONTAB=$(find_crontab) || { log_error "QNAP crontab command is unavailable"; return 1; }
    [ -f "$CRON_FILE" ] && [ ! -L "$CRON_FILE" ] || { log_error "QNAP crontab configuration is invalid"; return 1; }
    if [ "$mode" = install ]; then
        case "$hour" in ''|*[!0-9]*) log_error "Backup hour must be 0 through 23"; return 1 ;; esac
        case "$minute" in ''|*[!0-9]*) log_error "Backup minute must be 0 through 59"; return 1 ;; esac
        [ "$hour" -le 23 ] && [ "$minute" -le 59 ] || { log_error "Backup time is invalid"; return 1; }
        [ -f "$CLEARPOCKET_DATA_ROOT/recovery/clearpocket-recovery-key.txt" ] || {
            log_error "Create one successful manual backup before enabling the schedule"
            return 1
        }
        [ "$(grep -c '^BUDGET_APP_BACKUP_AGE_RECIPIENT=' "$ENV_FILE")" = "1" ] || {
            log_error "Backup recovery recipient is not configured"
            return 1
        }
    fi
    ORIGINAL="$CRON_FILE.clearpocket-original.$$"
    TEMPORARY="$CRON_FILE.clearpocket-new.$$"
    cp "$CRON_FILE" "$ORIGINAL" || return 1
    trap 'rm -f "$ORIGINAL" "$TEMPORARY"' EXIT
    trap 'exit 1' HUP INT TERM
    if ! awk 'index($0, "# ClearPocketServerBackup") == 0' "$CRON_FILE" > "$TEMPORARY"; then
        rm -f "$ORIGINAL" "$TEMPORARY"
        return 1
    fi
    if [ "$mode" = install ]; then
        printf '%s %s * * * test ! -x "%s/ClearPocketServer.sh" || "%s/ClearPocketServer.sh" backup >/dev/null 2>&1 # ClearPocketServerBackup\n' \
            "$minute" "$hour" "$QPKG_ROOT" "$QPKG_ROOT" >> "$TEMPORARY"
    fi
    chmod 600 "$TEMPORARY"
    mv "$TEMPORARY" "$CRON_FILE"
    if ! "$CRONTAB" "$CRON_FILE"; then
        mv "$ORIGINAL" "$CRON_FILE"
        "$CRONTAB" "$CRON_FILE" >/dev/null 2>&1 || true
        log_error "QNAP rejected the backup schedule; the prior crontab was restored"
        return 1
    fi
    rm -f "$ORIGINAL"
    trap - EXIT HUP INT TERM
    if [ "$mode" = install ]; then
        echo "Daily encrypted backup scheduled for hour $hour, minute $minute."
    else
        echo "Scheduled ClearPocket backup removed. Existing generations were preserved."
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
    backup)
        [ "$#" -eq 1 ] || { echo "Usage: $0 backup" >&2; exit 2; }
        [ -x "$QPKG_ROOT/ClearPocketBackup.sh" ] || { log_error "QNAP backup helper is missing"; exit 1; }
        "$QPKG_ROOT/ClearPocketBackup.sh" "$CLEARPOCKET_DATA_ROOT" "$DOCKER" "$SERVER_ROOT"
        ;;
    restore)
        [ "$#" -eq 4 ] || { echo "Usage: $0 restore /share/path/backup.tar.gz.age /share/path/identity.txt RESTORE" >&2; exit 2; }
        [ "$4" = "RESTORE" ] || { log_error "QNAP recovery requires the explicit final argument RESTORE"; exit 1; }
        [ -x "$QPKG_ROOT/ClearPocketRestore.sh" ] || { log_error "QNAP recovery helper is missing"; exit 1; }
        "$QPKG_ROOT/ClearPocketRestore.sh" "$CLEARPOCKET_DATA_ROOT" "$DOCKER" "$SERVER_ROOT" "$2" "$3"
        ;;
    upgrade)
        [ "$#" -eq 2 ] || { echo "Usage: $0 upgrade UPGRADE" >&2; exit 2; }
        upgrade_server "$2"
        ;;
    install-backup-schedule)
        [ "$#" -eq 3 ] || { echo "Usage: $0 install-backup-schedule HOUR MINUTE" >&2; exit 2; }
        update_backup_schedule install "$2" "$3"
        ;;
    remove-backup-schedule)
        [ "$#" -eq 1 ] || { echo "Usage: $0 remove-backup-schedule" >&2; exit 2; }
        update_backup_schedule remove
        ;;
    backup-schedule-status)
        [ "$#" -eq 1 ] || { echo "Usage: $0 backup-schedule-status" >&2; exit 2; }
        grep '# ClearPocketServerBackup$' /etc/config/crontab || echo "No ClearPocket backup schedule is installed."
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
        echo "Usage: $0 {start|stop|restart|status|backup|restore|upgrade|install-backup-schedule|remove-backup-schedule|backup-schedule-status|verify-local-device|import-local-device}" >&2
        exit 2
        ;;
esac
