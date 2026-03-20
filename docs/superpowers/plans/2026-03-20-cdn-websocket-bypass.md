# CDN WebSocket Bypass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional CDN fallback path (Cloudflare + WebSocket) to exit server, with subscription integration on relay.

**Architecture:** XRAY Reality on port 443 handles both Reality and CDN traffic. Non-Reality TLS (from Cloudflare) falls back to Caddy, which routes WebSocket to a new XRAY WS inbound on localhost. Relay generates both Reality and CDN profiles in subscriptions via a fake 3X-UI inbound with externalProxy.

**Tech Stack:** Bash, XRAY, Caddy, SQLite (3X-UI), jq, Cloudflare (manual config)

**Spec:** `docs/superpowers/specs/2026-03-20-cdn-websocket-bypass-design.md`

---

### Task 1: Port collision checking in common.sh

**Files:**
- Modify: `scripts/lib/common.sh:100-102`

- [ ] **Step 1: Update generate_random_port() with collision checking**

Replace the current function:

```bash
generate_random_port() {
    local excluded_ports=("$@")
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        # Skip if port is already listening
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            continue
        fi
        # Skip if in excluded list
        local collision=false
        for ep in "${excluded_ports[@]}"; do
            if [[ "$port" == "$ep" ]]; then
                collision=true
                break
            fi
        done
        if [[ "$collision" == false ]]; then
            echo "$port"
            return
        fi
    done
}
```

- [ ] **Step 2: Verify no existing callers break**

Check all callers of `generate_random_port` — they currently pass no args, so `excluded_ports` will be empty and behavior is unchanged except for the `ss` check.

```bash
grep -rn 'generate_random_port' scripts/
```

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/common.sh
git commit -m "feat: add port collision checking to generate_random_port"
```

---

### Task 2: WS inbound support in xray.sh

**Files:**
- Modify: `scripts/lib/xray.sh:21-111`

- [ ] **Step 1: Add CDN parameters to configure_xray_exit()**

Add three optional parameters after `xver`. The function signature becomes:

```bash
configure_xray_exit() {
    local listen_port="${1:-443}"
    local uuid="$2"
    local private_key="$3"
    local short_id="$4"
    local dest="$5"
    local server_name="$6"
    local xhttp_path="$7"
    local xver="${8:-0}"
    local cdn_ws_port="${9:-}"
    local cdn_ws_path="${10:-}"
```

- [ ] **Step 2: Conditionally add WS inbound to config**

After the existing heredoc (`XRAYEOF`), if `cdn_ws_port` is set, use `jq` to add the WS inbound:

```bash
    if [[ -n "$cdn_ws_port" && -n "$cdn_ws_path" ]]; then
        log_info "Adding CDN WebSocket inbound on 127.0.0.1:${cdn_ws_port}..."
        local tmp_config
        tmp_config=$(jq \
            --argjson ws_port "$cdn_ws_port" \
            --arg ws_path "$cdn_ws_path" \
            '.inbounds += [{
                tag: "vless-ws-in",
                listen: "127.0.0.1",
                port: $ws_port,
                protocol: "vless",
                settings: {
                    clients: [{ id: .inbounds[0].settings.clients[0].id }],
                    decryption: "none"
                },
                streamSettings: {
                    network: "ws",
                    wsSettings: {
                        path: ("/"+$ws_path)
                    }
                },
                sniffing: {
                    enabled: true,
                    destOverride: ["http","tls","quic"],
                    routeOnly: true
                }
            }]' /usr/local/etc/xray/config.json)
        echo "$tmp_config" > /usr/local/etc/xray/config.json
        log_ok "CDN WebSocket inbound added (port: $cdn_ws_port)"
    fi
```

Note: the WS inbound reuses the UUID from the first (Reality) inbound via `.inbounds[0].settings.clients[0].id`.

- [ ] **Step 3: Verify existing callers still work**

Current callers pass 8 positional args. New params 9 and 10 default to empty, so existing calls are unaffected:

```bash
grep -n 'configure_xray_exit' scripts/
```

Files that call it: `setup-exit.sh`, `update-exit.sh`. Both pass exactly 8 args.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/xray.sh
git commit -m "feat: add optional CDN WebSocket inbound to exit XRAY config"
```

