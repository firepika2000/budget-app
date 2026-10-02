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

PAGE=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^page=//p' | head -n 1)
[ -n "$PAGE" ] || PAGE=overview
case "$PAGE" in overview|connections|data|backups|logs) ;; *) PAGE=overview ;; esac
OVERVIEW_CLASS=page
CONNECTIONS_CLASS=page
DATA_CLASS=page
BACKUPS_CLASS=page
LOGS_CLASS=page
case "$PAGE" in
    overview) OVERVIEW_CLASS="page active" ;;
    connections) CONNECTIONS_CLASS="page active" ;;
    data) DATA_CLASS="page active" ;;
    backups) BACKUPS_CLASS="page active" ;;
    logs) LOGS_CLASS="page active" ;;
esac

COMMAND=status
FORMAT=page
OUTPUT=""
RESULT_CLASS=ok
if [ "${REQUEST_METHOD:-GET}" = POST ]; then
    case "${CONTENT_LENGTH:-}" in ''|*[!0-9]*) fail_page "400 Bad Request" "Invalid request." ;; esac
    [ "$CONTENT_LENGTH" -le 4096 ] || fail_page "413 Payload Too Large" "Request is too large."
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    COMMAND=$(printf '%s' "$BODY" | tr '&' '\n' | sed -n 's/^command=//p')
    FORMAT=$(printf '%s' "$BODY" | tr '&' '\n' | sed -n 's/^format=//p')
    [ -n "$FORMAT" ] || FORMAT=page
    case "$FORMAT" in page|terminal) ;; *) fail_page "400 Bad Request" "Invalid response format." ;; esac
    SUBMITTED_TOKEN=$(printf '%s' "$BODY" | tr '&' '\n' | sed -n 's/^csrf=//p')
    [ "$SUBMITTED_TOKEN" = "$TOKEN" ] || fail_page "403 Forbidden" "Request protection failed. Reopen the app from QTS."
    case "$COMMAND" in
        status|health|version|logs|backup|restart|backup-schedule-status|connection-info|authority-inventory|configure-tailscale) ;;
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
backup-schedule-status
connection-info
authority-inventory
configure-tailscale'
        ;;
    *)
        OUTPUT_FILE="${TMPDIR:-/tmp}/clearpocket-manager.$$.out"
        trap 'rm -f "$OUTPUT_FILE"' EXIT HUP INT TERM
        if [ "$COMMAND" = configure-tailscale ]; then
            set -- configure-tailscale ENABLE
        else
            set -- "$COMMAND"
        fi
        if "$SERVICE" "$@" > "$OUTPUT_FILE" 2>&1; then
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

if [ "$FORMAT" = terminal ]; then
    case "$COMMAND" in logs|authority-inventory) ;; *) fail_page "400 Bad Request" "Invalid read-only data request." ;; esac
    if [ "$RESULT_CLASS" = error ]; then
        printf 'Status: 503 Service Unavailable\r\n'
    fi
    printf 'Content-Type: text/plain; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n\r\n'
    printf '%s\n' "$OUTPUT"
    exit 0
fi

SAFE_OUTPUT=$(printf '%s\n' "$OUTPUT" | escape_html)
SAFE_COMMAND=$(printf '%s' "$COMMAND" | escape_html)
VERSION=$(tr -d '\r\n' < "$QPKG_ROOT/server/VERSION" 2>/dev/null | escape_html)
HOST=$(hostname 2>/dev/null | escape_html)
SYSTEM_CONFIG=${CLEARPOCKET_SYSTEM_CONFIG:-/etc/config/clearpocket-server.conf}
DATA_ROOT=$(sed -n 's/^CLEARPOCKET_DATA_ROOT=//p' "$SYSTEM_CONFIG" 2>/dev/null)
ENV_FILE="$DATA_ROOT/.env"
PUBLIC_URL=$(sed -n 's/^BUDGET_APP_PAIRING_PUBLIC_URL=//p' "$ENV_FILE" 2>/dev/null)
PORT=$(sed -n 's/^CLEARPOCKET_PORT=//p' "$ENV_FILE" 2>/dev/null)
case "$PORT" in ''|*[!0-9]*) PORT=18080 ;; esac
if [ -n "$PUBLIC_URL" ]; then
    CONNECTION_STATE="Secure connection ready"
    DISPLAY_URL=$(printf '%s' "$PUBLIC_URL" | escape_html)
    CONNECTION_CLASS=ready
