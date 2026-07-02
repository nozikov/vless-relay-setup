#!/bin/bash
# WireGuard backhaul to an externally-managed peer (relay-only, no services).
#
# The far end is NOT managed by this repo (e.g. a UniFi Express home router):
# no install/configure/uninstall of anything WireGuard-related exists here.
# Relay uses XRAY's native userspace `wireguard` outbound — a config-only
# addition to the 3X-UI xrayTemplateConfig. The same outbound block, stood up
# in a throwaway `xray run`, doubles as the pre-flight/selfcheck dry-run.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# WireGuard keys are 32 bytes base64-encoded: 43 chars + '='.
validate_wg_key() {
    local key="$1"
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# Mask a key for confirmation output — never echo WG_PRIVATE_KEY in full.
mask_wg_key() {
    local key="$1"
    echo "${key:0:4}****(hidden)"
}

# Static-shape validation of the full peer param set (setup prompt + update flags
# share this). The live check is wg_dry_run — this only catches obvious typos.
validate_wg_peer_params() {
    local private_key="$1"
    local address="$2"
    local peer_pubkey="$3"
    local endpoint="$4"
    local keepalive="${5:-25}"
    local mtu="${6:-1380}"

    if ! validate_wg_key "$private_key"; then
        log_error "Invalid WireGuard private key (expected 44-char base64)"
        return 1
    fi
    if ! validate_wg_key "$peer_pubkey"; then
        log_error "Invalid WireGuard peer public key (expected 44-char base64)"
        return 1
    fi

    # Tunnel address: comma-separated list of IP[/NN]; IPv6 entries accepted loosely
    local entry ip
    local entries
    IFS=', ' read -ra entries <<< "$address"
    local seen=false
    for entry in "${entries[@]}"; do
        [[ -z "$entry" ]] && continue
        seen=true
        [[ "$entry" == *:* ]] && continue  # IPv6 — no deep validation
        ip="${entry%%/*}"
        if ! validate_ip "$ip"; then
            log_error "Invalid tunnel address entry: $entry"
            return 1
        fi
        if [[ "$entry" == */* ]] && ! [[ "${entry#*/}" =~ ^[0-9]{1,2}$ ]]; then
            log_error "Invalid tunnel address prefix: $entry"
            return 1
        fi
    done
    if [[ "$seen" != true ]]; then
        log_error "Tunnel address cannot be empty"
        return 1
    fi

    # Endpoint host:port — likely a DDNS hostname (residential/dynamic IP)
    if [[ "$endpoint" != *:* ]]; then
        log_error "Invalid endpoint (expected host:port): $endpoint"
        return 1
    fi
    local host="${endpoint%:*}" port="${endpoint##*:}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "Invalid endpoint port: $port"
        return 1
    fi
    if ! validate_domain "$host" && ! validate_ip "$host"; then
        log_error "Invalid endpoint host: $host"
        return 1
    fi

    if ! [[ "$keepalive" =~ ^[0-9]+$ ]]; then
        log_error "Invalid keepalive (seconds expected): $keepalive"
        return 1
    fi
    if ! [[ "$mtu" =~ ^[0-9]+$ ]] || [[ "$mtu" -lt 576 || "$mtu" -gt 1500 ]]; then
        log_error "Invalid MTU (576-1500 expected): $mtu"
        return 1
    fi
}

# Build the wg-out outbound JSON block (same factoring style as
# xhttp_extra_json / reality_limit_fallback_json). address/allowed_ips are
# comma-separated strings, split into JSON arrays here.
wg_outbound_json() {
    local private_key="$1"
    local address="$2"
    local peer_pubkey="$3"
    local endpoint="$4"
    local allowed_ips="${5:-0.0.0.0/0}"
    local keepalive="${6:-25}"
    local mtu="${7:-1380}"

    jq -n -c \
        --arg sk "$private_key" \
        --arg addr "$address" \
        --arg pk "$peer_pubkey" \
        --arg ep "$endpoint" \
        --arg aips "$allowed_ips" \
        --argjson ka "$keepalive" \
        --argjson mtu "$mtu" \
        '{
            tag: "wg-out",
            protocol: "wireguard",
            settings: {
                secretKey: $sk,
                address: ($addr | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
                peers: [{
                    publicKey: $pk,
                    endpoint: $ep,
                    allowedIPs: ($aips | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
                    keepAlive: $ka
                }],
                mtu: $mtu
            }
        }'
}

# Optional convenience for admins self-generating a keypair instead of using a
# router-issued config. `xray x25519` emits a raw Curve25519 keypair usable as
# a WG keypair — no wireguard-tools dependency needed. Modern xray prints keys
# in base64url without padding (Reality's encoding); WireGuard and router UIs
# expect standard base64 with padding, so convert before exporting.
generate_wg_keypair() {
    log_info "Generating WireGuard keypair via xray x25519..."

    local keys
    keys=$(xray x25519)

    export WG_PRIVATE_KEY
    WG_PRIVATE_KEY=$(echo "$keys" | grep -i "private" | awk '{print $NF}' | _wg_key_to_std_base64)
    export WG_PUBLIC_KEY
    WG_PUBLIC_KEY=$(echo "$keys" | grep -iE "public|password" | awk '{print $NF}' | _wg_key_to_std_base64)

    if [[ -z "$WG_PRIVATE_KEY" || -z "$WG_PUBLIC_KEY" ]]; then
        log_error "Failed to parse x25519 keys"
        return 1
    fi

    log_ok "WireGuard keypair generated"
    log_info "  Public key (register on the router): $WG_PUBLIC_KEY"
}

# stdin: one key, base64url-no-pad (43 chars) or already-standard base64 (44).
# stdout: standard WG base64 (43 chars + '=').
_wg_key_to_std_base64() {
    local key
    key=$(tr -- '-_' '+/')
    [[ -z "$key" ]] && return 0
    [[ "$key" == *= ]] || key="${key}="
    echo "$key"
}

# Parse a UniFi/wg-quick INI config and export the peer params:
#   WG_PRIVATE_KEY WG_ADDRESS WG_PEER_PUBKEY WG_ENDPOINT
#   WG_ALLOWED_IPS (default 0.0.0.0/0)  WG_KEEPALIVE (25)  WG_MTU (1380)
# Requires exactly one [Peer] section — multi-peer configs are out of scope.
# [Interface] DNS is read-and-discarded: XRAY's wireguard outbound has no
# in-tunnel DNS setting; the relay resolves names itself.
parse_wg_conf() {
    local path="$1"

    if [[ ! -f "$path" ]]; then
        log_error "WireGuard config not found: $path"
        return 1
    fi

    local section="" line key value key_lc peer_count=0
    local priv="" addr="" mtu="" peer_pub="" endpoint="" aips="" keepalive=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip comments (base64 values never contain '#' or ';') and whitespace
        line="${line%%#*}"
        line="${line%%;*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([A-Za-z]+)\]$ ]]; then
            section="${BASH_REMATCH[1],,}"
            [[ "$section" == "peer" ]] && peer_count=$((peer_count + 1))
            continue
        fi

        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        key_lc="${key,,}"

        case "${section}.${key_lc}" in
            interface.privatekey) priv="$value" ;;
            interface.address)    addr="$value" ;;
            interface.mtu)        mtu="$value" ;;
            interface.dns)
                log_info "Ignoring DNS = ${value} (XRAY wireguard outbound has no in-tunnel DNS)"
                ;;
            peer.publickey)           peer_pub="$value" ;;
            peer.endpoint)            endpoint="$value" ;;
            peer.allowedips)          aips="$value" ;;
            peer.persistentkeepalive) keepalive="$value" ;;
        esac
    done < "$path"

    if [[ "$peer_count" -ne 1 ]]; then
        log_error "Expected exactly one [Peer] section in $path, found $peer_count (multi-peer configs are not supported)"
        return 1
    fi

    local missing=""
    [[ -z "$priv" ]]     && missing="$missing PrivateKey"
    [[ -z "$addr" ]]     && missing="$missing Address"
    [[ -z "$peer_pub" ]] && missing="$missing PublicKey"
    [[ -z "$endpoint" ]] && missing="$missing Endpoint"
    if [[ -n "$missing" ]]; then
        log_error "WireGuard config $path is missing required field(s):$missing"
        return 1
    fi

    export WG_PRIVATE_KEY="$priv"
    export WG_ADDRESS="$addr"
    export WG_PEER_PUBKEY="$peer_pub"
    export WG_ENDPOINT="$endpoint"
    export WG_ALLOWED_IPS="${aips:-0.0.0.0/0}"
    export WG_KEEPALIVE="${keepalive:-25}"
    export WG_MTU="${mtu:-1380}"

    log_ok "Parsed WireGuard config: $path"
    log_info "  Private key: $(mask_wg_key "$WG_PRIVATE_KEY")"
    log_info "  Address:     $WG_ADDRESS"
    log_info "  Peer pubkey: $WG_PEER_PUBKEY"
    log_info "  Endpoint:    $WG_ENDPOINT"
    log_info "  AllowedIPs:  $WG_ALLOWED_IPS  Keepalive: $WG_KEEPALIVE  MTU: $WG_MTU"
}

