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

# Drop-ins that Ubuntu's socket-activation migration leaves behind. 00-socket.conf
# adds Wants=ssh.socket to ssh.service, so with it in place a plain
# `systemctl restart ssh` starts the socket again (verified on 24.04).
SSH_SOCKET_DROPINS=(
    /etc/systemd/system/ssh.service.d/00-socket.conf
    /etc/systemd/system/ssh.socket.d/addresses.conf
)

# Undo setup_ssh_hardening: sshd_config, socket-activation state, unit enablement.
# Called only from setup_ssh_hardening — reads its locals via bash dynamic scoping.
_ssh_hardening_rollback() {
    local dropin prev_port
    log_error "Restoring previous sshd_config and SSH units; UFW was NOT touched."
    cp -p "$backup_dir/sshd_config" "$ssh_config"

    if [[ "$socket_switched" == true ]]; then
        for dropin in "${SSH_SOCKET_DROPINS[@]}"; do
            if [[ -f "${backup_dir}${dropin}" ]]; then
                mkdir -p "$(dirname "$dropin")"
                cp -p "${backup_dir}${dropin}" "$dropin"
            fi
        done
        systemctl unmask ssh.socket >/dev/null 2>&1 || true
        systemctl daemon-reload || true
        if [[ "$service_was_enabled" != true ]]; then
            systemctl disable "$sshd_service" >/dev/null 2>&1 || true
        fi
        # Free the port for the socket. Established sessions survive the stop
        # (ssh.service has KillMode=process).
        systemctl stop "$sshd_service" || true
        systemctl reset-failed "$sshd_service" >/dev/null 2>&1 || true
        if [[ "$socket_was_enabled" == true ]]; then
            systemctl enable ssh.socket || true
        fi
        if [[ "$socket_was_active" == true ]]; then
            systemctl start ssh.socket || true
        fi
    else
        systemctl restart "$sshd_service" || true
    fi
    rm -rf "$backup_dir"

    prev_port=$(grep -m1 '^Port ' "$ssh_config" 2>/dev/null | awk '{print $2}') || true
    prev_port="${prev_port:-22}"
    if tcp_port_listening "$prev_port"; then
        log_error "SSH is listening on port ${prev_port} again. Check: systemctl status ${sshd_service} ssh.socket"
    else
        log_error "SSH may be unreachable — keep this session open. Check: systemctl status ${sshd_service} ssh.socket"
    fi
}

setup_ssh_hardening() {
    local ssh_port="${1:-22}"
    local ssh_config="/etc/ssh/sshd_config"
    local sshd_service="sshd"
    local sshd_bin
    local backup_dir=""
    local bound=false
    local socket_was_active=false socket_was_enabled=false service_was_enabled=false
    local socket_switched=false
    local dropin

    log_info "Hardening SSH..."

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        log_warn "No SSH authorized_keys found! Skipping SSH hardening to avoid lockout."
        log_warn "Configure SSH keys first, then re-run this script."
        return 0
    fi

    # Keep the pre-change state so a failed port switch can be undone —
    # update-* scripts read the port back from sshd_config, so leaving a Port
    # that sshd never bound would make the next update close the real port.
    # Backups go to /run (tmpfs, root-only dir from mktemp -d): an interrupted run
    # doesn't leave copies piling up in /etc/ssh, and they're gone after reboot.
    backup_dir=$(mktemp -d /run/vpn-ssh-hardening.XXXXXX)
    cp -p "$ssh_config" "$backup_dir/sshd_config"

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

    # Validate before touching any unit: a broken config must not reach a restart.
    # /run/sshd (privilege separation dir) only exists once ssh.service has run —
    # on a socket-activated box that never took a connection `sshd -t` fails without it.
    sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    install -d -m 0755 /run/sshd
    if ! "$sshd_bin" -t -f "$ssh_config"; then
        log_error "sshd_config failed validation (sshd -t) — restoring it, sshd NOT restarted"
        cp -p "$backup_dir/sshd_config" "$ssh_config"
        rm -rf "$backup_dir"
        exit 1
    fi

    # Service is named "ssh" on Debian/Ubuntu, "sshd" on RHEL/Fedora
    if systemctl list-unit-files ssh.service &>/dev/null; then
        sshd_service="ssh"
    fi

    # Ubuntu 22.10+/24.04 socket-activate SSH: ssh.socket owns the listener and
    # sshd ignores Port from sshd_config, so a custom port silently stays on 22
    # and UFW then locks us out. Switch to the standalone ssh.service so
    # sshd_config is authoritative — Ubuntu's documented procedure
    # (discourse.ubuntu.com/t/30189): remove the migration drop-ins, daemon-reload,
    # disable the socket, enable the service. We additionally MASK the socket: a
    # leftover/foreign Wants=ssh.socket can then no longer start it next to sshd
    # (it does without the mask — verified on 24.04); openssh-server's postinst
    # keeps an admin mask and the disabled state on package upgrades.
    # Debian 12 / Ubuntu 22.04 ship ssh.socket disabled, so this branch is skipped
    # there; on re-runs (update-*) the socket is masked — skipped as well.
    systemctl is-active --quiet ssh.socket 2>/dev/null && socket_was_active=true
    [[ "$(systemctl is-enabled ssh.socket 2>/dev/null || true)" == "enabled" ]] && socket_was_enabled=true
    if [[ "$socket_was_active" == true || "$socket_was_enabled" == true ]]; then
        [[ "$(systemctl is-enabled "${sshd_service}.service" 2>/dev/null || true)" == "enabled" ]] && \
            service_was_enabled=true
        log_info "ssh.socket (socket activation) detected — switching to ${sshd_service}.service so Port takes effect"
        socket_switched=true
        for dropin in "${SSH_SOCKET_DROPINS[@]}"; do
            if [[ -f "$dropin" ]]; then
                mkdir -p "${backup_dir}$(dirname "$dropin")"
                cp -p "$dropin" "${backup_dir}${dropin}"
                rm -f "$dropin"
                log_info "Removed socket-activation drop-in $dropin"
            fi
        done
        # Established sessions survive: ssh.service uses KillMode=process
        if ! systemctl daemon-reload || \
           ! systemctl disable --now ssh.socket || \
           ! systemctl mask ssh.socket || \
           ! systemctl enable "$sshd_service"; then
            log_error "Failed to switch from ssh.socket to ${sshd_service}.service"
            _ssh_hardening_rollback
            exit 1
        fi
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
        _ssh_hardening_rollback
        exit 1
    fi

    rm -rf "$backup_dir"
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