else
    CONNECTION_STATE="Connection setup needed"
    DISPLAY_URL="Enable Tailscale HTTPS below"
    CONNECTION_CLASS=attention
fi
case "$PUBLIC_URL" in
    https://*.ts.net)
        TAILSCALE_ACTION='<div class="badge">Tailscale HTTPS is enabled</div><p class="note">ClearPocket is using the private HTTPS address shown above. No router forwarding is required.</p>'
        ;;
    *)
        TAILSCALE_ACTION='<form method="post"><input type="hidden" name="csrf" value="'"$TOKEN"'"><input type="hidden" name="command" value="configure-tailscale"><label class="note"><input type="checkbox" required> I have completed the Tailscale prerequisites.</label><div style="margin-top:10px"><button>Enable Tailscale HTTPS</button></div></form>'
        ;;
esac
CONNECTION_INFO=$("$SERVICE" connection-info 2>&1 || true)
SAFE_CONNECTION_INFO=$(printf '%s\n' "$CONNECTION_INFO" | escape_html)

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'Content-Security-Policy: default-src '\''none'\''; style-src '\''unsafe-inline'\''; script-src '\''nonce-%s'\''; connect-src '\''self'\''; form-action '\''self'\''; frame-ancestors '\''self'\''\r\n' "$TOKEN"
printf 'Referrer-Policy: no-referrer\r\n'
printf 'X-Content-Type-Options: nosniff\r\n\r\n'
cat <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClearPocket Server</title><style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;--green:#28785d;--green2:#195d49;--ink:#14212b;--muted:#627080;--line:#dae2e7;--panel:#fff;--bg:#f4f7f6;--soft:#edf7f3;--warn:#a45b12}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);line-height:1.45}main{max-width:1120px;margin:auto;padding:34px 26px 64px}.hero{display:flex;justify-content:space-between;align-items:center;gap:22px;margin-bottom:20px}.brand{display:flex;align-items:center;gap:14px}.mark{width:48px;height:48px;border-radius:15px;background:linear-gradient(145deg,var(--green),var(--green2));display:grid;place-items:center;color:white;font-size:25px;font-weight:800;box-shadow:0 8px 24px #195d4930}.eyebrow{color:var(--green);font-size:.78rem;font-weight:800;text-transform:uppercase;letter-spacing:.09em}h1{font-size:2rem;line-height:1.1;margin:4px 0}h2{font-size:1.25rem;margin:0 0 8px}h3{font-size:1rem;margin:0 0 6px}.subtitle,.muted{color:var(--muted)}.tabs{display:flex;gap:5px;overflow:auto;border-bottom:1px solid var(--line);margin-bottom:26px;padding:0 2px}.tabs a{color:var(--muted);text-decoration:none;padding:11px 14px;border-bottom:3px solid transparent;white-space:nowrap}.tabs a.active{color:var(--green);border-color:var(--green);font-weight:800}.page{display:none}.page.active{display:block}.badge{border-radius:999px;padding:8px 12px;font-size:.85rem;font-weight:750;background:var(--soft);color:var(--green2)}.badge.attention{background:#fff3df;color:var(--warn)}.meta,.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.meta{margin-bottom:28px}.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:19px;box-shadow:0 8px 28px #14202b0b}.label{font-size:.76rem;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:.04em}.value{font-size:1.02rem;font-weight:720;margin-top:5px;overflow-wrap:anywhere}.section{margin-top:28px}.section:first-child{margin-top:0}.section-head{display:flex;justify-content:space-between;align-items:end;gap:12px;margin-bottom:12px}.connection{grid-column:span 2;background:linear-gradient(145deg,var(--soft),var(--panel))}.url{margin:15px 0 7px;padding:12px 14px;background:#10211b;color:#dff9ee;border-radius:10px;font:600 .93rem ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}.steps{margin:14px 0 0;padding-left:22px}.steps li{margin:9px 0}.option{display:flex;flex-direction:column;min-height:230px}.option.recommended{border-color:#84b8a5;box-shadow:0 10px 32px #28785d16}.option .tag{align-self:flex-start;margin-bottom:13px;padding:4px 8px;border-radius:999px;background:var(--soft);color:var(--green2);font-size:.72rem;font-weight:800}.option form{margin-top:auto}.note{font-size:.86rem;color:var(--muted)}button{appearance:none;border:0;border-radius:10px;padding:11px 15px;background:var(--green);color:white;font:700 .9rem inherit;cursor:pointer}button:hover{background:var(--green2)}button.secondary{background:#e8efec;color:var(--green2)}button[aria-pressed=true]{background:#76531d}.quick{display:flex;flex-wrap:wrap;gap:9px}.quick form{display:inline}.danger button{background:#a43b35}.console{background:#0d151a;color:#d9f5e8;border-radius:16px;padding:18px}.console pre{white-space:pre-wrap;margin:0;max-height:360px;overflow:auto;font:500 .85rem/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}.live-console pre{height:430px;max-height:58vh}.console form{display:flex;gap:8px;margin-top:14px}.console input[type=text]{flex:1;background:#19232a;color:#fff;border:1px solid #40515c;border-radius:9px;padding:11px;font:inherit}.error{color:#ff9b91}details{margin-top:18px}summary{cursor:pointer;font-weight:750;color:var(--muted);padding:6px 0}.connection-data{white-space:pre-wrap;font:500 .82rem/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);margin:10px 0 0}.inventory-summary{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin:16px 0}.inventory-table{width:100%;border-collapse:collapse}.inventory-table th,.inventory-table td{text-align:left;padding:11px 9px;border-bottom:1px solid var(--line);vertical-align:top}.inventory-table th{font-size:.75rem;color:var(--muted);text-transform:uppercase}.table-wrap{overflow:auto}a{color:var(--green);font-weight:650}@media(max-width:800px){.meta,.grid,.inventory-summary{grid-template-columns:1fr}.connection{grid-column:auto}.hero{align-items:flex-start;flex-direction:column}.badge{align-self:flex-start}.live-console pre{height:340px}}@media(prefers-color-scheme:dark){:root{--ink:#edf3f7;--muted:#9eabb6;--line:#27343c;--panel:#121b21;--bg:#091015;--soft:#142a23}.badge.attention{background:#332511;color:#ffc477}.url{background:#07110d}.console{background:#060c10}.secondary{color:#d7ebe3!important;background:#243630!important}}
</style></head><body><main>
<header class="hero"><div class="brand"><div class="mark">C</div><div><div class="eyebrow">Private household server</div><h1>ClearPocket</h1><div class="subtitle">Connection, protection, and QNAP operations</div></div></div><div class="badge $CONNECTION_CLASS">$CONNECTION_STATE</div></header>
<nav class="tabs" aria-label="Server administration"><a class="$( [ "$PAGE" = overview ] && echo active )" href="?page=overview">Overview</a><a class="$( [ "$PAGE" = connections ] && echo active )" href="?page=connections">Connections</a><a class="$( [ "$PAGE" = data ] && echo active )" href="?page=data">Hosted Data</a><a class="$( [ "$PAGE" = backups ] && echo active )" href="?page=backups">Backups</a><a class="$( [ "$PAGE" = logs ] && echo active )" href="?page=logs">Live Logs</a></nav>
<div class="$OVERVIEW_CLASS">
<section class="meta"><div class="card"><div class="label">Server</div><div class="value">$VERSION</div></div><div class="card"><div class="label">QNAP</div><div class="value">$HOST</div></div><div class="card"><div class="label">Administration</div><div class="value">QTS administrators only</div></div></section>

