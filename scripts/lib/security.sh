#!/bin/bash
# Server security hardening

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# True if sshd holds a TCP listener on the port (a bare systemd socket that
# has not spawned sshd yet does not count — sshd may still fail to start).
sshd_listens_on() {
    local port="$1"
    ss -tlnpH "sport = :${port}" 2>/dev/null | grep -q '"sshd"'
}

# True if anything (sshd or a systemd socket) accepts TCP on the port.
tcp_port_listening() {
    local port="$1"
    [[ -n "$(ss -tlnH "sport = :${port}" 2>/dev/null)" ]]
}

setup_ssh_hardening() {
    local ssh_port="${1:-22}"
    local ssh_config="/etc/ssh/sshd_config"
    local sshd_service="sshd"
    local config_backup=""
    local bound=false

    log_info "Hardening SSH..."

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        log_warn "No SSH authorized_keys found! Skipping SSH hardening to avoid lockout."
        log_warn "Configure SSH keys first, then re-run this script."
        return 0
    fi

    # Keep the pre-change config so a failed port switch can be undone —
    # update-* scripts read the port back from sshd_config, so leaving a Port
    # that sshd never bound would make the next update close the real port.
    config_backup=$(mktemp /etc/ssh/sshd_config.vpn-bak.XXXXXX)
    cp -p "$ssh_config" "$config_backup"

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

    # Service is named "ssh" on Debian/Ubuntu, "sshd" on RHEL/Fedora
    if systemctl list-unit-files ssh.service &>/dev/null; then
        sshd_service="ssh"
    fi

    # Ubuntu 22.10+/24.04 socket-activate SSH: ssh.socket owns the listener and
    # sshd ignores Port from sshd_config, so a custom port silently stays on 22
    # and UFW then locks us out. Switch to the standalone ssh.service so
    # sshd_config is authoritative. Debian 12 / Ubuntu 22.04 ship ssh.socket
    # disabled, so this branch is skipped there; on re-runs (update-*) the
    # socket is already disabled — skipped as well.
    if systemctl is-active --quiet ssh.socket 2>/dev/null || \
       [[ "$(systemctl is-enabled ssh.socket 2>/dev/null || true)" == "enabled" ]]; then
        log_info "ssh.socket (socket activation) detected — switching to ${sshd_service}.service so Port takes effect"
        # Established sessions survive: ssh.service uses KillMode=process
        systemctl disable --now ssh.socket
        systemctl enable "$sshd_service" >/dev/null 2>&1 || true
    fi

    if systemctl restart "$sshd_service"; then
        # Confirm the daemon itself bound the port before UFW (configured
        # later in setup_security) closes anything else.
        for _ in 1 2 3 4 5; do
            if sshd_listens_on "$ssh_port"; then
                bound=true
                break
            fi
            sleep 1
        done
    fi

    if [[ "$bound" != true ]]; then
        log_error "sshd is NOT listening on port ${ssh_port} after restart (try: ss -tlnp | grep sshd)"
        log_error "Restoring previous sshd_config; UFW was NOT touched."
        cp -p "$config_backup" "$ssh_config"
        rm -f "$config_backup"
        systemctl restart "$sshd_service" || true
        if tcp_port_listening 22; then
            log_error "SSH is listening on port 22 again. Check: systemctl status ${sshd_service}"
        else
            log_error "SSH may be unreachable — keep this session open. Check: systemctl status ${sshd_service}"
        fi
        exit 1
    fi

    rm -f "$config_backup"
    log_ok "SSH hardened: password auth disabled, key-only access, port $ssh_port (sshd listening)"
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

    # Never let UFW seal off the only working SSH port. Hardening verifies its
    # own port switch, but with --skip-ssh / no authorized_keys sshd_config is
    # left as is and sshd may still be on 22 while only ssh_port gets allowed.
    if [[ "$ssh_port" != "22" ]] && ! tcp_port_listening "$ssh_port" && tcp_port_listening 22; then
        log_warn "Nothing listens on SSH port ${ssh_port}, but port 22 does — keeping 22 open in UFW"
        setup_ufw "$@" "22:SSH-fallback"
    else
        setup_ufw "$@"
    fi
}
