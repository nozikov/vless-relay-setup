#!/bin/bash
# Relay server setup
# Run: ./setup.sh relay

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/reality.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/caddy.sh"

main() {
    local force=false skip_ssh=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --skip-ssh) skip_ssh=true ;;
        esac
    done

    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Setup"
    echo "  (Russia / Entry point)  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root
    check_os

    # Guard: prevent accidental re-setup on a configured server
    if [[ -f /etc/x-ui/x-ui.db ]] && [[ "$force" != true ]]; then
        log_warn "Existing 3X-UI database detected!"
        log_warn "Running setup again will regenerate ALL keys and break client connections."
        log_info "To update config from latest codebase: ./setup.sh update-relay"
        log_info "To force full reinstall: ./setup.sh relay --force"
        exit 1
    fi

    # --- Step 1: Exit server details ---
    log_info "=== Exit Server Connection Details ==="
    echo "Enter the values from exit server setup:"
    echo ""

    local exit_ip exit_port exit_uuid exit_pubkey exit_short_id exit_sni exit_xhttp_path
    prompt_input "Exit server IP" exit_ip
    prompt_input "Exit server port" exit_port "443"
    prompt_input "Exit server UUID" exit_uuid
    prompt_input "Exit server Reality public key" exit_pubkey
    prompt_input "Exit server Reality short ID" exit_short_id
    prompt_input "Exit server Reality SNI" exit_sni
    prompt_input "Exit server XHTTP path" exit_xhttp_path

    local cdn_domain="" cdn_path=""
    prompt_input "Exit CDN domain (Enter if not configured)" cdn_domain ""
    if [[ -n "$cdn_domain" ]]; then
        if ! validate_domain "$cdn_domain"; then
            log_error "Invalid domain format: $cdn_domain"
            exit 1
        fi
        prompt_input "Exit CDN path (from exit-server-info.txt CDN_PATH)" cdn_path
        validate_not_empty "$cdn_path" "CDN path" || exit 1
    fi

    # Validate exit server inputs
    validate_ip "$exit_ip" || { log_error "Invalid IP address: $exit_ip"; exit 1; }
    validate_uuid "$exit_uuid" || { log_error "Invalid UUID format: $exit_uuid"; exit 1; }
    validate_not_empty "$exit_pubkey" "Exit public key" || exit 1
    validate_not_empty "$exit_short_id" "Exit short ID" || exit 1
    validate_not_empty "$exit_sni" "Exit SNI" || exit 1
    validate_not_empty "$exit_xhttp_path" "Exit XHTTP path" || exit 1

    # --- Step 2: Relay configuration ---
    log_info "=== Relay Configuration ==="

    local panel_port panel_path admin_user admin_pass domain
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

    local selfsteal_domain="" panel_domain="" sub_domain=""
    prompt_input "Domain for SelfSteal SNI (Enter to skip for auto-select)" selfsteal_domain ""

    if [[ -n "$selfsteal_domain" ]]; then
        if ! validate_domain "$selfsteal_domain"; then
            log_error "Invalid domain format: $selfsteal_domain"
            exit 1
        fi
        check_domain_dns "$selfsteal_domain" || exit 1

        prompt_input "Domain for 3X-UI panel (e.g. panel.${selfsteal_domain})" panel_domain
        if ! validate_domain "$panel_domain"; then
            log_error "Invalid domain format: $panel_domain"
            exit 1
        fi
        check_domain_dns "$panel_domain" || exit 1

        prompt_input "Domain for subscriptions (Enter to skip)" sub_domain ""
        if [[ -n "$sub_domain" ]]; then
            if ! validate_domain "$sub_domain"; then
                log_error "Invalid domain format: $sub_domain"
                exit 1
            fi
            check_domain_dns "$sub_domain" || exit 1
        fi
    else
        # Non-SelfSteal: keep existing single domain prompt
        prompt_input "Domain for subscriptions, optional, Enter to skip" domain ""
    fi

    # --- Step 3: System setup ---
    log_info "=== System Setup ==="
    update_system
    install_dependencies

    # --- Step 4: Install XRAY (for key generation only) ---
    log_info "=== XRAY Setup ==="
    install_xray

    if [[ -n "$selfsteal_domain" ]]; then
        # SelfSteal mode
        log_info "=== SelfSteal Setup ==="
        install_caddy
        setup_selfsteal_content
        generate_reality_keypair
        generate_short_id
        export REALITY_DEST="$CADDY_SOCK"
        export REALITY_SERVER_NAME="$selfsteal_domain"
    else
        setup_reality  # Generate local Reality keys and dest
    fi

    local relay_uuid
    relay_uuid=$(xray uuid)
    log_ok "Generated UUID for default user: $relay_uuid"

    disable_system_xray  # 3X-UI manages its own xray process

    # --- Step 5: Install and configure 3X-UI ---
    log_info "=== 3X-UI Setup ==="

    if [[ -n "$selfsteal_domain" ]]; then
        install_3xui true  # skip port 80 cleanup — Caddy needs it
    else
        install_3xui
    fi

    configure_3xui "$panel_port" "$panel_path" "$admin_user" "$admin_pass"

    # Configure subscription + SelfSteal-specific settings
    # All DB writes happen in one stop/start window to avoid extra restarts
    local sub_port="" sub_path=""
    if [[ -n "$selfsteal_domain" ]]; then
        x-ui stop

        # Bind panel to localhost (Caddy proxies external access)
        xui_db_set "webListen" "127.0.0.1"

        # SelfSteal: subscriptions via Caddy (if sub_domain provided)
        if [[ -n "$sub_domain" ]]; then
            sub_port=$((panel_port + 1))
            sub_path=$(generate_random_path)
            xui_db_set "subEnable" "true"
            xui_db_set "subPort" "$sub_port"
            xui_db_set "subPath" "/$sub_path/"
            xui_db_set "subDomain" "$sub_domain"
            xui_db_set "subListen" "127.0.0.1"
            xui_db_set "subURI" "https://${sub_domain}/${sub_path}/"
            # Clear certs set by 3X-UI installer — Caddy handles TLS termination,
            # subscription must listen on plain HTTP for Caddy reverse proxy to work
            xui_db_set "subCertFile" ""
            xui_db_set "subKeyFile" ""
        fi

        x-ui start

        # CDN subscription proxy: sits between Caddy and 3X-UI subscription,
        # appends the correct CDN VLESS link to every subscription response.
        # Must be set up BEFORE Caddyfile generation so Caddy gets the proxy port.
        local caddy_sub_port="$sub_port"
        if [[ -n "$cdn_domain" && -n "$sub_port" ]]; then
            # Symmetric XHTTP CDN link
            local cdn_vless_link sub_proxy_port
            cdn_vless_link="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up#CDN%20XHTTP"

            # Asymmetric CDN link with downloadSettings
            local cdn_vless_link_asym="" download_extra extra_encoded
            download_extra=$(jq -n -c \
                --arg padding "100-1000" \
                --arg exit_addr "$exit_ip" \
                --arg exit_sni_val "$exit_sni" \
                --arg exit_pubkey_val "$exit_pubkey" \
                --arg exit_short_id_val "$exit_short_id" \
                --arg exit_path "$exit_xhttp_path" \
                '{
                    xPaddingBytes: $padding,
                    downloadSettings: {
                        address: $exit_addr,
                        port: 443,
                        network: "xhttp",
                        security: "reality",
                        realitySettings: {
                            serverName: $exit_sni_val,
                            publicKey: $exit_pubkey_val,
                            shortId: $exit_short_id_val,
                            fingerprint: "chrome"
                        },
                        xhttpSettings: {
                            path: ("/"+$exit_path),
                            mode: "auto"
                        }
                    }
                }')
            extra_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$download_extra")
            cdn_vless_link_asym="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up&extra=${extra_encoded}#CDN%20Asymmetric"

            sub_proxy_port=$((sub_port + 1))
            setup_sub_proxy "$sub_port" "$cdn_vless_link" "$sub_proxy_port" "$cdn_domain" "$cdn_path" "$cdn_vless_link_asym"
            caddy_sub_port="$sub_proxy_port"
        fi

        # Generate Caddyfile with all domains
        generate_caddyfile "$selfsteal_domain" "$panel_domain" "$panel_port" \
            "$sub_domain" "$caddy_sub_port"
        start_caddy
        setup_caddy_systemd_dependency "x-ui"
    else
        # Non-SelfSteal: existing flow
        if [[ -n "$domain" ]]; then
            sub_port=$((panel_port + 1))
            sub_path=$(generate_random_path)
            configure_3xui_subscription "$domain" "$sub_port" "$sub_path"
            issue_domain_cert "$domain" || true
        else
            log_info "No domain provided — skipping subscriptions and SSL cert"
        fi
    fi

    # Create relay inbound and xray template (all DB writes)
    local default_sub_id
    default_sub_id=$(head -c 8 /dev/urandom | xxd -p)

    local xver=0
    [[ -n "$selfsteal_domain" ]] && xver=1

    create_3xui_relay_inbound "$relay_uuid" "$REALITY_PRIVATE_KEY" \
        "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
        "$default_sub_id" "$exit_ip" "$xver"

    configure_3xui_relay_template "$exit_ip" "$exit_port" "$exit_uuid" \
        "$exit_pubkey" "$exit_short_id" "$exit_sni" "$exit_xhttp_path"

    # First restart: 3X-UI loads inbound + template, normalizes inbound JSON
    x-ui restart
    log_ok "3X-UI restarted with relay inbound and routing"

    # Patch fields that 3X-UI strips on normalization (subId, publicKey for subscriptions)
    patch_3xui_relay_inbound "$default_sub_id" "$REALITY_PUBLIC_KEY"

    # Final restart: xray picks up patched config
    x-ui restart
    log_ok "3X-UI restarted with patched subscription fields"

    # --- Step 6: Security ---
    log_info "=== Security Setup ==="
    local security_args=()
    [[ "$skip_ssh" == true ]] && security_args+=("--skip-ssh")
    security_args+=(--ssh-port "$ssh_port" "$ssh_port":SSH 443:XRAY)
    if [[ -n "$selfsteal_domain" ]]; then
        security_args+=(80:Caddy-ACME)
    else
        security_args+=("$panel_port:3X-UI Panel")
    fi
    if [[ -n "$sub_port" ]] && [[ -z "$selfsteal_domain" ]]; then
        # Only open sub_port directly when NOT using SelfSteal (Caddy proxies it otherwise)
        security_args+=("$sub_port:Subscription")
    fi
    setup_security "${security_args[@]}"

    # --- Step 7: Verify ---
    verify_relay_server "$panel_port" "$sub_port" "$exit_ip" "$exit_port" "${selfsteal_domain:-}"

    # --- Done ---
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip="<not detected>"

    echo ""
    echo "==========================================="
    log_ok "RELAY server setup complete!"
    echo "==========================================="
    echo ""
    echo "  Server:    ${server_ip}"
    echo "  Protocol:  VLESS + Reality (TCP) → Exit (XHTTP)"
    echo "  Port:      443"
    echo "  Exit:      ${exit_ip}"
    echo ""

    if [[ -n "$selfsteal_domain" ]]; then
        echo "  SelfSteal: ${selfsteal_domain}"
        echo ""
        echo "  Panel:     https://${panel_domain}/${panel_path}/"
        echo "  User:      ${admin_user}"
        echo ""
        if [[ -n "$sub_domain" ]]; then
            echo "-------------------------------------------"
            echo "  Subscriptions:"
            echo "-------------------------------------------"
            echo "  Base URL:  https://${sub_domain}/${sub_path}/"
            echo "  Default:   https://${sub_domain}/${sub_path}/${default_sub_id}"
            echo ""
        fi
        echo "  DNS records required:"
        echo "    A  ${selfsteal_domain}  → ${server_ip}"
        echo "    A  ${panel_domain}      → ${server_ip}"
        if [[ -n "$sub_domain" ]]; then
            echo "    A  ${sub_domain}        → ${server_ip}"
        fi
        echo ""
    else
        echo "  Panel:     https://${server_ip}:${panel_port}/${panel_path}/"
        echo "  User:      ${admin_user}"
        echo ""
        if [[ -n "${domain:-}" ]]; then
            echo "-------------------------------------------"
            echo "  Subscriptions:"
            echo "-------------------------------------------"
            echo "  Base URL:  https://${domain}:${sub_port}/${sub_path}/"
            echo "  Default:   https://${domain}:${sub_port}/${sub_path}/${default_sub_id}"
            echo ""
            echo "  DNS: set A-record ${domain} → ${server_ip}"
            echo ""
        else
            echo "  Subscriptions: not configured (no domain)"
            echo ""
        fi
    fi
    if [[ -n "$cdn_domain" ]]; then
        echo "  CDN Fallback: ${cdn_domain}"
        echo ""
        local cdn_display_link="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up#CDN%20XHTTP"
        echo "-------------------------------------------"
        echo "  CDN VLESS link (for manual client setup):"
        echo "-------------------------------------------"
        echo "  $cdn_display_link"
        echo ""
    fi
    if [[ "$ssh_port" != "22" ]]; then
        echo "  SSH port:  ${ssh_port}"
        echo ""
        echo "  WARNING: Update your SSH config to use port ${ssh_port}"
        echo "           ssh -p ${ssh_port} root@${server_ip}"
        echo ""
    fi
    echo "  Next steps:"
    echo "    1. Log into 3X-UI panel"
    echo "    2. Inbounds → your relay → + Add Client"
    echo "    3. Share subscription links with users"
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
