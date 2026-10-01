#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 DATA_ROOT DOCKER SERVER_ROOT" >&2
    exit 2
fi

DATA_ROOT=$1
DOCKER=$2
SERVER_ROOT=$3
ENV_FILE="$DATA_ROOT/.env"
BACKUP_DIR="$DATA_ROOT/backups"
RECOVERY_DIR="$DATA_ROOT/recovery"
DROPBOX_CREDENTIALS="$DATA_ROOT/dropbox.env"
LOCK_DIR="$DATA_ROOT/operations/qnap-backup.lock"

case "$DATA_ROOT" in /share/*) ;; *) echo "Invalid QNAP data root" >&2; exit 2 ;; esac
[ -x "$DOCKER" ] || { echo "Container Station Docker command is unavailable" >&2; exit 1; }
[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || { echo "Private server configuration is invalid" >&2; exit 1; }
[ -f "$SERVER_ROOT/compose.yaml" ] || { echo "Server Compose contract is missing" >&2; exit 1; }

compose() {
    "$DOCKER" compose --project-directory "$SERVER_ROOT" --env-file "$ENV_FILE" \
        -f "$SERVER_ROOT/compose.yaml" "$@"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -r "$LOCK_DIR/pid" ]; then
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && { echo "A QNAP backup is already running" >&2; exit 1; } ;;
        esac
    fi
    rm -rf "$LOCK_DIR" || exit 1
    mkdir "$LOCK_DIR" || exit 1
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

mkdir -p "$BACKUP_DIR" "$RECOVERY_DIR"
STAGING=$(mktemp -d "$DATA_ROOT/.backup-staging.XXXXXX") || exit 1
PARTIAL=""
API_PAUSED=false
STATUS_RECORDED=false
DATABASE_TEMPORARY="/tmp/clearpocket-backup-$$.sql"

record_status() {
    state=$1
    destination_json=${2:-}
    if [ "$state" = healthy ] && [ -n "$destination_json" ]; then
        compose run --rm --no-deps --user root --volume "$BACKUP_DIR:/backup:ro" \
            --volume "$destination_json:/status/destination.json:ro" api sh -c \
            'python scripts/backup_health.py healthy "/backup/$1" --reported-path "$2" --destination-json /status/destination.json && chown budget:budget "$BUDGET_APP_BACKUP_STATUS_PATH"' \
            backup-health "$FILENAME" "$FINAL"
    elif [ "$state" = healthy ]; then
        compose run --rm --no-deps --user root --volume "$BACKUP_DIR:/backup:ro" api sh -c \
            'python scripts/backup_health.py healthy "/backup/$1" --reported-path "$2" && chown budget:budget "$BUDGET_APP_BACKUP_STATUS_PATH"' \
            backup-health "$FILENAME" "$FINAL"
    elif [ "$state" = publication_failed ]; then
        compose run --rm --no-deps --user root --volume "$BACKUP_DIR:/backup:ro" api sh -c \
            'python scripts/backup_health.py publication_failed "/backup/$1" --reported-path "$2" && chown budget:budget "$BUDGET_APP_BACKUP_STATUS_PATH"' \
            backup-health "$FILENAME" "$FINAL"
    else
        compose run --rm --no-deps --user root api sh -c \
            'python scripts/backup_health.py failed && chown budget:budget "$BUDGET_APP_BACKUP_STATUS_PATH"'
    fi
}

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$API_PAUSED" = true ]; then
        if ! compose start api; then
            echo "ClearPocket API could not be resumed; use App Center to restart it" >&2
            result=1
        fi
    fi
    compose exec -T database rm -f "$DATABASE_TEMPORARY" >/dev/null 2>&1 || true
    if [ "$result" -ne 0 ] && [ "$STATUS_RECORDED" != true ]; then
        record_status failed >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING"
    [ -z "$PARTIAL" ] || rm -f "$PARTIAL"
    rm -rf "$LOCK_DIR"
    exit "$result"
}
trap cleanup EXIT HUP INT TERM

RECIPIENT=$(sed -n 's/^BUDGET_APP_BACKUP_AGE_RECIPIENT=//p' "$ENV_FILE")
RECIPIENT_COUNT=$(grep -c '^BUDGET_APP_BACKUP_AGE_RECIPIENT=' "$ENV_FILE" || true)
[ "$RECIPIENT_COUNT" -le 1 ] || {
    echo "Private configuration has duplicate backup recipients" >&2
    exit 1
}
IDENTITY="$RECOVERY_DIR/clearpocket-recovery-key.txt"
if [ -z "$RECIPIENT" ]; then
    if [ ! -e "$IDENTITY" ]; then
        compose run --rm --no-deps --user root --volume "$RECOVERY_DIR:/recovery" \
            --entrypoint age-keygen api -o /recovery/clearpocket-recovery-key.txt
    fi
    [ -f "$IDENTITY" ] && [ ! -L "$IDENTITY" ] || { echo "Recovery identity is invalid" >&2; exit 1; }
    RECIPIENT=$(compose run --rm --no-deps --volume "$IDENTITY:/recovery/key.txt:ro" \
        --entrypoint age-keygen api -y /recovery/key.txt)
    printf '%s\n' "$RECIPIENT" | grep -Eq '^age1[0-9a-z]+$' || {
        echo "Generated recovery identity could not be validated" >&2
        exit 1
    }
    TEMP_ENV="$ENV_FILE.recipient.$$"
    { cat "$ENV_FILE"; printf 'BUDGET_APP_BACKUP_AGE_RECIPIENT=%s\n' "$RECIPIENT"; } > "$TEMP_ENV"
    chmod 600 "$TEMP_ENV"
    mv "$TEMP_ENV" "$ENV_FILE"
    echo "Recovery identity created at $IDENTITY"
    echo "Copy it to a separate protected device; losing it makes backups unrecoverable."
fi
printf '%s\n' "$RECIPIENT" | grep -Eq '^age1[0-9a-z]+$' || {
    echo "Configured backup recipient is invalid" >&2
    exit 1
}
RETENTION=$(sed -n 's/^BUDGET_APP_BACKUP_RETENTION=//p' "$ENV_FILE")
RETENTION_COUNT=$(grep -c '^BUDGET_APP_BACKUP_RETENTION=' "$ENV_FILE" || true)
[ "$RETENTION_COUNT" -le 1 ] || {
    echo "Private configuration has duplicate backup retention settings" >&2
    exit 1
}
[ -n "$RETENTION" ] || RETENTION=10
case "$RETENTION" in ''|*[!0-9]*|0) echo "Backup retention must be a positive integer" >&2; exit 1 ;; esac
DROPBOX_FOLDER=$(sed -n 's/^BUDGET_APP_DROPBOX_FOLDER=//p' "$ENV_FILE")
DROPBOX_FOLDER_COUNT=$(grep -c '^BUDGET_APP_DROPBOX_FOLDER=' "$ENV_FILE" || true)
[ "$DROPBOX_FOLDER_COUNT" -le 1 ] || { echo "Duplicate Dropbox folder setting" >&2; exit 1; }
[ -n "$DROPBOX_FOLDER" ] || DROPBOX_FOLDER=/Backups
case "$DROPBOX_FOLDER" in /*) [ "$DROPBOX_FOLDER" != / ] || { echo "Dropbox folder cannot be the account root" >&2; exit 1; } ;; *) echo "Dropbox folder must be absolute" >&2; exit 1 ;; esac
if [ -e "$DROPBOX_CREDENTIALS" ]; then
    [ -f "$DROPBOX_CREDENTIALS" ] && [ ! -L "$DROPBOX_CREDENTIALS" ] || {
        echo "Dropbox credential file is unsafe" >&2
        exit 1
    }
fi

apply_retention() {
    count=0
    for generation in $(ls -1t "$BACKUP_DIR"/budget-*.tar.gz.age 2>/dev/null); do
        [ -f "$generation" ] && [ ! -L "$generation" ] || continue
        count=$((count + 1))
        if [ "$count" -gt "$RETENTION" ]; then
            rm -f "$generation"
        fi
    done
}

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILENAME="budget-$TIMESTAMP.tar.gz.age"
FINAL="$BACKUP_DIR/$FILENAME"
[ ! -e "$FINAL" ] || { echo "A backup with this timestamp already exists" >&2; exit 1; }
PARTIAL="$BACKUP_DIR/.$FILENAME.$$.partial"
mkdir "$STAGING/attachments"

echo "Creating coordinated encrypted QNAP backup at $FINAL"
compose exec -T api sh -c \
    'if [ -n "${BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY:-}" ]; then printf "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s\n" "$BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"; else printf "BUDGET_APP_JWT_SECRET=%s\n" "$BUDGET_APP_JWT_SECRET"; fi' \
    > "$STAGING/attachment-key-recovery.env"
grep -Eq '^BUDGET_APP_(ATTACHMENT_ENCRYPTION_KEY|JWT_SECRET)=[^[:space:]]+$' "$STAGING/attachment-key-recovery.env" || {
    echo "Attachment recovery material is invalid; no service was stopped" >&2
    exit 1
}

compose stop api
API_PAUSED=true
compose exec -T database sh -c \
    "umask 077; pg_dump --clean --if-exists --no-owner --no-privileges --exclude-table-data=pairing_codes -U budget -d budget > '$DATABASE_TEMPORARY'"
compose cp "database:$DATABASE_TEMPORARY" "$STAGING/database.sql"
REVISION=$(compose exec -T database psql -At -U budget -d budget -c 'SELECT version_num FROM alembic_version')
printf '%s\n' "$REVISION" | grep -Eq '^[A-Za-z0-9_]+$' || { echo "Database revision is invalid" >&2; exit 1; }
printf 'format_version=1\ncreated_at=%s\ndatabase_revision=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REVISION" > "$STAGING/BACKUP-METADATA"
compose cp api:/var/lib/budget-app/attachments/. "$STAGING/attachments"
compose run --rm --no-deps --volume "$STAGING/attachments:/capture/attachments:ro" api \
    python scripts/backup_capture.py validate-attachments /capture/attachments
compose exec -T database rm -f "$DATABASE_TEMPORARY"
compose start api
API_PAUSED=false

compose run --rm --no-deps --user root --volume "$STAGING:/capture" api \
    python scripts/backup_archive.py create-manifest /capture
compose run --rm --no-deps --user root --volume "$STAGING:/capture:ro" \
    --volume "$BACKUP_DIR:/output" --entrypoint sh api -c \
    "fifo=/tmp/clearpocket-backup-fifo; rm -f \$fifo; mkfifo \$fifo || exit 1; \
     tar -C /capture -czf - BACKUP-METADATA database.sql attachments attachment-key-recovery.env MANIFEST.sha256 > \$fifo & tar_pid=\$!; \
     age --recipient '$RECIPIENT' --output '/output/$(basename "$PARTIAL")' < \$fifo; age_status=\$?; \
     wait \$tar_pid; tar_status=\$?; rm -f \$fifo; test \$age_status -eq 0 -a \$tar_status -eq 0"
[ -f "$PARTIAL" ] || { echo "Encrypted backup publication failed" >&2; exit 1; }
mv "$PARTIAL" "$FINAL"
PARTIAL=""
if [ -f "$DROPBOX_CREDENTIALS" ]; then
    DROPBOX_RESULT="$STAGING/dropbox-publication.json"
    if ! compose run --rm --no-deps --user root \
        --volume "$FINAL:/input/$FILENAME:ro" \
        --volume "$DROPBOX_CREDENTIALS:/run/secrets/dropbox.env:ro" api \
        python scripts/backup_destination.py publish "/input/$FILENAME" \
        --destination dropbox --credentials-file /run/secrets/dropbox.env \
        --dropbox-folder "$DROPBOX_FOLDER" --keep "$RETENTION" > "$DROPBOX_RESULT"; then
        record_status publication_failed
        STATUS_RECORDED=true
        echo "Encrypted QNAP backup was retained locally, but Dropbox publication failed" >&2
        exit 1
    fi
    record_status healthy "$DROPBOX_RESULT"
else
    record_status healthy
fi
STATUS_RECORDED=true
apply_retention
echo "Encrypted QNAP backup complete: $FINAL"
echo "Test recovery regularly and keep the recovery identity separate from this NAS."
