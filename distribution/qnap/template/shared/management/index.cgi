#!/bin/sh

QPKG_NAME=ClearPocketServer
GETCFG=${CLEARPOCKET_GETCFG:-/sbin/getcfg}
QPKG_ROOT=${CLEARPOCKET_QPKG_ROOT:-$($GETCFG "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf 2>/dev/null)}
SERVICE="$QPKG_ROOT/ClearPocketServer.sh"
TOKEN_FILE="$QPKG_ROOT/management/.csrf-token"
AUTH_FETCH_OVERRIDE=${CLEARPOCKET_AUTH_FETCH:-}

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

fail_page() {
    printf 'Status: %s\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$1" "$2"
    exit 0
}

redirect_to_https() {
    case "${HTTPS:-}" in on|ON|1) return 0 ;; esac
    REQUEST_HOST=${HTTP_HOST:-${SERVER_NAME:-}}
    case "$REQUEST_HOST" in
        *:*) REQUEST_HOST=${REQUEST_HOST%%:*} ;;
    esac
    case "$REQUEST_HOST" in
        ''|*[!A-Za-z0-9.-]*) fail_page "400 Bad Request" "Invalid management host." ;;
    esac
    printf 'Status: 302 Found\r\nLocation: https://%s/cgi-bin/qpkg/ClearPocketServer/index.cgi\r\nCache-Control: no-store\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nRedirecting to secure ClearPocket management.\n' "$REQUEST_HOST"
    exit 0
}

redirect_to_https

cookie_value() {
    printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | \
        sed -n "s/^[[:space:]]*$1=//p" | head -n 1
}

fetch_qts_authentication() {
    SID=$1
    if [ -n "$AUTH_FETCH_OVERRIDE" ]; then
        [ -x "$AUTH_FETCH_OVERRIDE" ] || return 1
        "$AUTH_FETCH_OVERRIDE" "$SID"
        return
    fi
    AUTH_PORT=${SERVER_PORT:-443}
    case "$AUTH_PORT" in ''|*[!0-9]*) AUTH_PORT=443 ;; esac
    AUTH_URL="https://127.0.0.1:$AUTH_PORT/cgi-bin/authLogin.cgi?sid=$SID"
    CURL=$(command -v curl 2>/dev/null || true)
    if [ -n "$CURL" ] && [ -x "$CURL" ]; then
        "$CURL" -k -fsS --max-time 5 "$AUTH_URL"
        return
    fi
    WGET=$(command -v wget 2>/dev/null || true)
    if [ -n "$WGET" ] && [ -x "$WGET" ]; then
        "$WGET" -qO- --no-check-certificate "$AUTH_URL"
        return
    fi
    if [ -x /bin/busybox ]; then
        /bin/busybox wget -qO- --no-check-certificate "$AUTH_URL"
        return
    fi
    return 1
}

require_qts_administrator() {
    for COOKIE_NAME in QTS_SSL_SSID QTS_SSID NAS_SID; do
        SID=$(cookie_value "$COOKIE_NAME")
        case "$SID" in ''|*[!A-Za-z0-9]*) continue ;; esac
        [ "${#SID}" -le 128 ] || continue
        AUTH_RESPONSE=$(fetch_qts_authentication "$SID" 2>/dev/null) || continue
        printf '%s' "$AUTH_RESPONSE" | grep -Eq '<authPassed>(<!\[CDATA\[)?1(\]\]>)?</authPassed>' || continue
        printf '%s' "$AUTH_RESPONSE" | grep -Eq '<isAdmin>(<!\[CDATA\[)?1(\]\]>)?</isAdmin>' || continue
        return 0
    done
    fail_page "401 Unauthorized" "A valid QTS administrator session is required. Open ClearPocket Server from an authenticated QTS administrator session."
}

require_qts_administrator

[ -n "$QPKG_ROOT" ] && [ -x "$SERVICE" ] && [ -r "$TOKEN_FILE" ] || \
    fail_page "503 Service Unavailable" "ClearPocket Server management is not available."

TOKEN=$(cat "$TOKEN_FILE")
case "$TOKEN" in ''|*[!A-Za-z0-9_-]*) fail_page "503 Service Unavailable" "Management protection is invalid." ;; esac
[ "${#TOKEN}" -eq 43 ] || fail_page "503 Service Unavailable" "Management protection is invalid."

