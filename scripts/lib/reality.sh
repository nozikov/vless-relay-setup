#!/bin/bash
# Reality dest site discovery and key generation

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

generate_reality_keypair() {
    log_info "Generating x25519 key pair for Reality..."

    local keys
    keys=$(xray x25519)

    export REALITY_PRIVATE_KEY
    REALITY_PRIVATE_KEY=$(echo "$keys" | grep -i "private" | awk '{print $NF}')
    export REALITY_PUBLIC_KEY
    REALITY_PUBLIC_KEY=$(echo "$keys" | grep -iE "public|password" | awk '{print $NF}')

    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
        log_error "Failed to parse x25519 keys"
        exit 1
    fi

    log_ok "Reality keys generated"
    log_info "  Private key: $REALITY_PRIVATE_KEY"
    log_info "  Public key:  $REALITY_PUBLIC_KEY"
}

generate_short_id() {
    export REALITY_SHORT_ID
    REALITY_SHORT_ID=$(openssl rand -hex 4)
    log_ok "Short ID generated: $REALITY_SHORT_ID"
}

check_site_tls13() {
    local domain="$1"
    local result
    result=$(echo | timeout 5 openssl s_client -connect "$domain:443" \
        -tls1_3 -brief 2>&1 | grep -c "TLSv1.3" || true)
    [[ "$result" -ge 1 ]]
}

find_best_reality_dest() {
    log_info "Selecting best Reality dest site..."

    local sites=("www.microsoft.com" "www.apple.com" "dl.google.com" "www.samsung.com" "gateway.icloud.com")
    local best_site=""
    local best_time=999999

    for site in "${sites[@]}"; do
        local time_ms
        time_ms=$(curl -so /dev/null -w '%{time_connect}' --max-time 5 "https://$site" 2>/dev/null || echo "999")
        # Convert to microseconds for integer comparison
        local time_us
        time_us=$(echo "$time_ms" | awk '{printf "%d", $1 * 1000000}')

        if check_site_tls13 "$site" 2>/dev/null; then
            log_info "  $site — ${time_ms}s (TLS 1.3 OK)"
            if [[ "$time_us" -lt "$best_time" ]]; then
                best_time="$time_us"
                best_site="$site"
            fi
        else
            log_info "  $site — skipped (no TLS 1.3)"
        fi
    done

    if [[ -z "$best_site" ]]; then
        best_site="www.microsoft.com"
        log_warn "No sites responded. Defaulting to $best_site"
    fi

    export REALITY_DEST="${best_site}:443"
    export REALITY_SERVER_NAME="$best_site"
    log_ok "Reality dest: $REALITY_DEST"
}

setup_reality() {
    find_best_reality_dest
    generate_reality_keypair
    generate_short_id
}
