#!/bin/bash
# 3X-UI panel installation and configuration

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/xui-api.sh"

XUI_BIN="${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"

# NOTE: client/inbound writes are delegated to lib/xui-api.sh (REST API on v3.x).
# This module sources xui-api.sh directly (same as common.sh) so create_3xui_relay_inbound
# and sync_cdn_clients can call xui_api_*. Orchestration scripts that ALSO call xui_api_*
# directly still source xui-api.sh themselves (enforced by the lib-imports invariant).

# xhttp_extra_json() shared helper now lives in common.sh so xray.sh (exit)
# and 3xui.sh (relay) use the same values. This prevents mismatch between
# relay outbound scMaxEachPostBytes and exit inbound cap.

install_3xui() {
    local skip_acme_port="${1:-false}"

    log_info "Installing 3X-UI panel..."

    # Open port 80 temporarily — the installer uses it for Let's Encrypt SSL cert
    ufw allow 80/tcp comment "ACME temp" > /dev/null 2>&1 || true

    # Pin 3X-UI to v3.1.0 and pull install.sh from the SAME tag (not master) so the
    # interactive prompt set is stable. Verified against the v3.1.0 installer source
    # (config_after_install / prompt_and_setup_ssl), the fresh-install prompt order is:
    #   1. Database type        [Choose [1]:]        blank → 1 = SQLite
    #   2. Customize panel port? [y/n]               blank → random port
    #   3. SSL method            [Choose (default 2)] → 4 = Skip SSL
    #      (blank here defaults to 2 = Let's Encrypt IP cert, which runs acme.sh on
    #       :80 and collides with Caddy — must explicitly pick 4)
    #   4. Bind panel to 127.0.0.1 only? [y/N]       blank → N (keep all-interfaces)
    # The SSL prompt is the 3rd read, not the 2nd — feeding 4 too early lands it on the
    # panel-port question and leaves SSL at its IP-cert default. Order matters.
    {
        printf '\n'   # 1. DB type            → SQLite (default 1)
        printf '\n'   # 2. Customize port?    → no (random port)
        printf '4\n'  # 3. SSL method         → Skip SSL
        printf '\n'   # 4. Bind to 127.0.0.1? → N (all interfaces)
        printf '\n%.0s' {1..96}  # any further/unexpected prompts: accept defaults
    } > /tmp/xui-answers
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/v3.1.0/install.sh) v3.1.0 < /tmp/xui-answers
    rm -f /tmp/xui-answers

    # Close temporary port 80 — unless Caddy needs it permanently (SelfSteal mode)
    if [[ "$skip_acme_port" != true ]]; then
        ufw delete allow 80/tcp > /dev/null 2>&1 || true
    fi

    if command -v x-ui &> /dev/null; then
        log_ok "3X-UI installed"
    else
        log_error "3X-UI installation failed"
        exit 1
    fi
}

# In SelfSteal mode Caddy owns all certs (its own + copied to Hysteria),
# so the acme.sh cron installed by 3X-UI's installer just spams the log
# with "port 80 already used by caddy" once a day. Drop it.
# Best-effort: if the operator runs acme.sh for unrelated sites on the same
# box, restore via `~/.acme.sh/acme.sh --install-cronjob`.
disable_acme_cron() {
    local acme="/root/.acme.sh/acme.sh"
    [[ -f "$acme" ]] || return 0

    # Skip if the cron entry isn't there (avoids a noisy log line on re-runs)
    if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
        return 0
    fi

    if "$acme" --uninstall-cronjob > /dev/null 2>&1; then
        log_ok "Disabled acme.sh cron (Caddy handles certs in SelfSteal mode)"
    else
        log_warn "acme.sh --uninstall-cronjob failed; cron may still fire on :80"
    fi
}

# Set a key-value pair in x-ui settings database
xui_db_set() {
    local key="${1//\'/\'\'}"
    local value="${2//\'/\'\'}"

    local exists
    exists=$(sqlite3 "$XUI_DB" "SELECT COUNT(*) FROM settings WHERE key='$key';")

    if [[ "$exists" -gt 0 ]]; then
        sqlite3 "$XUI_DB" "UPDATE settings SET value='$value' WHERE key='$key';"
    else
        sqlite3 "$XUI_DB" "INSERT INTO settings (key, value) VALUES ('$key', '$value');"
    fi
}

