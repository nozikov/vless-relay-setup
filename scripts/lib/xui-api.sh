#!/bin/bash
# 3X-UI panel REST API client (v3.x). Bearer-token auth; /panel/api/* is CSRF-exempt.
# Used for inbound + client writes (which must land in the normalized clients/
# client_inbounds tables). settings/xrayTemplateConfig stay on direct DB-write.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_API_TOKEN_FILE="/etc/vpn-cli/api-token"

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

# Idempotently ensure an API token exists in api_tokens and is persisted to file.
# MUST be called inside an `x-ui stop` ... `x-ui start` window (the panel may cache
# api_tokens at boot). 48 hex chars via openssl (NOT tr|head — SIGPIPE under
# pipefail). created_at = epoch millis.
bootstrap_api_token() {
    local token existing
    if [[ -r "$XUI_API_TOKEN_FILE" ]]; then
        token=$(cat "$XUI_API_TOKEN_FILE")
        existing=$(sqlite3 "$XUI_DB" \
            "SELECT COUNT(*) FROM api_tokens WHERE token='${token//\'/\'\'}' AND enabled=1;" 2>/dev/null) || existing=0
        if [[ "$existing" == "1" ]]; then
            log_info "Reusing existing API token ($XUI_API_TOKEN_FILE)"
            return 0
        fi
    fi
    token=$(openssl rand -hex 24)
    sqlite3 "$XUI_DB" "DELETE FROM api_tokens WHERE name='vpn-cli';"
    sqlite3 "$XUI_DB" "INSERT INTO api_tokens (name, token, enabled, created_at) \
        VALUES ('vpn-cli', '${token}', 1, strftime('%s','now')*1000);"
    mkdir -p "$(dirname "$XUI_API_TOKEN_FILE")"
    printf '%s' "$token" > "$XUI_API_TOKEN_FILE"
    chmod 0600 "$XUI_API_TOKEN_FILE"
    log_ok "API token bootstrapped → $XUI_API_TOKEN_FILE"
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
