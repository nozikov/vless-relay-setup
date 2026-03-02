#!/bin/bash
# VLESS Reality Relay VPN — Main Setup Script
# Usage: ./setup.sh [relay|exit]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

show_usage() {
    echo "Usage: $0 [relay|exit|uninstall]"
    echo ""
    echo "  exit      — Setup foreign exit server (internet access point)"
    echo "  relay     — Setup Russian relay server (entry point for users)"
    echo "  uninstall — Remove all VPN components (keeps SSH keys and certs)"
    echo "             Use --purge-certs to also remove SSL certificates"
    echo ""
    echo "Deploy EXIT server first, then RELAY server."
}

case "${1:-}" in
    relay)
        exec "$SCRIPT_DIR/setup-relay.sh"
        ;;
    exit)
        exec "$SCRIPT_DIR/setup-exit.sh"
        ;;
    uninstall)
        exec "$SCRIPT_DIR/uninstall.sh" "${@:2}"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