configure_3xui() {
    local panel_port="$1"
    local panel_path="$2"
    local admin_user="$3"
    local admin_pass="$4"

    log_info "Configuring 3X-UI panel..."

    # Stop x-ui BEFORE changing settings.
    # The running process overwrites the DB on shutdown with its in-memory state,
    # so any changes made while it's running get lost on restart.
    x-ui stop

    # Set panel port
    "$XUI_BIN" setting -port "$panel_port"

    # Set panel URL path
    "$XUI_BIN" setting -webBasePath "/$panel_path/"

    # Set admin credentials
    "$XUI_BIN" setting -username "$admin_user" -password "$admin_pass"

    # Start with new settings
    x-ui start

    log_ok "3X-UI configured:"
    log_info "  URL: https://<server-ip>:${panel_port}/${panel_path}/"
    log_info "  User: $admin_user"
}

configure_3xui_relay_template() {
    local exit_ip="$1"
    local exit_port="$2"
    local exit_uuid="$3"
    local exit_pubkey="$4"
    local exit_short_id="$5"
    local exit_sni="$6"

    local api_port="${7:-$(shuf -i 10000-60000 -n1)}"

    log_info "Writing xray template config to 3X-UI database..."

    local extra_json
    extra_json=$(xhttp_extra_json)

    local template
    template=$(jq -n -c \
        --arg exit_ip "$exit_ip" \
        --argjson exit_port "$exit_port" \
        --arg exit_uuid "$exit_uuid" \
        --arg exit_pubkey "$exit_pubkey" \
        --arg exit_short_id "$exit_short_id" \
        --arg exit_sni "$exit_sni" \
        --argjson api_port "$api_port" \
        --argjson extra "$extra_json" \
        '{
            log: {
                loglevel: "warning",
                access: "/var/log/xray/access.log",
                error: "/var/log/xray/error.log"
            },
            api: {
                services: ["HandlerService", "LoggerService", "StatsService"],
                tag: "api"
            },
            inbounds: [
                {
                    tag: "api",
                    listen: "127.0.0.1",
                    port: $api_port,
                    protocol: "dokodemo-door",
                    settings: { address: "127.0.0.1" }
                }
            ],
            stats: {},
            policy: {
                levels: {"0": {statsUserUplink: true, statsUserDownlink: true}},
                system: {
                    statsInboundUplink: true,
                    statsInboundDownlink: true,
                    statsOutboundUplink: true,
                    statsOutboundDownlink: true
                }
            },
            outbounds: [
                {
                    tag: "proxy-exit",
                    protocol: "vless",
                    settings: {
                        vnext: [{
                            address: $exit_ip,
                            port: $exit_port,
                            users: [{
                                id: $exit_uuid,
                                encryption: "none",
                                flow: "xtls-rprx-vision"
                            }]
                        }]
                    },
                    streamSettings: {
                        network: "raw",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            fingerprint: "chrome",
                            serverName: $exit_sni,
                            publicKey: $exit_pubkey,
                            shortId: $exit_short_id
                        },
                        sockopt: {
                            dialerProxy: "fragment",
                            tcpKeepAliveInterval: 30
                        }
                    }
                },
                {
                    tag: "direct",
                    protocol: "freedom"
                },
                {
                    tag: "block",
                    protocol: "blackhole"
                },
                {
                    tag: "fragment",
                    protocol: "freedom",
                    settings: {
                        fragment: {
                            packets: "tlshello",
                            length: "100-200",
                            interval: "10-20"
                        }
                    }
                }
            ],
            routing: {
                rules: [
                    {
                        type: "field",
                        inboundTag: ["api"],
                        outboundTag: "api"
                    },
                    {
                        type: "field",
                        inboundTag: ["inbound-443"],
                        outboundTag: "proxy-exit"
                    }
                ]
            }
        }')

    mkdir -p /var/log/xray

    xui_db_set "xrayTemplateConfig" "$template"

    log_ok "Xray relay template written to 3X-UI database (API port: $api_port)"
}

