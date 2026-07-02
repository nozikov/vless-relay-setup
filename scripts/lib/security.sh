#!/bin/bash
# Server security hardening

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

setup_ssh_hardening() {
    local ssh_port="${1:-22}"

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

    # Set SSH port — always clean existing Port lines to handle revert to 22
    sed -i '/^#\?Port /d' "$ssh_config"
    if [[ "$ssh_port" != "22" ]]; then
        echo "Port $ssh_port" >> "$ssh_config"
        log_info "SSH port changed to $ssh_port"
    fi

    # Ubuntu 22.10+/24.04 socket-activate SSH via ssh.socket, which OWNS the
    # listening port (ListenStream=22) and makes sshd ignore sshd_config's Port
    # directive. Editing Port + restarting ssh.service silently leaves the
    # daemon on 22 — and once UFW closes 22, that is a lockout. Revert to the
    # traditional standalone daemon so sshd_config is authoritative (update
    # scripts also read the port from there via grep).
    if systemctl list-unit-files ssh.socket &>/dev/null && \
       systemctl is-active --quiet ssh.socket 2>/dev/null; then
        log_info "Reverting SSH from socket-activation to ssh.service (so Port takes effect)"
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        # Neutralize the socket's port override in case anything re-triggers it
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/override.conf <<SOCKETEOF
[Socket]
ListenStream=
ListenStream=${ssh_port}
SOCKETEOF
        systemctl daemon-reload
    fi

    # Service is named "ssh" on Debian/Ubuntu, "sshd" on RHEL/Fedora
    local sshd_service="sshd"
    if systemctl list-unit-files ssh.service &>/dev/null; then
        sshd_service="ssh"
    fi
    systemctl enable "$sshd_service" >/dev/null 2>&1 || true
    systemctl restart "$sshd_service"

    # Verify the daemon actually bound the intended port before we let UFW close
    # the old one. A mismatch here is the difference between "hardened" and
    # "locked out", so fail loudly rather than press on.
    local bound=false _try
    for _try in 1 2 3 4 5; do
        if ss -tlnH "sport = :${ssh_port}" 2>/dev/null | grep -q ":${ssh_port}"; then
            bound=true
            break
        fi
        sleep 1
    done
    if [[ "$bound" != true ]]; then
        log_error "sshd is NOT listening on port ${ssh_port} after restart!"
        log_error "Aborting before UFW closes the old port — this would be a lockout."
        log_error "Check: systemctl status ${sshd_service}; ss -tlnp | grep sshd"
        exit 1
    fi
    log_ok "SSH hardened: password auth disabled, key-only access, port $ssh_port (listener confirmed)"
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
    local ssh_port="${1:-22}"

    log_info "Installing and configuring fail2ban..."

    apt-get install -y -qq fail2ban > /dev/null 2>&1

    cat > /etc/fail2ban/jail.local << JAIL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ${ssh_port}
JAIL

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_ok "fail2ban configured: ban after 3 attempts for 1 hour (port $ssh_port)"
}

setup_security() {
    # Usage: setup_security [--skip-ssh] [--ssh-port PORT] port:label [port:label ...]
    local skip_ssh=false
    local ssh_port=22
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --skip-ssh) skip_ssh=true; shift ;;
            --ssh-port) ssh_port="$2"; shift 2 ;;
            *) break ;;
        esac
    done

    if [[ "$skip_ssh" == true ]]; then
        log_info "Skipping SSH hardening (--skip-ssh)"
    else
        setup_ssh_hardening "$ssh_port"
    fi
    setup_fail2ban "$ssh_port"
    setup_ufw "$@"
}
