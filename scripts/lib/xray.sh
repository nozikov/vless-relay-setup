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
    local cdn_ws_port="${9:-}"
    local cdn_ws_path="${10:-}"

    log_info "Configuring XRAY as exit server..."

    cat > /usr/local/etc/xray/config.json << XRAYEOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "dns": {
        "servers": [
            "94.140.14.14",
            "94.140.15.15",
            "1.1.1.1"
        ]
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
                    "extra": {
                        "xPaddingBytes": "100-1000",
                        "scMaxEachPostBytes": 1000000,
                        "scMaxBufferedPosts": 30
                    }
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

    if [[ -n "$cdn_ws_port" && -n "$cdn_ws_path" ]]; then
        log_info "Adding CDN WebSocket inbound on 127.0.0.1:${cdn_ws_port}..."
        local tmp_config
        if ! tmp_config=$(jq \
            --argjson ws_port "$cdn_ws_port" \
            --arg ws_path "$cdn_ws_path" \
            '.inbounds += [{
                tag: "vless-ws-in",
                listen: "127.0.0.1",
                port: $ws_port,
                protocol: "vless",
                settings: {
                    clients: [{ id: .inbounds[0].settings.clients[0].id }],
                    decryption: "none"
                },
                streamSettings: {
                    network: "ws",
                    wsSettings: {
                        path: ("/"+$ws_path)
                    }
                },
                sniffing: {
                    enabled: true,
                    destOverride: ["http","tls","quic"],
                    routeOnly: true
                }
            }]' /usr/local/etc/xray/config.json); then
            log_error "Failed to add CDN WebSocket inbound (jq error)"
            exit 1
        fi
        echo "$tmp_config" > /usr/local/etc/xray/config.json
        log_ok "CDN WebSocket inbound added (port: $cdn_ws_port)"
    fi
}

disable_system_xray() {
    log_info "Disabling system xray service (3X-UI manages its own xray)..."
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    log_ok "System xray disabled (binary kept for key generation)"
}

restart_xray() {
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
