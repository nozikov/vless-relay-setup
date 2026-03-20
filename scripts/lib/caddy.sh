#!/bin/bash
# Caddy web server for SelfSteal Reality SNI

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CADDY_SOCK="/dev/shm/caddy.sock"

install_caddy() {
    log_info "Installing Caddy..."

    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl > /dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq caddy > /dev/null 2>&1

    # Stop default service — we configure before starting
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true

    # Caddy APT package runs as 'caddy' user by default.
    # Override to run as root so it can create unix sockets in /dev/shm
    # and XRAY (running as root) can write to them without permission issues.
    mkdir -p /etc/systemd/system/caddy.service.d
    cat > /etc/systemd/system/caddy.service.d/override.conf << 'SVCEOF'
[Service]
User=root
Group=root
SVCEOF
    systemctl daemon-reload

    if command -v caddy &>/dev/null; then
        log_ok "Caddy installed: $(caddy version 2>/dev/null | head -1)"
    else
        log_error "Caddy installation failed"
        exit 1
    fi
}

generate_caddyfile() {
    local selfsteal_domain="$1"
    local panel_domain="${2:-}"
    local panel_port="${3:-}"
    local sub_domain="${4:-}"
    local sub_port="${5:-}"

    log_info "Generating Caddyfile..."

    # Global options — proxy_protocol MUST be scoped to unix socket server only.
    # Port 80 listener receives plain HTTP (no PROXY protocol).
    # The "servers unix" key scopes listener_wrappers to the unix socket listener.
    # NOTE: Verify exact Caddy v2 syntax for server key scoping during implementation.
    # If "servers unix" does not work, use named server approach per Caddy docs.
    cat > /etc/caddy/Caddyfile << CADDYEOF
{
    auto_https disable_redirects
    servers unix {
        listener_wrappers {
            proxy_protocol {
                allow 127.0.0.1/32
            }
            tls
        }
    }
}

https://${selfsteal_domain} {
    bind unix/${CADDY_SOCK}
    root * /var/www/html/selfsteal
    file_server
}
CADDYEOF

    if [[ -n "$panel_domain" && -n "$panel_port" ]]; then
        cat >> /etc/caddy/Caddyfile << CADDYEOF

https://${panel_domain} {
    bind unix/${CADDY_SOCK}
    reverse_proxy 127.0.0.1:${panel_port} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            tls_insecure_skip_verify
        }
    }
}
CADDYEOF
    fi

    if [[ -n "$sub_domain" && -n "$sub_port" ]]; then
        cat >> /etc/caddy/Caddyfile << CADDYEOF

https://${sub_domain} {
    bind unix/${CADDY_SOCK}
    reverse_proxy 127.0.0.1:${sub_port} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            tls_insecure_skip_verify
        }
    }
}
CADDYEOF
    fi

    # Common blocks: HTTP redirect + catch-all abort
    cat >> /etc/caddy/Caddyfile << CADDYEOF

http:// {
    redir https://{host}{uri} permanent
}

https:// {
    bind unix/${CADDY_SOCK}
    tls internal
    abort
}
CADDYEOF

    log_ok "Caddyfile written to /etc/caddy/Caddyfile"
}

setup_selfsteal_content() {
    log_info "Setting up SelfSteal static content..."

    mkdir -p /var/www/html/selfsteal

    local choice
    echo ""
    echo "  Static site for SelfSteal:"
    echo "    1) Git repo URL (will be cloned)"
    echo "    2) Local path on server"
    echo "    3) Generate placeholder page"
    echo ""
    read -rp "  Choose [1/2/3] (default: 3): " choice
    choice="${choice:-3}"

    case "$choice" in
        1)
            local repo_url
            read -rp "  Git repo URL: " repo_url
            if [[ -z "$repo_url" ]]; then
                log_warn "No URL provided, generating placeholder"
                generate_placeholder_page
                return
            fi
            rm -rf /var/www/html/selfsteal/*
            if git clone --depth 1 "$repo_url" /var/www/html/selfsteal/ 2>/dev/null; then
                rm -rf /var/www/html/selfsteal/.git
                log_ok "Static site cloned from $repo_url"
            else
                log_warn "Git clone failed, generating placeholder page"
                generate_placeholder_page
            fi
            ;;
        2)
            local local_path
            read -rp "  Local path: " local_path
            if [[ -d "$local_path" ]]; then
                rm -rf /var/www/html/selfsteal/*
                cp -r "$local_path"/* /var/www/html/selfsteal/
                log_ok "Static site copied from $local_path"
            else
                log_warn "Path not found: $local_path, generating placeholder"
                generate_placeholder_page
            fi
            ;;
        3|*)
            generate_placeholder_page
            ;;
    esac
}

generate_placeholder_page() {
    cat > /var/www/html/selfsteal/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               max-width: 640px; margin: 80px auto; padding: 0 20px; color: #333; }
        h1 { font-weight: 300; }
        p { line-height: 1.6; color: #666; }
    </style>
</head>
<body>
    <h1>Coming Soon</h1>
    <p>We are working on something new. Check back later.</p>
</body>
</html>
HTMLEOF
    log_ok "Placeholder page generated"
}

start_caddy() {
    log_info "Starting Caddy..."

    # Check port 80 availability
    if ss -tlnp | grep -q ":80 "; then
        local pid
        pid=$(ss -tlnp | grep ":80 " | grep -oP 'pid=\K[0-9]+' | head -1)
        log_warn "Port 80 is occupied by PID $pid"
        log_warn "Caddy needs port 80 for ACME HTTP challenges"
    fi

    systemctl enable caddy
    systemctl start caddy

    if systemctl is-active --quiet caddy; then
        log_ok "Caddy is running"
    else
        log_error "Caddy failed to start. Check: journalctl -u caddy"
        return 1
    fi
}

setup_caddy_systemd_dependency() {
    local service="$1"  # "xray" or "x-ui"
    log_info "Adding systemd dependency: ${service} after caddy..."

    mkdir -p "/etc/systemd/system/${service}.service.d"
    cat > "/etc/systemd/system/${service}.service.d/after-caddy.conf" << SVCEOF
[Unit]
After=caddy.service
Wants=caddy.service
SVCEOF

    systemctl daemon-reload
    log_ok "systemd: ${service} will start after caddy"
}

uninstall_caddy() {
    log_info "Removing Caddy..."

    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true
    apt-get purge -y caddy > /dev/null 2>&1 || true

    rm -rf /etc/caddy 2>/dev/null || true
    rm -rf /var/www/html/selfsteal 2>/dev/null || true
    rm -f /dev/shm/caddy.sock 2>/dev/null || true

    # Remove systemd overrides
    rm -rf /etc/systemd/system/caddy.service.d 2>/dev/null || true
    rm -rf /etc/systemd/system/xray.service.d/after-caddy.conf 2>/dev/null || true
    rm -rf /etc/systemd/system/x-ui.service.d/after-caddy.conf 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # Remove Caddy APT repo
    rm -f /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true

    log_ok "Caddy removed"
}
