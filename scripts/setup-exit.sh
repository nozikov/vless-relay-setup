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
source "$SCRIPT_DIR/lib/hysteria.sh"
source "$SCRIPT_DIR/lib/warp.sh"
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
    enable_bbr
    raise_service_nofile

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
    log_info "Panel port: $panel_port (random)"
    log_info "Panel path: $panel_path (random)"

    admin_user="${ADMIN_USER:-admin}"
    admin_pass="${ADMIN_PASS:-$(generate_admin_pass)}"
    log_info "Admin user: $admin_user (auto, override via ADMIN_USER env)"
    log_info "Admin pass: auto-generated, shown in the final summary (override via ADMIN_PASS env)"

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

    local dns_mode="adguard" adguard_choice
    prompt_input "Enable AdGuard DNS filtering on exit (blocks ads/trackers)? [Y/n]" adguard_choice "Y"
    case "$adguard_choice" in
        [Nn]*) dns_mode="default" ;;
    esac

    local hysteria_port="" hysteria_port_end="" hysteria_obfs=""
    if [[ -n "$selfsteal_domain" ]]; then
        prompt_input "Hysteria 2 UDP port (Enter to skip)" hysteria_port ""
        if [[ -n "$hysteria_port" ]]; then
            if ! [[ "$hysteria_port" =~ ^[0-9]+$ ]] || [[ "$hysteria_port" -lt 1024 || "$hysteria_port" -gt 64535 ]]; then
                log_error "Invalid port: $hysteria_port (must be 1024-64535)"
                exit 1
            fi
            hysteria_port_end=$((hysteria_port + 1000))
            hysteria_obfs=$(openssl rand -hex 16)
            log_info "Hysteria 2: UDP ${hysteria_port}-${hysteria_port_end}, Salamander enabled"
        fi
    fi

    # --- Step 2: System setup ---
    log_info "=== System Setup ==="
    update_system
    install_dependencies

    # --- Step 3: Install and configure XRAY ---
    log_info "=== XRAY Setup ==="
    install_xray

    local exit_uuid
    exit_uuid=$(xray uuid)
    log_ok "Generated UUID for relay connection: $exit_uuid"

    # WARP outbound for AI services (issue #35) — opt-in, default N
    local warp_enabled="N" warp_choice
    prompt_input "Enable WARP outbound for AI services (ChatGPT/Claude/Gemini/Cursor)?" warp_choice "N"
    case "$warp_choice" in
        [Yy]*) warp_enabled="Y" ;;
    esac
    if [[ "$warp_enabled" == "Y" ]]; then
        install_warp
        configure_warp
    fi

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
            1 "$cdn_port" "$cdn_path" "$dns_mode" "$warp_enabled"
    else
        # Auto mode: select best external site
        setup_reality

        configure_xray_exit 443 "$exit_uuid" "$REALITY_PRIVATE_KEY" \
            "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
            0 "" "" "$dns_mode" "$warp_enabled"
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
        disable_acme_cron
    fi

    # --- Hysteria 2 (optional, requires SelfSteal) ---
    if [[ -n "$hysteria_port" ]]; then
        log_info "=== Hysteria 2 Setup ==="
        install_hysteria
        configure_hysteria "$hysteria_port" "$hysteria_port_end" \
            "$selfsteal_domain" "$exit_uuid" "$hysteria_obfs"
        restart_hysteria
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
    if [[ -n "$hysteria_port" ]]; then
        ufw allow "${hysteria_port}:${hysteria_port_end}/udp" comment "Hysteria2" > /dev/null 2>&1 || true
        log_ok "UFW: UDP ${hysteria_port}:${hysteria_port_end} opened for Hysteria 2"
    fi

    # --- Step 6: Verify ---
    # selfcheck может вернуть 1 при FAIL — не abort'им установку, "Done" банер должен напечататься
    "$SCRIPT_DIR/selfcheck.sh" || true

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
EOF
    if [[ "$warp_enabled" == "Y" ]]; then
        echo "WARP_ENABLED=Y" >> /root/exit-server-info.txt
    fi

    if [[ -n "$cdn_domain" ]]; then
        cat >> /root/exit-server-info.txt << EOF
CDN_DOMAIN=$cdn_domain
CDN_PATH=$cdn_path
CDN_PORT=$cdn_port
EOF
    fi

    if [[ -n "$hysteria_port" ]]; then
        cat >> /root/exit-server-info.txt << EOF
HYSTERIA_PORT=$hysteria_port
HYSTERIA_PORT_END=$hysteria_port_end
HYSTERIA_OBFS=$hysteria_obfs
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
    if [[ -n "$hysteria_port" ]]; then
        echo "  Hysteria2: UDP ${hysteria_port}-${hysteria_port_end} (Salamander)"
    fi
    echo ""
    echo "  Panel:     https://${server_ip}:${panel_port}/${panel_path}/"
    echo "  User:      ${admin_user}"
    echo "  Password:  ${admin_pass}"
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
    if [[ "$warp_enabled" == "Y" ]]; then
        echo "  WARP outbound:        enabled (AI services)"
    fi
    if [[ -n "$cdn_domain" ]]; then
        echo "  Exit CDN domain:      $cdn_domain"
        echo "  Exit CDN path:        $cdn_path"
    fi
    if [[ -n "$hysteria_port" ]]; then
        echo "  Exit Hysteria port:   $hysteria_port"
        echo "  Exit Hysteria range:  $hysteria_port-$hysteria_port_end"
        echo "  Exit Hysteria obfs:   $hysteria_obfs"
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
install -m 0600 /dev/null "$LOG_FILE"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
