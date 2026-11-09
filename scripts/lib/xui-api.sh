#!/bin/bash
# 3X-UI panel REST API client (v3.x). Bearer-token auth; /panel/api/* is CSRF-exempt.
# Used for inbound + client writes (which must land in the normalized clients/
# client_inbounds tables). settings/xrayTemplateConfig stay on direct DB-write.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_API_TOKEN_FILE="${XUI_API_TOKEN_FILE:-/etc/vpn-cli/api-token}"

# Build the API base URL from the settings table. Honours webBasePath
# (stored with leading+trailing slash) and HTTPS if a web cert is configured.
xui_api_base() {
    local port path scheme cert
    port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null) || true
    path=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null) || true
    cert=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null) || true
    [[ -z "$port" ]] && port=2053
    [[ -z "$path" ]] && path="/"
    # normalize to exactly one leading and one trailing slash
    path="/${path#/}"; path="${path%/}/"
    scheme=http
    [[ -n "$cert" ]] && scheme=https
    printf '%s://127.0.0.1:%s%spanel/api' "$scheme" "$port" "$path"
}

# Read the persisted Bearer token. Returns 1 if absent.
xui_api_token() {
    [[ -r "$XUI_API_TOKEN_FILE" ]] || return 1
    cat "$XUI_API_TOKEN_FILE"
}

# Does the panel store api_tokens.token as SHA-256(plaintext)? 3X-UI v3.3.1+ hashes
# at rest: MatchToken() compares SHA-256(presented Bearer) against the column, so a
# plaintext row never matches. v3.1.0 compares plaintext. The on-disk signal is the
# "ApiTokensHash" seeder row: a fresh v3.3.1+ DB records it on first start, an
# upgraded DB records it right after hashExistingApiTokens() rewrote legacy rows.
# Without that row (v3.1.0, or a newer binary that hasn't started yet) plaintext is
# right either way: v3.1.0 reads it as-is, and a newer binary hashes it on first
# start (the seeder skips rows that already look like a SHA-256 hex digest).
xui_api_tokens_hashed() {
    local n
    n=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM history_of_seeders WHERE seeder_name='ApiTokensHash';" 2>/dev/null) || n=0
    [[ "${n:-0}" -gt 0 ]]
}

# Returns 0 if api_tokens has the given column (v3.11 added scope + expires_at).
xui_api_tokens_has_column() {
    local col="$1" n
    n=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM pragma_table_info('api_tokens') WHERE name='${col//\'/\'\'}';" 2>/dev/null) || n=0
    [[ "${n:-0}" -gt 0 ]]
}

# Lowercase hex SHA-256 of a string — same as 3X-UI crypto.HashTokenSHA256
# (unsalted, hex-encoded). openssl rather than sha256sum: already a dependency.
xui_sha256_hex() {
    printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
}

# Idempotently ensure an API token exists in api_tokens and is persisted to file.
# MUST be called inside an `x-ui stop` ... `x-ui start` window (direct DB write; a
# running panel would overwrite it from memory on shutdown). 48 hex chars via
# openssl (NOT tr|head — SIGPIPE under pipefail).
#
# $XUI_API_TOKEN_FILE always holds the PLAINTEXT (that is what the Bearer header
# carries). What goes into the DB depends on the panel — see xui_api_tokens_hashed.
# On v3.11 the row also needs scope='admin' (MatchToken rejects an unknown/empty
# scope) and expires_at=0 (never); both columns are set only when they exist, so
# the same code still works against a v3.1.0 DB (update-relay without --upgrade).
#
# Upgrade v3.1.0 → v3.11.0: the first start of the new binary hashes our plaintext
# row, so the reuse check (by hash) matches and the token keeps working. A row left
# plaintext after the hashing seeder already ran fails the check and is re-issued,
# so every update-relay run self-heals a broken token.
#
# The installer's own admin tokens (install/cli-fallback) are revoked separately by
# revoke_installer_api_tokens in lib/3xui.sh — that has to run on the exit too.
bootstrap_api_token() {
    local token db_token existing hashed=false
    local where_extra="" extra_cols="" extra_vals=""
    xui_api_tokens_hashed && hashed=true
    if xui_api_tokens_has_column scope; then
        where_extra+=" AND scope='admin'"; extra_cols+=", scope"; extra_vals+=", 'admin'"
    fi
    if xui_api_tokens_has_column expires_at; then
        where_extra+=" AND expires_at=0"; extra_cols+=", expires_at"; extra_vals+=", 0"
    fi

    if [[ -r "$XUI_API_TOKEN_FILE" ]]; then
        token=$(cat "$XUI_API_TOKEN_FILE")
        if [[ -n "$token" ]]; then
            db_token="$token"
            [[ "$hashed" == true ]] && db_token=$(xui_sha256_hex "$token")
            existing=$(sqlite3 "$XUI_DB" \
                "SELECT COUNT(*) FROM api_tokens WHERE name='vpn-cli' AND token='${db_token//\'/\'\'}' AND enabled=1${where_extra};" \
                2>/dev/null) || existing=0
            if [[ "$existing" == "1" ]]; then
                log_info "Reusing existing API token ($XUI_API_TOKEN_FILE)"
                return 0
            fi
        fi
    fi

    token=$(openssl rand -hex 24)
    db_token="$token"
    [[ "$hashed" == true ]] && db_token=$(xui_sha256_hex "$token")
    sqlite3 "$XUI_DB" "DELETE FROM api_tokens WHERE name='vpn-cli';"
    # created_at in epoch millis (what v3.1.0 expects); v3.11 normalizes millis to
    # seconds on start (normalizeApiTokenCreatedAtSeconds), so one value fits both.
    sqlite3 "$XUI_DB" "INSERT INTO api_tokens (name, token, enabled, created_at${extra_cols}) \
        VALUES ('vpn-cli', '${db_token}', 1, strftime('%s','now')*1000${extra_vals});"
    mkdir -p "$(dirname "$XUI_API_TOKEN_FILE")"
    (umask 077 && printf '%s' "$token" > "$XUI_API_TOKEN_FILE")
    chmod 0600 "$XUI_API_TOKEN_FILE"
    if [[ "$hashed" == true ]]; then
        log_ok "API token bootstrapped (stored as SHA-256) → $XUI_API_TOKEN_FILE"
    else
        log_ok "API token bootstrapped → $XUI_API_TOKEN_FILE"
    fi
}