<section class="section"><div class="section-head"><div><h2>Server operations</h2><div class="muted">Routine checks and recoverable maintenance.</div></div></div><div class="card"><div class="quick">
<form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="status"><button>Status</button></form>
<form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="health"><button>Health</button></form>
<form method="post" class="danger"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="restart"><button>Restart services</button></form>
</div><details open><summary>Latest result</summary><section class="console"><pre class="$RESULT_CLASS" aria-live="polite"><strong>\$ $SAFE_COMMAND</strong>
$SAFE_OUTPUT</pre></section></details></div></section></div>

<div class="$CONNECTIONS_CLASS"><section class="section"><div class="section-head"><div><h2>Connect ClearPocket on iPhone</h2><div class="muted">Use one secure address at home and away.</div></div></div><div class="grid">
<article class="card connection"><div class="label">App server address</div><div class="url">$DISPLAY_URL</div><ol class="steps"><li>Install Tailscale on the QNAP and each iPhone, then sign in to the same tailnet.</li><li>In ClearPocket, open <strong>Profile &amp; Settings → Data Source → Connect to Existing Server</strong>.</li><li>Enter the secure address above. The first device signs in normally; add later devices from <strong>Profile &amp; Settings → Devices</strong> using a five-minute QR code.</li></ol></article>
<article class="card"><div class="label">Connection details</div><pre class="connection-data">$SAFE_CONNECTION_INFO</pre><form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="connection-info"><button class="secondary">Refresh details</button></form></article>
</div></section>