create_3xui_relay_inbound() {
    local relay_uuid="$1"
    local private_key="$2"
    local public_key="$3"
    local short_id="$4"
    local dest="$5"
    local server_name="$6"

    log_info "Creating VLESS Reality relay inbound via 3X-UI API..."

    local sub_id="${7:-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')}"
    local exit_ip="${8:-}"
    local xver="${9:-0}"
    local relay_xhttp_path="${10:-$(generate_random_path)}"

    local relay_city exit_city remark
    relay_city=$(curl -s --max-time 3 "http://ip-api.com/json/?fields=city" | jq -r '.city // empty') || true
    if [[ -n "$exit_ip" ]]; then
        exit_city=$(curl -s --max-time 3 "http://ip-api.com/json/${exit_ip}?fields=city" | jq -r '.city // empty') || true
    fi
    remark="${relay_city:-Relay} → ${exit_city:-Exit}"

    # Inbound is created WITHOUT clients; the seed client is added via the API
    # (clients/add) so it lands in the normalized clients/client_inbounds tables.
    local settings stream_settings sniffing extra_json lf_json
    settings=$(jq -n -c '{clients: [], decryption: "none", fallbacks: []}')

    extra_json=$(xhttp_extra_json)
    lf_json=$(reality_limit_fallback_json)
    stream_settings=$(jq -n -c \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg dest "$dest" \
        --arg server_name "$server_name" \
        --argjson xver "$xver" \
        --arg relay_path "$relay_xhttp_path" \
        --argjson extra "$extra_json" \
        --argjson lf "$lf_json" \
        '{
            network: "xhttp",
            security: "reality",
            realitySettings: ({
                show: false,
                dest: $dest,
                xver: $xver,
                serverNames: [$server_name],
                privateKey: $private_key,
                publicKey: $public_key,
                shortIds: [$short_id],
                settings: { publicKey: $public_key, fingerprint: "chrome", spiderX: "" }
            } + $lf),
            xhttpSettings: { path: ("/"+$relay_path), mode: "auto", extra: $extra }
        }')

    sniffing=$(jq -n -c '{enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}')

    # v3 inbounds/add: settings/streamSettings/sniffing are escaped JSON STRINGS.
    local inbound_json
    inbound_json=$(jq -n -c \
        --arg remark "$remark" \
        --arg settings "$settings" \
        --arg stream "$stream_settings" \
        --arg sniffing "$sniffing" \
        '{
            remark: $remark, port: 443, protocol: "vless",
            enable: true, expiryTime: 0, total: 0, listen: "",
            tag: "inbound-443",
            settings: $settings, streamSettings: $stream, sniffing: $sniffing
        }')

    local inbound_id
    inbound_id=$(xui_api_add_inbound "$inbound_json") || { log_error "Failed to create relay inbound"; return 1; }
    log_ok "VLESS Reality XHTTP relay inbound created (port 443, tag inbound-443, id $inbound_id)"

    # Add the seed default-user client via the API so it lands in the normalized
    # clients/client_inbounds tables (fixes #44). Done here (not in the caller) so
    # the inbound id stays internal and this function returns nothing on stdout —
    # log_* write to stdout, which would otherwise pollute a captured return value.
    local seed_client
    seed_client=$(jq -n -c --arg id "$relay_uuid" --arg s "$sub_id" \
        '{id:$id, email:"default-user", flow:"", limitIp:0, totalGB:0, expiryTime:0, enable:true, subId:$s, tgId:0, reset:0, comment:""}')
    xui_api_add_client "$inbound_id" "$seed_client" \
        || { log_error "Failed to create seed client (default-user)"; return 1; }
    log_ok "Seed client default-user created (subId $sub_id)"
}

configure_3xui_subscription() {
    local domain="$1"
    local sub_port="$2"
    local sub_path="$3"

    log_info "Configuring subscription service..."

    # Subscription settings are not available via CLI flags,
    # configure directly in the x-ui SQLite database
    xui_db_set "subEnable" "true"
    xui_db_set "subPort" "$sub_port"
    xui_db_set "subPath" "/$sub_path/"
    xui_db_set "subDomain" "$domain"

    log_ok "Subscription configured:"
    log_info "  URL: https://${domain}:${sub_port}/${sub_path}/"
}

