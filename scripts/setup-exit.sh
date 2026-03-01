#!/bin/bash
# Exit server setup (Netherlands)
# Run: ./setup.sh exit

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/reality.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/3xui.sh"

main() {
    echo "==========================================="
    echo "  VLESS Reality VPN — EXIT Server Setup"
    echo "  (Netherlands / Foreign server)"
    echo "==========================================="
    echo ""

    check_root
    check_os

    # --- Step 1: Gather configuration ---
    log_info "=== Configuration ==="

    local panel_port panel_path admin_user admin_pass
    panel_port=$(generate_random_port)
    panel_path=$(generate_random_path)

    prompt_input "3X-UI panel port" panel_port "$panel_port"
    prompt_input "3X-UI panel secret path" panel_path "$panel_path"
    prompt_input "Admin username" admin_user "admin"
    prompt_password "Admin password" admin_pass

    # --- Step 2: System setup ---
    log_info "=== System Setup ==="
    update_system
    install_dependencies

    # --- Step 3: Install and configure XRAY ---
    log_info "=== XRAY Setup ==="
    install_xray
    setup_reality

    local exit_uuid xhttp_path
    exit_uuid=$(xray uuid)
    xhttp_path=$(generate_random_path)
    log_ok "Generated UUID for relay connection: $exit_uuid"

    configure_xray_exit 443 "$exit_uuid" "$REALITY_PRIVATE_KEY" \
        "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
        "$xhttp_path"

    restart_xray

    # --- Step 4: Install 3X-UI ---
    log_info "=== 3X-UI Setup ==="
    install_3xui
    configure_3xui "$panel_port" "$panel_path" "$admin_user" "$admin_pass"

    # --- Step 5: Security ---
    log_info "=== Security Setup ==="
    setup_security 22 "$panel_port" 443

    # --- Done ---
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip="<not detected>"

    echo ""
    echo "==========================================="
    log_ok "EXIT server setup complete!"
    echo "==========================================="
    echo ""
    echo "Save these values for RELAY server setup:"
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
    echo "3X-UI Panel:"
    echo "  https://${server_ip}:${panel_port}/${panel_path}/"
    echo ""

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

    log_ok "Connection info saved to /root/exit-server-info.txt"
}

main