---

### Task 3: CDN domain block in caddy.sh

**Files:**
- Modify: `scripts/lib/caddy.sh:40-119`

- [ ] **Step 1: Add CDN parameters to generate_caddyfile()**

Add three parameters after `sub_port`:

```bash
generate_caddyfile() {
    local selfsteal_domain="$1"
    local panel_domain="${2:-}"
    local panel_port="${3:-}"
    local sub_domain="${4:-}"
    local sub_port="${5:-}"
    local cdn_domain="${6:-}"
    local cdn_ws_path="${7:-}"
    local cdn_ws_port="${8:-}"
```

- [ ] **Step 2: Add CDN domain block before the common blocks**

Insert this before the `# Common blocks` comment (before the `http://` redirect block). Add after the sub_domain block and before the common blocks:

```bash
    if [[ -n "$cdn_domain" && -n "$cdn_ws_path" && -n "$cdn_ws_port" ]]; then
        cat >> /etc/caddy/Caddyfile << CADDYEOF

https://${cdn_domain} {
    bind unix/${CADDY_SOCK}
    @websocket {
        path /${cdn_ws_path}
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @websocket 127.0.0.1:${cdn_ws_port}
    root * /var/www/html/selfsteal
    file_server
}
CADDYEOF
    fi
```

- [ ] **Step 3: Verify existing callers unaffected**

Exit calls: `generate_caddyfile "$selfsteal_domain"` — new params default to empty.
Relay calls: `generate_caddyfile "$selfsteal_domain" "$panel_domain" "$panel_port" "$sub_domain" "$sub_port"` — new params default to empty.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/caddy.sh
git commit -m "feat: add CDN domain WebSocket routing to Caddyfile"
```

---

### Task 4: CDN prompts and integration in setup-exit.sh

**Files:**
- Modify: `scripts/setup-exit.sh`

- [ ] **Step 1: Modify SelfSteal prompt to mention CDN**

Change line 62:

```bash
    prompt_input "Domain for SelfSteal SNI (Enter to skip, required for CDN mode)" selfsteal_domain ""
```

- [ ] **Step 2: Add CDN domain prompt after SelfSteal validation**

After the SelfSteal DNS check block (after line 69), add:

```bash
    local cdn_domain=""
    if [[ -n "$selfsteal_domain" ]]; then
        prompt_input "CDN domain for Cloudflare (Enter to skip)" cdn_domain ""
        if [[ -n "$cdn_domain" ]]; then
            if ! validate_domain "$cdn_domain"; then
                log_error "Invalid domain format: $cdn_domain"
                exit 1
            fi
            if [[ "$cdn_domain" == "$selfsteal_domain" ]]; then
                log_error "CDN domain must be different from SelfSteal domain"
                exit 1
            fi
            # Don't check DNS — CDN domain resolves to Cloudflare IP, not server IP
            log_info "CDN domain: $cdn_domain (configure Cloudflare after setup)"
        fi
    fi
```

- [ ] **Step 3: Generate CDN parameters**

After `xhttp_path` generation (after line 83), add:

```bash
    local cdn_ws_path="" cdn_ws_port=""
    if [[ -n "$cdn_domain" ]]; then
        cdn_ws_path=$(generate_random_path)
        cdn_ws_port=$(generate_random_port "$panel_port")
        log_ok "Generated CDN WebSocket path and port"
    fi
```

- [ ] **Step 4: Pass CDN params to configure_xray_exit()**

In the SelfSteal branch (line 99-101), add CDN params:

```bash
        configure_xray_exit 443 "$exit_uuid" "$REALITY_PRIVATE_KEY" \
            "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
            "$xhttp_path" 1 "$cdn_ws_port" "$cdn_ws_path"
```

- [ ] **Step 5: Pass CDN params to generate_caddyfile()**

In the SelfSteal branch, update the `generate_caddyfile` call. On exit server, panel/sub params are empty:

```bash
        generate_caddyfile "$selfsteal_domain" "" "" "" "" \
            "$cdn_domain" "$cdn_ws_path" "$cdn_ws_port"
