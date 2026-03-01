#!/bin/bash
# XRAY-core installation and configuration

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_xray() {
    log_info "Installing XRAY-core..."

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    if command -v xray &> /dev/null; then
        local version
        version=$(xray version | head -1)
        log_ok "XRAY installed: $version"
    else
        log_error "XRAY installation failed"
        exit 1
    fi
}

apply_xray_config() {
    local config_file="$1"
    local xray_config="/usr/local/etc/xray/config.json"

    cp "$config_file" "$xray_config"
    log_ok "XRAY config applied: $xray_config"
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

configure_xray_relay() {
    local listen_port="${1:-443}"
    local relay_uuid="$2"
    local relay_private_key="$3"
    local relay_short_id="$4"
    local relay_dest="$5"
    local relay_server_name="$6"
    local exit_ip="$7"
    local exit_port="$8"
    local exit_uuid="$9"
    local exit_public_key="${10}"
    local exit_short_id="${11}"
    local exit_server_name="${12}"
    local exit_xhttp_path="${13}"

    log_info "Configuring XRAY as relay server..."

    cat > /usr/local/etc/xray/config.json << XRAYEOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
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
                        "id": "${relay_uuid}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${relay_dest}:443",
                    "xver": 0,
                    "serverNames": ["${relay_server_name}"],
                    "privateKey": "${relay_private_key}",
                    "shortIds": ["${relay_short_id}"]
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
            "tag": "proxy-exit",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "${exit_ip}",
                        "port": ${exit_port},
                        "users": [
                            {
                                "id": "${exit_uuid}",
                                "encryption": "none"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "mode": "auto",
                    "path": "/${exit_xhttp_path}"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "fingerprint": "chrome",
                    "serverName": "${exit_server_name}",
                    "publicKey": "${exit_public_key}",
                    "shortId": "${exit_short_id}"
                }
            }
        },
        {
            "tag": "direct",
            "protocol": "freedom"
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
                "inboundTag": ["vless-reality-in"],
                "outboundTag": "proxy-exit"
            }
        ]
    }
}
XRAYEOF

    mkdir -p /var/log/xray
    log_ok "XRAY relay config written"
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
