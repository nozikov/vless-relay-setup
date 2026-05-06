#!/bin/bash
# Selfcheck helpers — outside probes, cert expiry, system resources
# Used by scripts/selfcheck.sh
# Convention: each check returns 0=OK, 1=WARN, 2=FAIL

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

probe_selfsteal_hairpin() {
    local server_ip="$1"
    local domain="${2:-}"

    # Pre-check: outbound HTTPS reachable at all?
    if ! curl -s --max-time 3 -o /dev/null "https://1.1.1.1/" 2>/dev/null; then
        log_warn "No outbound HTTPS — outside probes skipped"
        return 1
    fi

    # Hairpin check: curl our own external IP using configured SNI (--resolve)
    # so Reality matches serverNames and exercises the same path a DPI probe takes.
    # Without --resolve curl uses Host=<IP>, no SNI → Reality fallback to caddy.sock
    # via catch-all, not the selfsteal vhost. We want the selfsteal vhost.
    local probe_url probe_args
    if [[ -n "$domain" ]]; then
        probe_url="https://${domain}/"
        probe_args=(--resolve "${domain}:443:${server_ip}")
    else
        # Fallback: no domain known (auto-mode Reality dest, no SelfSteal)
        probe_url="https://${server_ip}/"
        probe_args=()
    fi

    local out
    out=$(curl -sk --max-time 5 "${probe_args[@]}" "$probe_url" \
        -o /dev/null -w '%{http_code} %{size_download}' 2>/dev/null) || out="000 0"
    local http_code="${out%% *}" resp_size="${out##* }"

    if [[ "$http_code" == "000" ]]; then
        log_warn "Hairpin NAT not supported — verify selfsteal manually from another device"
        return 1
    fi

    if [[ "$http_code" != "200" ]]; then
        log_error "Selfsteal probe: HTTP $http_code (expected 200) — masque may be broken"
        return 2
    fi

    if [[ "$resp_size" -lt 1024 ]]; then
        log_error "Selfsteal probe: response too small ($resp_size bytes) — masque may be broken"
        return 2
    fi

    log_ok "Selfsteal masque alive (HTTP 200, $resp_size bytes)"
    return 0
}

probe_cdn_external() {
    local cdn_domain="$1"
    local cdn_path="$2"

    # XRAY XHTTP inbound returns 404 on bare GET (it expects POST/upload-down chunked).
    # If we see 200 with HTML body, that means Caddy is serving selfsteal content
    # instead of routing to XRAY — CDN path is broken.
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
        404|405|400)
            # Expected from XHTTP inbound on bare GET — CDN chain works
            log_ok "CDN reachable (HTTP $http_code from XHTTP inbound — chain alive)"
            return 0
            ;;
        200)
            log_error "CDN probe: HTTP 200 (likely selfsteal HTML — CDN path not routing to XRAY)"
            return 2
            ;;
        *)
            log_warn "CDN probe: unexpected HTTP $http_code — manual check recommended"
            return 1
            ;;
    esac
}

check_cert_expiry() {
    local domain="$1"

    # Search common cert paths for both Caddy and acme.sh.
    # Caddy may use Let's Encrypt OR ZeroSSL (fallback when LE rate-limited)
    # → glob over all ACME CA dirs.
    local cert_file=""
    local cert_glob_paths=(
        /var/lib/caddy/.local/share/caddy/certificates/*/"${domain}"/"${domain}".crt
        /root/.acme.sh/"${domain}"_ecc/"${domain}".cer
        /root/.acme.sh/"${domain}"/"${domain}".cer
        /etc/letsencrypt/live/"${domain}"/fullchain.pem
    )
    local p
    for p in "${cert_glob_paths[@]}"; do
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