```

- [ ] **Step 6: Add CDN fields to exit-server-info.txt**

After the existing `EXIT_XHTTP_PATH` line (line 144), add:

```bash
    if [[ -n "$cdn_domain" ]]; then
        cat >> /root/exit-server-info.txt << EOF
CDN_DOMAIN=$cdn_domain
CDN_WS_PATH=$cdn_ws_path
CDN_WS_PORT=$cdn_ws_port
EOF
    fi
```

- [ ] **Step 7: Add Cloudflare instructions to final output**

After the "Values for RELAY server setup" section (around line 180), add:

```bash
    if [[ -n "$cdn_domain" ]]; then
        echo ""
        echo "  CDN domain:       $cdn_domain"
        echo "  CDN WS path:      $cdn_ws_path"
        echo ""
        echo "-------------------------------------------"
        echo "  Cloudflare setup (manual):"
        echo "-------------------------------------------"
        echo "  1. Add ${cdn_domain} to Cloudflare (free plan)"
        echo "  2. DNS: A ${cdn_domain} -> ${server_ip} (Proxy: ON)"
        echo "  3. SSL/TLS -> Full"
        echo "  4. Network -> WebSockets: ON"
        echo ""
    fi
```

Also add CDN values to the "Values for RELAY server setup" section:

```bash
    if [[ -n "$cdn_domain" ]]; then
        echo "  Exit CDN domain:      $cdn_domain"
        echo "  Exit CDN WS path:     $cdn_ws_path"
    fi
