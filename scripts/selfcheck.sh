#!/bin/bash
# Selfcheck — runs after setup/update or manually.
# Verifies local services + outside probes (selfsteal masque alive from outside).
# Run: ./setup.sh selfcheck [--quiet]
# Exit code: 0 = OK or warnings only; 1 = at least one FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/selfcheck.sh"
source "$SCRIPT_DIR/lib/xui-api.sh"
source "$SCRIPT_DIR/lib/wireguard.sh"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XUI_DB="/etc/x-ui/x-ui.db"

# shellcheck disable=SC2178
run_selfcheck_exit() {
    local -n _fails="$1"
    local -n _warns="$2"
    local rc

    log_info "=== Block 1 — local services ==="
    verify_service_running xray "XRAY"           || _fails=$((_fails + 1))
    verify_service_running x-ui "3X-UI"          || _fails=$((_fails + 1))
    verify_port_listening 443 "XRAY"             || _fails=$((_fails + 1))

    if [[ -d /etc/caddy ]]; then
        verify_service_running caddy "Caddy"     || _fails=$((_fails + 1))
        verify_port_listening 80 "Caddy ACME"    || _fails=$((_fails + 1))
    fi

    if [[ -f /etc/hysteria/config.yaml ]]; then
        verify_service_running hysteria-server "Hysteria 2" || _fails=$((_fails + 1))
    fi

    if command -v warp-cli &>/dev/null && \
       jq -e '.outbounds[] | select(.tag=="warp")' "$XRAY_CONFIG" &>/dev/null; then
        if warp-cli --accept-tos status 2>/dev/null | grep -qE 'Connected'; then
            log_ok "WARP tunnel connected"
        else
            log_error "WARP outbound configured but warp-cli not connected"
            _fails=$((_fails + 1))
        fi
    fi

    log_info "=== Block 2 — system resources ==="
    rc=0; check_disk_space || rc=$?
    case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac

    rc=0; check_ram_free || rc=$?
    case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac

    # Cert expiry — only if SelfSteal mode (dest = caddy.sock with our domain)
    local domain=""
    if [[ -f "$XRAY_CONFIG" ]]; then
        domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' \
            "$XRAY_CONFIG" 2>/dev/null) || true
        if jq -e '.inbounds[0].streamSettings.realitySettings.dest | contains("caddy.sock")' \
            "$XRAY_CONFIG" &>/dev/null && [[ -n "$domain" && "$domain" != "null" ]]; then
            rc=0; check_cert_expiry "$domain" || rc=$?
            case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac
        fi
    fi

    log_info "=== Block 3 — outside probes ==="
    local server_ip=""
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || true
    if [[ -n "$server_ip" ]]; then
        rc=0; probe_selfsteal_hairpin "$server_ip" "$domain" || rc=$?
        case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac
    else
        log_warn "Cannot determine external IP — outside probes skipped"
        _warns=$((_warns + 1))
    fi

    # CDN external probe (only if CDN configured)
    local cdn_domain="" cdn_path=""
    if [[ -f /etc/caddy/Caddyfile && -n "$domain" ]]; then
        cdn_domain=$(grep -oP '(?<=https://)\S+(?= \{)' /etc/caddy/Caddyfile 2>/dev/null | \
            grep -v "$domain" | head -1) || true
        if [[ -n "$cdn_domain" ]]; then
            cdn_path=$(jq -r '.inbounds[] | select(.tag=="vless-cdn-in") | .streamSettings.xhttpSettings.path // empty' \
                "$XRAY_CONFIG" 2>/dev/null | sed 's|^/||') || true
            if [[ -n "$cdn_path" ]]; then
                rc=0; probe_cdn_external "$cdn_domain" "$cdn_path" || rc=$?
                case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac
            fi
        fi
    fi
}

