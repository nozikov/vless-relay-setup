#!/bin/bash
# Verification helpers — used by scripts/selfcheck.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

verify_service_running() {
    local service="$1"
    local label="$2"
    if systemctl is-active --quiet "$service"; then
        log_ok "$label is running"
        return 0
    else
        log_error "$label is NOT running"
        log_error "  Check: journalctl -u $service --no-pager -n 20"
        return 1
    fi
}

# verify_port_listening PORT LABEL [tcp|udp] — protocol defaults to tcp.
verify_port_listening() {
    local port="$1"
    local label="$2"
    local proto="${3:-tcp}"
    local ss_flags
    case "$proto" in
        tcp) ss_flags="-tlnH" ;;
        udp) ss_flags="-ulnH" ;;
        *)
            log_error "verify_port_listening: unknown protocol '$proto'"
            return 1
            ;;
    esac
    # ss's own filter instead of `ss | grep -q`: grep -q exits on the first match,
    # ss then dies of SIGPIPE and under pipefail the check reports a false FAIL.
    if [[ -n "$(ss "$ss_flags" "sport = :${port}" 2>/dev/null)" ]]; then
        log_ok "$label is listening on port $port/$proto"
        return 0
    else
        log_error "$label is NOT listening on port $port/$proto"
        return 1
    fi
}