```

- [ ] **Step 8: Commit**

```bash
git add scripts/setup-exit.sh
git commit -m "feat: add CDN domain setup to exit server installation"
```

---

### Task 5: CDN inbound for subscriptions in 3xui.sh

**Files:**
- Modify: `scripts/lib/3xui.sh`

This task creates a "fake" inbound in 3X-UI database purely for subscription link generation. The inbound listens on localhost (XRAY runs it but nothing connects externally). The `externalProxy` field tells 3X-UI to generate subscription links pointing to the CDN domain.

- [ ] **Step 1: Research externalProxy column on live server**

SSH to relay server and check if the column exists:

```bash
ssh vpn-relay "sqlite3 /etc/x-ui/x-ui.db '.schema inbounds'"
```

Look for `externalProxy` in the schema. If missing, the 3X-UI version may need upgrading, or we use alternative approach (see Step 1b).

- [ ] **Step 1b: Fallback if externalProxy not available**

If the column doesn't exist, skip CDN inbound creation and instead output a manual VLESS link in setup-relay.sh final output. The link format:

```
vless://<exit-uuid>@<cdn-domain>:443?type=ws&security=tls&path=%2F<ws-path>&host=<cdn-domain>&sni=<cdn-domain>#CDN%20Fallback
```

Users add it to their client manually. This is the simplest fallback.

- [ ] **Step 2: Add create_3xui_cdn_inbound() function**

Add after `patch_3xui_relay_inbound()`:

```bash
create_3xui_cdn_inbound() {
    local exit_uuid="$1"
    local cdn_domain="$2"
    local cdn_ws_path="$3"
    local sub_id="$4"
    local cdn_ws_port="${5:-}"

    log_info "Creating CDN fallback inbound in 3X-UI database..."

    # Use a random localhost port — XRAY will listen but nothing connects externally
    if [[ -z "$cdn_ws_port" ]]; then
        cdn_ws_port=$(generate_random_port)
    fi

    local settings stream_settings sniffing

    settings=$(jq -n -c \
        --arg uuid "$exit_uuid" \
        --arg sub_id "$sub_id" \
        '{
            clients: [{
                id: $uuid,
                email: "cdn-fallback",
                limitIp: 0,
                totalGB: 0,
                expiryTime: 0,
                enable: true,
                subId: $sub_id,
                tgId: "",
                reset: 0
            }],
            decryption: "none",
            fallbacks: []
        }')

    stream_settings=$(jq -n -c \
        --arg ws_path "$cdn_ws_path" \
        '{
            network: "ws",
            security: "none",
            wsSettings: {
                path: ("/"+$ws_path),
                headers: {}
            }
        }')

    sniffing='{"enabled":false}'

    local external_proxy
    external_proxy=$(jq -n -c \
        --arg dest "$cdn_domain" \
        '[{
            forceTls: "tls",
            dest: $dest,
            port: 443,
            remark: ""
        }]')

    # Escape single quotes for SQLite
    local s_settings="${settings//\'/\'\'}"
    local s_stream="${stream_settings//\'/\'\'}"
    local s_sniffing="${sniffing//\'/\'\'}"
    local s_external="${external_proxy//\'/\'\'}"

    # Check if externalProxy column exists
    local has_external_proxy
    has_external_proxy=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM pragma_table_info('inbounds') WHERE name='externalProxy';")

    if [[ "$has_external_proxy" -gt 0 ]]; then
        sqlite3 "$XUI_DB" "INSERT INTO inbounds (
            user_id, up, down, total, remark, enable, expiry_time,
            listen, port, protocol, settings, stream_settings,
            tag, sniffing, externalProxy
        ) VALUES (
            1, 0, 0, 0, 'CDN Fallback', 1, 0,
            '127.0.0.1', ${cdn_ws_port}, 'vless',
            '${s_settings}', '${s_stream}',
            'inbound-cdn', '${s_sniffing}', '${s_external}'
        );"
        log_ok "CDN inbound created with externalProxy -> ${cdn_domain}:443"
    else
        log_warn "externalProxy column not found in 3X-UI database"
        log_warn "CDN profile will not appear in subscriptions automatically"
        log_warn "Upgrade 3X-UI to latest version for full CDN subscription support"
        # Still create inbound without externalProxy — admin can configure manually
        sqlite3 "$XUI_DB" "INSERT INTO inbounds (
            user_id, up, down, total, remark, enable, expiry_time,
            listen, port, protocol, settings, stream_settings,
            tag, sniffing
        ) VALUES (
            1, 0, 0, 0, 'CDN Fallback', 1, 0,
            '127.0.0.1', ${cdn_ws_port}, 'vless',
            '${s_settings}', '${s_stream}',
            'inbound-cdn', '${s_sniffing}'
        );"
        log_ok "CDN inbound created (configure externalProxy manually in panel)"
    fi
}
```

- [ ] **Step 3: Add patch_3xui_cdn_inbound() for normalization cycle**

Same pattern as `patch_3xui_relay_inbound()` — re-add subId after 3X-UI strips it:

```bash
patch_3xui_cdn_inbound() {
    local sub_id="$1"

    log_info "Patching CDN inbound subscription fields..."

    local current_settings
    current_settings=$(sqlite3 "$XUI_DB" \
        "SELECT settings FROM inbounds WHERE tag='inbound-cdn';") || return 0

    if [[ -z "$current_settings" ]]; then
        log_warn "CDN inbound not found, skipping patch"
        return 0
    fi

    local patched_settings
    patched_settings=$(echo "$current_settings" | jq -c \
        --arg sub_id "$sub_id" \
        '.clients[0].subId = $sub_id | .clients[0].tgId = "" | .clients[0].reset = 0')
    local s_settings="${patched_settings//\'/\'\'}"
    sqlite3 "$XUI_DB" \
        "UPDATE inbounds SET settings='${s_settings}' WHERE tag='inbound-cdn';"

    log_ok "CDN inbound patched (subId for subscriptions)"
}
```

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/3xui.sh
git commit -m "feat: add CDN fallback inbound for subscription generation"
```

---

### Task 6: CDN prompts and subscription in setup-relay.sh

**Files:**
- Modify: `scripts/setup-relay.sh`

- [ ] **Step 1: Add CDN prompts after exit server details**

After `exit_xhttp_path` prompt (line 53), add:

```bash
    local cdn_domain="" cdn_ws_path=""
    prompt_input "Exit CDN domain (Enter if not configured)" cdn_domain ""
    if [[ -n "$cdn_domain" ]]; then
        if ! validate_domain "$cdn_domain"; then
            log_error "Invalid domain format: $cdn_domain"
            exit 1
        fi
        prompt_input "Exit CDN WebSocket path" cdn_ws_path
        validate_not_empty "$cdn_ws_path" "CDN WebSocket path" || exit 1
    fi
```

- [ ] **Step 2: Create CDN inbound after relay inbound**

After `create_3xui_relay_inbound` call (line 200), add:

