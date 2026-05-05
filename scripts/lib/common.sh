#!/bin/bash
# Common functions for VPN setup scripts

set -euo pipefail

# Project version (read from VERSION file in repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "unknown")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        log_error "This script requires Ubuntu"
        exit 1
    fi
    log_ok "OS: Ubuntu detected"
}

prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local input
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " input
        printf -v "$var_name" '%s' "${input:-$default}"
    else
        read -rp "$prompt: " input
        printf -v "$var_name" '%s' "$input"
    fi
}

prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local input
    while true; do
        read -srp "$prompt: " input
        echo
        if [[ ! "$input" =~ ^[[:print:]]+$ ]]; then
            log_warn "Password contains non-ASCII characters (wrong keyboard layout?)"
            log_warn "Please try again with English layout"
            continue
        fi
        if [[ -z "$input" ]]; then
            log_warn "Password cannot be empty"
            continue
        fi
        break
    done
    printf -v "$var_name" '%s' "$input"
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_uuid() {
    local uuid="$1"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_not_empty() {
    local value="$1"
    local name="$2"
    if [[ -z "$value" ]]; then
        log_error "$name cannot be empty"
        return 1
    fi
}

generate_random_port() {
    local excluded_ports=("$@")
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        # Skip if port is already listening
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            continue
        fi
        # Skip if in excluded list
        local collision=false
        for ep in "${excluded_ports[@]}"; do
            if [[ "$port" == "$ep" ]]; then
                collision=true
                break
            fi
        done
        if [[ "$collision" == false ]]; then
            echo "$port"
            return
        fi
    done
}

generate_random_path() {
    openssl rand -hex 8
}

generate_admin_pass() {
    # od reads exactly 12 bytes and exits — no SIGPIPE on the writer (unlike
    # `tr </dev/urandom | head -c N`, which exits 141 under pipefail).
    # od + tr are in coreutils on every base Ubuntu — no openssl dependency,
    # so this works even before install_dependencies runs. 24 hex = 96 bits.
    od -An -N12 -tx1 /dev/urandom | tr -d ' \n'
}

# Single source of truth for XHTTP extra params (padding + mux + flow control).
# Values track XTLS upstream recommendations (discussion #4113, PR #4163):
#   - scMinPostsIntervalMs as range "10-50" (randomized) — avoids timing fingerprint
#   - scMaxEachPostBytes 1000000 (1MB) — upstream default
#   - scMaxBufferedPosts 30 — upstream default
#   - xmux.hMaxRequestTimes "600-900" — prevents hitting Nginx/CDN 1000-req cap
# Used on BOTH sides:
#   - Client-side (relay→exit outbound, subscription VLESS URLs): full block applies;
#     xmux and scMinPostsIntervalMs drive client behavior.
#   - Server-side (relay inbound, exit inbound): xmux and scMinPostsIntervalMs are
#     ignored at runtime but travel in subscription URL as metadata. xPaddingBytes,
#     scMaxEachPostBytes, scMaxBufferedPosts are enforced by the server.
# NOTE: scMaxEachPostBytes MUST match between relay outbound (client perspective)
# and exit inbound (server cap) — otherwise large POSTs get rejected.
xhttp_extra_json() {
    jq -n -c '{
        xPaddingBytes: "100-1000",
        scMaxEachPostBytes: 1000000,
        scMaxBufferedPosts: 30,
        scMinPostsIntervalMs: "10-50",
        xmux: {
            maxConcurrency: "16-32",
            maxConnections: 0,
            cMaxReuseTimes: "64-128",
            hMaxRequestTimes: "600-900"
        }
    }'
}

# Single source of truth for Reality fallback rate limits (server-side).
# Throttles only fallback traffic — real VPN clients passing the Reality
# handshake are NOT affected. Probes/visitors hitting the masquerade site
# get a "cheap-VPS-like" speed profile: full 5 MB burst, then 256 KB/s.
# Values match autoXRAY community baseline (xVRVx/autoXRAY).
# Used in:
#   - exit Reality inbound (xray.sh::configure_xray_exit)
#   - relay Reality inbound (3xui.sh::create_3xui_relay_inbound)
#   - relay re-add after 3X-UI normalize (3xui.sh::patch_3xui_relay_inbound)
#   - update-relay.sh in-place merge into existing DB row
reality_limit_fallback_json() {
    jq -n -c '{
        limitFallbackUpload: {
            afterBytes: 0,
            bytesPerSec: 65536,
            burstBytesPerSec: 0
        },
        limitFallbackDownload: {
            afterBytes: 5242880,
            bytesPerSec: 262144,
            burstBytesPerSec: 2097152
        }
    }'
}

# Both tune functions must be called BEFORE any service restart in the script —
# raise_service_nofile applies on next service start, so existing restarts later
# in update-*.sh pick up the new limit naturally without a second restart.
enable_bbr() {
    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ "$current" == "bbr" ]]; then
        log_ok "BBR already active"
        return 0
    fi

    cat > /etc/sysctl.d/99-vpn-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL

    sysctl --system >/dev/null || true

    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ "$current" == "bbr" ]]; then
        log_ok "BBR enabled (TCP congestion control + fq qdisc)"
    else
        log_warn "BBR not applied (kernel module missing?) — current: ${current:-unknown}"
    fi
}

raise_service_nofile() {
    local conf=/etc/systemd/system.conf.d/99-vpn-limits.conf
    if [[ -f "$conf" ]] && grep -q '^DefaultLimitNOFILE=65535$' "$conf"; then
        log_ok "systemd nofile limit already 65535"
        return 0
    fi

    mkdir -p /etc/systemd/system.conf.d
    cat > "$conf" <<'LIMITS'
[Manager]
DefaultLimitNOFILE=65535
LIMITS

    systemctl daemon-reexec
    log_ok "systemd nofile limit set to 65535 (applies on next service start)"
}

install_dependencies() {
    log_info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq openssl cron socat git sqlite3 > /dev/null 2>&1
    log_ok "Dependencies installed"
}

update_system() {
    log_info "Updating system..."
    apt-get update -qq && apt-get upgrade -y -qq > /dev/null 2>&1
    log_ok "System updated"
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]
}

check_domain_dns() {
    local domain="$1"
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip=""
    local domain_ip
    domain_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1) || domain_ip=""

    if [[ -z "$domain_ip" ]]; then
        log_error "DNS for ${domain} does not resolve"
        log_error "Set A-record: ${domain} → ${server_ip}"
        return 1
    fi

    if [[ -n "$server_ip" && "$domain_ip" != "$server_ip" ]]; then
        log_error "DNS for ${domain} resolves to ${domain_ip}, but this server is ${server_ip}"
        return 1
    fi

    log_ok "DNS verified: ${domain} → ${domain_ip}"
}
