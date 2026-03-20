#!/bin/bash
# Exit server setup
# Run: ./setup.sh exit

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/reality.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/caddy.sh"
source "$SCRIPT_DIR/lib/verify.sh"

main() {
    local force=false skip_ssh=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --skip-ssh) skip_ssh=true ;;
        esac
    done

    echo "==========================================="
    echo "  VLESS Reality VPN — EXIT Server Setup"
    echo "  (Netherlands / Foreign server)  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root
    check_os

    # Guard: prevent accidental re-setup on a configured server
    if [[ -f /usr/local/etc/xray/config.json ]] && [[ "$force" != true ]]; then
        log_warn "Existing XRAY configuration detected!"
        log_warn "Running setup again will regenerate ALL keys and break the relay connection."
        log_info "To update config from latest codebase: ./setup.sh update-exit"
        log_info "To force full reinstall: ./setup.sh exit --force"
        exit 1
    fi

    # --- Step 1: Gather configuration ---
    log_info "=== Configuration ==="

    local panel_port panel_path admin_user admin_pass
    panel_port=$(generate_random_port)
    panel_path=$(generate_random_path)

    prompt_input "3X-UI panel port" panel_port "$panel_port"
    prompt_input "3X-UI panel secret path" panel_path "$panel_path"
    prompt_input "Admin username" admin_user "admin"
    validate_ascii "$admin_user" "Username" || exit 1
    prompt_password "Admin password" admin_pass

    local selfsteal_domain=""
    prompt_input "Domain for SelfSteal SNI (Enter to skip for auto-select)" selfsteal_domain ""

    if [[ -n "$selfsteal_domain" ]]; then
        if ! validate_domain "$selfsteal_domain"; then
            log_error "Invalid domain format: $selfsteal_domain"
            exit 1
        fi
        check_domain_dns "$selfsteal_domain" || exit 1
    fi

    # --- Step 2: System setup ---
    log_info "=== System Setup ==="
    update_system
    install_dependencies

    # --- Step 3: Install and configure XRAY ---
    log_info "=== XRAY Setup ==="
    install_xray

    local exit_uuid xhttp_path
    exit_uuid=$(xray uuid)
    xhttp_path=$(generate_random_path)
    log_ok "Generated UUID for relay connection: $exit_uuid"

    if [[ -n "$selfsteal_domain" ]]; then
        # SelfSteal mode: Caddy + unix socket
        log_info "=== SelfSteal Setup ==="
        install_caddy
        setup_selfsteal_content
        generate_reality_keypair
        generate_short_id
        export REALITY_DEST="$CADDY_SOCK"
        export REALITY_SERVER_NAME="$selfsteal_domain"
        generate_caddyfile "$selfsteal_domain"
        start_caddy
        setup_caddy_systemd_dependency "xray"

        configure_xray_exit 443 "$exit_uuid" "$REALITY_PRIVATE_KEY" \
            "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
            "$xhttp_path" 1
    else
        # Auto mode: select best external site
        setup_reality

        configure_xray_exit 443 "$exit_uuid" "$REALITY_PRIVATE_KEY" \
            "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
            "$xhttp_path" 0
    fi

    restart_xray

    # --- Step 4: Install 3X-UI ---
    log_info "=== 3X-UI Setup ==="
    install_3xui
    configure_3xui "$panel_port" "$panel_path" "$admin_user" "$admin_pass"

    # --- Step 5: Security ---
    log_info "=== Security Setup ==="
    local security_args=()
    [[ "$skip_ssh" == true ]] && security_args+=("--skip-ssh")
    security_args+=(22:SSH 443:XRAY "$panel_port:3X-UI Panel")
    if [[ -n "$selfsteal_domain" ]]; then
        security_args+=(80:Caddy-ACME)
    fi
    setup_security "${security_args[@]}"

    # --- Step 6: Verify ---
    verify_exit_server "$panel_port" "${selfsteal_domain:-}"

    # --- Done ---
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip="<not detected>"

    # Save connection info for relay setup
    install -m 0600 /dev/null /root/exit-server-info.txt
    cat > /root/exit-server-info.txt << EOF
EXIT_IP=$server_ip
EXIT_PORT=443
EXIT_UUID=$exit_uuid
EXIT_PUBLIC_KEY=$REALITY_PUBLIC_KEY
EXIT_SHORT_ID=$REALITY_SHORT_ID
EXIT_SERVER_NAME=$REALITY_SERVER_NAME
EXIT_XHTTP_PATH=$xhttp_path
EOF

    echo ""
    echo "==========================================="
    log_ok "EXIT server setup complete!"
    echo "==========================================="
    echo ""
    echo "  Server:    ${server_ip}"
    echo "  Protocol:  VLESS + Reality + XHTTP"
    echo "  Port:      443"
    echo "  SNI:       ${REALITY_SERVER_NAME}"
    if [[ -n "$selfsteal_domain" ]]; then
        echo "  SelfSteal: ${selfsteal_domain} (Caddy + unix socket)"
    fi
    echo ""
    echo "  Panel:     https://${server_ip}:${panel_port}/${panel_path}/"
    echo "  User:      ${admin_user}"
    echo ""
    echo "-------------------------------------------"
    echo "  Values for RELAY server setup:"
    echo "-------------------------------------------"
    echo "  Exit server IP:       $server_ip"
    echo "  Exit server port:     443"
    echo "  Exit UUID:            $exit_uuid"
    echo "  Exit Reality pubkey:  $REALITY_PUBLIC_KEY"
    echo "  Exit Reality shortId: $REALITY_SHORT_ID"
    echo "  Exit Reality SNI:     $REALITY_SERVER_NAME"
    echo "  Exit XHTTP path:     $xhttp_path"
    echo "-------------------------------------------"
    echo ""
    echo "  Saved to /root/exit-server-info.txt"
    echo ""
    echo "  Next: run ./scripts/setup.sh relay on the relay server"
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
