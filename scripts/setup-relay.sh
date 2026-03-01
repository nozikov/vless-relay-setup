#!/bin/bash
# Relay server setup (Russia)
# Run: ./setup.sh relay

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/reality.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/3xui.sh"

main() {
    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Setup"
    echo "  (Russia / Entry point)"
    echo "==========================================="
    echo ""

    check_root
    check_os

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

    # --- Step 2: Relay configuration ---
    log_info "=== Relay Configuration ==="

    local panel_port panel_path admin_user admin_pass domain
    panel_port=$(generate_random_port)
    panel_path=$(generate_random_path)

    prompt_input "3X-UI panel port" panel_port "$panel_port"
    prompt_input "3X-UI panel secret path" panel_path "$panel_path"
    prompt_input "Admin username" admin_user "admin"
    prompt_password "Admin password" admin_pass
    prompt_input "Your domain for subscriptions (e.g. vpn.example.com)" domain

    # --- Step 3: System setup ---
    log_info "=== System Setup ==="
    update_system
    install_dependencies

    # --- Step 4: Install and configure XRAY ---
    log_info "=== XRAY Setup ==="
    install_xray
    setup_reality  # Generate local Reality keys and dest

    local relay_uuid
    relay_uuid=$(xray uuid)
    log_ok "Generated UUID for first user: $relay_uuid"

    configure_xray_relay 443 "$relay_uuid" "$REALITY_PRIVATE_KEY" \
        "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
        "$exit_ip" "$exit_port" "$exit_uuid" "$exit_pubkey" \
        "$exit_short_id" "$exit_sni" "$exit_xhttp_path"

    restart_xray

    # --- Step 5: Install 3X-UI ---
    log_info "=== 3X-UI Setup ==="
    install_3xui
    configure_3xui "$panel_port" "$panel_path" "$admin_user" "$admin_pass"

    # Configure subscription (separate port to avoid bind conflict with panel)
    local sub_port sub_path
    sub_port=$((panel_port + 1))
    sub_path=$(generate_random_path)
    configure_3xui_subscription "$domain" "$sub_port" "$sub_path"

    # --- Step 6: Security ---
    log_info "=== Security Setup ==="
    setup_security 22:SSH 443:XRAY "$panel_port:3X-UI Panel" "$sub_port:Subscription"

    # --- Done ---
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip="<not detected>"

    echo ""
    echo "==========================================="
    log_ok "RELAY server setup complete!"
    echo "==========================================="
    echo ""
    echo "3X-UI Panel:"
    echo "  https://${server_ip}:${panel_port}/${panel_path}/"
    echo ""
    echo "Subscription URL:"
    echo "  https://${domain}:${sub_port}/${sub_path}/"
    echo ""
    echo "IMPORTANT: Set DNS A-record for ${domain} → ${server_ip}"
    echo ""
    echo "Next steps:"
    echo "  1. Point your domain to this server's IP"
    echo "  2. Log into 3X-UI panel"
    echo "  3. Create inbound with VLESS + Reality (panel will manage users)"
    echo "  4. Share subscription link with your users"
}

main