COMMAND=status
OUTPUT=""
RESULT_CLASS=ok
if [ "${REQUEST_METHOD:-GET}" = POST ]; then
    case "${CONTENT_LENGTH:-}" in ''|*[!0-9]*) fail_page "400 Bad Request" "Invalid request." ;; esac
    [ "$CONTENT_LENGTH" -le 4096 ] || fail_page "413 Payload Too Large" "Request is too large."
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    COMMAND=$(printf '%s' "$BODY" | tr '&' '\n' | sed -n 's/^command=//p')
    SUBMITTED_TOKEN=$(printf '%s' "$BODY" | tr '&' '\n' | sed -n 's/^csrf=//p')
    [ "$SUBMITTED_TOKEN" = "$TOKEN" ] || fail_page "403 Forbidden" "Request protection failed. Reopen the app from QTS."
    case "$COMMAND" in
        status|health|version|logs|backup|restart|backup-schedule-status) ;;
        *) COMMAND=help ;;
    esac
fi

case "$COMMAND" in
    help)
        OUTPUT='Allowed commands:
status
health
version
logs
backup
restart
backup-schedule-status'
        ;;
    *)
        OUTPUT_FILE="${TMPDIR:-/tmp}/clearpocket-manager.$$.out"
        trap 'rm -f "$OUTPUT_FILE"' EXIT HUP INT TERM
        if "$SERVICE" "$COMMAND" > "$OUTPUT_FILE" 2>&1; then
            OUTPUT=$(cat "$OUTPUT_FILE")
        else
            RESULT_CLASS=error
            OUTPUT=$(cat "$OUTPUT_FILE")
            [ -n "$OUTPUT" ] || OUTPUT="Command failed. Review QTS and Container Station logs."
        fi
        rm -f "$OUTPUT_FILE"
        trap - EXIT HUP INT TERM
        ;;
esac

SAFE_OUTPUT=$(printf '%s\n' "$OUTPUT" | escape_html)
SAFE_COMMAND=$(printf '%s' "$COMMAND" | escape_html)
VERSION=$(tr -d '\r\n' < "$QPKG_ROOT/server/VERSION" 2>/dev/null | escape_html)
HOST=$(hostname 2>/dev/null | escape_html)

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'Content-Security-Policy: default-src '\''none'\''; style-src '\''unsafe-inline'\''; form-action '\''self'\''; frame-ancestors '\''self'\''\r\n'
printf 'Referrer-Policy: no-referrer\r\n'
printf 'X-Content-Type-Options: nosniff\r\n\r\n'
cat <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClearPocket Server</title><style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}body{margin:0;background:#f3f5f8;color:#16202a}main{max-width:1000px;margin:auto;padding:28px}.hero{display:flex;justify-content:space-between;align-items:end;gap:20px}.eyebrow{color:#35705b;font-weight:700}.meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:22px 0}.card{background:#fff;border:1px solid #dce2e8;border-radius:14px;padding:16px;box-shadow:0 4px 18px #14202b0d}.label{font-size:.8rem;color:#627080}.value{font-weight:650;margin-top:5px}.console{background:#10151b;color:#d9f5e8;border-radius:14px;padding:18px}.console pre{white-space:pre-wrap;min-height:210px;margin:0 0 18px;max-height:340px;overflow:auto}.console form{display:flex;gap:8px}.console input[type=text]{flex:1;background:#1c242d;color:#fff;border:1px solid #46515d;border-radius:8px;padding:11px;font:inherit}.console button,.quick button{border:0;border-radius:8px;padding:11px 15px;background:#2d7259;color:#fff;font-weight:650}.quick{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0}.quick form{display:inline}.danger button{background:#9d352f}.error{color:#ff9b91}@media(prefers-color-scheme:dark){body{background:#0c1116;color:#edf3f7}.card{background:#141b22;border-color:#27333e}.label{color:#9eabb6}}
</style></head><body><main><div class="hero"><div><div class="eyebrow">QNAP management</div><h1>ClearPocket Server</h1></div><div>Private household authority</div></div>
<section class="meta"><div class="card"><div class="label">Server version</div><div class="value">$VERSION</div></div><div class="card"><div class="label">NAS host</div><div class="value">$HOST</div></div><div class="card"><div class="label">Management access</div><div class="value">QTS administrators</div></div></section>
<div class="quick">
<form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="status"><button>Status</button></form>
<form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="health"><button>Health</button></form>
<form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="logs"><button>Recent logs</button></form>
<form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="backup"><button>Encrypted backup</button></form>
<form method="post" class="danger"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="restart"><button>Restart services</button></form>
</div>
<section class="console"><pre class="$RESULT_CLASS" aria-live="polite"><strong>\$ $SAFE_COMMAND</strong>
$SAFE_OUTPUT</pre><form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="text" name="command" aria-label="Management command" autocomplete="off" spellcheck="false" placeholder="Type help for allowed commands"><button>Run</button></form></section>
</main></body></html>
EOF
