#!/bin/bash
# Uninstall all VPN components from the server
# Preserves SSH keys and sshd_config
# Run: ./setup.sh uninstall [--force] [--purge-certs]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

FORCE=false
PURGE_CERTS=false

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --force) FORCE=true ;;
            --purge-certs) PURGE_CERTS=true ;;
        esac
    done
}

confirm_uninstall() {
    if [[ "$FORCE" == true ]]; then
        return 0
    fi

    echo ""
    log_warn "This will remove ALL VPN components from this server:"
    echo "  - 3X-UI panel and database"
    echo "  - XRAY core"
    echo "  - fail2ban"
    echo "  - UFW firewall rules"
    echo "  - SSL certificates (only with --purge-certs)"
    echo "  - sqlite3, socat"
    echo ""
    echo "  SSH keys and sshd_config will NOT be touched."
    echo ""
    read -rp "Are you sure? (y/N): " answer
    if [[ "${answer,,}" != "y" ]]; then
        log_info "Aborted."
        exit 0
    fi
}

uninstall_3xui() {
    log_info "Removing 3X-UI..."

    if command -v x-ui &>/dev/null; then
        x-ui stop 2>/dev/null || true
        echo "y" | x-ui uninstall 2>/dev/null || true
        log_ok "3X-UI uninstalled"
    else
        log_info "3X-UI not found, skipping"
    fi

    rm -rf /etc/x-ui/ 2>/dev/null || true
}

uninstall_xray() {
    log_info "Removing XRAY..."

    if command -v xray &>/dev/null || [[ -f /usr/local/bin/xray ]]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove < /dev/null 2>/dev/null || true
        log_ok "XRAY removed"
    else
        log_info "XRAY not found, skipping"
    fi

    rm -rf /usr/local/etc/xray/ 2>/dev/null || true
    rm -rf /var/log/xray/ 2>/dev/null || true
}

uninstall_acme() {
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        if [[ "$PURGE_CERTS" == true ]]; then
            log_info "Removing acme.sh and certificates..."
            ~/.acme.sh/acme.sh --uninstall 2>/dev/null || true
            rm -rf ~/.acme.sh 2>/dev/null || true
            rm -rf /root/cert/ 2>/dev/null || true
            log_ok "acme.sh and certificates removed"
        else
            log_info "acme.sh and certs preserved (use --purge-certs to remove)"
        fi
    else
        log_info "acme.sh not found, skipping"
    fi
}

uninstall_fail2ban() {
    log_info "Removing fail2ban..."

    if dpkg -l fail2ban &>/dev/null 2>&1; then
        systemctl stop fail2ban 2>/dev/null || true
        apt-get purge -y fail2ban > /dev/null 2>&1 || true
        rm -f /etc/fail2ban/jail.local 2>/dev/null || true
        log_ok "fail2ban removed"
    else
        log_info "fail2ban not installed, skipping"
    fi
}

uninstall_ufw() {
    log_info "Removing UFW..."

    if command -v ufw &>/dev/null; then
        ufw --force reset > /dev/null 2>&1 || true
        ufw --force disable > /dev/null 2>&1 || true
        apt-get purge -y ufw > /dev/null 2>&1 || true
        log_ok "UFW removed"
    else
        log_info "UFW not installed, skipping"
    fi
}

uninstall_packages() {
    log_info "Removing extra packages..."

    apt-get purge -y sqlite3 socat > /dev/null 2>&1 || true
    apt-get autoremove -y > /dev/null 2>&1 || true
    log_ok "Extra packages removed"
}

cleanup_files() {
    log_info "Cleaning up leftover files..."

    rm -f /root/exit-server-info.txt 2>/dev/null || true
    log_ok "Cleanup complete"
}

main() {
    echo "==========================================="
    echo "  VLESS Reality VPN — Uninstall"
    echo "==========================================="
    echo ""

    parse_args "$@"
    check_root
    confirm_uninstall

    uninstall_3xui
    uninstall_xray
    uninstall_acme
    uninstall_fail2ban
    uninstall_ufw
    uninstall_packages
    cleanup_files

    echo ""
    echo "==========================================="
    log_ok "All VPN components removed."
    echo "==========================================="
    echo ""
    log_info "SSH keys and sshd_config were preserved."
}

main "$@"
