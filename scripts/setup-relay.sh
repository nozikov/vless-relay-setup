#!/bin/bash
# Relay server setup (Russia)
# Run: ./setup.sh relay

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/reality.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/verify.sh"

main() {
    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Setup"
    echo "  (Russia / Entry point)  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root
    check_os

    # Guard: prevent accidental re-setup on a configured server
    if [[ -f /etc/x-ui/x-ui.db ]] && [[ "${1:-}" != "--force" ]]; then
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
    prompt_input "Domain for subscriptions, optional, Enter to skip" domain ""

    # --- Step 3: System setup ---
    log_info "=== System Setup ==="
    update_system
    install_dependencies

    # --- Step 4: Install XRAY (for key generation only) ---
    log_info "=== XRAY Setup ==="
    install_xray
    setup_reality  # Generate local Reality keys and dest

    local relay_uuid
    relay_uuid=$(xray uuid)
    log_ok "Generated UUID for default user: $relay_uuid"

    disable_system_xray  # 3X-UI manages its own xray process

    # --- Step 5: Install and configure 3X-UI ---
    log_info "=== 3X-UI Setup ==="
    install_3xui
    configure_3xui "$panel_port" "$panel_path" "$admin_user" "$admin_pass"

    # Configure subscription (only if domain is provided)
    local sub_port="" sub_path=""
    if [[ -n "$domain" ]]; then
        sub_port=$((panel_port + 1))
        sub_path=$(generate_random_path)
        configure_3xui_subscription "$domain" "$sub_port" "$sub_path"
        issue_domain_cert "$domain" || true
    else
        log_info "No domain provided — skipping subscriptions and SSL cert"
    fi

    # Create relay inbound and xray template (all DB writes)
    local default_sub_id
    default_sub_id=$(head -c 8 /dev/urandom | xxd -p)
    create_3xui_relay_inbound "$relay_uuid" "$REALITY_PRIVATE_KEY" \
        "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
        "$default_sub_id" "$exit_ip"

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
    log_info "=== Updating UFW ==="
    local ufw_args=("443:XRAY" "$panel_port:3X-UI Panel")
    if [[ -n "$sub_port" ]]; then
        ufw_args+=("$sub_port:Subscription")
    fi
    allow_ports "${ufw_args[@]}"

    # --- Step 7: Verify ---
    verify_relay_server "$panel_port" "$sub_port" "$exit_ip" "$exit_port"

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
    echo "  Panel:     https://${server_ip}:${panel_port}/${panel_path}/"
    echo "  User:      ${admin_user}"
    echo ""
    if [[ -n "$domain" ]]; then
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
    echo "  Next steps:"
    echo "    1. Log into 3X-UI panel"
    echo "    2. Inbounds → your relay → + Add Client"
    echo "    3. Share subscription links with users"
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