# xui_api_request METHOD PATH [JSON_BODY]
# Echoes the JSON payload on success; returns 1 (with log_error) otherwise.
xui_api_request() {
    local method="$1" path="$2" body="${3:-}"
    local token base url curlopts=()
    token=$(xui_api_token) || { log_error "No API token — run setup-relay/update-relay to bootstrap"; return 1; }
    base=$(xui_api_base)
    url="${base}/${path#/}"
    curlopts=(-sS -m 15 -w $'\n%{http_code}'
        -H "Authorization: Bearer ${token}"
        -H "X-Requested-With: XMLHttpRequest")
    [[ "$base" == https://* ]] && curlopts+=(-k)
    if [[ -n "$body" ]]; then
        curlopts+=(-H "Content-Type: application/json" --data "$body")
    fi
    local resp http_code payload ok msg
    resp=$(curl "${curlopts[@]}" -X "$method" "$url") || { log_error "curl $method $url failed"; return 1; }
    http_code="${resp##*$'\n'}"
    payload="${resp%$'\n'*}"
    if [[ "$http_code" != "200" ]]; then
        log_error "API $method ${path} → HTTP ${http_code}: ${payload}"
        return 1
    fi
    ok=$(printf '%s' "$payload" | jq -r '.success // false' 2>/dev/null) || ok=false
    if [[ "$ok" != "true" ]]; then
        msg=$(printf '%s' "$payload" | jq -r '.msg // "unknown error"' 2>/dev/null) || msg="unparseable response"
        log_error "API $method ${path} → success=false: ${msg}"
        return 1
    fi
    printf '%s' "$payload"
}

# Create an inbound from a full inbound JSON object. Echoes created inbound id.
xui_api_add_inbound() {
    local inbound_json="$1" resp id
    resp=$(xui_api_request POST "inbounds/add" "$inbound_json") || return 1
    id=$(printf '%s' "$resp" | jq -r '.obj.id // empty')
    if [[ -z "$id" ]]; then
        local tag
        tag=$(printf '%s' "$inbound_json" | jq -r '.tag // empty')
        [[ -n "$tag" ]] && id=$(xui_api_inbound_id "$tag")
    fi
    [[ -n "$id" ]] || { log_error "inbounds/add: cannot determine new inbound id"; return 1; }
    printf '%s' "$id"
}

# Look up an inbound id by tag.
xui_api_inbound_id() {
    local tag="$1" resp
    resp=$(xui_api_request GET "inbounds/list") || return 1
    printf '%s' "$resp" | jq -r --arg t "$tag" 'first(.obj[]? | select(.tag==$t) | .id) // empty'
}

# Add a client (client JSON object) to the inbound with the given numeric id.
xui_api_add_client() {
    local inbound_id="$1" client_json="$2" body
    body=$(jq -n -c --argjson client "$client_json" --argjson iid "$inbound_id" \
        '{client: $client, inboundIds: [$iid]}')
    xui_api_request POST "clients/add" "$body" >/dev/null
}

# Delete a client across all inbounds by email.
xui_api_del_client() {
    local email="$1"
    xui_api_request POST "clients/del/${email}" >/dev/null
}

# Echo the clients array (from clients/list) as JSON.
xui_api_list_clients() {
    local resp
    resp=$(xui_api_request GET "clients/list") || return 1
    printf '%s' "$resp" | jq -c '.obj // []'
}
