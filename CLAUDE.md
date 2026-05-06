# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Two-server VPN deployment automation: relay (entry node) + exit (exit node) using VLESS + XTLS-Reality (XHTTP on relay client-facing inbound, RAW + xtls-rprx-vision on relay→exit and Direct Exit), managed via 3X-UI panels. Pure Bash scripts, no frameworks.

## Architecture

```
User → Relay server (3X-UI + embedded XRAY, port 443)
         → VLESS Reality XHTTP inbound (sniffing: routeOnly)
         → fragment outbound (splits TLS ClientHello for DPI bypass)
         → proxy-exit outbound (VLESS Reality RAW + xtls-rprx-vision, dialerProxy: fragment)
              → Exit server (standalone XRAY, port 443, RAW + Vision)
                   → routing:
                       AI domains → WARP outbound (optional, issue #35)
                       geoip:private → block
                       else → internet (freedom outbound, domainStrategy: UseIP)

SelfSteal mode (optional):
  XRAY Reality dest → /dev/shm/caddy.sock (xver=1, PROXY protocol)
  DPI probe → Caddy (unix socket) → real website with valid cert
  DNS A-record → server IP (eliminates IP/SNI mismatch)
  Caddy also reverse-proxies 3X-UI panel and subscriptions (relay only)

CDN Fallback (optional, requires SelfSteal):
  Symmetric mode:
    Client → Cloudflare CDN → Exit server:443
      → XRAY Reality → Caddy (unix socket) → 127.0.0.1:cdn_port
      → VLESS XHTTP inbound (packet-up mode) → internet
  Asymmetric mode:
    Upload: Client → Cloudflare CDN → Exit (same XHTTP inbound as symmetric)
    Download: Client → Exit:443 (Reality RAW + Vision direct, same main inbound relay uses)
  Separate domain on Cloudflare (Proxied, SSL: Full)
  Exit: Caddy routes CDN path to local XRAY XHTTP inbound
  Relay: sub-proxy appends CDN VLESS links (symmetric + asymmetric) to subscriptions

Hysteria 2 (optional, requires SelfSteal):
  Client → Exit:UDP_RANGE (Hysteria 2 + Salamander obfuscation)
  Standalone binary alongside XRAY, independent systemd service
  Auth: exit UUID as password, TLS cert: copied from Caddy's Let's Encrypt
  Config: /etc/hysteria/config.yaml, certs: /etc/hysteria/certs/
  Port hopping: native listen on UDP range (e.g. 34821-35821)
  Masquerade: reverse proxy to SelfSteal site
  Link added to subscription via sub-proxy HYSTERIA_LINK env var
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
- `xray.sh` — XRAY installation, exit server JSON config (including optional CDN XHTTP inbound with padding)
- `3xui.sh` — 3X-UI install/configure, SQLite operations, SSL certs, inbound/template management
- `verify.sh` — post-setup smoke tests (services, ports, connectivity)
- `hysteria.sh` — Hysteria 2 installation, YAML config generation, cert copy from Caddy, restart, uninstall
- `sub-proxy.py` — subscription proxy: sits between Caddy and 3X-UI subscription, appends CDN VLESS + Hysteria 2 links. Passes through HTML pages (QR codes) for browsers, modifies only base64 responses for apps

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

### Synchronous Migration: Vision Replaces XHTTP on Exit (v1.10.0+)

Exit's main inbound and relay's `proxy-exit` outbound must be on the same transport: either both XHTTP (≤v1.9.x) or both RAW + xtls-rprx-vision (v1.10.0+). Cannot mix.

`update-exit` migrates the exit inbound; `update-relay` migrates the relay outbound and regenerates sub-proxy URLs (Direct Exit + CDN asymmetric downloadSettings switch to `type=raw&flow=xtls-rprx-vision`). Update order: **exit first, then relay**. ~30s window of broken connectivity for relay-routed clients between the two updates. Direct Exit URLs cached in client subscriptions also break until subscription refresh.

Idempotency: re-running update-* on an already-migrated config is a no-op (jq detection on `xhttpSettings` field). Relay client-facing inbound stays XHTTP. CDN packet-up XHTTP inbound (localhost) stays XHTTP — Cloudflare requires HTTP. Hysteria 2 unaffected.

### Update Scripts

`update-exit.sh` reads current keys/UUID/dest/xver from XRAY config, regenerates config via `configure_xray_exit()`, restarts. `update-relay.sh` reads current exit params from DB, patches inbound sniffing (routeOnly) via jq, auto-migrates TCP relay inbound to XHTTP if still on TCP (generates random path, patches stream_settings via jq), regenerates template via `configure_3xui_relay_template()`, restarts. Both create timestamped backups and auto-rollback on failure.

Both update scripts detect SelfSteal mode (by checking if `dest` contains `caddy.sock`) and preserve it. They also detect the current SSH port from `sshd_config` and pass it through to `setup_security`. With `--upgrade`, Caddy is also updated in SelfSteal mode.

The inbound patch in `update-relay.sh` runs between `x-ui stop` and `x-ui start` — same window as the template write. This is safe because x-ui is stopped (no in-memory overwrite risk).

`update-relay.sh` also auto-updates CDN VLESS links in sub-proxy if active. It reads exit Reality params from the relay template, extracts CDN domain/path from the sub-proxy service file env vars (`CDN_DOMAIN`, `CDN_PATH`), regenerates both symmetric and asymmetric links, and rewrites the entire service file (not sed — `&` in URLs breaks sed replacements). For migration from pre-v1.4.0, it falls back to parsing the old VLESS URL if dedicated env vars are absent.

### Dest Format Convention

Callers pass the FULL dest value including port if needed. Functions use it as-is without appending `:443`:
- Auto mode: `dest="www.microsoft.com:443"` (port set in `reality.sh`)
- SelfSteal mode: `dest="/dev/shm/caddy.sock"` (no port for unix socket)

This affects `configure_xray_exit()`, `create_3xui_relay_inbound()`, and both update scripts.

### CDN Fallback

CDN Fallback adds an XHTTP inbound on exit (localhost-only, packet-up mode) and a Caddy route for the CDN domain. Cloudflare proxies HTTP traffic to exit:443 → Caddy → XRAY XHTTP inbound. All clients share one exit UUID on the CDN path. Both main and CDN inbounds include `extra` block with `xPaddingBytes` for traffic padding.

**Asymmetric mode**: upload goes through Cloudflare CDN, download bypasses CDN via Reality direct to exit (reuses the main XHTTP inbound). Configured via `downloadSettings` in the client's `extra` parameter. Both symmetric and asymmetric links are included in subscriptions.

**Sub-proxy** on relay intercepts subscription responses. For browser requests (`Accept: text/html`), it passes through 3X-UI's HTML page with QR codes. For app requests (base64), it appends CDN VLESS links (asymmetric first, then symmetric as fallback). Environment: `CDN_VLESS_LINK`, `CDN_VLESS_LINK_ASYM`, `CDN_DOMAIN`, `CDN_PATH`, `SUB_UPSTREAM`, `SUB_PROXY_PORT` (all with `%%` escaping for systemd where needed).

**Caddy CDN routing**: uses `@cdn path /CDN_PATH*` matcher to route CDN requests to the local XHTTP inbound. No WebSocket-specific matchers needed — XHTTP uses standard HTTP POST/GET.

**Caddy subscription routing**: in SelfSteal+CDN mode, Caddy proxies subscriptions to sub-proxy port (not directly to 3X-UI). Sub-proxy then proxies to 3X-UI and modifies the response.

**subURI**: 3X-UI setting that overrides the displayed subscription URL. Must include the full path with trailing content: `https://sub.domain/subPath/`. Without this, 3X-UI shows internal `http://127.0.0.1:port` links.

