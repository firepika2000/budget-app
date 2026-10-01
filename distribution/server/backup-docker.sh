#!/bin/sh
set -eu

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || {
    echo "Run install-docker.sh before creating a backup." >&2
    exit 1
}
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is installed but is not running." >&2; exit 1; }
USER_ID=$(id -u)
GROUP_ID=$(id -g)

DEFAULT_BACKUP="${XDG_DATA_HOME:-$HOME/.local/share}/clearpocket-server/backups"
DEFAULT_RECOVERY="${XDG_CONFIG_HOME:-$HOME/.config}/clearpocket-server/recovery"
BACKUP_DIR=${1:-}
RECOVERY_DIR=${2:-}
if [ -z "$BACKUP_DIR" ]; then
    printf 'Encrypted backup folder [%s]: ' "$DEFAULT_BACKUP"
    IFS= read -r BACKUP_DIR || BACKUP_DIR=""
    [ -n "$BACKUP_DIR" ] || BACKUP_DIR=$DEFAULT_BACKUP
fi
if [ -z "$RECOVERY_DIR" ]; then
    printf 'Separate recovery-key folder [%s]: ' "$DEFAULT_RECOVERY"
    IFS= read -r RECOVERY_DIR || RECOVERY_DIR=""
    [ -n "$RECOVERY_DIR" ] || RECOVERY_DIR=$DEFAULT_RECOVERY
