#!/bin/bash
# VLESS Reality Relay VPN — Main Setup Script
# Usage: ./setup.sh [relay|exit]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

show_usage() {
    echo "Usage: $0 [exit|relay|update-exit|update-relay|uninstall]"
    echo ""
    echo "  exit         — Setup foreign exit server (internet access point)"
    echo "                 Use --force to reinstall even if already configured"
    echo "  relay        — Setup Russian relay server (entry point for users)"
    echo "                 Use --force to reinstall even if already configured"
    echo "  update-exit  — Update exit server config from latest codebase"
    echo "                 Use --upgrade to also update XRAY and 3X-UI binaries"
    echo "  update-relay — Update relay server config from latest codebase"
    echo "                 Use --upgrade to also update 3X-UI"
    echo "  uninstall    — Remove all VPN components (keeps SSH keys and certs)"
    echo "                 Use --purge-certs to also remove SSL certificates"
    echo ""
    echo "  All commands accept --skip-ssh to skip SSH hardening"
    echo ""
    echo "Deploy EXIT server first, then RELAY server."
}

case "${1:-}" in
    relay)
        exec "$SCRIPT_DIR/setup-relay.sh" "${@:2}"
        ;;
    exit)
        exec "$SCRIPT_DIR/setup-exit.sh" "${@:2}"
        ;;
    update-exit)
        exec "$SCRIPT_DIR/update-exit.sh" "${@:2}"
        ;;
    update-relay)
        exec "$SCRIPT_DIR/update-relay.sh" "${@:2}"
        ;;
    uninstall)
        exec "$SCRIPT_DIR/uninstall.sh" "${@:2}"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
