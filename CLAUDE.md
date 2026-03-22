# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Two-server VPN deployment automation: relay (Russia) + exit (abroad) using VLESS + XTLS-Reality + XHTTP, managed via 3X-UI panels. Pure Bash scripts, no frameworks.

## Architecture

```
User → Relay server (3X-UI + embedded XRAY, port 443)
         → VLESS Reality TCP inbound (sniffing: routeOnly)
         → fragment outbound (splits TLS ClientHello for DPI bypass)
         → proxy-exit outbound (VLESS Reality XHTTP, dialerProxy: fragment)
              → Exit server (standalone XRAY, port 443)
                   → routing: geoip:private → block
                   → internet (freedom outbound, domainStrategy: UseIP)

SelfSteal mode (optional):
  XRAY Reality dest → /dev/shm/caddy.sock (xver=1, PROXY protocol)
  DPI probe → Caddy (unix socket) → real website with valid cert
  DNS A-record → server IP (eliminates IP/SNI mismatch)
  Caddy also reverse-proxies 3X-UI panel and subscriptions (relay only)

CDN Fallback (optional, requires SelfSteal):
  Client → Cloudflare CDN (simplers.club) → Exit server:443
    → XRAY Reality → Caddy (unix socket) → 127.0.0.1:cdn_ws_port
    → VLESS WebSocket inbound → internet
  Separate domain on Cloudflare (Proxied, SSL: Full, WebSockets: ON)
  Exit: Caddy routes WS path to local XRAY WS inbound
  Relay: sub-proxy appends CDN VLESS link to subscription responses
```

**Exit server**: XRAY runs as systemd service, config in `/usr/local/etc/xray/config.json`.
**Relay server**: 3X-UI manages its own XRAY process, config stored in SQLite at `/etc/x-ui/x-ui.db`.

