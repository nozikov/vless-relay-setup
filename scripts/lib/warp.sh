#!/bin/bash
# Cloudflare WARP outbound for AI service routing (issue #35)
# Installs cloudflare-warp via official apt repo, runs as socks5 on 127.0.0.1:40000.
# XRAY routes AI-domain traffic through this socks5 to evade DC-IP blocks.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WARP_PROXY_PORT=40000
WARP_KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
WARP_APT_LIST="/etc/apt/sources.list.d/cloudflare-client.list"

install_warp() {
    log_info "Installing Cloudflare WARP..."

    if command -v warp-cli &>/dev/null; then
        log_info "warp-cli already present, skipping install"
        systemctl enable --now warp-svc 2>/dev/null || true
        return 0
    fi

    # Cleanup half-installed apt state on any error during install.
    # Function is invoked via trap — shellcheck can't see that.
    # shellcheck disable=SC2329
    _warp_install_cleanup() {
        log_warn "WARP install failed — cleaning up apt state"
        rm -f "$WARP_APT_LIST" "$WARP_KEYRING"
    }
    trap _warp_install_cleanup ERR

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --dearmor > "$WARP_KEYRING"

    local codename
    if command -v lsb_release &>/dev/null; then
        codename=$(lsb_release -cs)
    else
        # shellcheck disable=SC1091
        . /etc/os-release
        codename="${VERSION_CODENAME:-bookworm}"
    fi
    echo "deb [signed-by=$WARP_KEYRING] https://pkg.cloudflareclient.com/ $codename main" \
        > "$WARP_APT_LIST"

    apt_update_retry
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflare-warp

    trap - ERR

    systemctl enable --now warp-svc

    # warp-svc на свежем apt-install обычно встаёт за 15-25 секунд,
    # 30s даём с запасом. Плюс на первом вызове warp-cli требует
    # явного accept-TOS — без флага падает с prompt про TTY.
    local _i
    for _i in $(seq 1 30); do
        if warp-cli --accept-tos status &>/dev/null; then
            log_ok "Cloudflare WARP installed (warp-svc up)"
            return 0
        fi
        sleep 1
    done
    log_error "warp-svc failed to start after 30s"
    return 1
}

configure_warp() {
    log_info "Configuring WARP as socks5 on 127.0.0.1:${WARP_PROXY_PORT}..."

    # --accept-tos на каждый вызов — на свежей установке без него команды
    # требуют интерактивного TTY. После первого --accept-tos флаг
    # эффективно no-op (TOS уже принят), но безопаснее не предполагать.
    if ! warp-cli --accept-tos status 2>/dev/null | grep -qE 'Registered|Connected'; then
        warp-cli --accept-tos registration new </dev/null
    fi

    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port "$WARP_PROXY_PORT"
    warp-cli --accept-tos connect

    local _i
    for _i in 1 2 3 4 5; do
        sleep 1
        if ss -tln 2>/dev/null | grep -qE ":${WARP_PROXY_PORT}\s"; then
            log_ok "WARP socks5 listening on 127.0.0.1:${WARP_PROXY_PORT}"
            return 0
        fi
    done

    log_error "WARP failed to listen on :${WARP_PROXY_PORT}"
    return 1
}

restart_warp() {
    warp-cli --accept-tos disconnect 2>/dev/null || true
    warp-cli --accept-tos connect
}

is_warp_running() {
    warp-cli --accept-tos status 2>/dev/null | grep -qE 'Status update: Connected|^Connected'
}

uninstall_warp() {
    log_info "Removing Cloudflare WARP..."
    warp-cli --accept-tos disconnect 2>/dev/null || true
    warp-cli --accept-tos registration delete 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true
    systemctl disable warp-svc 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp 2>/dev/null || true
    rm -f "$WARP_APT_LIST" "$WARP_KEYRING"
    log_ok "Cloudflare WARP removed"
}