# Validate + normalize the LAN-exception allow-list (comma/space-separated
# IPs/CIDRs). Each entry must be a private-host-scale exception: bare IPs are
# promoted to /32; prefixes broader than /24 (e.g. 192.168.0.0/16, 10.0.0.0/8)
# are refused — narrow per-host holes are the whole point of this list.
# Prints the normalized space-separated list on stdout.
validate_wg_lan_allow() {
    local raw="$1"
    local normalized=() entries entry ip prefix

    IFS=', ' read -ra entries <<< "$raw"
    for entry in "${entries[@]}"; do
        [[ -z "$entry" ]] && continue
        ip="${entry%%/*}"
        if [[ "$entry" == */* ]]; then
            prefix="${entry#*/}"
        else
            prefix=32
        fi
        if ! validate_ip "$ip"; then
            log_error "Invalid LAN allow entry: $entry (expected IP or CIDR)"
            return 1
        fi
        if ! [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || [[ "$prefix" -gt 32 ]]; then
            log_error "Invalid LAN allow prefix: $entry"
            return 1
        fi
        if [[ "$prefix" -lt 24 ]]; then
            log_error "LAN allow entry too broad: $entry — use narrow per-host /32s (nothing wider than /24)"
            return 1
        fi
        normalized+=("${ip}/${prefix}")
    done

    echo "${normalized[*]-}"
}

# The pre-flight/selfcheck workhorse: stand up a throwaway userspace tunnel
# (disposable `xray run`: scratch socks5 inbound → wg-out) and curl an echo-IP
# service through it. Proves the hand-copied peer values actually handshake and
# egress — a raw UDP probe can't (WireGuard ignores non-handshake packets).
# Touches nothing on the live relay: no config write, no x-ui restart, no
# network interface. Exports WG_DRY_RUN_EGRESS_IP on success.
wg_dry_run() {
    local private_key="$1"
    local address="$2"
    local peer_pubkey="$3"
    local endpoint="$4"
    local allowed_ips="${5:-0.0.0.0/0}"
    local keepalive="${6:-25}"
    local mtu="${7:-1380}"

    if ! command -v xray &> /dev/null; then
        log_error "xray binary not found — cannot dry-run the WireGuard tunnel"
        return 1
    fi

    local socks_port outbound cfg_file
    socks_port=$(generate_random_port)
    outbound=$(wg_outbound_json "$private_key" "$address" "$peer_pubkey" "$endpoint" \
        "$allowed_ips" "$keepalive" "$mtu")

    # Config carries the WG private key — 0600 and removed on return
    cfg_file=$(mktemp /tmp/wg-dryrun-XXXXXX.json)
    chmod 600 "$cfg_file"
    jq -n -c \
        --argjson wg "$outbound" \
        --argjson port "$socks_port" \
        '{
            log: {loglevel: "warning"},
            inbounds: [{
                tag: "socks-in",
                listen: "127.0.0.1",
                port: $port,
                protocol: "socks",
                settings: {udp: false}
            }],
            outbounds: [$wg],
            routing: {rules: [{type: "field", inboundTag: ["socks-in"], outboundTag: "wg-out"}]}
        }' > "$cfg_file"

    log_info "Dry-run: throwaway WireGuard tunnel to ${endpoint} (userspace, no interface)..."
    xray run -c "$cfg_file" > /dev/null 2>&1 &
    local xray_pid=$!
    # RETURN trap is function-local (not inherited by callees without functrace)
    # shellcheck disable=SC2064
    trap "kill $xray_pid 2>/dev/null || true; wait $xray_pid 2>/dev/null || true; rm -f '$cfg_file'" RETURN

    sleep 1
    if ! kill -0 "$xray_pid" 2>/dev/null; then
        log_error "Dry-run: xray failed to start (malformed key/address?)"
        return 1
    fi

    local egress_ip="" attempt
    for attempt in 1 2 3; do
        if egress_ip=$(curl -s4 --max-time 10 --socks5-hostname "127.0.0.1:${socks_port}" \
            https://ifconfig.me 2>/dev/null) && [[ -n "$egress_ip" ]]; then
            break
        fi
        egress_ip=""
        sleep 2
    done

    if [[ -z "$egress_ip" ]]; then
        log_error "Dry-run FAILED: no traffic egressed through the tunnel (handshake or routing failed)"
        log_error "  Check: peer public key, relay private key, endpoint ${endpoint} reachable (UDP),"
        log_error "  and that the router-side peer is registered with this relay's public key."
        return 1
    fi

    export WG_DRY_RUN_EGRESS_IP="$egress_ip"

    local relay_ip
    relay_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || relay_ip=""
    if [[ -n "$relay_ip" && "$egress_ip" == "$relay_ip" ]]; then
        log_error "Dry-run: tunnel egress IP ($egress_ip) equals this relay's own IP — traffic is NOT leaving via the peer (misrouted/mis-scoped peer?)"
        return 1
    fi

    log_ok "WireGuard tunnel OK — egress IP: $egress_ip"
    return 0
}