fi
case "$BACKUP_DIR" in /*) ;; *) echo "Backup folder must be an absolute path." >&2; exit 1 ;; esac
case "$RECOVERY_DIR" in /*) ;; *) echo "Recovery folder must be an absolute path." >&2; exit 1 ;; esac
[ "$BACKUP_DIR" != "$RECOVERY_DIR" ] || { echo "Keep the recovery identity separate from backup generations." >&2; exit 1; }
mkdir -p "$BACKUP_DIR" "$RECOVERY_DIR"
[ -d "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ] || { echo "Backup folder is unsafe." >&2; exit 1; }
[ -d "$RECOVERY_DIR" ] && [ ! -L "$RECOVERY_DIR" ] || { echo "Recovery folder is unsafe." >&2; exit 1; }
chmod 700 "$BACKUP_DIR" "$RECOVERY_DIR"

LOCK_DIR="$BACKUP_DIR/.clearpocket-backup.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -r "$LOCK_DIR/pid" ]; then
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && { echo "Another ClearPocket backup is already running." >&2; exit 1; } ;;
        esac
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

compose() {
    docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
        -f "$SCRIPT_DIR/compose.yaml" "$@"
}

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/clearpocket-backup.XXXXXX")
PARTIAL=""
API_PAUSED=false
STATUS_RECORDED=false
DATABASE_TEMPORARY="/tmp/clearpocket-backup-$$.sql"

record_status() {
    state=$1
    if [ "$state" = healthy ]; then
        compose run --rm --no-deps --user root --volume "$BACKUP_DIR:/backup:ro" api sh -c \
            'python scripts/backup_health.py healthy "/backup/$1" --reported-path "$2" && chown budget:budget "$BUDGET_APP_BACKUP_STATUS_PATH"' \
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
        compose start api >/dev/null 2>&1 || echo "The API could not be resumed; run ./manage.py start." >&2
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
    echo "Private configuration has duplicate backup recipients." >&2
    exit 1
}
IDENTITY="$RECOVERY_DIR/clearpocket-recovery-key.txt"
if [ -z "$RECIPIENT" ]; then
    if [ -e "$IDENTITY" ]; then
        [ -f "$IDENTITY" ] && [ ! -L "$IDENTITY" ] || { echo "Existing recovery identity is unsafe." >&2; exit 1; }
        printf 'A recovery identity already exists. Type USE to adopt it without replacement: '
        IFS= read -r reuse || reuse=""
        [ "$reuse" = USE ] || { echo "Existing recovery identity was preserved but not adopted." >&2; exit 1; }
    else
        compose run --rm --no-deps --user root --volume "$RECOVERY_DIR:/recovery" \
            --entrypoint sh api -c \
            "age-keygen -o /recovery/clearpocket-recovery-key.txt && chmod 600 /recovery/clearpocket-recovery-key.txt && chown '$USER_ID:$GROUP_ID' /recovery/clearpocket-recovery-key.txt"
    fi
    RECIPIENT=$(compose run --rm --no-deps --volume "$IDENTITY:/recovery/key.txt:ro" \
        --entrypoint age-keygen api -y /recovery/key.txt)
    printf '%s\n' "$RECIPIENT" | grep -Eq '^age1[0-9a-z]+$' || { echo "Recovery identity is invalid." >&2; exit 1; }
    TEMP_ENV="$ENV_FILE.recipient.$$"
    { cat "$ENV_FILE"; printf 'BUDGET_APP_BACKUP_AGE_RECIPIENT=%s\n' "$RECIPIENT"; } > "$TEMP_ENV"
    chmod 600 "$TEMP_ENV"
    mv "$TEMP_ENV" "$ENV_FILE"
    echo "Recovery identity created at $IDENTITY"
    echo "Copy it to a separate protected device; losing it makes backups unrecoverable."
fi
printf '%s\n' "$RECIPIENT" | grep -Eq '^age1[0-9a-z]+$' || { echo "Configured backup recipient is invalid." >&2; exit 1; }
RETENTION=$(sed -n 's/^BUDGET_APP_BACKUP_RETENTION=//p' "$ENV_FILE")
RETENTION_COUNT=$(grep -c '^BUDGET_APP_BACKUP_RETENTION=' "$ENV_FILE" || true)
[ "$RETENTION_COUNT" -le 1 ] || { echo "Duplicate retention setting." >&2; exit 1; }
[ -n "$RETENTION" ] || RETENTION=10
case "$RETENTION" in ''|*[!0-9]*|0) echo "Backup retention must be a positive integer." >&2; exit 1 ;; esac

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILENAME="budget-$TIMESTAMP.tar.gz.age"
FINAL="$BACKUP_DIR/$FILENAME"
[ ! -e "$FINAL" ] || { echo "A backup with this timestamp already exists." >&2; exit 1; }
PARTIAL="$BACKUP_DIR/.$FILENAME.$$.partial"
mkdir "$STAGING/attachments"

echo "Creating coordinated encrypted backup at $FINAL"
compose exec -T api sh -c \
    'if [ -n "${BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY:-}" ]; then printf "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s\n" "$BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"; else printf "BUDGET_APP_JWT_SECRET=%s\n" "$BUDGET_APP_JWT_SECRET"; fi' \
    > "$STAGING/attachment-key-recovery.env"
grep -Eq '^BUDGET_APP_(ATTACHMENT_ENCRYPTION_KEY|JWT_SECRET)=[^[:space:]]+$' "$STAGING/attachment-key-recovery.env" || {
    echo "Attachment recovery material is invalid; no service was stopped." >&2
    exit 1
}
compose stop api
API_PAUSED=true
compose exec -T database sh -c \
    "umask 077; pg_dump --clean --if-exists --no-owner --no-privileges -U budget -d budget > '$DATABASE_TEMPORARY'"
compose cp "database:$DATABASE_TEMPORARY" "$STAGING/database.sql"
REVISION=$(compose exec -T database psql -At -U budget -d budget -c 'SELECT version_num FROM alembic_version')
printf '%s\n' "$REVISION" | grep -Eq '^[A-Za-z0-9_]+$' || { echo "Database revision is invalid." >&2; exit 1; }
printf 'format_version=1\ncreated_at=%s\ndatabase_revision=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REVISION" > "$STAGING/BACKUP-METADATA"
compose cp api:/var/lib/budget-app/attachments/. "$STAGING/attachments"
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
     wait \$tar_pid; tar_status=\$?; rm -f \$fifo; test \$age_status -eq 0 -a \$tar_status -eq 0 && \
     chmod 600 '/output/$(basename "$PARTIAL")' && chown '$USER_ID:$GROUP_ID' '/output/$(basename "$PARTIAL")'"
[ -f "$PARTIAL" ] || { echo "Encrypted backup publication failed." >&2; exit 1; }
mv "$PARTIAL" "$FINAL"
PARTIAL=""
record_status healthy
STATUS_RECORDED=true
count=0
for generation in $(ls -1t "$BACKUP_DIR"/budget-*.tar.gz.age 2>/dev/null); do
    [ -f "$generation" ] && [ ! -L "$generation" ] || continue
    count=$((count + 1))
    [ "$count" -le "$RETENTION" ] || rm -f "$generation"
done
echo "Encrypted backup complete: $FINAL"
