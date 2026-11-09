#!/bin/bash
# Server security hardening

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# True if sshd holds a TCP listener on the port (a bare systemd socket that
# has not spawned sshd yet does not count — sshd may still fail to start).
sshd_listens_on() {
    local port="$1"
    local out
    out=$(ss -tlnpH "sport = :${port}" 2>/dev/null) || true
    [[ "$out" == *'"sshd"'* ]]
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

# Our sshd settings. Ubuntu/Debian cloud images put
# `Include /etc/ssh/sshd_config.d/*.conf` at the top of sshd_config and sshd
# keeps the FIRST value it reads, so a provider's 50-cloud-init.conf with
# `PasswordAuthentication yes` beats any edit further down the main file (#57).
# 00-* sorts first, so these values win.
SSH_HARDENING_DROPIN=/etc/ssh/sshd_config.d/00-vpn-hardening.conf

# True if the main sshd_config pulls in sshd_config.d/*.conf (Debian 11+/Ubuntu 20.04+).
sshd_config_includes_dropins() {
    local ssh_config="${1:-/etc/ssh/sshd_config}"
    local includes
    includes=$(grep -Ei '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/' "$ssh_config" 2>/dev/null) || true
    [[ -n "$includes" ]]
}

# Effective SSH port: the first `port` of `sshd -T` (main file + drop-ins, as
# sshd itself resolves them), falling back to our drop-in, then the main file, then 22.
detect_ssh_port() {
    local sshd_bin effective port=""
    sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    # sshd -T refuses to run without the privsep dir, which a socket-activated
    # box that never took a connection doesn't have yet.
    install -d -m 0755 /run/sshd 2>/dev/null || true
    effective=$("$sshd_bin" -T 2>/dev/null) || true
    port=$(awk '$1 == "port" {print $2; exit}' <<< "$effective")
    if [[ -z "$port" ]]; then
        port=$(awk 'tolower($1) == "port" {print $2; exit}' "$SSH_HARDENING_DROPIN" 2>/dev/null) || true
    fi
    if [[ -z "$port" ]]; then
        port=$(awk 'tolower($1) == "port" {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null) || true
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        port=22
    fi
    echo "$port"
}

# Put sshd_config and our drop-in back as they were before setup_ssh_hardening.
# Reads setup_ssh_hardening's locals via bash dynamic scoping.
_ssh_restore_config_files() {
    cp -p "$backup_dir/sshd_config" "$ssh_config"
    if [[ -f "$backup_dir/vpn-hardening.conf" ]]; then
        cp -p "$backup_dir/vpn-hardening.conf" "$SSH_HARDENING_DROPIN"
    else
        rm -f "$SSH_HARDENING_DROPIN"
    fi
}

# Undo setup_ssh_hardening: sshd_config, socket-activation state, unit enablement.
# Called only from setup_ssh_hardening — reads its locals via bash dynamic scoping.
_ssh_hardening_rollback() {
    local dropin prev_port
    log_error "Restoring previous sshd_config, ${SSH_HARDENING_DROPIN} and SSH units; UFW was NOT touched."
    _ssh_restore_config_files

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
        # The stop above also took down a standalone sshd (socket merely enabled,
        # or a leftover socket next to a running service) — bring it back, or the
        # host ends up with no SSH listener at all.
        if [[ "$service_was_active" == true ]]; then
            systemctl start "$sshd_service" || true
        fi
    else
        systemctl restart "$sshd_service" || true
    fi
    rm -rf "$backup_dir"

    prev_port=$(detect_ssh_port)
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
    local service_was_active=false
    local socket_switched=false
    local dropin effective eff_ports eff_password has_include=false

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
    if [[ -f "$SSH_HARDENING_DROPIN" ]]; then
        cp -p "$SSH_HARDENING_DROPIN" "$backup_dir/vpn-hardening.conf"
    fi

    # The main file is edited too: it is what sshd reads when there is no
    # Include (older Debian), and it keeps the main file consistent with the
    # drop-in when the Include sits below these lines. Prepending an Include
    # ourselves would instead pull unknown drop-ins into the config.
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$ssh_config"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$ssh_config"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$ssh_config"
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$ssh_config"

    # Port is cumulative (every Port line adds a listener), not first-wins, so it
    # goes to exactly one place. Always drop it from the main file — this also
    # removes the line v1.12 and earlier appended there — and handles revert to 22.
    sed -i '/^#\?Port /d' "$ssh_config"
    sshd_config_includes_dropins "$ssh_config" && has_include=true
    if [[ "$has_include" == true ]]; then
        mkdir -p "$(dirname "$SSH_HARDENING_DROPIN")"
        cat > "$SSH_HARDENING_DROPIN" << SSHD
# Managed by vless-relay-setup (setup_ssh_hardening). Sorts first in
# sshd_config.d, so these values beat provider drop-ins like 50-cloud-init.conf.
Port ${ssh_port}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHD
        chmod 0644 "$SSH_HARDENING_DROPIN"
    else
        # No Include: sshd never reads sshd_config.d, the main file is authoritative.
        rm -f "$SSH_HARDENING_DROPIN"
        if [[ "$ssh_port" != "22" ]]; then
            echo "Port $ssh_port" >> "$ssh_config"
        fi
    fi
    if [[ "$ssh_port" != "22" ]]; then
        log_info "SSH port set to $ssh_port"
    fi

    # Validate before touching any unit: a broken config must not reach a restart.
    # /run/sshd (privilege separation dir) only exists once ssh.service has run —
    # on a socket-activated box that never took a connection `sshd -t` fails without it.
    sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    install -d -m 0755 /run/sshd
    if ! "$sshd_bin" -t -f "$ssh_config"; then
        log_error "sshd_config failed validation (sshd -t) — restoring it, sshd NOT restarted"
        _ssh_restore_config_files
        rm -rf "$backup_dir"
        exit 1
    fi

    # Check the values sshd will actually use (main file + every drop-in, first
    # value wins). sshd -T only reads files, so checking before the restart gives
    # the same answer as after it — and a mismatch costs no restart at all.
    effective=$("$sshd_bin" -T -f "$ssh_config" 2>/dev/null) || true
    eff_password=$(awk '$1 == "passwordauthentication" {print $2; exit}' <<< "$effective")
    eff_ports=$(awk '$1 == "port" {print $2}' <<< "$effective")
    if [[ "$eff_password" != "no" ]] || ! grep -qx "$ssh_port" <<< "$eff_ports"; then
        log_error "Effective sshd config (sshd -T) does not match: passwordauthentication=${eff_password:-?}, port(s)=${eff_ports//$'\n'/,} (expected no / ${ssh_port})"
        log_error "Another file in /etc/ssh/sshd_config.d probably overrides it — restoring, sshd NOT restarted"
        _ssh_restore_config_files
        rm -rf "$backup_dir"
        exit 1
    fi
    if [[ "$eff_ports" != "$ssh_port" ]]; then
        log_warn "sshd will also listen on other ports (${eff_ports//$'\n'/,}) — a Port line outside our config; UFW opens only ${ssh_port}"
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
        systemctl is-active --quiet "${sshd_service}.service" 2>/dev/null && service_was_active=true
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

# UFW rules only accumulate: after an SSH port change the old port and the
# 22:SSH-fallback rule stay open (#58). Delete our own SSH rules (comment exactly
# "SSH" / "SSH-fallback") on ports outside the keep list. Rules without our
# comments are the admin's and stay. Runs only when sshd is confirmed on the
# first keep port, and never removes a port sshd currently listens on.
# Usage: prune_stale_ssh_ufw_rules KEEP_PORT [KEEP_PORT ...]
prune_stale_ssh_ufw_rules() {
    local keep_ports=("$@")
    local added line port keep k
    local stale=()
    local rule_re="^ufw allow ([0-9]+)/tcp comment '(SSH|SSH-fallback)'$"

    if ! sshd_listens_on "${keep_ports[0]}"; then
        log_info "sshd is not confirmed on port ${keep_ports[0]} — leaving existing SSH rules in UFW"
        return 0
    fi

    added=$(ufw show added 2>/dev/null) || return 0
    while IFS= read -r line; do
        [[ "$line" =~ $rule_re ]] || continue
        port="${BASH_REMATCH[1]}"
        keep=false
        for k in "${keep_ports[@]}"; do
            [[ "$port" == "$k" ]] && keep=true
        done
        if [[ "$keep" == false ]] && sshd_listens_on "$port"; then
            log_warn "sshd still listens on ${port} — keeping its UFW rule"
            keep=true
        fi
        if [[ "$keep" == false ]]; then
            stale+=("$port")
        fi
    done <<< "$added"

    for port in "${stale[@]}"; do
        # Delete by rule spec: removes the v4 and v6 rule, no renumbering issues.
        if ufw --force delete allow "${port}/tcp" >/dev/null; then
            log_info "Removed stale UFW SSH rule for port ${port}"
        else
            log_warn "Failed to remove stale UFW rule for port ${port}"
        fi
    done
}

# Remove the UFW "allow PORT/tcp" rule (v4 + v6) if one was added — the comment
# is not part of the match, so this drops what setup_ufw created under any label.
# Quiet no-op without ufw or without such a rule. $2 = label for the log line.
ufw_close_tcp_port() {
    local port="$1" label="${2:-}" added
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    command -v ufw &> /dev/null || return 0
    # Captured first, then matched: `ufw show added | grep -q` is a SIGPIPE trap
    # under pipefail.
    added=$(ufw show added 2>/dev/null) || true
    if grep -qE "^ufw allow ${port}/tcp( |\$)" <<< "$added"; then
        ufw --force delete allow "${port}/tcp" > /dev/null 2>&1 || true
        log_ok "UFW: closed ${port}/tcp${label:+ ($label)}"
    fi
}

# Print (one per line) the TCP ports of UFW allow rules whose comment is exactly $1.
ufw_tcp_ports_with_comment() {
    local comment="$1" added line
    command -v ufw &> /dev/null || return 0
    added=$(ufw show added 2>/dev/null) || return 0
    while IFS= read -r line; do
        if [[ "$line" =~ ^ufw\ allow\ ([0-9]+)/tcp\ comment\ \'(.*)\'$ ]] \
           && [[ "${BASH_REMATCH[2]}" == "$comment" ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done <<< "$added"
}

# Close UFW rules for 3X-UI panel/subscription ports: the ports given, plus every
# rule we labelled "3X-UI Panel" (the port may have changed since it was opened).
# Never touches 22/80/443 or the SSH port.
# Usage: close_xui_ufw_ports SSH_PORT [PORT ...]   (empty values ignored)
close_xui_ufw_ports() {
    local ssh_port="$1" p
    shift
    local ports=("$@")
    local labelled
    labelled=$(ufw_tcp_ports_with_comment "3X-UI Panel")
    while IFS= read -r p; do
        [[ -n "$p" ]] && ports+=("$p")
    done <<< "$labelled"
    for p in "${ports[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ "$p" == "80" || "$p" == "443" || "$p" == "22" || "$p" == "$ssh_port" ]]; then
            continue
        fi
        ufw_close_tcp_port "$p" "3X-UI panel/subscription"
    done
}

setup_fail2ban() {
    # ssh_port may be a comma list ("2222,22" while UFW keeps an SSH fallback)
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
    local keep_ports=() entry
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

    # Never let UFW seal off the only working SSH port. Hardening verifies its
    # own port switch, but with --skip-ssh / no authorized_keys sshd_config is
    # left as is and sshd may still be on 22 while only ssh_port gets allowed.
    if [[ "$ssh_port" != "22" ]] && ! tcp_port_listening "$ssh_port" && tcp_port_listening 22; then
        # Port 22 stays reachable, so the sshd jail must cover it too.
        setup_fail2ban "${ssh_port},22"
        log_warn "Nothing listens on SSH port ${ssh_port}, but port 22 does — keeping 22 open in UFW"
        setup_ufw "$@" "22:SSH-fallback"
        keep_ports+=(22)
    else
        setup_fail2ban "$ssh_port"
        setup_ufw "$@"
    fi

    # Every port we just allowed stays, whatever its label: `ufw delete allow
    # PORT/tcp` matches by spec, so pruning an old SSH port that is now reused
    # by another service would close that service.
    for entry in "$@"; do
        keep_ports+=("${entry%%:*}")
    done
    prune_stale_ssh_ufw_rules "$ssh_port" "${keep_ports[@]}"
}
