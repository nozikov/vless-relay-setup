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
                    "path": "/${xhttp_path}"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${dest}:443",
                    "xver": 0,
                    "serverNames": ["${server_name}"],
                    "privateKey": "${private_key}",
                    "shortIds": ["${short_id}"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom"
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ]
}
XRAYEOF

    mkdir -p /var/log/xray
    log_ok "XRAY exit config written"
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
    else
        log_error "XRAY failed to start. Check: journalctl -u xray"
        exit 1
    fi
}
