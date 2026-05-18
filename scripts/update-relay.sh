#!/bin/bash
# Update relay server configuration from latest codebase
# Run: ./setup.sh update-relay [--upgrade]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"
source "$SCRIPT_DIR/lib/3xui.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/caddy.sh"

main() {
    local upgrade=false skip_ssh=false
    local arg_hy_port="" arg_hy_port_end="" arg_hy_obfs=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --upgrade) upgrade=true ;;
            --skip-ssh) skip_ssh=true ;;
            --hysteria-port) arg_hy_port="$2"; shift ;;
            --hysteria-port-end) arg_hy_port_end="$2"; shift ;;
            --hysteria-obfs) arg_hy_obfs="$2"; shift ;;
        esac
        shift
    done

    echo "==========================================="
    echo "  VLESS Reality VPN — RELAY Server Update  v${PROJECT_VERSION}"
    echo "==========================================="
    echo ""

    check_root
    enable_bbr
    raise_service_nofile

    # Backup 3X-UI database before any changes
    local backup_path
    backup_path="${XUI_DB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$XUI_DB" "$backup_path"
    log_ok "Database backup saved: $backup_path"

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

    local exit_ip exit_port exit_uuid exit_pubkey exit_short_id exit_sni api_port
    exit_ip=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].address')
    exit_port=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].port')
    exit_uuid=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .settings.vnext[0].users[0].id')
    exit_pubkey=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.publicKey')
    exit_short_id=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.shortId')
    exit_sni=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.realitySettings.serverName')
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

    local is_selfsteal=false
    local current_dest
    current_dest=$(sqlite3 "$XUI_DB" \
        "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';" | \
        jq -r '.realitySettings.dest') || true
    if [[ "$current_dest" == *"caddy.sock"* ]]; then
        is_selfsteal=true
        log_info "SelfSteal mode detected"
    fi

    local is_cdn=false
    local cdn_settings
    cdn_settings=$(sqlite3 "$XUI_DB" \
        "SELECT settings FROM inbounds WHERE tag='inbound-cdn';" 2>/dev/null) || true
    if [[ -n "$cdn_settings" ]]; then
        is_cdn=true
        log_info "CDN mode detected"
    fi

    # Detect current relay inbound transport (TCP or XHTTP)
    local current_network
    current_network=$(sqlite3 "$XUI_DB" \
        "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';" | \
        jq -r '.network') || true
    if [[ "$current_network" == "xhttp" ]]; then
        log_info "XHTTP inbound detected"
    else
        log_info "TCP inbound detected — will migrate to XHTTP"
    fi

    # --- Step 2b: Heal Caddy socket perms (issue #42) ---
    # Install/refresh systemd override BEFORE apt upgrade — if apt-postinst
    # restarts Caddy in this run, ExecStartPost will already be in place.
    if [[ "$is_selfsteal" == true ]]; then
        install_caddy_systemd_override
        if [[ -S "/dev/shm/caddy.sock" ]] && [[ "$(stat -c '%a' /dev/shm/caddy.sock 2>/dev/null)" != "666" ]]; then
            log_info "Restarting Caddy to apply socket perms fix..."
            systemctl restart caddy
        fi
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

        if [[ "$is_selfsteal" == true ]]; then
            log_info "Upgrading Caddy..."
            apt-get update -qq && apt-get install -y -qq caddy > /dev/null 2>&1
            log_ok "Caddy upgraded"
        fi
    fi

    # 3X-UI installer leaves an acme.sh cron behind that conflicts with Caddy on :80
    if [[ "$is_selfsteal" == true ]]; then
        disable_acme_cron
    fi

    # --- Step 5: Update xray template ---
    log_info "=== Updating XRAY Template ==="

    # 3X-UI overwrites DB on shutdown with in-memory state.
    # Must stop before writing, then start to load fresh config.
    x-ui stop

    # Patch inbound sniffing to add routeOnly (idempotent — jq sets the field)
    local current_sniffing patched_sniffing
    current_sniffing=$(sqlite3 "$XUI_DB" \
        "SELECT sniffing FROM inbounds WHERE tag='inbound-443';") || true
    if [[ -n "$current_sniffing" ]]; then
        patched_sniffing=$(echo "$current_sniffing" | jq -c '.routeOnly = true')
        local s_sniffing="${patched_sniffing//\'/\'\'}"
        sqlite3 "$XUI_DB" \
            "UPDATE inbounds SET sniffing='${s_sniffing}' WHERE tag='inbound-443';"
        log_ok "Inbound sniffing patched (routeOnly: true)"
    fi

    # Precompute XHTTP extra block (xmux + padding + flow control) — shared helper.
    local extra_json
    extra_json=$(xhttp_extra_json)

    # Migrate TCP inbound to XHTTP if still on TCP
    if [[ "$current_network" != "xhttp" ]]; then
        local relay_xhttp_path
        relay_xhttp_path=$(generate_random_path)
        log_info "Migrating relay inbound to XHTTP (path: $relay_xhttp_path)..."

        local current_stream patched_stream
        current_stream=$(sqlite3 "$XUI_DB" \
            "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';")
        # Write xhttpSettings complete with extra in a single pass —
        # prevents fragility if the post-migration patch block is skipped/reordered.
        patched_stream=$(echo "$current_stream" | jq -c \
            --arg relay_path "$relay_xhttp_path" \
            --argjson extra "$extra_json" \
            '.network = "xhttp"
            | .xhttpSettings = {
                path: ("/"+$relay_path),
                mode: "auto",
                extra: $extra
            }
            | del(.tcpSettings)')
        local s_stream="${patched_stream//\'/\'\'}"
        sqlite3 "$XUI_DB" \
            "UPDATE inbounds SET stream_settings='${s_stream}' WHERE tag='inbound-443';"
        # Clear flow from all clients — flow is incompatible with XHTTP
        # (Shadowrocket and other clients connect without flow on XHTTP)
        local current_settings patched_settings
        current_settings=$(sqlite3 "$XUI_DB" \
            "SELECT settings FROM inbounds WHERE tag='inbound-443';")
        patched_settings=$(echo "$current_settings" | jq -c \
            '.clients = [.clients[] | .flow = ""]')
        local s_settings="${patched_settings//\'/\'\'}"
        sqlite3 "$XUI_DB" \
            "UPDATE inbounds SET settings='${s_settings}' WHERE tag='inbound-443';"

        log_ok "Relay inbound migrated from TCP to XHTTP"
    fi

    # Idempotent patch of XHTTP extra + Reality limitFallback on existing installs
    # (already on XHTTP before this run). Ensures current recommended values are
    # applied on every update — XHTTP extra needed for TSPU TLS-policing resistance
    # on client→relay leg (XTLS issue #5332); limitFallback throttles probe traffic
    # hitting the Reality fallback for anti-fingerprint.
    local current_inbound_stream updated_inbound_stream lf_json
    lf_json=$(reality_limit_fallback_json)
    current_inbound_stream=$(sqlite3 "$XUI_DB" \
        "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';") || true
    if [[ -n "$current_inbound_stream" && \
          "$(echo "$current_inbound_stream" | jq -r '.network')" == "xhttp" ]]; then
        updated_inbound_stream=$(echo "$current_inbound_stream" | jq -c \
            --argjson extra "$extra_json" \
            --argjson lf "$lf_json" \
            '.xhttpSettings.extra = $extra
            | .realitySettings += $lf')
        if [[ -z "$updated_inbound_stream" ]]; then
            log_error "jq failed to patch XHTTP extra/limitFallback on inbound (input malformed?)"
            exit 1
        fi
        local s_inbound_stream="${updated_inbound_stream//\'/\'\'}"
        sqlite3 "$XUI_DB" \
            "UPDATE inbounds SET stream_settings='${s_inbound_stream}' WHERE tag='inbound-443';"
        log_ok "XHTTP inbound patched (extra block + Reality limitFallback)"
    fi

    # Issue #38: backfill client_traffics для всех клиентов в settings.clients[],
    # у кого нет row (включая seed default-user на серверах <=v1.10.0).
    # Идемпотентно: ensure_client_traffics_row делает INSERT WHERE NOT EXISTS.
    local backfill_emails backfill_added=0
    backfill_emails=$(sqlite3 "$XUI_DB" \
        "SELECT json_extract(value, '\$.email')
         FROM inbounds, json_each(json_extract(settings, '\$.clients'))
         WHERE tag='inbound-443';" 2>/dev/null) || true
    if [[ -n "$backfill_emails" ]]; then
        while IFS= read -r email; do
            [[ -z "$email" ]] && continue
            local before after
            before=$(sqlite3 "$XUI_DB" \
                "SELECT COUNT(*) FROM client_traffics WHERE email='${email//\'/\'\'}';")
            ensure_client_traffics_row "$email"
            after=$(sqlite3 "$XUI_DB" \
                "SELECT COUNT(*) FROM client_traffics WHERE email='${email//\'/\'\'}';")
            if [[ "$before" == "0" && "$after" != "0" ]]; then
                backfill_added=$((backfill_added + 1))
                log_info "  Added client_traffics row for '$email'"
            fi
        done <<< "$backfill_emails"
        if [[ "$backfill_added" -gt 0 ]]; then
            log_ok "Backfilled $backfill_added client_traffics row(s) (issue #38)"
        fi
    fi

    if echo "$template" | jq -e '.outbounds[] | select(.tag=="proxy-exit") | .streamSettings.xhttpSettings' > /dev/null 2>&1; then
        log_info "Migrating proxy-exit outbound XHTTP → RAW + xtls-rprx-vision (issue #33)"
        log_warn "  This relay will speak Vision to ${exit_ip}:${exit_port}."
        log_warn "  Make sure 'update-exit' has ALREADY been run on the exit server,"
        log_warn "  otherwise relay-routed clients will fail until exit is migrated."
    else
        log_info "proxy-exit outbound already on RAW + Vision, regenerating template"
    fi

    configure_3xui_relay_template "$exit_ip" "$exit_port" "$exit_uuid" \
        "$exit_pubkey" "$exit_short_id" "$exit_sni" "$api_port"

    x-ui start

    # 3X-UI itself running ≠ xray inside it healthy. Bad template can leave x-ui up
    # while xray fails to bind. Wait briefly, then probe port 443.
    local xray_healthy=false
    if systemctl is-active --quiet x-ui; then
        for _ in 1 2 3 4 5; do
            sleep 1
            if ss -tln 2>/dev/null | grep -qE ':443\s'; then
                xray_healthy=true
                break
            fi
        done
    fi

    if [[ "$xray_healthy" != true ]]; then
        log_warn "3X-UI/xray failed to bind :443 — restoring DB backup..."
        x-ui stop || true
        cp "$backup_path" "$XUI_DB"
        x-ui start
        sleep 3
        if systemctl is-active --quiet x-ui && ss -tln 2>/dev/null | grep -qE ':443\s'; then
            log_ok "Previous database restored, 3X-UI is running"
        else
            log_error "Rollback also failed. Check: x-ui log"
        fi
        exit 1
    fi
    log_ok "3X-UI restarted with updated template (xray bound :443)"

    # --- Step 5b: Update extra links in sub-proxy if active ---
    local sub_proxy_service="/etc/systemd/system/sub-proxy.service"
    if [[ -f "$sub_proxy_service" ]]; then
        log_info "Updating links in sub-proxy..."

        # Update sub-proxy script and config templates from codebase
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        install -m 0755 "$script_dir/lib/sub-proxy.py" /usr/local/bin/sub-proxy.py
        mkdir -p /etc/sub-proxy
        # Refresh templates на existing relay'ях (issue #21 + cleanup стейлой sr-conf-*)
        install -m 0644 "$script_dir/lib/templates/sr-module-ru.sgmodule" /etc/sub-proxy/sr-module-ru.sgmodule
        install -m 0644 "$script_dir/lib/templates/happ-routing-ru.json" /etc/sub-proxy/happ-routing-ru.json
        install -m 0644 "$script_dir/lib/templates/share-page.html" /etc/sub-proxy/share-page.html

        # Read CDN params — prefer dedicated env vars, fall back to old URL parsing
        local cdn_domain cdn_path
        cdn_domain=$(grep -oP '(?<=CDN_DOMAIN=).+' "$sub_proxy_service") || true
        cdn_path=$(grep -oP '(?<=CDN_PATH=).+' "$sub_proxy_service") || true
        if [[ -z "$cdn_domain" ]]; then
            # Migration from old format: parse from VLESS URL
            cdn_domain=$(grep 'CDN_VLESS_LINK=' "$sub_proxy_service" | grep -oP '(?<=@)[^:]+' | head -1) || true
            cdn_path=$(grep 'CDN_VLESS_LINK=' "$sub_proxy_service" | grep -oP '(?<=path=%%2F)[^&]+' | head -1) || true
        fi

        # Read Hysteria params from existing service, then override with CLI args
        local hy_port hy_port_end hy_obfs
        hy_port=$(grep -oP '(?<=HYSTERIA_PORT=).+' "$sub_proxy_service") || true
        hy_port_end=$(grep -oP '(?<=HYSTERIA_PORT_END=).+' "$sub_proxy_service") || true
        hy_obfs=$(grep -oP '(?<=HYSTERIA_OBFS=).+' "$sub_proxy_service") || true

        # CLI args override service file values (for adding/updating Hysteria)
        [[ -n "$arg_hy_port" ]] && hy_port="$arg_hy_port"
        [[ -n "$arg_hy_port_end" ]] && hy_port_end="$arg_hy_port_end"
        [[ -n "$arg_hy_obfs" ]] && hy_obfs="$arg_hy_obfs"

        # Default port_end if only port provided
        if [[ -n "$hy_port" && -z "$hy_port_end" ]]; then
            hy_port_end=$((hy_port + 1000))
        fi

        if [[ -n "$cdn_domain" && -n "$cdn_path" ]] || [[ -n "$hy_port" && -n "$hy_obfs" ]]; then
            # Read ExecStart from existing service file
            local exec_start
            exec_start=$(grep -oP '(?<=ExecStart=).+' "$sub_proxy_service") || true

            # CDN links — only when CDN Fallback is configured
            local cdn_vless_link="" cdn_vless_link_asym=""
            if [[ -n "$cdn_domain" && -n "$cdn_path" ]]; then
                # Symmetric XHTTP CDN link
                cdn_vless_link="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up#CDN%20XHTTP"

                # Asymmetric CDN link: upload via Cloudflare XHTTP, download via Reality
                # direct to exit using RAW + xtls-rprx-vision (matches main inbound).
                local download_extra extra_encoded
                download_extra=$(jq -n -c \
                    --arg padding "100-1000" \
                    --arg addr "$exit_ip" \
                    --arg sni "$exit_sni" \
                    --arg pubkey "$exit_pubkey" \
                    --arg sid "$exit_short_id" \
                    '{
                        xPaddingBytes: $padding,
                        downloadSettings: {
                            address: $addr, port: 443, network: "raw",
                            security: "reality",
                            flow: "xtls-rprx-vision",
                            realitySettings: {
                                serverName: $sni, publicKey: $pubkey,
                                shortId: $sid, fingerprint: "chrome",
                                spiderX: "/"
                            }
                        }
                    }')
                extra_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$download_extra")
                cdn_vless_link_asym="vless://${exit_uuid}@${cdn_domain}:443?type=xhttp&security=tls&sni=${cdn_domain}&host=${cdn_domain}&path=%2F${cdn_path}&mode=packet-up&extra=${extra_encoded}#CDN%20Asymmetric"
            fi

            # Direct exit link — RAW + xtls-rprx-vision flow (matches main inbound).
            local direct_vless_link="vless://${exit_uuid}@${exit_ip}:${exit_port}?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${exit_sni}&fp=chrome&pbk=${exit_pubkey}&sid=${exit_short_id}&spx=%2F#Direct%20Exit"

            # Hysteria 2 link — only when Hysteria is configured
            local hysteria_link=""
            if [[ -n "$hy_port" && -n "$hy_obfs" ]]; then
                hysteria_link="hysteria2://${exit_uuid}@${exit_ip}:${hy_port},${hy_port}-${hy_port_end}/?obfs=salamander&obfs-password=${hy_obfs}&sni=${exit_sni}&insecure=0#Hysteria%202"
                log_info "Hysteria 2 link updated"
            fi

            # URL-encoded XHTTP extra — sub-proxy injects into each relay VLESS URL
            # since 3X-UI's built-in subscription generator does not emit extra=.
            local relay_extra_encoded
            relay_extra_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$extra_json")

            # Escape % for systemd
            local link_escaped="${cdn_vless_link//%/%%}"
            local link_asym_escaped="${cdn_vless_link_asym//%/%%}"
            local direct_escaped="${direct_vless_link//%/%%}"
            local hysteria_escaped="${hysteria_link//%/%%}"
            local relay_extra_escaped="${relay_extra_encoded//%/%%}"

            # Read existing service params
            local sub_upstream sub_proxy_port
            sub_upstream=$(grep -oP '(?<=SUB_UPSTREAM=).+' "$sub_proxy_service") || true
            sub_proxy_port=$(grep -oP '(?<=SUB_PROXY_PORT=).+' "$sub_proxy_service") || true

            # Backup before rewriting — restore on regen failure
            local sub_proxy_backup
            sub_proxy_backup="${sub_proxy_service}.bak.$(date +%Y%m%d-%H%M%S)"
            cp "$sub_proxy_service" "$sub_proxy_backup"

            # Rewrite entire service file (never sed — & in URLs breaks sed)
            cat > "$sub_proxy_service" << SVCEOF
[Unit]
Description=Subscription proxy (appends extra links)
After=x-ui.service

[Service]
Type=simple
Environment=CDN_VLESS_LINK=${link_escaped}
Environment=CDN_VLESS_LINK_ASYM=${link_asym_escaped}
Environment=DIRECT_VLESS_LINK=${direct_escaped}
Environment=HYSTERIA_LINK=${hysteria_escaped}
Environment=HYSTERIA_PORT=${hy_port}
Environment=HYSTERIA_PORT_END=${hy_port_end}
Environment=HYSTERIA_OBFS=${hy_obfs}
Environment=CDN_DOMAIN=${cdn_domain}
Environment=CDN_PATH=${cdn_path}
Environment=RELAY_XHTTP_EXTRA=${relay_extra_escaped}
Environment=SUB_UPSTREAM=${sub_upstream}
Environment=SUB_PROXY_PORT=${sub_proxy_port}
ExecStart=${exec_start}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF
            systemctl daemon-reload
            systemctl restart sub-proxy
            sleep 2
            if systemctl is-active --quiet sub-proxy; then
                log_ok "Sub-proxy updated"
            else
                log_warn "Sub-proxy failed to start, restoring backup..."
                cp "$sub_proxy_backup" "$sub_proxy_service"
                systemctl daemon-reload
                systemctl restart sub-proxy || true
                if systemctl is-active --quiet sub-proxy; then
                    log_ok "Previous sub-proxy.service restored"
                else
                    log_error "Sub-proxy rollback also failed. Check: journalctl -u sub-proxy"
                fi
                exit 1
            fi
        fi
    fi

    # --- Step 6: Security ---
    log_info "=== Security ==="
    local ssh_port
    ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | head -1 | awk '{print $2}') || true
    ssh_port="${ssh_port:-22}"
    log_info "Current SSH port: $ssh_port"

    local security_args=()
    [[ "$skip_ssh" == true ]] && security_args+=("--skip-ssh")
    security_args+=(--ssh-port "$ssh_port" "$ssh_port":SSH 443:XRAY "$panel_port:3X-UI Panel")
    if [[ "$is_selfsteal" == true ]]; then
        security_args+=(80:Caddy-ACME)
    elif [[ -n "$sub_port" ]]; then
        security_args+=("$sub_port:Subscription")
    fi
    setup_security "${security_args[@]}"

    # Install vpn CLI symlink (issue #23) — идемпотентно для существующих серверов
    install_vpn_cli_symlink "$SCRIPT_DIR/vpn"

    # --- Step 7: Verify ---
    # selfcheck может вернуть 1 при FAIL — не abort'им апдейт, "Done" банер должен напечататься
    "$SCRIPT_DIR/selfcheck.sh" || true

    # --- Done ---
    echo ""
    echo "==========================================="
    log_ok "RELAY server update complete!"
    echo "==========================================="
    echo ""
    echo "  Template updated from latest codebase"
    if [[ "$current_network" != "xhttp" ]]; then
        echo "  Relay inbound migrated from TCP to XHTTP"
    fi
    if [[ "$upgrade" == true ]]; then
        echo "  3X-UI upgraded to latest version"
    fi
    echo "  Security re-applied"
    echo "  Clients and subscriptions preserved"
    if [[ "$is_cdn" == true ]]; then
        echo "  CDN fallback inbound preserved"
    fi
    if [[ -n "$arg_hy_port" ]]; then
        echo "  Hysteria 2 link added to subscriptions"
    fi
    echo ""
    echo "  Tell users to refresh the subscription URL in their VPN client —"
    echo "  cached Direct Exit / CDN-asymmetric links from before v1.10.0 will"
    echo "  not work after the Vision migration (see issue #33)."
    echo ""
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main "$@" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
