#!/bin/bash
# Server security hardening

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

setup_ssh() {
    log_info "Hardening SSH..."

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        log_error "No SSH authorized_keys found!"
        log_error "Configure SSH keys first, then re-run this script."
        return 1
    fi

    local ssh_port ssh_config
    ssh_port="${1}"
    ssh_config="/etc/ssh/sshd_config"

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$ssh_config"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$ssh_config"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$ssh_config"
    sed -i "s/^#\?Port [0-9]\+/Port $ssh_port/" "$ssh_config"

    
    log_ok "SSH hardened: password auth disabled, key-only access, port changed"
}

setup_ufw() {
    if ! check_ufw; then
        log_info "Configuring UFW firewall..."

        apt-get install -y ufw > /dev/null 2>&1

        ufw default deny incoming
        ufw default allow outgoing
    else
        return 0
    fi
}

allow_ports() {
    # Usage: allow_ports port:label [port:label ...]
    # Example: allow_ports 443:XRAY 48658:"3X-UI Panel"
    if check_ufw; then
        local summary=""
        for entry in "$@"; do
            local port="${entry%%:*}"
            local label="${entry#*:}"
            ufw allow from 0.0.0.0/0 to any port "$port" proto tcp comment "$label"
            summary="${summary:+$summary, }${label}=${port}"
        done
        log_ok "UFW configured: $summary"
    else
        log_warn "UFW not found. Skipping"
    fi
}

setup_fail2ban() {
    log_info "Installing and configuring fail2ban..."
    local ssh_port="${1}"

    apt-get install -y -qq fail2ban > /dev/null 2>&1

    cat > /etc/fail2ban/jail.local << JAIL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $ssh_port
JAIL

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_ok "fail2ban configured: ban after 3 attempts for 1 hour"
}