#!/bin/bash
# Server security hardening

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

setup_ssh_hardening() {
    log_info "Hardening SSH..."

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        log_warn "No SSH authorized_keys found! Skipping SSH hardening to avoid lockout."
        log_warn "Configure SSH keys first, then re-run this script."
        return 0
    fi

    local ssh_config="/etc/ssh/sshd_config"

    # Disable password authentication
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$ssh_config"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$ssh_config"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$ssh_config"

    systemctl restart sshd
    log_ok "SSH hardened: password auth disabled, key-only access"
}

setup_ufw() {
    local ssh_port="${1:-22}"
    local panel_port="${2:-}"
    local xray_port="${3:-443}"

    log_info "Configuring UFW firewall..."

    apt-get install -y -qq ufw > /dev/null 2>&1

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$ssh_port"/tcp comment "SSH"
    ufw allow "$xray_port"/tcp comment "XRAY"

    if [[ -n "$panel_port" ]]; then
        ufw allow "$panel_port"/tcp comment "3X-UI Panel"
    fi

    echo "y" | ufw enable
    log_ok "UFW configured: SSH=$ssh_port, XRAY=$xray_port, Panel=$panel_port"
}

setup_fail2ban() {
    log_info "Installing and configuring fail2ban..."

    apt-get install -y -qq fail2ban > /dev/null 2>&1

    cat > /etc/fail2ban/jail.local << 'JAIL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
JAIL

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_ok "fail2ban configured: ban after 3 attempts for 1 hour"
}

setup_security() {
    local ssh_port="${1:-22}"
    local panel_port="${2:-}"
    local xray_port="${3:-443}"

    setup_ssh_hardening
    setup_fail2ban
    setup_ufw "$ssh_port" "$panel_port" "$xray_port"
}