```bash
    if [[ -n "$cdn_domain" ]]; then
        local cdn_sub_id
        cdn_sub_id=$(head -c 8 /dev/urandom | xxd -p)

        create_3xui_cdn_inbound "$exit_uuid" "$cdn_domain" "$cdn_ws_path" \
            "$cdn_sub_id"
    fi
```

- [ ] **Step 3: Patch CDN inbound after normalization restart**

After `patch_3xui_relay_inbound` call (line 210), add:

```bash
    if [[ -n "$cdn_domain" ]]; then
        patch_3xui_cdn_inbound "$cdn_sub_id"
    fi
```

- [ ] **Step 4: Add CDN fallback link to final output**

In the final output section, after the subscription URLs, add:

```bash
    if [[ -n "$cdn_domain" ]]; then
        echo "  CDN Fallback: configured (${cdn_domain})"
        echo "  CDN profile included in subscriptions"
        echo ""
    fi
```

- [ ] **Step 5: Output manual VLESS link as backup**

Always output the CDN VLESS link for manual use, in case externalProxy doesn't work:

```bash
    if [[ -n "$cdn_domain" ]]; then
        local cdn_vless_link="vless://${exit_uuid}@${cdn_domain}:443?type=ws&security=tls&path=%2F${cdn_ws_path}&host=${cdn_domain}&sni=${cdn_domain}#CDN%20Fallback"
        echo "-------------------------------------------"
        echo "  CDN VLESS link (for manual client setup):"
        echo "-------------------------------------------"
        echo "  $cdn_vless_link"
        echo ""
    fi
```

- [ ] **Step 6: Commit**

```bash
git add scripts/setup-relay.sh
git commit -m "feat: add CDN subscription profile to relay setup"
```

---

### Task 7: Preserve CDN mode in update-exit.sh

**Files:**
- Modify: `scripts/update-exit.sh`

- [ ] **Step 1: Detect CDN mode from current XRAY config**

After the `is_selfsteal` detection (line 60), add:

```bash
    local is_cdn=false cdn_ws_port="" cdn_ws_path=""
    cdn_ws_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .port' "$XRAY_CONFIG" 2>/dev/null) || true
    cdn_ws_path=$(jq -r '.inbounds[] | select(.tag=="vless-ws-in") | .streamSettings.wsSettings.path' "$XRAY_CONFIG" 2>/dev/null | sed 's|^/||') || true
    if [[ -n "$cdn_ws_port" && "$cdn_ws_port" != "null" ]]; then
        is_cdn=true
        log_info "CDN mode detected (WS port: $cdn_ws_port)"
    fi
```

- [ ] **Step 2: Pass CDN params to configure_xray_exit()**

Update the `configure_xray_exit` call (line 118-119):

```bash
    configure_xray_exit "$listen_port" "$uuid" "$private_key" \
        "$short_id" "$dest" "$server_name" "$xhttp_path" "$xver" \
        "$cdn_ws_port" "$cdn_ws_path"
```

- [ ] **Step 3: Add CDN fields to exit-server-info.txt**

After the existing info file generation (line 159), add:

```bash
    if [[ "$is_cdn" == true ]]; then
        # Read CDN domain from existing Caddyfile
        local cdn_domain=""
        cdn_domain=$(grep -oP '(?<=https://)\S+(?= \{)' /etc/caddy/Caddyfile 2>/dev/null | grep -v "$server_name" | head -1) || true
        if [[ -n "$cdn_domain" ]]; then
            cat >> /root/exit-server-info.txt << EOF
CDN_DOMAIN=$cdn_domain
CDN_WS_PATH=$cdn_ws_path
CDN_WS_PORT=$cdn_ws_port
EOF
        fi
    fi
```

- [ ] **Step 4: Commit**

```bash
git add scripts/update-exit.sh
git commit -m "feat: preserve CDN mode during exit server updates"
```

---

### Task 8: Preserve CDN params in update-relay.sh

**Files:**
- Modify: `scripts/update-relay.sh`

- [ ] **Step 1: Detect CDN inbound in DB**

After `is_selfsteal` detection (line 98), add:

```bash
    local is_cdn=false
    local cdn_settings
    cdn_settings=$(sqlite3 "$XUI_DB" \
        "SELECT settings FROM inbounds WHERE tag='inbound-cdn';" 2>/dev/null) || true
    if [[ -n "$cdn_settings" ]]; then
        is_cdn=true
        log_info "CDN mode detected"
    fi
```

CDN inbound data is preserved automatically — we don't touch it during template updates. The template only affects outbounds and routing, not inbounds. 3X-UI manages inbounds separately.

- [ ] **Step 2: Log CDN status in final output**

In the "Done" section (line 188), add:

```bash
    if [[ "$is_cdn" == true ]]; then
        echo "  CDN fallback inbound preserved"
    fi
```

- [ ] **Step 3: Commit**

```bash
git add scripts/update-relay.sh
git commit -m "feat: detect and preserve CDN mode during relay updates"
```

---

### Task 9: WS port verification in verify.sh

**Files:**
- Modify: `scripts/lib/verify.sh`

- [ ] **Step 1: Add CDN verification to verify_exit_server()**

Add `cdn_ws_port` parameter and verification. Update the function signature:

```bash
verify_exit_server() {
    local panel_port="$1"
    local selfsteal_domain="${2:-}"
    local cdn_ws_port="${3:-}"
```

After the SelfSteal verification block (line 47), add:

```bash
    if [[ -n "$cdn_ws_port" ]]; then
        verify_port_listening "$cdn_ws_port" "CDN WebSocket (localhost)" || ok=false
    fi
```

- [ ] **Step 2: Update callers of verify_exit_server()**

In `setup-exit.sh`, update the call:

```bash
    verify_exit_server "$panel_port" "${selfsteal_domain:-}" "${cdn_ws_port:-}"
```

In `update-exit.sh`, update the call:

```bash
    verify_exit_server "${panel_port:-0}" "$selfsteal_domain" "${cdn_ws_port:-}"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/verify.sh scripts/setup-exit.sh scripts/update-exit.sh
git commit -m "feat: add CDN WebSocket port to exit server verification"
```

---

### Task 10: E2E verification on live servers

**Files:** None (manual testing)

- [ ] **Step 1: Test exit setup with CDN**

```bash
ssh vpn-exit "cd ~/vless-relay-setup && git pull && sudo ./scripts/setup.sh exit --force"
# During setup: enter SelfSteal domain + CDN domain
```

Verify:
- XRAY config has two inbounds (vless-reality-in + vless-ws-in)
- Caddy has CDN domain block in Caddyfile
- WS port is listening on localhost
- exit-server-info.txt contains CDN fields
- Cloudflare instructions shown in output

- [ ] **Step 2: Configure Cloudflare manually**

In Cloudflare dashboard:
1. Add CDN domain
2. A record -> exit IP, Proxy ON
3. SSL/TLS -> Full
4. Network -> WebSockets ON

- [ ] **Step 3: Test CDN path works**

From a client machine, test the CDN WebSocket path:

```bash
curl -v --http1.1 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  "https://cdn-domain.com/ws-path"
```

Expected: 101 Switching Protocols (or connection upgrade attempt).

- [ ] **Step 4: Test relay setup with CDN**

```bash
ssh vpn-relay "cd ~/vless-relay-setup && git pull && sudo ./scripts/setup.sh relay --force"
# During setup: enter CDN domain and WS path from exit output
```

Verify:
- CDN inbound exists in 3X-UI DB: `sqlite3 /etc/x-ui/x-ui.db "SELECT tag,remark FROM inbounds;"`
- Subscription includes CDN profile (check subscription URL in browser)

- [ ] **Step 5: Test VPN connectivity via both paths**

1. Import subscription in VPN client (v2rayN, Hiddify, etc.)
2. Verify two profiles appear (Reality + CDN)
3. Connect via Reality profile — confirm internet works
4. Connect via CDN profile — confirm internet works

- [ ] **Step 6: Test update scripts preserve CDN**

```bash
ssh vpn-exit "cd ~/vless-relay-setup && sudo ./scripts/setup.sh update-exit"
ssh vpn-relay "cd ~/vless-relay-setup && sudo ./scripts/setup.sh update-relay"
```

Verify CDN configuration is preserved after both updates.