# shellcheck disable=SC2178
run_selfcheck_relay() {
    local -n _fails="$1"
    local -n _warns="$2"
    local rc

    log_info "=== Block 1 — local services ==="
    verify_service_running x-ui "3X-UI"           || _fails=$((_fails + 1))
    verify_port_listening 443 "XRAY (3X-UI)"      || _fails=$((_fails + 1))

    if [[ -d /etc/caddy ]]; then
        verify_service_running caddy "Caddy"      || _fails=$((_fails + 1))
        verify_port_listening 80 "Caddy ACME"     || _fails=$((_fails + 1))
    fi

    if [[ -f /etc/systemd/system/sub-proxy.service ]]; then
        verify_service_running sub-proxy "Sub-proxy" || _fails=$((_fails + 1))
    fi

    log_info "=== Block 2 — system resources ==="
    rc=0; check_disk_space || rc=$?
    case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac

    rc=0; check_ram_free || rc=$?
    case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac

    # Cert expiry — read selfsteal domain from 3X-UI inbound
    local domain=""
    if [[ -f "$XUI_DB" ]]; then
        domain=$(sqlite3 "$XUI_DB" \
            "SELECT stream_settings FROM inbounds WHERE tag='inbound-443';" 2>/dev/null | \
            jq -r '.realitySettings.serverNames[0] // empty' 2>/dev/null) || true
        if [[ -n "$domain" && "$domain" != "null" ]]; then
            rc=0; check_cert_expiry "$domain" || rc=$?
            case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac
        fi
    fi

    # API reachability (relay) — confirms Bearer token + panel API are live.
    if xui_api_request GET "inbounds/list" >/dev/null 2>&1; then
        log_ok "3X-UI panel API reachable (Bearer token valid)"
    else
        log_warn "3X-UI panel API not reachable / token invalid"
        _warns=$((_warns + 1))
    fi

    # WireGuard backhaul (WG-to-external-peer mode) — template sanity + live
    # dry-run. Nothing to check on the far end (externally managed router).
    local template=""
    template=$(sqlite3 "$XUI_DB" \
        "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null) || true
    if [[ -n "$template" ]] && \
       echo "$template" | jq -e '.outbounds[] | select(.tag=="wg-out")' >/dev/null 2>&1; then
        log_info "=== WireGuard backhaul ==="

        local wg_sk wg_addr wg_pk wg_ep wg_aips wg_ka wg_mtu wg_lan
        wg_sk=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.secretKey // empty')
        wg_addr=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.address | join(",")')
        wg_pk=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.peers[0].publicKey // empty')
        wg_ep=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.peers[0].endpoint // empty')
        wg_aips=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.peers[0].allowedIPs | join(",")')
        wg_ka=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.peers[0].keepAlive // 25')
        wg_mtu=$(echo "$template" | jq -r '.outbounds[] | select(.tag=="wg-out") | .settings.mtu // 1380')

        if [[ -z "$wg_sk" || -z "$wg_pk" || -z "$wg_ep" ]]; then
            log_error "wg-out outbound incomplete (missing secretKey/publicKey/endpoint)"
            _fails=$((_fails + 1))
        else
            log_ok "wg-out outbound present (peer: $wg_ep)"

            # LAN-exception allow-list: INFO, not PASS/FAIL — a green check must
            # not hide which private hosts are intentionally punched through.
            wg_lan=$(echo "$template" | jq -r \
                '[.routing.rules[] | select(.outboundTag=="wg-out") | .ip // [] | .[]] | join(", ")')
            if [[ -n "$wg_lan" ]]; then
                log_info "LAN-exception allow-list (relay side): $wg_lan"
                log_info "  Not probed here — actual reachability depends on router-side peer scoping"
            fi

            # Live check: fresh ephemeral tunnel from the configured params.
            # Proves the params + router are good NOW; it is NOT introspection
            # of the running wg-out outbound (no wg0 interface / wg show exists).
            rc=0; wg_dry_run "$wg_sk" "$wg_addr" "$wg_pk" "$wg_ep" "$wg_aips" "$wg_ka" "$wg_mtu" || rc=$?
            if [[ "$rc" -eq 0 ]]; then
                log_info "  (verifies params via a fresh tunnel — does NOT prove the router-side peer is LAN-scoped)"
            else
                log_error "WireGuard backhaul dry-run failed (no handshake/egress with configured params)"
                _fails=$((_fails + 1))
            fi

            # Supplementary: the live outbound's only observable signal is xray's own logs
            if [[ -f /var/log/xray/error.log ]]; then
                local wg_errs
                wg_errs=$(tail -n 200 /var/log/xray/error.log 2>/dev/null | grep -ci 'wireguard') || true
                if [[ "${wg_errs:-0}" -gt 0 ]]; then
                    log_warn "xray error.log mentions wireguard ${wg_errs} time(s) in last 200 lines — live outbound may be degraded"
                    _warns=$((_warns + 1))
                fi
            fi
        fi
    fi

    log_info "=== Block 3 — outside probes ==="
    local server_ip=""
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || true
    if [[ -n "$server_ip" ]]; then
        rc=0; probe_selfsteal_hairpin "$server_ip" "$domain" || rc=$?
        case "$rc" in 1) _warns=$((_warns + 1)) ;; 2) _fails=$((_fails + 1)) ;; esac
    else
        log_warn "Cannot determine external IP — outside probes skipped"
        _warns=$((_warns + 1))
    fi
}

main() {
    local quiet=false
    for arg in "$@"; do
        case "$arg" in
            --quiet) quiet=true ;;
        esac
    done

    if [[ "$quiet" == true ]]; then
        export NO_COLOR=1
    fi

    # Auto-detect role: standalone xray.service indicates exit. На relay
    # xray бежит как subprocess 3X-UI и xray.service disabled/inactive
    # (хотя файл /usr/local/etc/xray/config.json может остаться от
    # старых установок — поэтому нельзя просто проверять файл).
    local role=""
    if systemctl is-enabled --quiet xray 2>/dev/null; then
        role="exit"
    elif [[ -f "$XUI_DB" ]]; then
        role="relay"
    elif [[ -f "$XRAY_CONFIG" ]]; then
        role="exit"
    else
        log_error "Cannot detect role — neither $XRAY_CONFIG nor $XUI_DB found"
        log_error "Has the server been set up? Try: sudo ./setup.sh exit  or  sudo ./setup.sh relay"
        exit 1
    fi

    echo ""
    echo "==========================================="
    echo "  Selfcheck — $role server  v${PROJECT_VERSION}"
    echo "==========================================="

    local fails=0 warns=0
    if [[ "$role" == "exit" ]]; then
        run_selfcheck_exit fails warns
    else
        run_selfcheck_relay fails warns
    fi

    echo ""
    echo "==========================================="
    if [[ "$fails" -gt 0 ]]; then
        log_error "Result: $fails ISSUE(S) FOUND ($warns warning(s))"
        echo "==========================================="
        exit 1
    elif [[ "$warns" -gt 0 ]]; then
        log_ok "Result: ALL OK ($warns warning(s))"
    else
        log_ok "Result: ALL OK"
    fi
    echo "==========================================="
}

main "$@"
