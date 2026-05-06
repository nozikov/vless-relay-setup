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

verify_port_listening() {
    local port="$1"
    local label="$2"
    if ss -tlnp | grep -q ":${port} "; then
        log_ok "$label is listening on port $port"
        return 0
    else
        log_error "$label is NOT listening on port $port"
        return 1
    fi
}
