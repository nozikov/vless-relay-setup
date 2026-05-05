#!/bin/bash
# XRAY-core installation and configuration

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_xray() {
    log_info "Installing XRAY-core..."

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install < /dev/null

    if command -v xray &> /dev/null; then
        local version
        version=$(xray version 2>/dev/null | head -1 || true)
        log_ok "XRAY installed: $version"
    else
        log_error "XRAY installation failed"
        exit 1
    fi
}

configure_xray_exit() {
    local listen_port="${1:-443}"
    local uuid="$2"
    local private_key="$3"
    local short_id="$4"
    local dest="$5"
    local server_name="$6"
    local xhttp_path="$7"
    local xver="${8:-0}"
    local cdn_port="${9:-}"
    local cdn_path="${10:-}"
    local dns_mode="${11:-adguard}"

    log_info "Configuring XRAY as exit server..."

    # XHTTP extra block from shared helper. Server-side fields apply (padding,
    # scMaxEachPostBytes, scMaxBufferedPosts). Client-side fields (xmux,
    # scMinPostsIntervalMs) are ignored at runtime but kept for config parity.
    local extra_json
    extra_json=$(xhttp_extra_json)

    local dns_servers_json
    case "$dns_mode" in
        adguard)
            dns_servers_json='"94.140.14.14", "94.140.15.15", "1.1.1.1"'
            log_info "DNS: AdGuard (ad/tracker filtering)"
            ;;
        default)
            dns_servers_json='"1.1.1.1", "8.8.8.8"'
            log_info "DNS: Cloudflare + Google (no filtering)"
            ;;
        *)
            log_error "Unknown dns_mode: $dns_mode (expected: adguard|default)"
            exit 1
            ;;
    esac

    cat > /usr/local/etc/xray/config.json << XRAYEOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "dns": {
        "servers": [${dns_servers_json}]
    },
    "inbounds": [
        {
            "tag": "vless-reality-in",
            "listen": "0.0.0.0",
            "port": ${listen_port},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${uuid}"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "mode": "auto",
                    "path": "/${xhttp_path}",
                    "extra": ${extra_json}
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${dest}",
                    "xver": ${xver},
                    "serverNames": ["${server_name}"],
                    "privateKey": "${private_key}",
                    "shortIds": ["${short_id}"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIP"
            }
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            }
        ]
    }
}
XRAYEOF

    mkdir -p /var/log/xray
    log_ok "XRAY exit config written"

    # Merge Reality fallback rate-limits into the inbound. Throttles only
    # fallback traffic (probes, casual visitors hitting the masquerade site);
    # authenticated VPN clients passing the Reality handshake are not affected.
    local lf_json tmp_config
    lf_json=$(reality_limit_fallback_json)
    if ! tmp_config=$(jq \
        --argjson lf "$lf_json" \
        '.inbounds[0].streamSettings.realitySettings += $lf' \
        /usr/local/etc/xray/config.json); then
        log_error "Failed to merge Reality limitFallback (jq error)"
        exit 1
    fi
    echo "$tmp_config" > /usr/local/etc/xray/config.json

    if [[ -n "$cdn_port" && -n "$cdn_path" ]]; then
        log_info "Adding CDN XHTTP inbound on 127.0.0.1:${cdn_port}..."
        local cdn_extra_json
        cdn_extra_json=$(xhttp_extra_json)
        if ! tmp_config=$(jq \
            --argjson cdn_port "$cdn_port" \
            --arg cdn_path "$cdn_path" \
            --argjson extra "$cdn_extra_json" \
            '.inbounds += [{
                tag: "vless-cdn-in",
                listen: "127.0.0.1",
                port: $cdn_port,
                protocol: "vless",
                settings: {
                    clients: [{ id: .inbounds[0].settings.clients[0].id }],
                    decryption: "none"
                },
                streamSettings: {
                    network: "xhttp",
                    xhttpSettings: {
                        mode: "packet-up",
                        path: ("/"+$cdn_path),
                        extra: $extra
                    }
                },
                sniffing: {
                    enabled: true,
                    destOverride: ["http","tls","quic"],
                    routeOnly: true
                }
            }]' /usr/local/etc/xray/config.json); then
            log_error "Failed to add CDN XHTTP inbound (jq error)"
            exit 1
        fi
        echo "$tmp_config" > /usr/local/etc/xray/config.json
        log_ok "CDN XHTTP inbound added (port: $cdn_port)"
    fi
}

disable_system_xray() {
    log_info "Disabling system xray service (3X-UI manages its own xray)..."
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    log_ok "System xray disabled (binary kept for key generation)"
}

restart_xray() {
    # Validate config before restart — catches schema errors (e.g., binary too old
    # for limitFallback) explicitly instead of leaving xray in a failed state.
    if ! xray -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        log_error "xray config validation failed:"
        xray -test -config /usr/local/etc/xray/config.json || true
        return 1
    fi

    systemctl restart xray
    systemctl enable xray

    if systemctl is-active --quiet xray; then
        log_ok "XRAY is running"
        return 0
    else
        log_error "XRAY failed to start. Check: journalctl -u xray"
        return 1
    fi
}
