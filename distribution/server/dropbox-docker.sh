#!/bin/sh
set -eu

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || {
    echo "Run install-docker.sh before using Dropbox backup storage." >&2
    exit 1
}
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is installed but is not running." >&2; exit 1; }
USER_ID=$(id -u)
GROUP_ID=$(id -g)

compose() {
    docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
        -f "$SCRIPT_DIR/compose.yaml" "$@"
}

require_absolute_file() {
    value=$1
    label=$2
    case "$value" in /*) ;; *) echo "$label must be an absolute path." >&2; exit 1 ;; esac
    [ -f "$value" ] && [ ! -L "$value" ] || { echo "$label must be a regular non-linked file." >&2; exit 1; }
}

ACTION=${1:-}
case "$ACTION" in
    publish)
        [ "$#" -ge 3 ] && [ "$#" -le 5 ] || {
            echo "Usage: $0 publish ARCHIVE CREDENTIALS [DROPBOX_FOLDER] [KEEP]" >&2
            exit 2
        }
        ARCHIVE=$2
        CREDENTIALS=$3
        FOLDER=${4:-/Backups}
        KEEP=${5:-10}
        require_absolute_file "$ARCHIVE" "Encrypted backup"
        case "$ARCHIVE" in *.tar.gz.age) ;; *) echo "Only encrypted .tar.gz.age backups can be published." >&2; exit 1 ;; esac
        require_absolute_file "$CREDENTIALS" "Dropbox credential file"
        case "$KEEP" in ''|*[!0-9]*|0) echo "Retention must be a positive integer." >&2; exit 1 ;; esac
        compose run --rm --no-deps --user "$USER_ID:$GROUP_ID" \
            --volume "$ARCHIVE:/input/archive.age:ro" \
            --volume "$CREDENTIALS:/run/secrets/dropbox.env:ro" api \
            python scripts/backup_destination.py publish /input/archive.age \
            --destination dropbox --credentials-file /run/secrets/dropbox.env \
            --dropbox-folder "$FOLDER" --keep "$KEEP"
        ;;
    list)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
            echo "Usage: $0 list CREDENTIALS [DROPBOX_FOLDER]" >&2
            exit 2
        }
        CREDENTIALS=$2
        FOLDER=${3:-/Backups}
        require_absolute_file "$CREDENTIALS" "Dropbox credential file"
        compose run --rm --no-deps --user "$USER_ID:$GROUP_ID" \
            --volume "$CREDENTIALS:/run/secrets/dropbox.env:ro" api \
            python scripts/backup_destination.py list --destination dropbox \
            --credentials-file /run/secrets/dropbox.env --dropbox-folder "$FOLDER"
        ;;
    fetch)
        [ "$#" -ge 4 ] && [ "$#" -le 5 ] || {
            echo "Usage: $0 fetch REMOTE_PATH OUTPUT CREDENTIALS [DROPBOX_FOLDER]" >&2
            exit 2
        }
        REMOTE=$2
        OUTPUT=$3
        CREDENTIALS=$4
        FOLDER=${5:-/Backups}
        case "$REMOTE" in "$FOLDER"/*.tar.gz.age) ;; *) echo "Remote backup is outside the selected Dropbox folder." >&2; exit 1 ;; esac
        case "$OUTPUT" in /*) ;; *) echo "Restore output must be an absolute path." >&2; exit 1 ;; esac
        [ ! -e "$OUTPUT" ] || { echo "Restore output already exists." >&2; exit 1; }
        OUTPUT_DIR=$(dirname -- "$OUTPUT")
        OUTPUT_NAME=$(basename -- "$OUTPUT")
        [ -d "$OUTPUT_DIR" ] && [ ! -L "$OUTPUT_DIR" ] || { echo "Restore output folder is unsafe." >&2; exit 1; }
        case "$OUTPUT_NAME" in *.tar.gz.age) ;; *) echo "Restore output must end in .tar.gz.age." >&2; exit 1 ;; esac
        require_absolute_file "$CREDENTIALS" "Dropbox credential file"
        compose run --rm --no-deps --user "$USER_ID:$GROUP_ID" \
            --volume "$OUTPUT_DIR:/output" \
            --volume "$CREDENTIALS:/run/secrets/dropbox.env:ro" api \
            python scripts/backup_destination.py fetch-dropbox "$REMOTE" "/output/$OUTPUT_NAME" \
            --credentials-file /run/secrets/dropbox.env --dropbox-folder "$FOLDER"
        ;;
    *)
        echo "Usage: $0 {publish|list|fetch} ..." >&2
        exit 2
        ;;
esac