<section class="section"><div class="section-head"><div><h2>Secure hosting</h2><div class="muted">Choose how family devices reach this server. Never forward the raw API port.</div></div></div><div class="grid">
<article class="card option recommended"><div class="tag">Recommended</div><h3>Tailscale private HTTPS</h3><p>Encrypted access at home, on cellular, and while traveling without opening router ports. Tailscale access rules still control which devices can reach the server.</p><p class="note">Before enabling: connect the QNAP Tailscale app, enable MagicDNS and HTTPS certificates in your tailnet, and choose a NAS device name that contains no sensitive information.</p>$TAILSCALE_ACTION</article>
<article class="card option"><div class="tag">Home network</div><h3>Private DNS + valid certificate</h3><p>For customers who prefer direct LAN access, use a hostname you control, a publicly trusted certificate, and a QTS reverse proxy to ClearPocket’s loopback bridge.</p><p class="note">This requires router/DNS and certificate administration. Self-signed certificates are not suitable for ordinary iPhone connections.</p><div class="note">Advanced administrators can configure this through the QNAP service CLI with <strong>configure-qnap-https HOSTNAME CONFIGURE</strong>.</div></article>
<article class="card option"><div class="tag">Safety boundary</div><h3>Raw LAN port</h3><p>Port $PORT exists for local diagnostics and initial setup. It is not a secure remote endpoint and must never be forwarded through the router or exposed to the internet.</p><p class="note">Tailscale setup automatically rebinds it to NAS loopback so only the private HTTPS proxy can reach it.</p></article>
</div></section>
</div>

<div class="$DATA_CLASS"><section class="section"><div class="section-head"><div><h2>Hosted household authorities</h2><div class="muted">Operational inventory across the families and friends hosted by this server.</div></div><button id="inventory-refresh" type="button" class="secondary">Refresh inventory</button></div><p class="note">This view intentionally excludes balances, categories, payees, memos, and transaction contents.</p><div id="inventory-summary" class="inventory-summary"><div class="card">Loading inventory…</div></div><div class="card table-wrap"><table class="inventory-table"><thead><tr><th>Household</th><th>Owner</th><th>Members</th><th>Budgets</th><th>Activity</th><th>Storage</th></tr></thead><tbody id="inventory-rows"><tr><td colspan="6">Loading…</td></tr></tbody></table></div><p class="note" id="inventory-status"></p></section></div>

<div class="$BACKUPS_CLASS"><section class="section"><div class="section-head"><div><h2>Backups and recovery</h2><div class="muted">Protect every hosted household as one coordinated authority.</div></div></div><div class="card"><div class="quick"><form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="backup"><button>Encrypted backup now</button></form><form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="hidden" name="command" value="backup-schedule-status"><button class="secondary">Schedule status</button></form></div><details open><summary>Latest result</summary><section class="console"><pre class="$RESULT_CLASS"><strong>\$ $SAFE_COMMAND</strong>
$SAFE_OUTPUT</pre></section></details></div></section></div>

