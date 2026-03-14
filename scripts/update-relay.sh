#!/bin/bash
# Update relay server configuration from latest codebase
# Run: ./setup.sh update-relay [--upgrade]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/verify.sh"

main() {
    local upgrade=false
    if [[ "${1:-}" == "--upgrade" ]]; then
        upgrade=true
    fi

    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Update"
    echo "==========================================="
    echo ""

    check_root

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
    fi

    # --- Step 5: Update xray template ---
    log_info "=== Updating XRAY Template ==="

    # 3X-UI overwrites DB on shutdown with in-memory state.
    # Must stop before writing, then start to load fresh config.
    x-ui stop

    configure_3xui_relay_template "$exit_ip" "$exit_port" "$exit_uuid" \
        "$exit_pubkey" "$exit_short_id" "$exit_sni" "$exit_xhttp_path" "$api_port"

    x-ui start
    log_ok "3X-UI restarted with updated template"

    # --- Step 6: Security ---
    log_info "=== Security ==="
    local security_args=("22:SSH" "443:XRAY" "$panel_port:3X-UI Panel")
    if [[ -n "$sub_port" ]]; then
        security_args+=("$sub_port:Subscription")
    fi
    setup_security "${security_args[@]}"

    # --- Step 7: Verify ---
    verify_relay_server "$panel_port" "${sub_port:-}" "$exit_ip" "$exit_port"

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
    echo ""
}

main "$@"
