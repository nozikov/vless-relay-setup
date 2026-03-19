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

<<<<<<< HEAD
    # Determine the service name (ssh or sshd)
    local ssh_service=""
    local units
    units=$(systemctl list-unit-files 2>/dev/null)

    if echo "$units" | grep -q ssh.service; then
        ssh_service="ssh"
    elif echo "$units" | grep -q sshd.service; then
        ssh_service="sshd"
    fi

    if [[ -z "$ssh_service" ]]; then
        log_error "SSH service not found"
        return 1
    fi

    log_info "Found SSH service: $ssh_service"

    systemctl restart "$ssh_service"
=======
    # Service is named "ssh" on Debian/Ubuntu, "sshd" on RHEL/Fedora
    local sshd_service="sshd"
    if systemctl list-unit-files ssh.service &>/dev/null; then
        sshd_service="ssh"
    fi
    systemctl restart "$sshd_service"
>>>>>>> a5c4a5150890f258e78d515f5ed46dc51a269c93
    log_ok "SSH hardened: password auth disabled, key-only access"
}

setup_ufw() {
    # Usage: setup_ufw port:label [port:label ...]
    # Example: setup_ufw 22:SSH 443:XRAY 48658:"3X-UI Panel"
    log_info "Configuring UFW firewall..."

    apt-get install -y -qq ufw > /dev/null 2>&1

    ufw default deny incoming
    ufw default allow outgoing

    local summary=""
    for entry in "$@"; do
        local port="${entry%%:*}"
        local label="${entry#*:}"
        ufw allow "$port"/tcp comment "$label"
        summary="${summary:+$summary, }${label}=${port}"
    done

    echo "y" | ufw enable
    log_ok "UFW configured: $summary"
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
    # Usage: setup_security [--skip-ssh] port:label [port:label ...]
    local skip_ssh=false
    if [[ "${1:-}" == "--skip-ssh" ]]; then
        skip_ssh=true
        shift
    fi

    if [[ "$skip_ssh" == true ]]; then
        log_info "Skipping SSH hardening (--skip-ssh)"
    else
        setup_ssh_hardening
    fi
    setup_fail2ban
    setup_ufw "$@"
}