<div class="$LOGS_CLASS"><section class="section"><div class="section-head"><div><h2>Live server logs</h2><div class="muted">Read-only, automatically refreshed container output for troubleshooting.</div></div><div class="quick"><button id="live-toggle" type="button" aria-pressed="false">Pause</button><button id="live-refresh" type="button" class="secondary">Refresh now</button></div></div><section class="console live-console"><pre id="live-output" tabindex="0">Connecting to ClearPocket logs…</pre></section><p class="note" id="live-status">Updates every 3 seconds while this page is visible. The terminal is bounded to recent logs and cannot execute NAS commands.</p><details><summary>Advanced management console</summary><section class="console"><form method="post"><input type="hidden" name="csrf" value="$TOKEN"><input type="text" name="command" aria-label="Management command" autocomplete="off" spellcheck="false" placeholder="Type help for allowed commands"><button>Run</button></form></section></details></section></div>
<script nonce="$TOKEN">
(() => {
  const output = document.getElementById('live-output');
  const status = document.getElementById('live-status');
  const toggle = document.getElementById('live-toggle');
  const refresh = document.getElementById('live-refresh');
  if (!output) return;
  let paused = false;
  let timer;
  let activeRequest;
  async function loadLogs() {
    clearTimeout(timer);
    if (paused || document.hidden) { schedule(); return; }
    if (activeRequest) activeRequest.abort();
    activeRequest = new AbortController();
    try {
      const body = new URLSearchParams({csrf:'$TOKEN', command:'logs', format:'terminal'});
      const response = await fetch(location.pathname, {method:'POST', body, credentials:'same-origin', cache:'no-store', signal:activeRequest.signal});
      const text = await response.text();
      if (!response.ok) throw new Error(text || 'Server returned HTTP ' + response.status);
      const follow = output.scrollTop + output.clientHeight >= output.scrollHeight - 24;
      output.textContent = text;
      if (follow) output.scrollTop = output.scrollHeight;
      status.textContent = 'Updated ' + new Date().toLocaleTimeString() + ' · refreshes every 3 seconds while visible.';
    } catch (error) {
      if (error.name !== 'AbortError') status.textContent = 'Live logs unavailable: ' + error.message;
    } finally {
      activeRequest = undefined;
      schedule();
    }
  }
  function schedule() { clearTimeout(timer); timer = setTimeout(loadLogs, 3000); }
  toggle.addEventListener('click', () => {
    paused = !paused;
    toggle.textContent = paused ? 'Resume' : 'Pause';
    toggle.setAttribute('aria-pressed', String(paused));
    status.textContent = paused ? 'Live updates paused.' : 'Resuming live updates…';
    if (!paused) loadLogs();
  });
  refresh.addEventListener('click', loadLogs);
  document.addEventListener('visibilitychange', () => { if (!document.hidden && !paused) loadLogs(); });
  loadLogs();
})();
</script>
<script nonce="$TOKEN">
(() => {
  if ('$PAGE' !== 'data') return;
  const summary = document.getElementById('inventory-summary');
  const rows = document.getElementById('inventory-rows');
  const status = document.getElementById('inventory-status');
  const refresh = document.getElementById('inventory-refresh');
  const formatBytes = value => {
    const bytes = Number(value || 0);
    if (bytes < 1024) return bytes + ' B';
    const units = ['KB','MB','GB','TB'];
    let amount = bytes / 1024;
    let unit = 0;
    while (amount >= 1024 && unit < units.length - 1) { amount /= 1024; unit += 1; }
    return amount.toFixed(amount >= 10 ? 1 : 2) + ' ' + units[unit];
  };
  const cell = value => { const td = document.createElement('td'); td.textContent = value; return td; };
  async function loadInventory() {
    status.textContent = 'Refreshing hosted data inventory…';
    try {
      const body = new URLSearchParams({csrf:'$TOKEN', command:'authority-inventory', format:'terminal'});
      const response = await fetch(location.pathname + '?page=data', {method:'POST', body, credentials:'same-origin', cache:'no-store'});
      const text = await response.text();
      if (!response.ok) throw new Error(text || 'Server returned HTTP ' + response.status);
      const data = JSON.parse(text);
      summary.replaceChildren();
      const metrics = [['Households',data.summary.households],['Users',data.summary.users],['Budgets',data.summary.budgets],['Database',formatBytes(data.summary.database_bytes)],['Total stored',formatBytes(data.summary.total_bytes)]];
      for (const metric of metrics) { const card=document.createElement('div'); card.className='card'; const label=document.createElement('div'); label.className='label'; label.textContent=metric[0]; const value=document.createElement('div'); value.className='value'; value.textContent=metric[1]; card.append(label,value); summary.append(card); }
      rows.replaceChildren();
      for (const item of data.households) {
        const tr=document.createElement('tr');
        const household=document.createElement('td'); const strong=document.createElement('strong'); strong.textContent=item.name; household.append(strong,document.createElement('br')); household.append(document.createTextNode('Created ' + new Date(item.created_at).toLocaleDateString()));
        const owner=document.createElement('td'); owner.textContent=item.owner_display_name + ' · ' + item.owner_email;
        const activity=item.transactions + ' transactions' + (item.last_activity_at ? ' · ' + new Date(item.last_activity_at).toLocaleDateString() : '');
        const storage=formatBytes(item.attachment_stored_bytes) + ' · ' + item.attachments + ' files';
        tr.append(household,owner,cell(item.members),cell(item.budgets),cell(activity),cell(storage)); rows.append(tr);
      }
      if (!data.households.length) { const tr=document.createElement('tr'); const td=cell('No hosted households yet.'); td.colSpan=6; tr.append(td); rows.append(tr); }
      status.textContent = data.privacy + ' Updated ' + new Date().toLocaleTimeString() + '.';
    } catch (error) { status.textContent = 'Inventory unavailable: ' + error.message; }
  }
  refresh.addEventListener('click', loadInventory);
  loadInventory();
})();
</script>
</main></body></html>
EOF
