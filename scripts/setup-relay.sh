#!/bin/bash
# Relay server setup
# Run: ./setup.sh relay

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/reality.sh"
source "$SCRIPT_DIR/lib/xray.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/xui-api.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/caddy.sh"
source "$SCRIPT_DIR/lib/wireguard.sh"

main() {
    local force=false skip_ssh=false wg_conf_path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true ;;
            --skip-ssh) skip_ssh=true ;;
            --wg-conf) wg_conf_path="${2:-}"; shift ;;
        esac
        shift
    done

    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Setup"
    echo "  (Entry Point Node)  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root
    check_os
    enable_bbr
    raise_service_nofile

    # Guard: prevent accidental re-setup on a configured server
    if [[ -f /etc/x-ui/x-ui.db ]] && [[ "$force" != true ]]; then
        log_warn "Existing 3X-UI database detected!"
        log_warn "Running setup again will regenerate ALL keys and break client connections."
        log_info "To update config from latest codebase: ./setup.sh update-relay"
        log_info "To force full reinstall: ./setup.sh relay --force"
        exit 1
    fi

    # --- Step 1: Exit backhaul ---
    log_info "=== Exit Backhaul ==="

    local backhaul_mode="vless" backhaul_choice=""
    local exit_ip="" exit_port=443 exit_uuid="" exit_pubkey="" exit_short_id="" exit_sni=""
    local cdn_domain="" cdn_path=""
    local hysteria_port="" hysteria_port_end="" hysteria_obfs=""
    local wg_private_key="" wg_address="" wg_peer_pubkey="" wg_endpoint=""
    local wg_allowed_ips="0.0.0.0/0" wg_keepalive="25" wg_mtu="1380" wg_lan_allow=""

    if [[ -n "$wg_conf_path" ]]; then
        log_info "--wg-conf given — WireGuard-to-external-peer backhaul selected"
        backhaul_mode="wireguard"
    else
        echo "How should this relay reach the internet?"
        echo "  1) VLESS+Reality to an exit VPS set up by this project [default]"
        echo "  2) WireGuard to an externally-managed peer (e.g. home router)"
        prompt_input "Backhaul mode" backhaul_choice "1"
        case "$backhaul_choice" in
            1|vless)        backhaul_mode="vless" ;;
            2|wireguard|wg) backhaul_mode="wireguard" ;;
            *) log_error "Invalid backhaul choice: $backhaul_choice"; exit 1 ;;
        esac
    fi

    if [[ "$backhaul_mode" == "wireguard" ]]; then
        # WG peer values come from the router's own peer-creation UI (out of
        # this repo's scope). CDN/Hysteria/Direct-Exit prompts don't apply —
        # they all assume a VPS exit reachable inbound on 443.
        log_info "=== WireGuard Peer Details ==="
        echo "Enter the values from the WireGuard peer created on the router:"
        echo ""

        if [[ -z "$wg_conf_path" ]]; then
            prompt_input "Path to WireGuard .conf (Enter to type values manually)" wg_conf_path ""
        fi
        if [[ -n "$wg_conf_path" ]]; then
            parse_wg_conf "$wg_conf_path" || exit 1
            wg_private_key="$WG_PRIVATE_KEY"
            wg_address="$WG_ADDRESS"
            wg_peer_pubkey="$WG_PEER_PUBKEY"
            wg_endpoint="$WG_ENDPOINT"
            wg_allowed_ips="$WG_ALLOWED_IPS"
            wg_keepalive="$WG_KEEPALIVE"
            wg_mtu="$WG_MTU"
            local wg_confirm=""
            prompt_input "Use these values? [Y/n]" wg_confirm "Y"
            if [[ ! "$wg_confirm" =~ ^[Yy]$ ]]; then
                log_error "Aborted by user"
                exit 1
            fi
        else
            prompt_input "Relay WireGuard private key (from the router-generated config)" wg_private_key
            prompt_input "Relay tunnel address (assigned by the router, e.g. 192.168.2.4/32)" wg_address
            prompt_input "Router WireGuard public key" wg_peer_pubkey
            prompt_input "Router WireGuard endpoint host:port (DDNS hostname is fine, e.g. myhome.mooo.com:8264)" wg_endpoint
            prompt_input "Allowed IPs" wg_allowed_ips "0.0.0.0/0"
            prompt_input "Persistent keepalive (seconds)" wg_keepalive "25"
            prompt_input "Tunnel MTU" wg_mtu "1380"
        fi

        # Static-shape validation — a parsed .conf is not trusted to be well-formed
        validate_wg_peer_params "$wg_private_key" "$wg_address" "$wg_peer_pubkey" \
            "$wg_endpoint" "$wg_keepalive" "$wg_mtu" || exit 1

        # LAN-exception allow-list: narrow per-host holes in the relay-side
        # geoip:private block, e.g. the router admin panel at 192.168.2.1.
        echo ""
        echo "LAN hosts to allow through the tunnel (remote access to devices behind"
        echo "the router, e.g. the router admin panel at 192.168.2.1). Everything"
        echo "private not listed here stays blocked on the relay side."
        local wg_lan_allow_raw=""
        prompt_input "Comma-separated IPs/CIDRs (Enter for none)" wg_lan_allow_raw ""
        if [[ -n "$wg_lan_allow_raw" ]]; then
            wg_lan_allow=$(validate_wg_lan_allow "$wg_lan_allow_raw") || exit 1
        fi
    else
        echo "Enter the values from exit server setup:"
        echo ""

        prompt_input "Exit server IP" exit_ip
        prompt_input "Exit server UUID" exit_uuid
        prompt_input "Exit server Reality public key" exit_pubkey
        prompt_input "Exit server Reality short ID" exit_short_id
        prompt_input "Exit server Reality SNI" exit_sni

        prompt_input "Exit CDN domain (Enter if not configured)" cdn_domain ""
        if [[ -n "$cdn_domain" ]]; then
            if ! validate_domain "$cdn_domain"; then
                log_error "Invalid domain format: $cdn_domain"
                exit 1
            fi
            prompt_input "Exit CDN path (from exit-server-info.txt CDN_PATH)" cdn_path
            validate_not_empty "$cdn_path" "CDN path" || exit 1
        fi

        prompt_input "Exit Hysteria 2 port (Enter if not configured)" hysteria_port ""
        if [[ -n "$hysteria_port" ]]; then
            if ! [[ "$hysteria_port" =~ ^[0-9]+$ ]] || [[ "$hysteria_port" -lt 1024 || "$hysteria_port" -gt 64535 ]]; then
                log_error "Invalid Hysteria port: $hysteria_port (must be 1024-64535)"
                exit 1
            fi
            hysteria_port_end=$((hysteria_port + 1000))
            log_info "Hysteria 2: UDP ${hysteria_port}-${hysteria_port_end}, Salamander enabled"
            prompt_input "Exit Hysteria 2 obfs password" hysteria_obfs
            validate_not_empty "$hysteria_obfs" "Hysteria obfs password" || exit 1
        fi

        # Validate exit server inputs
        validate_ip "$exit_ip" || { log_error "Invalid IP address: $exit_ip"; exit 1; }
        validate_uuid "$exit_uuid" || { log_error "Invalid UUID format: $exit_uuid"; exit 1; }
        validate_not_empty "$exit_pubkey" "Exit public key" || exit 1
        validate_not_empty "$exit_short_id" "Exit short ID" || exit 1
        validate_not_empty "$exit_sni" "Exit SNI" || exit 1
    fi

    # --- Step 2: Relay configuration ---
    log_info "=== Relay Configuration ==="

    local panel_port panel_path admin_user admin_pass domain
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

    # WG pre-flight: hard gate BEFORE any relay config exists. A throwaway
    # userspace xray tunnel must handshake and egress with the collected peer
    # values — a transposed key or wrong endpoint fails fast here, not after
    # 3X-UI is installed and the template written.
    if [[ "$backhaul_mode" == "wireguard" ]]; then
        log_info "=== WireGuard Backhaul Pre-flight ==="
        if ! wg_dry_run "$wg_private_key" "$wg_address" "$wg_peer_pubkey" \
            "$wg_endpoint" "$wg_allowed_ips" "$wg_keepalive" "$wg_mtu"; then
            log_error "WireGuard pre-flight failed — aborting before any relay config is written."
            log_error "Fix the peer values (compare against the router's WireGuard peer config) and re-run."
            exit 1
        fi
    fi

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
        # Clear panel cert — guarantees plain HTTP to Caddy reverse proxy
        # regardless of whether sub_domain is set, and even if the 3X-UI
        # installer sets an IP cert on future versions
        xui_db_set "webCertFile" ""
        xui_db_set "webKeyFile" ""

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

        # Subscription proxy: sits between Caddy and 3X-UI subscription,
        # appends extra links (CDN, Direct Exit, Hysteria) to every subscription response.
        # Must be set up BEFORE Caddyfile generation so Caddy gets the proxy port.
        local caddy_sub_port="$sub_port"
        if [[ -n "$sub_port" ]] && [[ -n "$cdn_domain" || -n "$hysteria_port" ]]; then
            local cdn_vless_link="" cdn_vless_link_asym="" sub_proxy_port

            # CDN links — only when CDN Fallback is configured
            if [[ -n "$cdn_domain" ]]; then
                # Symmetric XHTTP CDN link
                cdn_vless_link="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up#CDN%20XHTTP"

                # Asymmetric CDN link: upload via Cloudflare XHTTP, download via Reality
                # direct to exit using RAW + xtls-rprx-vision (matches main inbound).
                local download_extra extra_encoded
                download_extra=$(jq -n -c \
                    --arg padding "100-1000" \
                    --arg exit_addr "$exit_ip" \
                    --arg exit_sni_val "$exit_sni" \
                    --arg exit_pubkey_val "$exit_pubkey" \
                    --arg exit_short_id_val "$exit_short_id" \
                    '{
                        xPaddingBytes: $padding,
                        downloadSettings: {
                            address: $exit_addr,
                            port: 443,
                            network: "raw",
                            security: "reality",
                            flow: "xtls-rprx-vision",
                            realitySettings: {
                                serverName: $exit_sni_val,
                                publicKey: $exit_pubkey_val,
                                shortId: $exit_short_id_val,
                                fingerprint: "chrome",
                                spiderX: "/"
                            }
                        }
                    }')
                extra_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$download_extra")
                cdn_vless_link_asym="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up&extra=${extra_encoded}#CDN%20Asymmetric"
            fi

            # Direct exit link — RAW + xtls-rprx-vision flow (matches main inbound).
            local direct_vless_link
            direct_vless_link="vless://${exit_uuid}@${exit_ip}:${exit_port}?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${exit_sni}&fp=chrome&pbk=${exit_pubkey}&sid=${exit_short_id}&spx=%2F#Direct%20Exit"

            # Hysteria 2 link — only when Hysteria is configured
            local hysteria_link=""
            if [[ -n "$hysteria_port" ]]; then
                hysteria_link="hysteria2://${exit_uuid}@${exit_ip}:${hysteria_port},${hysteria_port}-${hysteria_port_end}/?obfs=salamander&obfs-password=${hysteria_obfs}&sni=${exit_sni}&insecure=0#Hysteria%202"
            fi

            # URL-encoded XHTTP extra — sub-proxy injects into each relay VLESS URL
            # since 3X-UI's built-in subscription generator does not emit extra=.
            local relay_extra_json relay_extra_encoded
            relay_extra_json=$(xhttp_extra_json)
            relay_extra_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$relay_extra_json")

            sub_proxy_port=$((sub_port + 1))
            setup_sub_proxy "$sub_port" "$cdn_vless_link" "$sub_proxy_port" "$cdn_domain" "$cdn_path" "$cdn_vless_link_asym" "$direct_vless_link" "$hysteria_link" "$hysteria_port" "$hysteria_port_end" "$hysteria_obfs" "$relay_extra_encoded"
            caddy_sub_port="$sub_proxy_port"
        fi

        # Generate Caddyfile with all domains
        generate_caddyfile "$selfsteal_domain" "$panel_domain" "$panel_port" \
            "$sub_domain" "$caddy_sub_port"
        start_caddy
        setup_caddy_systemd_dependency "x-ui"
        disable_acme_cron
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
    default_sub_id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    local relay_xhttp_path
    relay_xhttp_path=$(generate_random_path)

    local xver=0
    [[ -n "$selfsteal_domain" ]] && xver=1

    # Write API token + xray template while x-ui is STOPPED, so both load fresh on
    # start (avoids the in-memory-flush overwrite + template-stripping traps), then
    # do all inbound/client work via the live REST API (live gRPC, no restart needed).
    x-ui stop
    bootstrap_api_token
    if [[ "$backhaul_mode" == "wireguard" ]]; then
        configure_3xui_relay_template wireguard "$wg_private_key" "$wg_address" \
            "$wg_peer_pubkey" "$wg_endpoint" "$wg_allowed_ips" "$wg_keepalive" \
            "$wg_mtu" "$wg_lan_allow"
    else
        configure_3xui_relay_template vless "$exit_ip" "$exit_port" "$exit_uuid" \
            "$exit_pubkey" "$exit_short_id" "$exit_sni"
    fi
    x-ui start
    log_ok "3X-UI started with template + API token loaded"

    # Wait for the panel API to come up before driving it.
    local _try
    for _try in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        xui_api_request GET "inbounds/list" >/dev/null 2>&1 && break
    done

    # Create the relay inbound and seed default-user via the API (both land in the
    # normalized clients/client_inbounds tables — fixes #44). create_3xui_relay_inbound
    # adds the seed client itself and returns nothing on stdout.
    create_3xui_relay_inbound "$relay_uuid" "$REALITY_PRIVATE_KEY" \
        "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$REALITY_DEST" "$REALITY_SERVER_NAME" \
        "$default_sub_id" "$exit_ip" "$xver" "$relay_xhttp_path" \
        || { log_error "Relay inbound/seed-client creation failed"; exit 1; }

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

    # Install vpn CLI symlink (issue #23)
    install_vpn_cli_symlink "$SCRIPT_DIR/vpn"

    # --- Step 7: Verify ---
    # selfcheck может вернуть 1 при FAIL — не abort'им установку, "Done" банер должен напечататься
    "$SCRIPT_DIR/selfcheck.sh" || true

    # --- Done ---
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip="<not detected>"

    echo ""
    echo "==========================================="
    log_ok "RELAY server setup complete!"
    echo "==========================================="
    echo ""
    echo "  Server:    ${server_ip}"
    if [[ "$backhaul_mode" == "wireguard" ]]; then
        echo "  Protocol:  VLESS + Reality (XHTTP) → WireGuard peer"
        echo "  Port:      443"
        echo "  Exit:      ${wg_endpoint} (WireGuard, externally managed)"
        [[ -n "${WG_DRY_RUN_EGRESS_IP:-}" ]] && echo "  Egress IP: ${WG_DRY_RUN_EGRESS_IP}"
        echo ""
        echo "  NOTE: Direct Exit / CDN Fallback / Hysteria 2 channels do not apply"
        echo "  in WireGuard mode — only the relay channel exists in subscriptions."
        echo ""
        if [[ -n "$wg_lan_allow" ]]; then
            echo "  LAN hosts allowed through the tunnel: ${wg_lan_allow}"
        fi
        echo "  This relay blocks private-IP destinations through the tunnel"
        if [[ -n "$wg_lan_allow" ]]; then
            echo "  except the LAN hosts allow-listed above. You MUST also scope the"
            echo "  router-side WireGuard peer to WAN egress plus exactly those hosts"
        else
            echo "  (no LAN exceptions). You SHOULD also scope the router-side"
            echo "  WireGuard peer to WAN egress only"
        fi
        echo "  — this repo cannot enforce the router side."
        echo ""
    else
        echo "  Protocol:  VLESS + Reality (XHTTP) → Exit (RAW + Vision)"
        echo "  Port:      443"
        echo "  Exit:      ${exit_ip}"
        echo ""
    fi

    if [[ -n "$selfsteal_domain" ]]; then
        echo "  SelfSteal: ${selfsteal_domain}"
        echo ""
        echo "  Panel:     https://${panel_domain}/${panel_path}/"
        echo "  User:      ${admin_user}"
        echo "  Password:  ${admin_pass}"
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
        echo "  Password:  ${admin_pass}"
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
    if [[ -n "$hysteria_port" ]]; then
        echo "  Hysteria 2:  UDP ${hysteria_port}-${hysteria_port_end} via ${exit_ip}"
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
install -m 0600 /dev/null "$LOG_FILE"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
