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
        if warp-cli status 2>/dev/null | grep -qE 'Connected'; then
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

    # Auto-detect role
    local role=""
    if [[ -f "$XRAY_CONFIG" ]]; then
        role="exit"
    elif [[ -f "$XUI_DB" ]]; then
        role="relay"
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
