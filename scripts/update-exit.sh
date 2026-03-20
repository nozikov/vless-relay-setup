#!/bin/bash
# Update exit server configuration from latest codebase
# Run: ./setup.sh update-exit [--upgrade]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/caddy.sh"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XUI_DB="/etc/x-ui/x-ui.db"

main() {
    local upgrade=false skip_ssh=false
    for arg in "$@"; do
        case "$arg" in
            --upgrade) upgrade=true ;;
            --skip-ssh) skip_ssh=true ;;
        esac
    done

    echo "==========================================="
    echo "  VLESS Reality VPN — EXIT Server Update  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root

    # --- Step 1: Validate existing installation ---
    log_info "=== Checking existing installation ==="

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        log_error "XRAY config not found at $XRAY_CONFIG"
        log_error "Run './setup.sh exit' first to perform initial setup"
        exit 1
    fi

    if ! command -v xray &> /dev/null; then
        log_error "XRAY binary not found"
        log_error "Run './setup.sh exit' first to perform initial setup"
        exit 1
    fi

    # --- Step 2: Extract current values ---
    log_info "=== Reading current configuration ==="

    local uuid private_key short_id dest server_name xhttp_path listen_port public_key xver
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
    short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
    dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONFIG")
    xver=$(jq -r '.inbounds[0].streamSettings.realitySettings.xver' "$XRAY_CONFIG")

    local is_selfsteal=false
    if [[ "$dest" == *"caddy.sock"* ]]; then
        is_selfsteal=true
        log_info "SelfSteal mode detected"
    fi
    server_name=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
    xhttp_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONFIG" | sed 's|^/||')
    listen_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    public_key=$(xray x25519 -i "$private_key" 2>/dev/null | grep -iE "public|password" | awk '{print $NF}')

    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        log_error "Failed to extract UUID from config"
        exit 1
    fi

    log_ok "Current config read successfully"
    log_info "  UUID:  $uuid"
    log_info "  Port:  $listen_port"
    log_info "  SNI:   $server_name"

    # Read panel port from 3X-UI DB (for UFW and verification)
    local panel_port=""
    if [[ -f "$XUI_DB" ]]; then
        panel_port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null) || true
    fi

    # --- Step 3: System update ---
    log_info "=== System Update ==="
    update_system

    # --- Step 4: Upgrade binaries (optional) ---
    if [[ "$upgrade" == true ]]; then
        log_info "=== Upgrading Binaries ==="

        log_info "Upgrading XRAY..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install < /dev/null
        local version
        version=$(xray version 2>/dev/null | head -1 || true)
        log_ok "XRAY upgraded: $version"

        if command -v x-ui &> /dev/null; then
            log_info "Upgrading 3X-UI..."
            printf '\n%.0s' {1..100} > /tmp/xui-answers
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) < /tmp/xui-answers
            rm -f /tmp/xui-answers
            log_ok "3X-UI upgraded"
        fi

        if [[ "$is_selfsteal" == true ]]; then
            log_info "Upgrading Caddy..."
            apt-get update -qq && apt-get install -y -qq caddy > /dev/null 2>&1
            log_ok "Caddy upgraded"
        fi
    fi

    # --- Step 5: Update XRAY config ---
    log_info "=== Updating XRAY Config ==="
    local backup_path="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$XRAY_CONFIG" "$backup_path"
    log_ok "Backup saved: $backup_path"

    configure_xray_exit "$listen_port" "$uuid" "$private_key" \
        "$short_id" "$dest" "$server_name" "$xhttp_path" "$xver"

    if ! restart_xray; then
        log_warn "Restoring previous config..."
        cp "$backup_path" "$XRAY_CONFIG"
        restart_xray || { log_error "Rollback also failed"; exit 1; }
        log_ok "Previous config restored, XRAY is running"
        exit 1
    fi

    # --- Step 6: Security ---
    log_info "=== Security ==="
    local security_args=()
    [[ "$skip_ssh" == true ]] && security_args+=("--skip-ssh")
    security_args+=(22:SSH 443:XRAY)
    if [[ -n "$panel_port" ]]; then
        security_args+=("$panel_port:3X-UI Panel")
    fi
    if [[ "$is_selfsteal" == true ]]; then
        security_args+=(80:Caddy-ACME)
    fi
    setup_security "${security_args[@]}"

    # --- Step 7: Update exit-server-info.txt ---
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip="<not detected>"

    install -m 0600 /dev/null /root/exit-server-info.txt
    cat > /root/exit-server-info.txt << EOF
EXIT_IP=$server_ip
EXIT_PORT=$listen_port
EXIT_UUID=$uuid
EXIT_PUBLIC_KEY=$public_key
EXIT_SHORT_ID=$short_id
EXIT_SERVER_NAME=$server_name
EXIT_XHTTP_PATH=$xhttp_path
EOF

    # --- Step 8: Verify ---
    verify_exit_server "${panel_port:-0}"

    # --- Done ---
    echo ""
    echo "==========================================="
    log_ok "EXIT server update complete!"
    echo "==========================================="
    echo ""
    echo "  Config updated from latest codebase"
    if [[ "$upgrade" == true ]]; then
        echo "  Binaries upgraded to latest versions"
    fi
    echo "  Security re-applied"
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
