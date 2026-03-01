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

    # Set panel port
    "$XUI_BIN" setting -port "$panel_port"

    # Set panel URL path
    "$XUI_BIN" setting -webBasePath "/$panel_path/"

    # Set admin credentials
    "$XUI_BIN" setting -username "$admin_user" -password "$admin_pass"

    # TLS is already configured by the 3X-UI installer (acme.sh)

    # Restart to apply
    x-ui restart

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

    local template
    template=$(jq -n -c \
        --arg exit_ip "$exit_ip" \
        --argjson exit_port "$exit_port" \
        --arg exit_uuid "$exit_uuid" \
        --arg exit_pubkey "$exit_pubkey" \
        --arg exit_short_id "$exit_short_id" \
        --arg exit_sni "$exit_sni" \
        --arg exit_xhttp_path "$exit_xhttp_path" \
        '{
            log: {
                loglevel: "warning",
                access: "/var/log/xray/access.log",
                error: "/var/log/xray/error.log"
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
                rules: [{
                    type: "field",
                    inboundTag: ["inbound-443"],
                    outboundTag: "proxy-exit"
                }]
            }
        }')

    mkdir -p /var/log/xray

    # Escape single quotes for SQLite
    local escaped="${template//\'/\'\'}"
    xui_db_set "xrayTemplateConfig" "$escaped"

    log_ok "Xray relay template written to 3X-UI database"
}

create_3xui_relay_inbound() {
    local relay_uuid="$1"
    local private_key="$2"
    local public_key="$3"
    local short_id="$4"
    local dest="$5"
    local server_name="$6"

    log_info "Creating VLESS Reality relay inbound in 3X-UI database..."

    local settings stream_settings sniffing

    settings=$(jq -n -c \
        --arg uuid "$relay_uuid" \
        '{
            clients: [{
                id: $uuid,
                flow: "xtls-rprx-vision",
                email: "default-user",
                limitIp: 0,
                totalGB: 0,
                expiryTime: 0,
                enable: true
            }],
            decryption: "none",
            fallbacks: []
        }')

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
                shortIds: [$short_id]
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
