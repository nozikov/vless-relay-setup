#!/bin/bash
# Update relay server configuration from latest codebase
# Run: ./setup.sh update-relay [--upgrade]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/caddy.sh"

main() {
    local upgrade=false skip_ssh=false
    for arg in "$@"; do
        case "$arg" in
            --upgrade) upgrade=true ;;
            --skip-ssh) skip_ssh=true ;;
        esac
    done

    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Update  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root

    # Backup 3X-UI database before any changes
    local backup_path
    backup_path="${XUI_DB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$XUI_DB" "$backup_path"
    log_ok "Database backup saved: $backup_path"

    # --- Step 1: Validate existing installation ---
    log_info "=== Checking existing installation ==="

    if [[ ! -f "$XUI_DB" ]]; then
        log_error "3X-UI database not found at $XUI_DB"
        log_error "Run './setup.sh relay' first to perform initial setup"
        exit 1
    fi

    if ! command -v x-ui &> /dev/null; then
        log_error "3X-UI not found"
        log_error "Run './setup.sh relay' first to perform initial setup"
        exit 1
    fi

    # --- Step 2: Extract current values ---
    log_info "=== Reading current configuration ==="

    local template
    template=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';")

    if [[ -z "$template" ]]; then
        log_error "No xray template config found in 3X-UI database"
        log_error "Run './setup.sh relay' first to perform initial setup"
        exit 1
    fi

    local exit_ip exit_port exit_uuid exit_pubkey exit_short_id exit_sni exit_xhttp_path api_port
    exit_ip=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].address')
    exit_port=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].port')
    exit_uuid=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].users[0].id')
    exit_pubkey=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.publicKey')
    exit_short_id=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.shortId')
    exit_sni=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.serverName')
    exit_xhttp_path=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.xhttpSettings.path' | sed 's|^/||')
    api_port=$(echo "$template" | jq -r '.inbounds[] | select(.tag=="api") | .port')

    if [[ -z "$exit_ip" || "$exit_ip" == "null" ]]; then
        log_error "Failed to extract exit server details from template"
        exit 1
    fi

    log_ok "Current config read successfully"
    log_info "  Exit:     $exit_ip:$exit_port"
    log_info "  SNI:      $exit_sni"
    log_info "  API port: $api_port"

    # Read panel/subscription ports from DB
    local panel_port sub_port sub_enable
    panel_port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';") || true
    sub_enable=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subEnable';") || true
    sub_port=""
    if [[ "$sub_enable" == "true" ]]; then
        sub_port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort';") || true
    fi

    local is_selfsteal=false
    local current_dest
    current_dest=$(sqlite3 "$XUI_DB" \
        "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';" | \
        jq -r '.realitySettings.dest') || true
    if [[ "$current_dest" == *"caddy.sock"* ]]; then
        is_selfsteal=true
        log_info "SelfSteal mode detected"
    fi

    local is_cdn=false
    local cdn_settings
    cdn_settings=$(sqlite3 "$XUI_DB" \
        "SELECT settings FROM inbounds WHERE tag='inbound-cdn';" 2>/dev/null) || true
    if [[ -n "$cdn_settings" ]]; then
        is_cdn=true
        log_info "CDN mode detected"
    fi

    # --- Step 3: System update ---
    log_info "=== System Update ==="
    update_system

    # --- Step 4: Upgrade 3X-UI (optional) ---
    if [[ "$upgrade" == true ]]; then
        log_info "=== Upgrading 3X-UI ==="
        printf '\n%.0s' {1..100} > /tmp/xui-answers
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) < /tmp/xui-answers
        rm -f /tmp/xui-answers
        log_ok "3X-UI upgraded"

        if [[ "$is_selfsteal" == true ]]; then
            log_info "Upgrading Caddy..."
            apt-get update -qq && apt-get install -y -qq caddy > /dev/null 2>&1
            log_ok "Caddy upgraded"
        fi
    fi

    # --- Step 5: Update xray template ---
    log_info "=== Updating XRAY Template ==="

    # 3X-UI overwrites DB on shutdown with in-memory state.
    # Must stop before writing, then start to load fresh config.
    x-ui stop

    # Patch inbound sniffing to add routeOnly (idempotent — jq sets the field)
    local current_sniffing patched_sniffing
    current_sniffing=$(sqlite3 "$XUI_DB" \
        "SELECT sniffing FROM inbounds WHERE tag='inbound-443';") || true
    if [[ -n "$current_sniffing" ]]; then
        patched_sniffing=$(echo "$current_sniffing" | jq -c '.routeOnly = true')
        local s_sniffing="${patched_sniffing//\'/\'\'}"
        sqlite3 "$XUI_DB" \
            "UPDATE inbounds SET sniffing='${s_sniffing}' WHERE tag='inbound-443';"
        log_ok "Inbound sniffing patched (routeOnly: true)"
    fi

    configure_3xui_relay_template "$exit_ip" "$exit_port" "$exit_uuid" \
        "$exit_pubkey" "$exit_short_id" "$exit_sni" "$exit_xhttp_path" "$api_port"

    x-ui start

    if ! systemctl is-active --quiet x-ui; then
        log_warn "3X-UI failed to start, restoring backup..."
        cp "$backup_path" "$XUI_DB"
        x-ui start
        if systemctl is-active --quiet x-ui; then
            log_ok "Previous database restored, 3X-UI is running"
        else
            log_error "Rollback also failed. Check: x-ui log"
        fi
        exit 1
    fi
    log_ok "3X-UI restarted with updated template"

    # --- Step 5b: Update CDN links in sub-proxy if active ---
    local sub_proxy_service="/etc/systemd/system/sub-proxy.service"
    if [[ -f "$sub_proxy_service" ]] && systemctl is-active --quiet sub-proxy 2>/dev/null; then
        log_info "Updating CDN links in sub-proxy..."

        # Read CDN params — prefer dedicated env vars, fall back to old URL parsing
        local cdn_domain cdn_path
        cdn_domain=$(grep -oP '(?<=CDN_DOMAIN=).+' "$sub_proxy_service") || true
        cdn_path=$(grep -oP '(?<=CDN_PATH=).+' "$sub_proxy_service") || true
        if [[ -z "$cdn_domain" ]]; then
            # Migration from old format: parse from VLESS URL
            cdn_domain=$(grep -oP '(?<=CDN_VLESS_LINK=vless://[^@]+@)[^:]+' "$sub_proxy_service") || true
            cdn_path=$(grep -oP '(?<=path=%%2F)[^&]+' "$sub_proxy_service") || true
        fi

        if [[ -n "$cdn_domain" && -n "$cdn_path" ]]; then
            # Read ExecStart from existing service file
            local exec_start
            exec_start=$(grep -oP '(?<=ExecStart=).+' "$sub_proxy_service") || true

            # Read exit Reality params from the just-written template
            local exit_pubkey_val exit_sni_val exit_short_id_val exit_xhttp_path_val exit_ip_val
            exit_pubkey_val=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.publicKey')
            exit_sni_val=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.serverName')
            exit_short_id_val=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.shortId')
            exit_xhttp_path_val=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.xhttpSettings.path' | sed 's|^/||')
            exit_ip_val=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].address')

            # Symmetric XHTTP CDN link
            local cdn_vless_link="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up#CDN%20XHTTP"

            # Asymmetric CDN link with downloadSettings
            local download_extra extra_encoded cdn_vless_link_asym
            download_extra=$(jq -n -c \
                --arg padding "100-1000" \
                --arg addr "$exit_ip_val" \
                --arg sni "$exit_sni_val" \
                --arg pubkey "$exit_pubkey_val" \
                --arg sid "$exit_short_id_val" \
                --arg path "$exit_xhttp_path_val" \
                '{
                    xPaddingBytes: $padding,
                    downloadSettings: {
                        address: $addr, port: 443, network: "xhttp",
                        security: "reality",
                        realitySettings: {
                            serverName: $sni, publicKey: $pubkey,
                            shortId: $sid, fingerprint: "chrome"
                        },
                        xhttpSettings: { path: ("/"+$path), mode: "auto" }
                    }
                }')
            extra_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$download_extra")
            cdn_vless_link_asym="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up&extra=${extra_encoded}#CDN%20Asymmetric"

            # Escape % for systemd
            local link_escaped="${cdn_vless_link//%/%%}"
            local link_asym_escaped="${cdn_vless_link_asym//%/%%}"

            # Read existing service params
            local sub_upstream sub_proxy_port
            sub_upstream=$(grep -oP '(?<=SUB_UPSTREAM=).+' "$sub_proxy_service") || true
            sub_proxy_port=$(grep -oP '(?<=SUB_PROXY_PORT=).+' "$sub_proxy_service") || true

            # Rewrite entire service file (never sed — & in URLs breaks sed)
            cat > "$sub_proxy_service" << SVCEOF