issue_domain_cert() {
    local domain="$1"

    log_info "Issuing SSL certificate for ${domain}..."

    # Check if valid cert already exists for this domain
    local cert_dir="/root/cert/domain"
    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        local cert_domain
        cert_domain=$(openssl x509 -in "$cert_dir/fullchain.pem" -noout -subject -nameopt multiline 2>/dev/null \
            | sed -n 's/\s*commonName\s*=\s*//p')
        local cert_expiry
        cert_expiry=$(openssl x509 -in "$cert_dir/fullchain.pem" -noout -enddate 2>/dev/null \
            | cut -d= -f2)
        if [[ "$cert_domain" == "$domain" ]] && \
           openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkend 2592000 2>/dev/null; then
            log_ok "Valid SSL certificate found for ${domain} (expires: $cert_expiry)"
            # Still configure 3X-UI to use the existing cert
            xui_db_set "webCertFile" "$cert_dir/fullchain.pem"
            xui_db_set "webKeyFile" "$cert_dir/privkey.pem"
            xui_db_set "subCertFile" "$cert_dir/fullchain.pem"
            xui_db_set "subKeyFile" "$cert_dir/privkey.pem"
            return 0
        fi
    fi

    # Verify DNS resolves to this server before attempting ACME
    local server_ip domain_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip=""
    domain_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1) || domain_ip=""

    if [[ -z "$domain_ip" ]]; then
        log_warn "DNS for ${domain} does not resolve yet"
        log_warn "Set A-record: ${domain} → ${server_ip}"
        log_warn "Then issue cert manually: ~/.acme.sh/acme.sh --issue -d $domain --standalone"
        return 1
    fi

    if [[ -n "$server_ip" && "$domain_ip" != "$server_ip" ]]; then
        log_warn "DNS for ${domain} resolves to ${domain_ip}, but this server is ${server_ip}"
        log_warn "Fix the A-record, then issue cert manually:"
        log_warn "  ~/.acme.sh/acme.sh --issue -d $domain --standalone"
        return 1
    fi

    # acme.sh is already installed by the 3X-UI installer
    local acme="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme" ]]; then
        log_warn "acme.sh not found, skipping SSL cert (configure manually)"
        return 1
    fi

    # Port 80 must be open for HTTP-01 validation
    ufw allow 80/tcp comment "ACME validation" > /dev/null 2>&1 || true

    if "$acme" --issue -d "$domain" --standalone; then
        mkdir -p "$cert_dir"
        "$acme" --install-cert -d "$domain" \
            --fullchain-file "$cert_dir/fullchain.pem" \
            --key-file "$cert_dir/privkey.pem"

        # Configure 3X-UI to use the domain cert for panel and subscription
        xui_db_set "webCertFile" "$cert_dir/fullchain.pem"
        xui_db_set "webKeyFile" "$cert_dir/privkey.pem"
        xui_db_set "subCertFile" "$cert_dir/fullchain.pem"
        xui_db_set "subKeyFile" "$cert_dir/privkey.pem"

        log_ok "SSL certificate issued and configured for ${domain}"
    else
        log_warn "Failed to issue SSL cert for ${domain}"
        log_warn "Ensure DNS A-record points to this server, then run:"
        log_warn "  $acme --issue -d $domain --standalone"
        return 1
    fi

    ufw delete allow 80/tcp > /dev/null 2>&1 || true
}

create_3xui_cdn_inbound() {
    local exit_uuid="$1"
    local cdn_domain="$2"
    local cdn_path="$3"
    local sub_id="$4"
    local cdn_port="${5:-}"

    log_info "Creating CDN fallback inbound in 3X-UI database..."

    # Use a random localhost port — XRAY will listen but nothing connects externally
    if [[ -z "$cdn_port" ]]; then
        cdn_port=$(generate_random_port)
    fi

    # Validate port is numeric
    if ! [[ "$cdn_port" =~ ^[0-9]+$ ]]; then
        log_error "Invalid CDN port: $cdn_port"
        return 1
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
                tgId: 0,
                reset: 0
            }],
            decryption: "none",
            fallbacks: []
        }')

    stream_settings=$(jq -n -c \
        --arg cdn_path "$cdn_path" \
        '{
            network: "xhttp",
            security: "none",
            xhttpSettings: {
                path: ("/"+$cdn_path),
                mode: "packet-up"
            }
        }')

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'

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
            '127.0.0.1', ${cdn_port}, 'vless',
            '${s_settings}', '${s_stream}',
            'inbound-cdn', '${s_sniffing}', '${s_external}'
        );"
        log_ok "CDN inbound created with externalProxy -> ${cdn_domain}:443"
    else
        log_warn "externalProxy column not found in 3X-UI database"
        log_warn "CDN profile will not appear in subscriptions automatically"
        log_warn "Upgrade 3X-UI to latest version for full CDN subscription support"
        # Still create inbound without externalProxy
        sqlite3 "$XUI_DB" "INSERT INTO inbounds (
            user_id, up, down, total, remark, enable, expiry_time,
            listen, port, protocol, settings, stream_settings,
            tag, sniffing
        ) VALUES (
            1, 0, 0, 0, 'CDN Fallback', 1, 0,
            '127.0.0.1', ${cdn_port}, 'vless',
            '${s_settings}', '${s_stream}',
            'inbound-cdn', '${s_sniffing}'
        );"
        log_ok "CDN inbound created (configure externalProxy manually in panel)"
    fi
}

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
        '.clients[0].subId = $sub_id | .clients[0].tgId = 0 | .clients[0].reset = 0')
    local s_settings="${patched_settings//\'/\'\'}"
    sqlite3 "$XUI_DB" \
        "UPDATE inbounds SET settings='${s_settings}' WHERE tag='inbound-cdn';"

    log_ok "CDN inbound patched (subId for subscriptions)"
}

