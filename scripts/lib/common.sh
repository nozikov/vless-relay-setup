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
        if [[ ! "$input" =~ ^[\ -~]+$ ]]; then
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

validate_ascii() {
    local value="$1"
    local name="$2"
    if [[ ! "$value" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        log_error "$name contains invalid characters (use English letters, digits, _ . -)"
        return 1
    fi
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
    shuf -i 10000-60000 -n 1
}

generate_random_path() {
    openssl rand -hex 8
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
