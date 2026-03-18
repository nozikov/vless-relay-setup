#!/bin/bash
# Base security setup
# Run: ./setup.sh security

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/security.sh"

main() {
    local ssh_port
    prompt_input "New SSH port" ssh_port "$(generate_random_port)"
    setup_ssh "$ssh_port"
    setup_fail2ban "$ssh_port"
    setup_ufw
    allow_ports "$ssh_port:SSH"
    log_warn "UFW and SSH services are about to restart"
    log_warn "You may disconnect from current section"
    log_warn "To get back you can use: ssh -p $ssh_port [-i <path_to_private_key>] <user>@<host>"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    echo "y" | ufw enable 2>/dev/null
}

LOG_FILE="/var/log/vpn-setup-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
main 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"