sync_cdn_clients() {
    log_info "Syncing clients to CDN inbound (via API)..."

    local cdn_id exit_uuid
    cdn_id=$(xui_api_inbound_id "inbound-cdn") || true
    if [[ -z "$cdn_id" ]]; then
        log_warn "CDN inbound not found, nothing to sync"
        return 0
    fi

    # Shared exit UUID = the UUID of the existing CDN inbound's client set.
    # Read it from the CDN inbound's settings JSON (read-only, sqlite is fine).
    exit_uuid=$(sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE tag='inbound-cdn';" \
        | jq -r 'first(.clients[]?.id) // empty') || true
    if [[ -z "$exit_uuid" ]]; then
        log_warn "Cannot determine CDN exit UUID — skipping CDN sync"
        return 0
    fi

    # Desired: one "<email>-cdn" per relay client, same subId, exit UUID.
    local relay_clients
    # Read relay clients from inbound-443 settings JSON: on v3 the API's clients/add
    # back-writes this JSON in addition to the normalized tables, so it stays current.
    relay_clients=$(sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE tag='inbound-443';" \
        | jq -c '[.clients[]? | {email: (.email + "-cdn"), subId: .subId, enable: .enable}]') || true
    [[ -z "$relay_clients" || "$relay_clients" == "null" ]] && relay_clients='[]'
    # Safety: a relay always has >=1 client (default-user). An empty desired set
    # here means an anomalous/empty read — do NOT proceed to the remove-extra loop,
    # which would purge every existing -cdn client. Bail without mutating.
    if [[ "$relay_clients" == "[]" ]]; then
        log_warn "CDN sync: relay client set read as empty — skipping (no add/remove) to avoid purging CDN clients"
        return 0
    fi

    # Current CDN client emails (from clients/list, filtered to the "-cdn" convention).
    local current_cdn
    current_cdn=$(xui_api_list_clients | jq -c '[.[]? | select(.email|endswith("-cdn")) | .email]') || current_cdn='[]'

    # Add missing.
    local desired_emails email
    desired_emails=$(printf '%s' "$relay_clients" | jq -r '.[].email')
    while IFS= read -r email; do
        [[ -z "$email" ]] && continue
        if ! printf '%s' "$current_cdn" | jq -e --arg e "$email" 'index($e) != null' >/dev/null; then
            local sub_id client_json
            sub_id=$(printf '%s' "$relay_clients" | jq -r --arg e "$email" 'first(.[]|select(.email==$e).subId)')
            client_json=$(jq -n -c --arg id "$exit_uuid" --arg e "$email" --arg s "$sub_id" \
                '{id:$id, email:$e, flow:"", limitIp:0, totalGB:0, expiryTime:0, enable:true, subId:$s, tgId:0, reset:0, comment:""}')
            xui_api_add_client "$cdn_id" "$client_json" \
                || log_warn "CDN sync: failed to add $email (continuing)"
        fi
    done <<< "$desired_emails"

    # Remove extra (present on CDN but no matching relay client).
    local cur_email
    while IFS= read -r cur_email; do
        [[ -z "$cur_email" ]] && continue
        if ! printf '%s' "$relay_clients" | jq -e --arg e "$cur_email" 'any(.[]; .email==$e)' >/dev/null; then
            xui_api_del_client "$cur_email" || log_warn "CDN sync: failed to remove $cur_email"
        fi
    done < <(printf '%s' "$current_cdn" | jq -r '.[]')

    log_ok "CDN inbound synced (via API)"
}

# Идемпотентная установка симлинка /usr/local/bin/vpn → <path-to-vpn>.
# Проверяет существование source и предупреждает если в /usr/local/bin/vpn
# лежит чужой не-симлинк (другая программа в PATH с таким именем).
install_vpn_cli_symlink() {
    local src="$1"
    local target="/usr/local/bin/vpn"

    if [[ ! -f "$src" || ! -x "$src" ]]; then
        log_warn "vpn CLI source not found or not executable at $src — skipping symlink"
        return 0
    fi

    if [[ -e "$target" && ! -L "$target" ]]; then
        log_warn "$target exists and is not a symlink — leaving in place. Remove it manually if you want vpn CLI."
        return 0
    fi

    ln -sf "$(realpath "$src")" "$target"
    log_ok "Installed 'vpn' CLI symlink at $target"
}
