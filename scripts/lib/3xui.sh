#!/bin/bash
# 3X-UI panel installation and configuration

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

XUI_BIN="${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"

install_3xui() {
    log_info "Installing 3X-UI panel..."

    # Open port 80 temporarily — the installer uses it for Let's Encrypt SSL cert
    ufw allow 80/tcp comment "ACME temp" > /dev/null 2>&1 || true

    # The installer asks interactive questions (confirm, port, SSL method, etc.)
    # Create an input file with empty lines to accept all defaults.
    # Using a file instead of pipe (yes "") avoids SIGPIPE with set -o pipefail.
    printf '\n%.0s' {1..100} > /tmp/xui-answers
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) < /tmp/xui-answers
    rm -f /tmp/xui-answers

    # Close temporary port 80
    ufw delete allow 80/tcp > /dev/null 2>&1 || true

    if command -v x-ui &> /dev/null; then
        log_ok "3X-UI installed"
    else
        log_error "3X-UI installation failed"
        exit 1
    fi
}

# Set a key-value pair in x-ui settings database
xui_db_set() {
    local key="$1"
    local value="$2"

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
    local exit_xhttp_path="$7"

    log_info "Writing xray template config to 3X-UI database..."

    # Pick a random port for the API tunnel (3X-UI gRPC ↔ xray)
    local api_port
    api_port=$(shuf -i 10000-60000 -n1)

    local template
    template=$(jq -n -c \
        --arg exit_ip "$exit_ip" \
        --argjson exit_port "$exit_port" \
        --arg exit_uuid "$exit_uuid" \
        --arg exit_pubkey "$exit_pubkey" \
        --arg exit_short_id "$exit_short_id" \
        --arg exit_sni "$exit_sni" \
        --arg exit_xhttp_path "$exit_xhttp_path" \
        --argjson api_port "$api_port" \
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
                                encryption: "none"
                            }]
                        }]
                    },
                    streamSettings: {
                        network: "xhttp",
                        xhttpSettings: {
                            mode: "auto",
                            path: ("/"+$exit_xhttp_path)
                        },
                        security: "reality",
                        realitySettings: {
                            show: false,
                            fingerprint: "chrome",
                            serverName: $exit_sni,
                            publicKey: $exit_pubkey,
                            shortId: $exit_short_id
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

    # Escape single quotes for SQLite
    local escaped="${template//\'/\'\'}"
    xui_db_set "xrayTemplateConfig" "$escaped"

    log_ok "Xray relay template written to 3X-UI database (API port: $api_port)"
}

create_3xui_relay_inbound() {
    local relay_uuid="$1"
    local private_key="$2"
    local public_key="$3"
    local short_id="$4"
    local dest="$5"
    local server_name="$6"

    log_info "Creating VLESS Reality relay inbound in 3X-UI database..."

    local sub_id settings stream_settings sniffing
    sub_id="${7:-$(head -c 8 /dev/urandom | xxd -p)}"

    settings=$(jq -n -c \
        --arg uuid "$relay_uuid" \
        --arg sub_id "$sub_id" \
        '{
            clients: [{
                id: $uuid,
                flow: "xtls-rprx-vision",
                email: "default-user",
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

    # 3X-UI subscription generator reads publicKey and fingerprint
    # from realitySettings.settings (nested), not from the top level.
    stream_settings=$(jq -n -c \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg dest "$dest" \
        --arg server_name "$server_name" \
        '{
            network: "tcp",
            security: "reality",
            realitySettings: {
                show: false,
                dest: ($dest+":443"),
                xver: 0,
                serverNames: [$server_name],
                privateKey: $private_key,
                publicKey: $public_key,
                shortIds: [$short_id],
                settings: {
                    publicKey: $public_key,
                    fingerprint: "chrome",
                    spiderX: ""
                }
            },
            tcpSettings: {
                acceptProxyProtocol: false,
                header: { type: "none" }
            }
        }')

    sniffing=$(jq -n -c '{
        enabled: true,
        destOverride: ["http","tls","quic"]
    }')

    # Escape single quotes for SQLite
    local s_settings="${settings//\'/\'\'}"
    local s_stream="${stream_settings//\'/\'\'}"
    local s_sniffing="${sniffing//\'/\'\'}"

    sqlite3 "$XUI_DB" "INSERT INTO inbounds (
        user_id, up, down, total, remark, enable, expiry_time,
        listen, port, protocol, settings, stream_settings,
        tag, sniffing
    ) VALUES (
        1, 0, 0, 0, 'VLESS Reality Relay', 1, 0,
        '', 443, 'vless', '${s_settings}', '${s_stream}',
        'inbound-443', '${s_sniffing}'
    );"

    log_ok "VLESS Reality relay inbound created (port 443, tag inbound-443)"
    log_info "  Default client subId: $sub_id"
}

# 3X-UI normalizes inbound JSON on first restart after INSERT, stripping
# fields it doesn't expect in server-side config (subId, realitySettings.settings).
# This function re-adds them so subscriptions work correctly.
# Must be called AFTER the x-ui restart that follows create_3xui_relay_inbound.
patch_3xui_relay_inbound() {
    local sub_id="$1"
    local public_key="$2"

    log_info "Patching relay inbound subscription fields..."

    local current_settings current_stream

    # Re-add subId to client settings
    current_settings=$(sqlite3 "$XUI_DB" \
        "SELECT settings FROM inbounds WHERE tag='inbound-443';")
    local patched_settings
    patched_settings=$(echo "$current_settings" | jq -c \
        --arg sub_id "$sub_id" \
        '.clients[0].subId = $sub_id | .clients[0].tgId = "" | .clients[0].reset = 0')
    local s_settings="${patched_settings//\'/\'\'}"
    sqlite3 "$XUI_DB" \
        "UPDATE inbounds SET settings='${s_settings}' WHERE tag='inbound-443';"

    # Re-add realitySettings.settings (publicKey + fingerprint for subscription URLs)
    current_stream=$(sqlite3 "$XUI_DB" \
        "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';")
    local patched_stream
    patched_stream=$(echo "$current_stream" | jq -c \
        --arg public_key "$public_key" \
        '.realitySettings.settings = {
            publicKey: $public_key,
            fingerprint: "chrome",
            spiderX: ""
        }')
    local s_stream="${patched_stream//\'/\'\'}"
    sqlite3 "$XUI_DB" \
        "UPDATE inbounds SET stream_settings='${s_stream}' WHERE tag='inbound-443';"

    log_ok "Relay inbound patched (subId + publicKey for subscriptions)"
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

    x-ui restart

    log_ok "Subscription configured:"
    log_info "  URL: https://${domain}:${sub_port}/${sub_path}/"
}

issue_domain_cert() {
    local domain="$1"

    log_info "Issuing SSL certificate for ${domain}..."

    # Verify DNS resolves to this server before attempting ACME
    local server_ip domain_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip=""
    domain_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1) || domain_ip=""

    if [[ -z "$domain_ip" ]]; then
        log_warn "DNS for ${domain} does not resolve yet"
        log_warn "Set A-record: ${domain} → ${server_ip}"
        log_warn "Then issue cert manually: ~/.acme.sh/acme.sh --issue -d $domain --standalone --force"
        return 1
    fi

    if [[ -n "$server_ip" && "$domain_ip" != "$server_ip" ]]; then
        log_warn "DNS for ${domain} resolves to ${domain_ip}, but this server is ${server_ip}"
        log_warn "Fix the A-record, then issue cert manually:"
        log_warn "  ~/.acme.sh/acme.sh --issue -d $domain --standalone --force"
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

    if "$acme" --issue -d "$domain" --standalone --force; then
        local cert_dir="/root/cert/domain"
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
        log_warn "  $acme --issue -d $domain --standalone --force"
        return 1
    fi

    ufw delete allow 80/tcp > /dev/null 2>&1 || true
}
