# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Two-server VPN deployment automation: relay (Russia) + exit (abroad) using VLESS + XTLS-Reality + XHTTP, managed via 3X-UI panels. Pure Bash scripts, no frameworks.

## Architecture

```
User → Relay server (3X-UI + embedded XRAY, port 443)
         → VLESS Reality TCP inbound
         → proxy-exit outbound (VLESS Reality XHTTP)
              → Exit server (standalone XRAY, port 443)
                   → internet (freedom outbound)
```

**Exit server**: XRAY runs as systemd service, config in `/usr/local/etc/xray/config.json`.
**Relay server**: 3X-UI manages its own XRAY process, config stored in SQLite at `/etc/x-ui/x-ui.db`.

Setup order is always exit first, then relay (relay needs exit server's keys/UUID).

## Entry Points

- `scripts/setup.sh` — router: delegates to `setup-exit.sh`, `setup-relay.sh`, or `uninstall.sh`
- `scripts/setup-exit.sh` — exit server orchestration (simpler, read this first)
- `scripts/setup-relay.sh` — relay server orchestration (complex, DB-driven)
- `scripts/uninstall.sh` — teardown with `--force` and `--purge-certs` flags

## Library Modules (`scripts/lib/`)

All sourced via `BASH_SOURCE` from orchestration scripts:

- `common.sh` — logging (`log_info/ok/warn/error`), `prompt_input`, `prompt_password`, validation, random generation
- `security.sh` — SSH hardening, UFW, fail2ban
- `reality.sh` — Reality key generation, destination site selection
- `xray.sh` — XRAY installation, exit server JSON config
- `3xui.sh` — 3X-UI install/configure, SQLite operations, SSL certs, inbound/template management
- `verify.sh` — post-setup smoke tests (services, ports, connectivity)

## Critical Patterns

### 3X-UI Database Timing

3X-UI holds an in-memory copy of its SQLite DB. On shutdown it writes memory → DB, overwriting external changes. The mandatory pattern is:

```bash
x-ui stop          # Flush memory to DB
# ... modify DB with sqlite3 / xui_db_set ...
x-ui start         # Load fresh state from DB
```

`xui_db_set()` in `3xui.sh` handles upsert for the `settings` table. Complex operations (inbounds) use direct `sqlite3` calls.

### 3X-UI Inbound Normalization

After INSERT into `inbounds` table, 3X-UI strips fields on first restart: `subId`, `realitySettings.settings` (publicKey/fingerprint). The workaround is a two-restart cycle:

1. Insert full inbound → restart (3X-UI normalizes/strips)
2. Patch stripped fields back with `jq` → restart (xray picks up patched config)

See `patch_3xui_relay_inbound()` and `create_3xui_relay_inbound()` in `3xui.sh`.

### 3X-UI Template Stripping

3X-UI can strip `api`/`stats`/`policy` from `xrayTemplateConfig` if it starts without the template loaded. Always write the template to DB **before** restarting, never after.

### Interactive Installer Workarounds

- **3X-UI installer**: Feed 100 newlines via file (`/tmp/xui-answers`) to accept defaults. Using `yes ""` causes SIGPIPE with `set -o pipefail`.
- **XRAY installer**: Redirect `< /dev/null` to prevent stdin consumption from piped input.

### SSL Certificate Caching

`issue_domain_cert()` checks for existing valid cert before calling acme.sh. Without `--force`, acme.sh also checks its own cache. Uninstall preserves certs by default (`--purge-certs` to remove). This avoids Let's Encrypt rate limits (5 duplicate certs per 168h per domain set).

## Code Conventions

- `set -euo pipefail` in all lib scripts
- Functions and variables: `snake_case`; exported/environment: `UPPER_CASE`
- All function params declared `local` at top of function body
- SQL string escaping: `${var//\'/\'\'}`
- JSON building: `jq -n -c` with `--arg`/`--argjson` parameters
- Optional operations use `|| true`; fatal errors use `exit 1`
- 4-space indentation
- Git commits: conventional format (`fix:`, `feat:`, `docs:`), "why" not "what"

## Testing

No automated test suite. Verification is manual E2E on live servers. `verify.sh` provides post-setup smoke tests (service status, port listening, network connectivity). Full test cycle:

```bash
ssh vpn-exit "cd ~/vless-relay-setup && sudo ./scripts/setup.sh exit"
ssh vpn-relay "cd ~/vless-relay-setup && sudo ./scripts/setup.sh relay"
# Then verify VPN connectivity from a client
```

## SSH Access

```bash
ssh vpn-exit    # Exit server (root)
ssh vpn-relay   # Relay server (root)
```

Both have the repo cloned at `~/vless-relay-setup/`.
