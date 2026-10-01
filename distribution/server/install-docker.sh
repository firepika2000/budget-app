#!/bin/sh
set -eu

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION_FILE="$SCRIPT_DIR/VERSION"
ENV_FILE="$SCRIPT_DIR/.env"
[ -f "$VERSION_FILE" ] && [ ! -L "$VERSION_FILE" ] || {
    echo "This is not a complete versioned ClearPocket Server package." >&2
    exit 1
}
VERSION=$(tr -d '\r\n' < "$VERSION_FILE")
case "$VERSION" in ''|edge|*[!A-Za-z0-9._-]*) echo "Server package version is invalid or not immutable." >&2; exit 1 ;; esac
[ "${#VERSION}" -le 64 ] || { echo "Server package version is invalid." >&2; exit 1; }
RELEASE_METADATA="$SCRIPT_DIR/RELEASE-METADATA.txt"
CONTENT_MANIFEST="$SCRIPT_DIR/PACKAGE-CONTENTS-SHA256.txt"
if [ -f "$RELEASE_METADATA" ]; then
    [ -f "$CONTENT_MANIFEST" ] && [ ! -L "$CONTENT_MANIFEST" ] || {
        echo "The release package integrity manifest is missing or unsafe. Download it again." >&2
        exit 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        echo "sha256sum is required to verify this release package." >&2
        exit 1
    }
    (cd "$SCRIPT_DIR" && sha256sum --check --strict --quiet PACKAGE-CONTENTS-SHA256.txt) || {
        echo "Release package content verification failed. Download it again." >&2
        exit 1
    }
    echo "Release package contents verified."
fi
command -v docker >/dev/null 2>&1 || { echo "Docker Engine or Docker Desktop is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is installed but is not running." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required." >&2; exit 1; }

IMAGE="ghcr.io/firepika2000/budget-server:$VERSION"
if [ ! -e "$ENV_FILE" ]; then
    printf 'ClearPocket Server first-time setup\n'
    printf 'For remote iPhone access, enter a public DNS name already pointing to this server.\n'
    printf 'Leave it blank for private, loopback-only installation.\n'
    printf "Public HTTPS hostname [local only]: "
    IFS= read -r PUBLIC_HOST || PUBLIC_HOST=""
    if [ -n "$PUBLIC_HOST" ]; then
        ALLOWED_HOST=$PUBLIC_HOST
        printf 'Automatic HTTPS requires inbound TCP ports 80 and 443. Raw port 8080 remains private.\n'
    else
        printf "Allowed local hostname [localhost]: "
        IFS= read -r ALLOWED_HOST || ALLOWED_HOST=""
        [ -n "$ALLOWED_HOST" ] || ALLOWED_HOST=localhost
    fi
    DEFAULT_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/clearpocket-server"
    printf 'Durable data folder [%s]: ' "$DEFAULT_DATA"
    IFS= read -r DATA_ROOT || DATA_ROOT=""
    [ -n "$DATA_ROOT" ] || DATA_ROOT=$DEFAULT_DATA
    case "$DATA_ROOT" in /*) ;; *) echo "Data folder must be an absolute path." >&2; exit 1 ;; esac
    case "$DATA_ROOT" in *'$'*|*'"'*|*"'"*|*'{'*|*'}'*|*..*) echo "Data folder contains unsupported characters." >&2; exit 1 ;; esac
    DATABASE="$DATA_ROOT/database"
    ATTACHMENTS="$DATA_ROOT/attachments"
    OPERATIONS="$DATA_ROOT/operations"
    mkdir -p "$DATABASE" "$ATTACHMENTS" "$OPERATIONS"
    chmod 700 "$DATA_ROOT" "$DATABASE" "$ATTACHMENTS" "$OPERATIONS"

    echo "Downloading immutable ClearPocket Server $VERSION..."
    docker pull "$IMAGE"
    USER_ID=$(id -u)
    GROUP_ID=$(id -g)
    set -- /bundle/configure.py --output /bundle/.env \
        --allowed-hosts "$ALLOWED_HOST" --bind-address 127.0.0.1 --port 8080 \
        --image ghcr.io/firepika2000/budget-server --version "$VERSION" \
        --database-storage "$DATABASE" --attachments-storage "$ATTACHMENTS" \
        --operations-storage "$OPERATIONS"
    [ -z "$PUBLIC_HOST" ] || set -- "$@" --public-host "$PUBLIC_HOST"
    docker run --rm --user "$USER_ID:$GROUP_ID" \
        --volume "$SCRIPT_DIR:/bundle" --entrypoint python "$IMAGE" "$@"
else
    [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || {
        echo "Existing private configuration is not a regular file; refusing to replace it." >&2
        exit 1
    }
    echo "Existing private configuration preserved."
fi

docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
    -f "$SCRIPT_DIR/compose.yaml" config --quiet
docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
    -f "$SCRIPT_DIR/compose.yaml" up -d
echo "Waiting for ClearPocket Server health..."
attempt=0
while [ "$attempt" -lt 60 ]; do
    if docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
        -f "$SCRIPT_DIR/compose.yaml" exec -T api python -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/v1/health', timeout=3)" \
        >/dev/null 2>&1; then
        PUBLIC_URL=$(sed -n 's/^BUDGET_APP_PAIRING_PUBLIC_URL=//p' "$ENV_FILE" | head -n 1)
        if [ -n "$PUBLIC_URL" ]; then
            echo "ClearPocket Server $VERSION is healthy. Open $PUBLIC_URL/admin."
        else
            echo "ClearPocket Server $VERSION is healthy. Open http://127.0.0.1:8080/admin on this computer."
        fi
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 2
done
echo "Containers started, but the API did not become healthy. Run ./manage.py diagnostics." >&2
exit 1
