#!/bin/sh
set -eu

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
EMPTY_GUARD="$SCRIPT_DIR/tools/require_empty_restore.sql"
[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || { echo "Run install-docker.sh before recovery." >&2; exit 1; }
[ -f "$EMPTY_GUARD" ] && [ ! -L "$EMPTY_GUARD" ] || { echo "Recovery validation tool is missing." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is installed but is not running." >&2; exit 1; }

ARCHIVE=${1:-}
IDENTITY=${2:-}
CONFIRMATION=${3:-}
if [ -z "$ARCHIVE" ]; then
    printf 'Full path to encrypted .tar.gz.age backup: '
    IFS= read -r ARCHIVE || ARCHIVE=""
fi
if [ -z "$IDENTITY" ]; then
    printf 'Full path to recovery identity: '
    IFS= read -r IDENTITY || IDENTITY=""
fi
case "$ARCHIVE" in /*.tar.gz.age) ;; *) echo "Recovery archive must be an absolute .tar.gz.age path." >&2; exit 1 ;; esac
case "$IDENTITY" in /*) ;; *) echo "Recovery identity must be an absolute path." >&2; exit 1 ;; esac
[ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || { echo "Recovery archive must be a regular non-linked file." >&2; exit 1; }
[ -f "$IDENTITY" ] && [ ! -L "$IDENTITY" ] || { echo "Recovery identity must be a regular non-linked file." >&2; exit 1; }
if [ -z "$CONFIRMATION" ]; then
    printf 'Type RESTORE to initialize this empty server: '
    IFS= read -r CONFIRMATION || CONFIRMATION=""
fi
[ "$CONFIRMATION" = RESTORE ] || { echo "Recovery cancelled; no data or configuration was changed."; exit 0; }

compose() {
    docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
        -f "$SCRIPT_DIR/compose.yaml" "$@"
}

LOCK_DIR="$SCRIPT_DIR/.clearpocket-restore.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -r "$LOCK_DIR/pid" ]; then
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && { echo "Another ClearPocket recovery is already running." >&2; exit 1; } ;;
        esac
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

STAGING=""
RESTORE_COMMITTED=false
DESTINATION_MUTATION_STARTED=false
ENV_BACKUP="$SCRIPT_DIR/.env.restore-original.$$"
GUARD_CONTAINER="/tmp/clearpocket-restore-guard-$$.sql"
DATABASE_CONTAINER="/tmp/clearpocket-restore-$$.sql"

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    compose exec -T database rm -f "$GUARD_CONTAINER" "$DATABASE_CONTAINER" >/dev/null 2>&1 || true
    [ -z "$STAGING" ] || rm -rf "$STAGING"
    rm -rf "$LOCK_DIR"
    if [ "$result" -ne 0 ]; then
        compose stop api >/dev/null 2>&1 || true
        if [ "$RESTORE_COMMITTED" = true ]; then
            echo "Recovery data committed, but activation failed. The API remains stopped for inspection." >&2
        else
            if [ "$DESTINATION_MUTATION_STARTED" = true ]; then
                compose run --rm --no-deps --user root api sh -c \
                    'find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -exec rm -rf {} \;' \
                    >/dev/null 2>&1 || echo "Could not remove recovery attachment staging; inspect the stopped destination." >&2
                if [ -f "$ENV_BACKUP" ]; then
                    mv "$ENV_BACKUP" "$ENV_FILE" || echo "Could not restore pre-recovery configuration." >&2
                fi
            fi
            echo "Recovery failed before commit. The archive and identity were not changed." >&2
        fi
    fi
    rm -f "$ENV_BACKUP"
    exit "$result"
}
trap cleanup EXIT HUP INT TERM

assert_empty_destination() {
    compose cp "$EMPTY_GUARD" "database:$GUARD_CONTAINER"
    compose exec -T database psql --single-transaction --set ON_ERROR_STOP=on \
        -U budget -d budget -f "$GUARD_CONTAINER"
    compose run --rm --no-deps api sh -c \
        'objects="$(find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -print -quit)"; test -z "$objects"'
}

compose up -d database api
assert_empty_destination
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/clearpocket-restore.XXXXXX")
compose run --rm --no-deps --user root \
    --volume "$ARCHIVE:/input/archive.age:ro" \
    --volume "$IDENTITY:/input/identity.txt:ro" \
    --volume "$STAGING:/restore" --entrypoint sh api -c \
    'age --decrypt --identity /input/identity.txt /input/archive.age > /restore/archive.tar.gz &&
     python scripts/backup_archive.py extract-verified /restore/archive.tar.gz /restore/verified &&
     rm -f /restore/archive.tar.gz'

RECOVERY_FILE="$STAGING/verified/attachment-key-recovery.env"
[ -f "$RECOVERY_FILE" ] && [ ! -L "$RECOVERY_FILE" ] || { echo "Verified backup has no attachment recovery material." >&2; exit 1; }
RECOVERY_LINE=$(cat "$RECOVERY_FILE")
case "$RECOVERY_LINE" in BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=?*) ;; *) echo "Attachment recovery material is invalid." >&2; exit 1 ;; esac
case "$RECOVERY_LINE" in *[![:graph:]]*) echo "Attachment recovery material is invalid." >&2; exit 1 ;; esac

compose stop api
assert_empty_destination
cp "$ENV_FILE" "$ENV_BACKUP"
chmod 600 "$ENV_BACKUP"
DESTINATION_MUTATION_STARTED=true
TEMP_ENV="$ENV_FILE.recovery.$$"
awk -v replacement="$RECOVERY_LINE" '
    BEGIN { count = 0 }
    /^BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=/ { print replacement; count += 1; next }
    { print }
    END { if (count != 1) exit 42 }
' "$ENV_FILE" > "$TEMP_ENV" || { rm -f "$TEMP_ENV"; echo "Private configuration has an ambiguous attachment key." >&2; exit 1; }
chmod 600 "$TEMP_ENV"
mv "$TEMP_ENV" "$ENV_FILE"
unset RECOVERY_LINE

compose run --rm --no-deps --user root --volume "$STAGING/verified:/restore:ro" api sh -c \
    'objects="$(find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -print -quit)";
     test -z "$objects" && cp -R /restore/attachments/. /var/lib/budget-app/attachments/ &&
     chown -R budget:budget /var/lib/budget-app/attachments && chmod -R u=rwX,go= /var/lib/budget-app/attachments'
compose cp "$EMPTY_GUARD" "database:$GUARD_CONTAINER"
compose cp "$STAGING/verified/database.sql" "database:$DATABASE_CONTAINER"
compose exec -T database psql --single-transaction --set ON_ERROR_STOP=on \
    -U budget -d budget -f "$GUARD_CONTAINER" -f "$DATABASE_CONTAINER"
RESTORE_COMMITTED=true

DIGEST=$(compose run --rm --no-deps --volume "$ARCHIVE:/input/archive.age:ro" api \
    python -c 'import hashlib; print(hashlib.file_digest(open("/input/archive.age", "rb"), "sha256").hexdigest())')
case "$DIGEST" in *[!0-9a-f]*|'') echo "Could not verify source archive digest." >&2; exit 1 ;; esac
[ "${#DIGEST}" -eq 64 ] || { echo "Could not verify source archive digest." >&2; exit 1; }
compose run --rm --no-deps --user root --env "RECOVERY_SHA256=$DIGEST" api python -c \
    'import json, os; from datetime import datetime, timezone; from pathlib import Path
p=Path("/var/lib/budget-app/operations/recovery-status.json"); t=p.with_name(p.name+".tmp")
t.write_text(json.dumps({"state":"verified","verified_at":datetime.now(timezone.utc).isoformat(),"source_provider":"shared_server_postgresql","source_archive_sha256":os.environ["RECOVERY_SHA256"],"database_integrity":"ok","foreign_keys":"ok"},sort_keys=True,indent=2)+"\n")
os.chmod(t,0o600); t.replace(p)'

compose up -d --force-recreate api
attempt=0
while [ "$attempt" -lt 60 ]; do
    if compose exec -T api python -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/v1/health', timeout=3)" \
        >/dev/null 2>&1; then
        echo "Encrypted backup restored and verified. Preserve the source and identity until a new backup succeeds."
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 2
done
echo "Recovered data committed, but the API did not become healthy." >&2
exit 1
