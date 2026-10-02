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

OPERATIONS_ROOT="$CLEARPOCKET_DATA_ROOT/operations"
STARTUP_LOCK="$OPERATIONS_ROOT/qnap-startup.lock"
STARTUP_PID="$STARTUP_LOCK/pid"
STARTUP_CANCEL="$OPERATIONS_ROOT/qnap-startup.cancel"
STARTUP_STATUS="$OPERATIONS_ROOT/qnap-startup.status"
STARTUP_LOG="$OPERATIONS_ROOT/qnap-startup.log"
mkdir -p "$OPERATIONS_ROOT"
chmod 700 "$OPERATIONS_ROOT"

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

ensure_release_image() {
    VERSION=$1
    IMAGE=$2
    METADATA="$SERVER_ROOT/RELEASE-METADATA.txt"
    [ -e "$METADATA" ] || return 0
    [ -f "$METADATA" ] && [ ! -L "$METADATA" ] || {
        log_error "QNAP release metadata is not a regular non-linked file"
        return 1
    }
    [ "$(grep -c '^version=' "$METADATA")" = "1" ] && \
        [ "$(sed -n 's/^version=//p' "$METADATA")" = "$VERSION" ] || {
        log_error "QNAP release metadata does not match the package version"
        return 1
    }
    [ "$(grep -c '^image=' "$METADATA")" = "1" ] || {
        log_error "QNAP release metadata has an ambiguous image digest"
        return 1
    }
    PINNED=$(sed -n 's/^image=//p' "$METADATA")
    PREFIX="$IMAGE@sha256:"
    case "$PINNED" in "$PREFIX"*) ;; *) log_error "QNAP release metadata has an unexpected image"; return 1 ;; esac
    DIGEST=${PINNED#"$PREFIX"}
    case "$DIGEST" in *[!0-9a-f]*) log_error "QNAP release metadata has an invalid image digest"; return 1 ;; esac
    [ "${#DIGEST}" = "64" ] || { log_error "QNAP release metadata has an invalid image digest"; return 1; }
    if ! "$DOCKER" image inspect "$PINNED" >/dev/null 2>&1; then
        "$DOCKER" pull "$PINNED" || {
            log_error "The immutable QNAP server image could not be downloaded"
            return 1
        }
    fi
    "$DOCKER" tag "$PINNED" "$IMAGE:$VERSION" || {
        log_error "The immutable QNAP server image could not be assigned its local version tag"
        return 1
    }
}

record_startup_status() {
    STATUS_TEMP="$STARTUP_STATUS.tmp.$$"
    printf '%s\n' "$1" > "$STATUS_TEMP"
    chmod 600 "$STATUS_TEMP"
    mv "$STATUS_TEMP" "$STARTUP_STATUS"
}

startup_in_progress() {
    [ -d "$STARTUP_LOCK" ] || return 1
    WORKER_PID=$(cat "$STARTUP_PID" 2>/dev/null || true)
    case "$WORKER_PID" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$WORKER_PID" 2>/dev/null
}

start_in_background() {
    if startup_in_progress; then
        echo "ClearPocket startup is already running in the background."
        return 0
    fi
    if [ -d "$STARTUP_LOCK" ] && [ ! -r "$STARTUP_PID" ]; then
        # A concurrent caller may observe the lock in the brief interval before its PID is written.
        sleep 1
        if startup_in_progress; then
            echo "ClearPocket startup is already running in the background."
            return 0
        fi
    fi
    rm -rf "$STARTUP_LOCK"
    mkdir "$STARTUP_LOCK" || {
        log_error "Unable to reserve the ClearPocket startup worker"
        return 1
    }
    chmod 700 "$STARTUP_LOCK"
    rm -f "$STARTUP_CANCEL"
    record_startup_status queued
    nohup "$0" startup-worker >> "$STARTUP_LOG" 2>&1 </dev/null &
    WORKER_PID=$!
    printf '%s\n' "$WORKER_PID" > "$STARTUP_PID"
    chmod 600 "$STARTUP_PID"
    echo "ClearPocket startup queued in the background. Use status or logs to follow progress."
}