[Unit]
Description=Subscription proxy (appends CDN link)
After=x-ui.service

[Service]
Type=simple
Environment=CDN_VLESS_LINK=${link_escaped}
Environment=CDN_VLESS_LINK_ASYM=${link_asym_escaped}
Environment=CDN_DOMAIN=${cdn_domain}
Environment=CDN_PATH=${cdn_path}
Environment=SUB_UPSTREAM=${sub_upstream}
Environment=SUB_PROXY_PORT=${sub_proxy_port}
ExecStart=${exec_start}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF
            systemctl daemon-reload
            systemctl restart sub-proxy
            log_ok "Sub-proxy updated with XHTTP CDN links"
        fi
    fi

    # --- Step 6: Security ---
    log_info "=== Security ==="
    local ssh_port
    ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | head -1 | awk '{print $2}') || true
    ssh_port="${ssh_port:-22}"
    log_info "Current SSH port: $ssh_port"

    local security_args=()
    [[ "$skip_ssh" == true ]] && security_args+=("--skip-ssh")
    security_args+=(--ssh-port "$ssh_port" "$ssh_port":SSH 443:XRAY "$panel_port:3X-UI Panel")
    if [[ "$is_selfsteal" == true ]]; then
        security_args+=(80:Caddy-ACME)
    elif [[ -n "$sub_port" ]]; then
        security_args+=("$sub_port:Subscription")
    fi
    setup_security "${security_args[@]}"

    # --- Step 7: Verify ---
    local selfsteal_domain=""
    if [[ "$is_selfsteal" == true ]]; then
        selfsteal_domain=$(sqlite3 "$XUI_DB" \
            "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';" | \
            jq -r '.realitySettings.serverNames[0]') || true
    fi
    verify_relay_server "$panel_port" "${sub_port:-}" "$exit_ip" "$exit_port" "${selfsteal_domain:-}"

    # --- Done ---
    echo ""
    echo "==========================================="
    log_ok "RELAY server update complete!"
    echo "==========================================="
    echo ""
    echo "  Template updated from latest codebase"
    if [[ "$upgrade" == true ]]; then
        echo "  3X-UI upgraded to latest version"
    fi
    echo "  Security re-applied"
    echo "  Clients and subscriptions preserved"
    if [[ "$is_cdn" == true ]]; then
        echo "  CDN fallback inbound preserved"
    fi
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
