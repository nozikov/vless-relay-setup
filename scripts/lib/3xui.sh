#!/bin/bash
# 3X-UI panel installation and configuration

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_3xui() {
    log_info "Installing 3X-UI panel..."

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< "y"

    if command -v x-ui &> /dev/null; then
        log_ok "3X-UI installed"
    else
        log_error "3X-UI installation failed"
        exit 1
    fi
}

configure_3xui() {
    local panel_port="$1"
    local panel_path="$2"
    local admin_user="$3"
    local admin_pass="$4"

    log_info "Configuring 3X-UI panel..."

    # Set panel port
    /usr/local/x-ui/x-ui setting -port "$panel_port"

    # Set panel URL path
    /usr/local/x-ui/x-ui setting -webBasePath "/$panel_path/"

    # Set admin credentials
    /usr/local/x-ui/x-ui setting -username "$admin_user" -password "$admin_pass"

    # Enable self-signed TLS for panel
    /usr/local/x-ui/x-ui setting -enableTLS true

    # Restart to apply
    x-ui restart

    log_ok "3X-UI configured:"
    log_info "  URL: https://<server-ip>:${panel_port}/${panel_path}/"
    log_info "  User: $admin_user"
}

configure_3xui_subscription() {
    local domain="$1"
    local sub_port="$2"
    local sub_path="$3"

    log_info "Configuring subscription service..."

    # 3X-UI has built-in subscription support
    # Configure via panel API or manual settings
    /usr/local/x-ui/x-ui setting -subEnable true
    /usr/local/x-ui/x-ui setting -subPort "$sub_port"
    /usr/local/x-ui/x-ui setting -subPath "/$sub_path/"
    /usr/local/x-ui/x-ui setting -subDomain "$domain"

    x-ui restart

    log_ok "Subscription configured:"
    log_info "  URL: https://${domain}:${sub_port}/${sub_path}/"
}
