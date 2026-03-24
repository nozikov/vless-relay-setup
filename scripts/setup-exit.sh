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
    echo "  (Exit Node)  v${PROJECT_VERSION}"
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

    local ssh_port=22
    prompt_input "Custom SSH port (Enter for default 22)" ssh_port "22"
    if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [[ "$ssh_port" -lt 1 || "$ssh_port" -gt 65535 ]]; then
        log_error "Invalid port: $ssh_port"
        exit 1
    fi

    local selfsteal_domain=""
    prompt_input "Domain for SelfSteal SNI (Enter to skip, required for CDN mode)" selfsteal_domain ""

    if [[ -n "$selfsteal_domain" ]]; then
        if ! validate_domain "$selfsteal_domain"; then
            log_error "Invalid domain format: $selfsteal_domain"
            exit 1
        fi
        check_domain_dns "$selfsteal_domain" || exit 1
    fi

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

    local cdn_path="" cdn_port=""
    if [[ -n "$cdn_domain" ]]; then
        cdn_path=$(generate_random_path)
        cdn_port=$(generate_random_port "$panel_port")
        log_ok "Generated CDN path and port"
    fi

    if [[ -n "$selfsteal_domain" ]]; then
        # SelfSteal mode: Caddy + unix socket
        log_info "=== SelfSteal Setup ==="
        install_caddy
        setup_selfsteal_content
        generate_reality_keypair
        generate_short_id
        export REALITY_DEST="$CADDY_SOCK"
        export REALITY_SERVER_NAME="$selfsteal_domain"
        generate_caddyfile "$selfsteal_domain" "" "" "" "" \
            "$cdn_domain" "$cdn_path" "$cdn_port"
        # Caddy is NOT started yet — port 80 must stay free for 3X-UI installer
        # (its ACME HTTP-01 challenge needs port 80).
        # systemd dependency is also deferred: Wants=caddy.service would auto-start
        # Caddy when XRAY restarts, defeating the purpose of delaying.

        configure_xray_exit 443 "$exit_uuid" "$REALITY_PRIVATE_KEY" \
            "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
            "$xhttp_path" 1 "$cdn_port" "$cdn_path"
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

    # Start Caddy AFTER 3X-UI is installed, then add systemd dependency
    if [[ -n "$selfsteal_domain" ]]; then
        start_caddy
        setup_caddy_systemd_dependency "xray"
    fi

    # --- Step 5: Security ---
    log_info "=== Security Setup ==="
    local security_args=()
    [[ "$skip_ssh" == true ]] && security_args+=("--skip-ssh")
    security_args+=(--ssh-port "$ssh_port" "$ssh_port":SSH 443:XRAY "$panel_port:3X-UI Panel")
    if [[ -n "$selfsteal_domain" ]]; then
        security_args+=(80:Caddy-ACME)
    fi
    setup_security "${security_args[@]}"

    # --- Step 6: Verify ---
    verify_exit_server "$panel_port" "${selfsteal_domain:-}" "${cdn_port:-}"

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

    if [[ -n "$cdn_domain" ]]; then
        cat >> /root/exit-server-info.txt << EOF
CDN_DOMAIN=$cdn_domain
CDN_PATH=$cdn_path
CDN_PORT=$cdn_port
EOF
    fi

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
    if [[ -n "$cdn_domain" ]]; then
        echo "  CDN:       ${cdn_domain} (Cloudflare CDN)"
    fi
    echo ""
    echo "  Panel:     https://${server_ip}:${panel_port}/${panel_path}/"
    echo "  User:      ${admin_user}"
    echo ""
    if [[ "$ssh_port" != "22" ]]; then
        echo "  SSH port:  ${ssh_port}"
        echo ""
        echo "  WARNING: Update your SSH config to use port ${ssh_port}"
        echo "           ssh -p ${ssh_port} root@${server_ip}"
        echo ""
    fi
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
    if [[ -n "$cdn_domain" ]]; then
        echo "  Exit CDN domain:      $cdn_domain"
        echo "  Exit CDN path:        $cdn_path"
    fi
    echo "-------------------------------------------"
    echo ""
    echo "  Saved to /root/exit-server-info.txt"
    echo ""
    if [[ -n "$cdn_domain" ]]; then
        echo "-------------------------------------------"
        echo "  Cloudflare setup (manual):"
        echo "-------------------------------------------"
        echo "  1. Add ${cdn_domain} to Cloudflare (free plan)"
        echo "  2. DNS: A ${cdn_domain} -> ${server_ip} (Proxy: ON)"
        echo "  3. SSL/TLS -> Full"
        echo ""
    fi
    echo "  Next: run ./scripts/setup.sh relay on the relay server"
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