**Service file rewriting**: Never use `sed` to modify sub-proxy.service — `&` in VLESS URLs is a sed special character. Always rewrite the entire file via heredoc.

### Caddy Unix Socket Permissions

XRAY runs as `nobody` but Caddy creates `/dev/shm/caddy.sock` with mode `0600` (root-only). `start_caddy()` does `chmod 0666` after start so XRAY can connect to the socket for Reality dest forwarding.

### Hysteria 2 TLS Certificates

Hysteria 2 uses Caddy's Let's Encrypt certs, copied to `/etc/hysteria/certs/`. Hysteria runs as user `hysteria` (created by installer), so `cert.key` needs `root:hysteria` ownership and mode `0640`. `update-exit.sh` refreshes certs on every run (Caddy may have auto-renewed). Config is YAML, not JSON — written via heredoc, not jq.

### Hysteria 2 Port Hopping

Hysteria standalone natively supports listening on a port range (`listen: :PORT-PORT_END`). No iptables rules needed. Client URL includes the range: `hysteria2://...@host:port,port-port_end/...`. UFW opens the entire range as UDP: `ufw allow PORT:PORT_END/udp`.

### WARP Outbound для AI (issue #35, v1.10.0+)

Опциональный socks5-proxy на 127.0.0.1:40000 через `cloudflare-warp` пакет (apt, signed-by). XRAY роутит AI-домены (geosite: openai/anthropic/google-gemini/cursor) через WARP outbound; остальной трафик идёт через freedom как обычно. Domain rule prepended в `routing.rules` ПЕРЕД geoip:private — критично для корректного матчинга AI-доменов.