run_startup_worker() {
    trap 'rm -rf "$STARTUP_LOCK"' EXIT HUP INT TERM
    echo "$(date '+%Y-%m-%d %H:%M:%S') ClearPocket startup began."
    record_startup_status downloading
    START_VERSION=$(tr -d '\r\n' < "$SERVER_ROOT/VERSION")
    START_IMAGE=$(sed -n 's/^CLEARPOCKET_SERVER_IMAGE=//p' "$ENV_FILE")
    if ! ensure_release_image "$START_VERSION" "$START_IMAGE"; then
        record_startup_status failed
        echo "ClearPocket startup failed while downloading the immutable server image."
        return 1
    fi
    if [ -e "$STARTUP_CANCEL" ]; then
        record_startup_status stopped
        echo "ClearPocket startup was stopped before containers were launched."
        return 0
    fi
    record_startup_status starting
    if ! compose config --quiet || ! compose up -d; then
        record_startup_status failed
        echo "ClearPocket startup failed while launching containers."
        return 1
    fi
    record_startup_status running
    echo "$(date '+%Y-%m-%d %H:%M:%S') ClearPocket containers launched."
}

show_startup_status() {
    if startup_in_progress; then
        printf 'ClearPocket startup: %s (background process %s)\n' \
            "$(cat "$STARTUP_STATUS" 2>/dev/null || echo working)" "$WORKER_PID"
    elif [ -r "$STARTUP_STATUS" ]; then
        printf 'ClearPocket startup: %s\n' "$(cat "$STARTUP_STATUS")"
    else
        echo "ClearPocket startup: not requested"
    fi
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

portable_archive() {
    ARCHIVE=$1
    IDENTITY=$2
    case "$ARCHIVE" in /share/*.tar.gz.age) ;; *) log_error "Portable archive must be a .tar.gz.age file in a QNAP shared folder"; return 1 ;; esac
    [ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || { log_error "Portable archive must be a regular non-linked file"; return 1; }
    set -- "run" "--rm" "--no-deps" "--user" "root" \
        "--volume" "$ARCHIVE:/import/archive.age:ro"
    PREPARE="install -m 600 -o budget -g budget /import/archive.age /tmp/archive.age"
    if [ "$IDENTITY" != "-" ]; then
        case "$IDENTITY" in /share/*) ;; *) log_error "Age identity must be in a QNAP shared folder"; return 1 ;; esac
        [ -f "$IDENTITY" ] && [ ! -L "$IDENTITY" ] || { log_error "Age identity must be a regular non-linked file"; return 1; }
        set -- "$@" "--volume" "$IDENTITY:/import/identity.txt:ro" \
            "--env" "BUDGET_APP_BACKUP_AGE_IDENTITY=/tmp/identity.txt"
        PREPARE="$PREPARE && install -m 600 -o budget -g budget /import/identity.txt /tmp/identity.txt"
    fi
    compose stop api || return 1
    compose up -d database || return 1
    if compose "$@" api sh -c \
        "$PREPARE && exec su -s /bin/sh budget -c 'alembic upgrade head && python scripts/portable_import.py /tmp/archive.age --server-environment'"; then
        if ! compose up -d || ! wait_healthy; then
            compose stop api >/dev/null 2>&1 || true
            log_error "Portable authority committed, but the API did not become healthy and remains stopped"
            return 1
        fi
        echo "Portable household imported and verified; all users must sign in again."
    else
        log_error "Portable import failed; the API remains stopped and source files were not changed"
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
    if [ -e "$SERVER_ROOT/RELEASE-METADATA.txt" ]; then
        ensure_release_image "$VERSION" "$IMAGE" || return 1
    else
        "$DOCKER" pull "$IMAGE:$VERSION" || {
            log_error "Version $VERSION could not be downloaded; configuration and running services were not changed"
            return 1
        }
    fi
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
        RETENTION=$(sed -n 's/^BUDGET_APP_BACKUP_RETENTION=//p' "$ENV_FILE")
        [ -n "$RETENTION" ] || RETENTION=10
        case "$RETENTION" in ''|*[!0-9]*) log_error "Backup retention is invalid"; return 1 ;; esac
        [ "$RETENTION" -ge 1 ] || { log_error "Backup retention is invalid"; return 1; }
    fi
    SCHEDULE_STATUS="$CLEARPOCKET_DATA_ROOT/operations/backup-schedule.json"
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
        STATUS_TEMPORARY="$SCHEDULE_STATUS.$$"
        umask 077
        printf '{"state":"enabled","provider":"qnap_cron","frequency":"daily","hour":%s,"minute":%s,"retention":%s,"updated_at":"%s"}\n' \
            "$hour" "$minute" "$RETENTION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$STATUS_TEMPORARY"
        mv "$STATUS_TEMPORARY" "$SCHEDULE_STATUS"
        compose exec -T -u root api chown budget:budget /var/lib/budget-app/operations/backup-schedule.json || {
            rm -f "$SCHEDULE_STATUS"
            ROLLBACK_TEMPORARY="$CRON_FILE.clearpocket-status-rollback.$$"
            awk 'index($0, "# ClearPocketServerBackup") == 0' "$CRON_FILE" > "$ROLLBACK_TEMPORARY" && \
                chmod 600 "$ROLLBACK_TEMPORARY" && mv "$ROLLBACK_TEMPORARY" "$CRON_FILE" && \
                "$CRONTAB" "$CRON_FILE" >/dev/null 2>&1 || true
            rm -f "$ROLLBACK_TEMPORARY"
            log_error "Backup schedule activation was rolled back because owner-visible status could not be published"
            return 1
        }
        echo "Daily encrypted backup scheduled for hour $hour, minute $minute."
    else
        rm -f "$SCHEDULE_STATUS"
        echo "Scheduled ClearPocket backup removed. Existing generations were preserved."
    fi
}

configure_qnap_https() {
    PUBLIC_HOST=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/\.$//')
    [ "$2" = "CONFIGURE" ] || {
        log_error "QNAP HTTPS setup requires the explicit final argument CONFIGURE"
        return 1
    }
    if ! printf '%s\n' "$PUBLIC_HOST" | awk -F. '
        NF < 2 { exit 1 }
        {
            numeric = 1
            for (i = 1; i <= NF; i++) {
                if (length($i) < 1 || length($i) > 63 ||
                    ($i !~ /^[a-z0-9][a-z0-9-]*[a-z0-9]$/ && $i !~ /^[a-z0-9]$/)) exit 1
                if ($i !~ /^[0-9]+$/) numeric = 0
            }
            if (numeric) exit 1
        }
    '; then
        log_error "Public host must be a fully qualified DNS hostname without a URL, path, or port"
        return 1
    fi
    case "$PUBLIC_HOST" in localhost|*.localhost) log_error "Public host cannot be localhost"; return 1 ;; esac

    for key in CLEARPOCKET_BIND_ADDRESS COMPOSE_PROFILES CLEARPOCKET_PUBLIC_HOST \
        CLEARPOCKET_QNAP_PROXY_PORT BUDGET_APP_ALLOWED_HOSTS BUDGET_APP_PAIRING_PUBLIC_URL \
        BUDGET_APP_FORWARDED_ALLOW_IPS; do
        [ "$(grep -c "^$key=" "$ENV_FILE")" -le 1 ] || {
            log_error "Private configuration contains duplicate $key settings"
            return 1
        }
    done

    TEMP_ENV="$ENV_FILE.qnap-https.$$"
    trap 'rm -f "$TEMP_ENV"' EXIT HUP INT TERM
    awk '
        !/^(CLEARPOCKET_BIND_ADDRESS|COMPOSE_PROFILES|CLEARPOCKET_PUBLIC_HOST|CLEARPOCKET_QNAP_PROXY_PORT|BUDGET_APP_ALLOWED_HOSTS|BUDGET_APP_PAIRING_PUBLIC_URL|BUDGET_APP_FORWARDED_ALLOW_IPS)=/ { print }
    ' "$ENV_FILE" > "$TEMP_ENV"
    {
        printf 'CLEARPOCKET_BIND_ADDRESS=127.0.0.1\n'
        printf 'COMPOSE_PROFILES=qnap-tls\n'
        printf 'CLEARPOCKET_PUBLIC_HOST=%s\n' "$PUBLIC_HOST"
        printf 'CLEARPOCKET_QNAP_PROXY_PORT=8443\n'
        printf 'BUDGET_APP_ALLOWED_HOSTS=%s,localhost,127.0.0.1\n' "$PUBLIC_HOST"
        printf 'BUDGET_APP_PAIRING_PUBLIC_URL=https://%s\n' "$PUBLIC_HOST"
        printf 'BUDGET_APP_FORWARDED_ALLOW_IPS=*\n'
    } >> "$TEMP_ENV"
    chmod 600 "$TEMP_ENV"
    "$DOCKER" compose --project-directory "$SERVER_ROOT" --env-file "$TEMP_ENV" \
        -f "$SERVER_ROOT/compose.yaml" config --quiet || {
        log_error "Generated QNAP HTTPS configuration is invalid; existing configuration was preserved"
        return 1
    }
    mv "$TEMP_ENV" "$ENV_FILE"
    trap - EXIT HUP INT TERM
    if ! compose up -d || ! wait_healthy; then
        log_error "HTTPS proxy configuration was saved, but services are not healthy; inspect Container Station logs"
        return 1
    fi
    echo "QNAP HTTPS bridge is ready on NAS loopback port 8443."
    echo "In QTS, proxy https://$PUBLIC_HOST:443 to http://127.0.0.1:8443 and assign its public certificate."
    echo "Raw API port 8080 is now bound to NAS loopback only."
}

case "$1" in
    start)
        # QTS invokes start synchronously during QPKG installation. An initial image pull can take
        # much longer than App Center's transaction window, so track it as a private background job.
        start_in_background
        ;;
    startup-worker)
        run_startup_worker
        ;;
    stop)
        # Stop is intentionally non-destructive and never removes persistent volumes.
        touch "$STARTUP_CANCEL"
        record_startup_status stopped
        compose stop
        ;;
    restart)
        compose stop && start_in_background
        ;;
    status)
        show_startup_status
        compose ps
        ;;
    health)
        [ "$#" -eq 1 ] || { echo "Usage: $0 health" >&2; exit 2; }
        if compose exec -T api python -c \
            "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/api/v1/health', timeout=3).read().decode())"; then
            echo "ClearPocket API is healthy."
        else
            log_error "ClearPocket API health check failed"
            exit 1
        fi
        ;;
    version)
        [ "$#" -eq 1 ] || { echo "Usage: $0 version" >&2; exit 2; }
        printf 'ClearPocket Server %s\n' "$(tr -d '\r\n' < "$SERVER_ROOT/VERSION")"
        ;;
    logs)
        [ "$#" -eq 1 ] || { echo "Usage: $0 logs" >&2; exit 2; }
        if [ -r "$STARTUP_LOG" ]; then
            echo "--- QNAP startup ---"
            tail -n 100 "$STARTUP_LOG"
        fi
        echo "--- ClearPocket containers ---"
        compose logs --no-color --tail 200 api database 2>&1 || true
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
    import-portable)
        [ "$#" -eq 4 ] || { echo "Usage: $0 import-portable /share/path/archive.tar.gz.age /share/path/identity.txt|'-' IMPORT" >&2; exit 2; }
        [ "$4" = "IMPORT" ] || { log_error "Portable import requires the explicit final argument IMPORT"; exit 1; }
        portable_archive "$2" "$3"
        ;;
    configure-qnap-https)
        [ "$#" -eq 3 ] || { echo "Usage: $0 configure-qnap-https budget.example.com CONFIGURE" >&2; exit 2; }
        configure_qnap_https "$2" "$3"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|health|version|logs|backup|restore|upgrade|install-backup-schedule|remove-backup-schedule|backup-schedule-status|verify-local-device|import-local-device|import-portable|configure-qnap-https}" >&2
        exit 2
        ;;
esac