Setup order is always exit first, then relay (relay needs exit server's keys/UUID).

## Entry Points

- `scripts/setup.sh` — router: delegates to setup/update/uninstall scripts. Passes extra args (`--force`, `--upgrade`)
- `scripts/setup-exit.sh` — exit server orchestration. Refuses to run if already configured (use `--force` to override)
- `scripts/setup-relay.sh` — relay server orchestration (complex, DB-driven). Same `--force` guard
- `scripts/update-exit.sh` — update exit config from latest codebase, preserving keys/UUID. `--upgrade` to update binaries
- `scripts/update-relay.sh` — update relay template + patch inbound sniffing, preserving clients. `--upgrade` to update 3X-UI
- `scripts/uninstall.sh` — teardown with `--force` and `--purge-certs` flags

## Library Modules (`scripts/lib/`)

All sourced via `BASH_SOURCE` from orchestration scripts:

- `common.sh` — logging (`log_info/ok/warn/error`), `prompt_input`, `prompt_password`, validation (`validate_domain`, `check_domain_dns`), random generation, `PROJECT_VERSION` from `VERSION` file
- `security.sh` — SSH hardening (custom port support), UFW, fail2ban
- `caddy.sh` — Caddy installation, Caddyfile generation, static site content, systemd dependency, sub-proxy setup, uninstall (SelfSteal mode only)
- `reality.sh` — Reality key generation, destination site selection
- `xray.sh` — XRAY installation, exit server JSON config (including optional CDN WebSocket inbound)
- `3xui.sh` — 3X-UI install/configure, SQLite operations, SSL certs, inbound/template management
- `verify.sh` — post-setup smoke tests (services, ports, connectivity)
- `sub-proxy.py` — subscription proxy: sits between Caddy and 3X-UI subscription, appends CDN VLESS link. Passes through HTML pages (QR codes) for browsers, modifies only base64 responses for apps

## Critical Patterns

### 3X-UI Database Timing

3X-UI holds an in-memory copy of its SQLite DB. On shutdown it writes memory → DB, overwriting external changes. The mandatory pattern is:

```bash
x-ui stop          # Flush memory to DB
# ... modify DB with sqlite3 / xui_db_set ...
x-ui start         # Load fresh state from DB
```

`xui_db_set()` in `3xui.sh` handles upsert for the `settings` table with automatic SQL escaping. Complex operations (inbounds) use direct `sqlite3` calls with manual escaping.

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

### Update Scripts

`update-exit.sh` reads current keys/UUID/dest/xver from XRAY config, regenerates config via `configure_xray_exit()`, restarts. `update-relay.sh` reads current exit params from DB, patches inbound sniffing (routeOnly) via jq, regenerates template via `configure_3xui_relay_template()`, restarts. Both create timestamped backups and auto-rollback on failure.

Both update scripts detect SelfSteal mode (by checking if `dest` contains `caddy.sock`) and preserve it. They also detect the current SSH port from `sshd_config` and pass it through to `setup_security`. With `--upgrade`, Caddy is also updated in SelfSteal mode.

The inbound patch in `update-relay.sh` runs between `x-ui stop` and `x-ui start` — same window as the template write. This is safe because x-ui is stopped (no in-memory overwrite risk).

`update-relay.sh` also auto-updates the CDN VLESS link in sub-proxy if active. It reads the current exit UUID from the relay template, extracts CDN domain/path from the existing sub-proxy service file, regenerates the link, and rewrites the entire service file (not sed — `&` in URLs breaks sed replacements).

### Dest Format Convention

Callers pass the FULL dest value including port if needed. Functions use it as-is without appending `:443`:
- Auto mode: `dest="www.microsoft.com:443"` (port set in `reality.sh`)
- SelfSteal mode: `dest="/dev/shm/caddy.sock"` (no port for unix socket)

This affects `configure_xray_exit()`, `create_3xui_relay_inbound()`, and both update scripts.

### CDN Fallback

CDN Fallback adds a WebSocket inbound on exit (localhost-only) and a Caddy route for the CDN domain. Cloudflare proxies WS traffic to exit:443 → Caddy → XRAY WS inbound. All clients share one exit UUID on the CDN path.

**Sub-proxy** on relay intercepts subscription responses. For browser requests (`Accept: text/html`), it passes through 3X-UI's HTML page with QR codes. For app requests (base64), it appends the CDN VLESS link. Environment: `CDN_VLESS_LINK` (with `%%` escaping for systemd), `SUB_UPSTREAM`, `SUB_PROXY_PORT`.

**Caddy subscription routing**: in SelfSteal+CDN mode, Caddy proxies subscriptions to sub-proxy port (not directly to 3X-UI). Sub-proxy then proxies to 3X-UI and modifies the response.

**subURI**: 3X-UI setting that overrides the displayed subscription URL. Must include the full path with trailing content: `https://sub.domain/subPath/`. Without this, 3X-UI shows internal `http://127.0.0.1:port` links.

**Service file rewriting**: Never use `sed` to modify sub-proxy.service — `&` in VLESS URLs is a sed special character. Always rewrite the entire file via heredoc.

### Caddy Unix Socket Permissions

XRAY runs as `nobody` but Caddy creates `/dev/shm/caddy.sock` with mode `0600` (root-only). `start_caddy()` does `chmod 0666` after start so XRAY can connect to the socket for Reality dest forwarding.

### Custom SSH Port

`setup_security()` accepts `--ssh-port PORT` flag. `setup_ssh_hardening()` modifies `sshd_config`, `setup_fail2ban()` configures the port in jail config, and UFW opens the custom port. Update scripts detect the current port via `grep '^Port ' /etc/ssh/sshd_config` with fallback to 22.

### Setup Guard

`setup-exit.sh` and `setup-relay.sh` check for existing configuration before running. If found, they refuse and suggest the update command instead. `--force` overrides the check for intentional full reinstall.

### Logging

All setup/update scripts wrap `main` with `tee` to `/var/log/vpn-setup-<script>-<timestamp>.log`. Exit code preserved via `PIPESTATUS[0]`.

### Versioning

`VERSION` file in repo root is the single source of truth. `common.sh` reads it into `PROJECT_VERSION`. All scripts display version in their banner. Bump version only when script behavior changes (not for docs/README changes).

## Code Conventions

- `set -euo pipefail` in all lib scripts
- Functions and variables: `snake_case`; exported/environment: `UPPER_CASE`
- All function params declared `local` at top of function body
- SQL string escaping: `xui_db_set()` handles it internally; direct `sqlite3` calls use `${var//\'/\'\'}`
- JSON building: `jq -n -c` with `--arg`/`--argjson` parameters
- Optional operations use `|| true`; fatal errors use `exit 1`
- 4-space indentation
- Git commits: conventional format (`fix:`, `feat:`, `docs:`), "why" not "what"

## Testing

No automated test suite. Verification is manual E2E on live servers. `verify.sh` provides post-setup smoke tests (service status, port listening, network connectivity). Full test cycle:

```bash
# Fresh install
ssh vpn-exit "cd ~/vless-relay-setup && sudo ./scripts/setup.sh exit"
ssh vpn-relay "cd ~/vless-relay-setup && sudo ./scripts/setup.sh relay"

# Update after code changes
ssh vpn-exit "cd ~/vless-relay-setup && git pull && sudo ./scripts/setup.sh update-exit"
ssh vpn-relay "cd ~/vless-relay-setup && git pull && sudo ./scripts/setup.sh update-relay"

# Then verify VPN connectivity from a client
```

## SSH Access

```bash
ssh vpn-exit    # Exit server (root)
ssh vpn-relay   # Relay server (root)
```

Both have the repo cloned at `~/vless-relay-setup/`.