Lifecycle:
- Fresh install: `setup-exit` спрашивает Y/N (default N)
- Update preserve: `update-exit` детектит outbound `warp` в config, сохраняет состояние
- Enable existing: `update-exit --enable-warp` — установка + добавление в config + рестарт
- Disable existing: `update-exit --disable-warp` — выкидывает rule + outbound из config (warp-cli не сносит)
- Полный снос: `uninstall.sh --purge-warp` — apt purge + удаление apt repo + ключа

`lib/warp.sh` API повторяет паттерн `lib/hysteria.sh`: install / configure / restart / uninstall + is_warp_running helper.

Известные ограничения: WARP free пропускная способность ~100 Mbps, рандомный CF IP при рестарте warp-svc, зависимость от CF apt-репо при установке. WARP+ (платный, статический IP) не поддерживается — out of scope.

### Custom SSH Port

`setup_security()` accepts `--ssh-port PORT` flag. `setup_ssh_hardening()` modifies `sshd_config`, `setup_fail2ban()` configures the port in jail config, and UFW opens the custom port. Update scripts detect the current port via `grep '^Port ' /etc/ssh/sshd_config` with fallback to 22.

### Setup Guard

`setup-exit.sh` and `setup-relay.sh` check for existing configuration before running. If found, they refuse and suggest the update command instead. `--force` overrides the check for intentional full reinstall.

### Logging

All setup/update scripts wrap `main` with `tee` to `/var/log/vpn-setup-<script>-<timestamp>.log`. Exit code preserved via `PIPESTATUS[0]`.

### Selfcheck (issue #22, v1.10.0+)

`scripts/selfcheck.sh` — auto-detect role (exit/relay по `/usr/local/etc/xray/config.json` vs `/etc/x-ui/x-ui.db`) + extended verify. Запускается auto в конце setup-* / update-* (заменил собой `verify_exit_server` / `verify_relay_server` callsites). Manual: `./setup.sh selfcheck`. Exit code 1 если есть FAIL.

Три блока проверок:
1. **Local services** (через `lib/verify.sh`): xray/x-ui/caddy/hysteria/warp-svc/sub-proxy running, ports listening
2. **System resources** (через `lib/selfcheck.sh`): cert expiry (<14 days = WARN, <7 = FAIL), disk >10% free, RAM >100MB free
3. **Outside probes**: curl на собственный external IP (hairpin NAT) → должен вернуть selfsteal HTML; CDN external probe через Cloudflare если CDN_DOMAIN настроен. Hairpin не везде работает — graceful degrade на WARN, не FAIL.

`local -n` nameref-паттерн используется для accumulate $fails/$warns между функциями. Convention: helper checks возвращают 0=OK, 1=WARN, 2=FAIL.

Не реализовано (out of scope для v1.10.0): `--notify` (Telegram), `--cron` flag, log scanning, JSON output. Если понадобится cron — пользователь добавляет crontab напрямую.

### vpn CLI (issue #23, v1.10.0+)

`scripts/vpn` — bash-CLI на relay для add/list/link/remove клиентов 3X-UI. Симлинк `/usr/local/bin/vpn` ставится в `setup-relay` и `update-relay`, удаляется в `uninstall`.

Под капотом — паттерн `x-ui stop / sqlite3+jq / x-ui start` (как в `patch_3xui_relay_inbound`), `sync_cdn_clients()` после add/remove, auto-rollback по health check `:443` через `ss -tln` (логика идентична `update-relay.sh`).

Защита от сноса `default-user`: это seed-клиент, без него CDN sync ломается. Имена валидируются regex'ом `^[a-zA-Z0-9_-]{1,32}$`.

Read-only команды (`list`, `link`) не делают `x-ui stop` — конкурентность с админом в веб-панели не страшна (мы только читаем).

`get_subscription_prefix()` читает `subURI` из `settings` table (выставлен в SelfSteal+CDN режиме); fallback — конструирует `https://${subDomain or ifconfig.me}:${subPort}${subPath}` для plain-режима.

На exit-сервере (нет `/etc/x-ui/x-ui.db`) — error «for relay only» и exit 1. Симлинк там не ставится.

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
