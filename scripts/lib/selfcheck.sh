#!/bin/bash
# Selfcheck helpers — outside probes, cert expiry, system resources
# Used by scripts/selfcheck.sh
# Convention: each check returns 0=OK, 1=WARN, 2=FAIL

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

probe_selfsteal_hairpin() {
    local server_ip="$1"

    # Pre-check: outbound HTTPS reachable at all?
    if ! curl -s --max-time 3 -o /dev/null "https://1.1.1.1/" 2>/dev/null; then
        log_warn "No outbound HTTPS — outside probes skipped"
        return 1
    fi

    # Hairpin check: can we curl our own external IP?
    local resp_size
    resp_size=$(curl -sk --max-time 5 "https://${server_ip}/" \
        -o /dev/null -w '%{size_download}' 2>/dev/null) || resp_size=0

    if [[ "$resp_size" -eq 0 ]]; then
        log_warn "Hairpin NAT not supported — verify selfsteal manually from another device"
        return 1
    fi

    if [[ "$resp_size" -lt 1024 ]]; then
        log_error "Selfsteal probe: response too small ($resp_size bytes) — masque may be broken"
        return 2
    fi

    log_ok "Selfsteal masque alive ($resp_size bytes)"
    return 0
}

probe_cdn_external() {
    local cdn_domain="$1"
    local cdn_path="$2"

    local http_code
    http_code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
        "https://${cdn_domain}/${cdn_path}" 2>/dev/null) || http_code="000"

    case "$http_code" in
        000)
            log_error "CDN probe: timeout/refused"
            return 2
            ;;
        521|522|523)
            log_error "CDN probe: Cloudflare $http_code (origin unreachable)"
            return 2
            ;;
        *)
            log_ok "CDN reachable ($http_code via Cloudflare)"
            return 0
            ;;
    esac
}

check_cert_expiry() {
    local domain="$1"

    # Search common cert paths for both Caddy and acme.sh
    local cert_file=""
    local search_paths=(
        "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt"
        "/root/.acme.sh/${domain}_ecc/${domain}.cer"
        "/root/.acme.sh/${domain}/${domain}.cer"
    )
    local p
    for p in "${search_paths[@]}"; do
        if [[ -f "$p" ]]; then
            cert_file="$p"
            break
        fi
    done

    if [[ -z "$cert_file" ]]; then
        log_warn "Cert file not found for $domain — skipping expiry check"
        return 1
    fi

    local expiry_str expiry_epoch now_epoch days_left
    expiry_str=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry_str" ]]; then
        log_warn "Cannot parse cert at $cert_file"
        return 1
    fi
    expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null) || {
        log_warn "Cannot parse cert expiry date"
        return 1
    }
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ "$days_left" -lt 7 ]]; then
        log_error "TLS cert expires in $days_left days (CRITICAL)"
        return 2
    elif [[ "$days_left" -lt 14 ]]; then
        log_warn "TLS cert expires in $days_left days (renew soon)"
        return 1
    fi

    log_ok "TLS cert valid ($days_left days remaining)"
    return 0
}

check_disk_space() {
    local pct_free
    pct_free=$(df / | awk 'NR==2 {print 100 - int($5)}')

    if [[ "$pct_free" -lt 5 ]]; then
        log_error "Disk: only ${pct_free}% free (CRITICAL)"
        return 2
    elif [[ "$pct_free" -lt 10 ]]; then
        log_warn "Disk: ${pct_free}% free"
        return 1
    fi

    log_ok "Disk: ${pct_free}% free"
    return 0
}

check_ram_free() {
    local mb_free
    mb_free=$(free -m | awk '/^Mem:/ {print $7}')

    if [[ "$mb_free" -lt 50 ]]; then
        log_error "RAM: only ${mb_free}MB available (CRITICAL)"
        return 2
    elif [[ "$mb_free" -lt 100 ]]; then
        log_warn "RAM: ${mb_free}MB available"
        return 1
    fi

    log_ok "RAM: ${mb_free}MB available"
    return 0
}
