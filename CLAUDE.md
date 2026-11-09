# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Two-server VPN deployment automation: relay (entry node) + exit (exit node) using VLESS + XTLS-Reality (XHTTP on relay client-facing inbound, RAW + xtls-rprx-vision on relay→exit and Direct Exit), relay managed via a 3X-UI panel, exit runs standalone XRAY (no panel since v1.13.0). Pure Bash scripts, no frameworks.

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

**Exit server**: XRAY runs as systemd service, config in `/usr/local/etc/xray/config.json`. No 3X-UI (since v1.13.0, issue #40) — older setups installed a decorative panel there (no inbounds, its own xray copy); `update-exit` removes it (see "Exit: no 3X-UI" below).
**Relay server**: 3X-UI manages its own XRAY process, config stored in SQLite at `/etc/x-ui/x-ui.db`. In SelfSteal mode the panel and the subscription server listen on 127.0.0.1 only and are reached through Caddy (panel/sub domains); their ports are not opened in UFW.

Setup order is always exit first, then relay (relay needs exit server's keys/UUID).

### Subscription Channels (full SelfSteal + CDN + Hysteria deployment)

A client subscription emits up to 5 channels. All share one UUID. Generation:
- **Channel 1** (Relay) is rendered by 3X-UI's subscription generator from the relay inbound. Sub-proxy merges `RELAY_XHTTP_EXTRA` env into the link's `extra=` (`patch_relay_vless()`): 3X-UI v2.x emitted no `extra`, v3.x emits only `extra={"mode":"auto"}` + top-level `mode` + empty `host=`. Our keys win, `mode` is kept only top-level (xray-core `SplitHTTPConfig.Build()` overwrites `extra.mode` with it anyway), empty `host=` is dropped (issue #49).
- **Channels 2-5** are appended by sub-proxy from systemd env vars (`DIRECT_VLESS_LINK`, `CDN_VLESS_LINK_ASYM`, `CDN_VLESS_LINK`, `HYSTERIA_LINK`).

| # | Channel | Client connects to | Wire protocol | Server-side path |
|---|---|---|---|---|
| 1 | Relay (main) | `relay_domain:443` | VLESS Reality **XHTTP** (mode=auto), SelfSteal SNI | Relay XHTTP inbound → fragment → proxy-exit (Reality RAW+Vision) → exit:443 main inbound |
| 2 | Direct Exit | `exit_ip:443` | VLESS Reality **RAW + xtls-rprx-vision**, sni=`exit_domain` | Exit main inbound directly (skips relay) |
| 3 | CDN Asymmetric | Upload: `cdn_domain:443` (Cloudflare). Download: `exit_ip:443` direct | Upload — VLESS XHTTP packet-up via CF. Download — Reality RAW+Vision direct (via `downloadSettings` in `extra`) | Upload → Caddy → exit's local XHTTP inbound (127.0.0.1:cdn_port). Download → exit main RAW+Vision inbound |
| 4 | CDN Symmetric | `cdn_domain:443` (Cloudflare both ways) | VLESS XHTTP packet-up | Cloudflare → exit:443 → Caddy unix socket → exit's local XHTTP inbound |
| 5 | Hysteria 2 | `exit_ip:hysteria_port` (UDP, port-hopping range) | Hysteria 2 + Salamander obfs, password = exit UUID | Standalone hysteria-server, separate from XRAY |

**Critical invariant**: exit's main inbound is **Reality RAW + xtls-rprx-vision** (since v1.10.0, not XHTTP). Channels 1, 2, and 3-download all terminate on this single inbound. Channel 1 reaches it via relay's `proxy-exit` outbound; channel 2 reaches it directly; channel 3-download reaches it via the client's secondary connection per `downloadSettings`. Exit's XHTTP inbound exists only for CDN traffic and listens on 127.0.0.1.

**Exit-side routing** (applies to all 5 channels uniformly): AI domains (geosite: openai/anthropic/google-gemini/cursor) → WARP outbound (socks5 127.0.0.1:40000) when WARP enabled; geoip:private → block; rest → freedom (UseIP).

## Entry Points

- `scripts/setup.sh` — router: delegates to setup/update/uninstall scripts. Passes extra args (`--force`, `--upgrade`)
- `scripts/setup-exit.sh` — exit server orchestration. Refuses to run if already configured (use `--force` to override)
- `scripts/setup-relay.sh` — relay server orchestration (complex, DB-driven). Same `--force` guard
- `scripts/update-exit.sh` — update exit config from latest codebase, preserving keys/UUID. `--upgrade` to update binaries (XRAY, Caddy, Hysteria). Removes a leftover 3X-UI panel; `--keep-3xui` skips that, `--purge-3xui` removes it even if it has inbounds
- `scripts/update-relay.sh` — update relay template + patch inbound sniffing, preserving clients. `--upgrade` to update 3X-UI
- `scripts/uninstall.sh` — teardown with `--force` and `--purge-certs` flags

## Library Modules (`scripts/lib/`)

All sourced via `BASH_SOURCE` from orchestration scripts:

- `common.sh` — logging (`log_info/ok/warn/error`), `prompt_input`, `prompt_password`, validation (`validate_domain`, `check_domain_dns`), random generation, `PROJECT_VERSION` from `VERSION` file, `XUI_VERSION` (3X-UI pin) + `xui_installed_version`, `apt_update_retry`
- `security.sh` — SSH hardening (custom port support), UFW, fail2ban
- `caddy.sh` — Caddy installation, Caddyfile generation, static site content, systemd dependency, sub-proxy setup, uninstall (SelfSteal mode only)
- `reality.sh` — Reality key generation, destination site selection
- `xray.sh` — XRAY installation, exit server JSON config (including optional CDN XHTTP inbound with padding)
- `3xui.sh` — 3X-UI install/configure (relay), SQLite operations, SSL certs, inbound/template management, `purge_3xui_panel` (exit-side legacy teardown), `xui_bind_loopback` (SelfSteal relay); UFW cleanup via `close_xui_ufw_ports` in `security.sh`
- `verify.sh` — post-setup smoke tests (services, ports, connectivity)
- `hysteria.sh` — Hysteria 2 installation, YAML config generation, cert copy from Caddy, restart, uninstall
- `xui-api.sh` — 3X-UI v3.x REST API client (Bearer token; SHA-256 of it in `api_tokens` on v3.3.1+, plaintext bootstrapped to `/etc/vpn-cli/api-token`): inbound + client create/delete/list. Used by setup-relay/update-relay/vpn/selfcheck. `settings`/`xrayTemplateConfig` stay on DB-write. Token and request body never go on curl's argv (visible in `ps`/`/proc/*/cmdline`): the `Authorization` header is fed as curl config on stdin (`-K -` + here-string), the JSON body via `--data-binary @<(printf …)`. Don't add a second stdin consumer to that curl.
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

**v3.x (since 1.11.0):** client/inbound *writes* go through the REST API (`lib/xui-api.sh`, Bearer token, CSRF-exempt `/panel/api/*`) so they populate v3's normalized `clients`+`client_inbounds` tables (the subscription server reads those — raw JSON-only writes 404, issue #44). The `x-ui stop`/`start` window is now used only for `settings`/`xrayTemplateConfig` DB-writes, `bootstrap_api_token` and `revoke_installer_api_tokens`. Reads (`vpn list/link`, selfcheck) read the normalized `clients` table directly.

**API token storage (v3.3.1+, pinned v3.11.0):** `api_tokens.token` holds SHA-256(plaintext) — the panel hashes the presented Bearer and compares. `/etc/vpn-cli/api-token` keeps the plaintext. `bootstrap_api_token` decides plaintext vs hash by the `ApiTokensHash` row in `history_of_seeders` and sets `scope='admin'`/`expires_at=0` only if those columns exist, so it works on both v3.1.0 and v3.11.0 DBs. It runs on every update-relay (after `--upgrade` too) and re-issues the token if the row doesn't match — this is what repairs relays upgraded from v3.1.0.

**Installer tokens (relay):** install.sh v3.11 mints admin tokens `install` (fresh DB) / `cli-fallback` (re-run that resets default creds), prints them to stdout (= our log) and writes `/etc/x-ui/install-result.env`. `revoke_installer_api_tokens` (`3xui.sh`, DB-write → inside the stop/start window) deletes exactly those names; called from `configure_3xui` (setup-relay) and update-relay's Step 5 window. `run_3xui_installer` deletes `install-result.env` right after the run. (The exit-side Step 4b of v1.12 is gone together with the exit panel.)

### 3X-UI Inbound Normalization

> **Obsolete since 1.11.0 (v3.x migration).** The two-restart insert→strip→patch cycle below applied to the v2.x raw-sqlite INSERT path. On v3.x the relay inbound is created via `POST /panel/api/inbounds/add`, which persists `realitySettings`/`subId` verbatim and live-injects into xray — no field stripping, no double-restart, and `patch_3xui_relay_inbound` was removed. The historical description is kept below for context.

After INSERT into `inbounds` table, 3X-UI strips fields on first restart: `subId`, `realitySettings.settings` (publicKey/fingerprint). The workaround is a two-restart cycle:

1. Insert full inbound → restart (3X-UI normalizes/strips)
2. Patch stripped fields back with `jq` → restart (xray picks up patched config)

See `patch_3xui_relay_inbound()` and `create_3xui_relay_inbound()` in `3xui.sh`.

### 3X-UI Template Stripping

3X-UI can strip `api`/`stats`/`policy` from `xrayTemplateConfig` if it starts without the template loaded. Always write the template to DB **before** restarting, never after.

### Interactive Installer Workarounds

- **3X-UI installer** (pinned `XUI_VERSION=v3.11.0` in `common.sh`, install.sh from the same tag): always via `run_3xui_installer`, which downloads install.sh with `curl -fsSL --retry 3` into a mktemp file (empty → abort), runs `bash "$tmp" "$XUI_VERSION"`, and afterwards requires `/usr/local/x-ui/x-ui -v` (prints bare `3.11.0`) == `XUI_VERSION` — mismatch → exit 1. No port-80 opening around it any more (SSL none → no ACME). Env: `XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite XUI_ENABLE_FAIL2BAN=false XUI_SERVER_IP=… < /dev/null`. Since v3.6.0 install.sh replaces every prompt with env/defaults in non-interactive mode, so the old answers file (`/tmp/xui-answers`) is gone. `XUI_ENABLE_FAIL2BAN=false` keeps the installer from rewriting our fail2ban config (IP Limit jail + global `backend=systemd`). `XUI_SERVER_IP` replaces the "enter your IPv4" loop when IP detection fails (issue #52).
- **XRAY installer**: Redirect `< /dev/null` to prevent stdin consumption from piped input.

### SSL Certificate Caching

`issue_domain_cert()` checks for existing valid cert before calling acme.sh. Without `--force`, acme.sh also checks its own cache. Uninstall preserves certs by default (`--purge-certs` to remove). This avoids Let's Encrypt rate limits (5 duplicate certs per 168h per domain set).

`cleanup_acme_panel_leftovers` (`common.sh`; called by `purge_3xui_panel` and by uninstall without `--purge-certs`) removes what 3X-UI's installer left for the panel: IP-named acme.sh certs (short-lived LE IP certs) + `/root/cert/ip`, and the acme.sh cron only if no other cert is left — a plain relay's domain cert keeps renewing. Never call it while a panel may still use `/root/cert/ip`.

### Synchronous Migration: Vision Replaces XHTTP on Exit (v1.10.0+)

Exit's main inbound and relay's `proxy-exit` outbound must be on the same transport: either both XHTTP (≤v1.9.x) or both RAW + xtls-rprx-vision (v1.10.0+). Cannot mix.

`update-exit` migrates the exit inbound; `update-relay` migrates the relay outbound and regenerates sub-proxy URLs (Direct Exit + CDN asymmetric downloadSettings switch to `type=raw&flow=xtls-rprx-vision`). Update order: **exit first, then relay**. ~30s window of broken connectivity for relay-routed clients between the two updates. Direct Exit URLs cached in client subscriptions also break until subscription refresh.

Idempotency: re-running update-* on an already-migrated config is a no-op (jq detection on `xhttpSettings` field). Relay client-facing inbound stays XHTTP. CDN packet-up XHTTP inbound (localhost) stays XHTTP — Cloudflare requires HTTP. Hysteria 2 unaffected.

### Exit: no 3X-UI (v1.13.0+, issue #40)

The exit panel never carried traffic (all channels terminate on standalone `xray.service` or `hysteria-server`) and, with the installer on SSL none, served a plain-HTTP admin login on a public port. Fresh `setup-exit` doesn't install it (no panel port in UFW, no panel URL/credentials in the banner or `exit-server-info.txt`); a `--force` re-run on an old box removes a leftover one.

`update-exit` (Step 2a, before `--upgrade`) calls `purge_3xui_panel` when `xui_panel_installed` — manual teardown, **not** `x-ui uninstall` (interactive, "xray will also uninstalled", deletes itself): read `webPort`, `systemctl stop/disable x-ui`, back up the DB (`sqlite3 .backup`, folds in the WAL) to `/root/x-ui-exit-backup-<ts>.db` (0600), remove the unit + `x-ui.service.d` + wants-link, `/usr/local/x-ui`, `/etc/x-ui`, `/var/log/x-ui`, `/usr/bin/x-ui`, `/etc/default/x-ui`, the IP Limit fail2ban files `3x-ipl*.conf` if present; close UFW `webPort/tcp` plus any rule commented `3X-UI Panel` (never 80/443/SSH); then confirm xray/caddy/hysteria are still active. Never touches `/usr/local/bin/xray`, `/usr/local/etc/xray`, `/var/log/xray` — the panel runs its own xray from `/usr/local/x-ui/bin`. Idempotent (no panel → no-op, no new backup).

`purge_3xui_panel` refuses on a relay (`/etc/vpn-cli/api-token` present or system `xray` not enabled) and skips an exit panel that has inbounds of its own unless `--purge-3xui` (setup-exit `--force` always purges). UFW cleanup goes through `close_xui_ufw_ports` (security.sh): given ports + every rule commented `3X-UI Panel`, never 22/80/443/SSH — shared with setup-relay/update-relay in SelfSteal. `update-exit --keep-3xui` leaves the panel exactly as is: not upgraded, not checked by selfcheck, its UFW rule stays (setup_ufw only adds rules). A later plain `update-exit` removes it. `uninstall.sh` still removes a panel if one is there (both roles).

### Relay SelfSteal: panel on loopback (v1.13.0+, issue #40)

`xui_bind_loopback [with-sub]` sets `webListen` (and `subListen` only with `with-sub`, i.e. when a subscription domain exists and Caddy proxies it — otherwise an admin may serve subs from IP:subPort) = `127.0.0.1` (DB-write → inside the stop/start window): setup-relay's SelfSteal window and update-relay's Step 5 window (SelfSteal only). Caddy (`reverse_proxy 127.0.0.1:<port>`), sub-proxy (`SUB_UPSTREAM=http://127.0.0.1:<sub_port>`) and `xui-api.sh` (`http://127.0.0.1:webPort`) already use loopback; `vpn` builds links from `subURI`. update-relay in SelfSteal no longer passes `panel_port`/`sub_port` to `setup_security` and runs `close_xui_ufw_ports` (webPort, subPort only when `subDomain` is set, plus `3X-UI Panel`-labelled rules; setup-relay does the same in SelfSteal for `--force` over old installs) — relays set up before v1.13.0 had `panel_port` re-opened on every update. Non-SelfSteal relay: unchanged (panel + sub ports open, cert from `issue_domain_cert`).

### Update Scripts

`update-exit.sh` reads current keys/UUID/dest/xver from XRAY config, regenerates config via `configure_xray_exit()`, restarts. `update-relay.sh` reads current exit params from DB, patches inbound sniffing (routeOnly) via jq, auto-migrates TCP relay inbound to XHTTP if still on TCP (generates random path, patches stream_settings via jq), regenerates template via `configure_3xui_relay_template()`, restarts. Both create timestamped backups and auto-rollback on failure.

3X-UI v3.11 keeps `x-ui.db` in SQLite **WAL** mode, so never `cp` the live DB and never restore without clearing the WAL. `xui_db_backup` (`3xui.sh`) takes the snapshot with `sqlite3 .backup` (consistent while the panel runs; fallback: `x-ui stop` → retry `.backup` → else `wal_checkpoint(TRUNCATE)` + `cp` → `x-ui start`; `x-ui stop` does NOT empty the `-wal`), switches the copy to `journal_mode=DELETE` (one self-contained file), sets 0600 and requires `integrity_check = ok` or exits. `xui_db_restore` stops x-ui (refuses if it is still active — its shutdown flush would overwrite the restore), removes `x-ui.db-wal`/`-shm`/`-journal` (otherwise sqlite replays post-backup frames on top), copies the backup in; the caller starts x-ui. update-relay takes the backup after the "DB exists" check (sqlite3 would create an empty DB at a missing path).

Both update scripts detect SelfSteal mode (by checking if `dest` contains `caddy.sock`) and preserve it. They also detect the current SSH port (`detect_ssh_port`, effective value from `sshd -T`) and pass it through to `setup_security`. With `--upgrade`, Caddy is also updated in SelfSteal mode.

The inbound patch in `update-relay.sh` runs between `x-ui stop` and `x-ui start` — same window as the template write. This is safe because x-ui is stopped (no in-memory overwrite risk).

`update-relay.sh` also auto-updates CDN VLESS links in sub-proxy if active. It reads exit Reality params from the relay template, reads CDN domain/path etc. via `sub_proxy_env_get` (`caddy.sh`: the env file, or `Environment=` lines of a pre-v1.13.1 unit with `%%` unescaped), regenerates both symmetric and asymmetric links, and rewrites the env file and the unit entirely (not sed — `&` in URLs breaks sed replacements). Backup of both goes to a `mktemp -d /run/vpn-sub-proxy.*` dir (restored if sub-proxy doesn't come up); after success the old world-readable `sub-proxy.service.bak.*` are deleted. For migration from pre-v1.4.0, it falls back to parsing the old VLESS URL if dedicated env vars are absent.

After the rollback point update-relay keeps the last 5 `x-ui.db.bak.*` (with their `.api-token` siblings) and update-exit the last 5 `config.json.bak.*` (`prune_backups`, `common.sh`).

### Dest Format Convention

Callers pass the FULL dest value including port if needed. Functions use it as-is without appending `:443`:
- Auto mode: `dest="www.microsoft.com:443"` (port set in `reality.sh`)
- SelfSteal mode: `dest="/dev/shm/caddy.sock"` (no port for unix socket)

This affects `configure_xray_exit()`, `create_3xui_relay_inbound()`, and both update scripts.

### CDN Fallback

CDN Fallback adds an XHTTP inbound on exit (localhost-only, packet-up mode) and a Caddy route for the CDN domain. Cloudflare proxies HTTP traffic to exit:443 → Caddy → XRAY XHTTP inbound. All clients share one exit UUID on the CDN path. Both main and CDN inbounds include `extra` block with `xPaddingBytes` for traffic padding.

**Asymmetric mode**: upload goes through Cloudflare CDN, download bypasses CDN via Reality direct to exit (reuses the main XHTTP inbound). Configured via `downloadSettings` in the client's `extra` parameter. Both symmetric and asymmetric links are included in subscriptions.

**Sub-proxy** on relay intercepts subscription responses. For browser requests (`Accept: text/html`), it passes through 3X-UI's HTML page with QR codes. For app requests (base64), it appends CDN VLESS links (asymmetric first, then symmetric as fallback). Environment: `CDN_VLESS_LINK`, `CDN_VLESS_LINK_ASYM`, `DIRECT_VLESS_LINK`, `HYSTERIA_*`, `CDN_DOMAIN`, `CDN_PATH`, `RELAY_XHTTP_EXTRA`, `SUB_UPSTREAM`, `SUB_PROXY_PORT` — in `/etc/sub-proxy/sub-proxy.env` (0600, `EnvironmentFile=`; since v1.13.1, #61). The links carry the exit UUID / obfs password; the 0644 unit holds no secrets (`Environment=` there was readable by everyone, also via `systemctl show`). Written by `write_sub_proxy_env` (atomic, single-quoted values, refuses `'` `\` newline) + `write_sub_proxy_unit`. No `%%` escaping: specifiers are expanded in unit files, not in EnvironmentFile content.

**Caddy CDN routing**: uses `@cdn path /CDN_PATH*` matcher to route CDN requests to the local XHTTP inbound. No WebSocket-specific matchers needed — XHTTP uses standard HTTP POST/GET.

**Caddy subscription routing**: in SelfSteal+CDN mode, Caddy proxies subscriptions to sub-proxy port (not directly to 3X-UI). Sub-proxy then proxies to 3X-UI and modifies the response.

**subURI**: 3X-UI setting that overrides the displayed subscription URL. Must include the full path with trailing content: `https://sub.domain/subPath/`. Without this, 3X-UI shows internal `http://127.0.0.1:port` links.

**Service file rewriting**: Never use `sed` to modify sub-proxy.env / sub-proxy.service — `&` in VLESS URLs is a sed special character. Always rewrite the entire file (`write_sub_proxy_env` / `write_sub_proxy_unit`).

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

### Private Exit IP: freedom finalRules (#59)

xray-core 26.10+ (3X-UI v3.11 ships 26.10.x): a freedom outbound blocks private destinations by default when the connection came from a vless/vmess/trojan/ss/hysteria inbound (`geodata.GetPrivateIPMatcher`: RFC1918, 100.64/10, loopback, link-local, 198.18/15, doc ranges, multicast, 240/4). Relay's `proxy-exit` dials the exit via `dialerProxy: fragment` — a freedom outbound, the final hop — so a private/CGNAT `EXIT_IP` (relay and exit in one provider network) silently fails.

`configure_3xui_relay_template` (both setup-relay and update-relay; update re-reads `exit_ip` from `proxy-exit` in the DB template) checks `is_private_ipv4` (`common.sh`, mirrors xray's IPv4 list) and, if private, adds `fragment.settings.finalRules = [{action:"allow", ip:["<EXIT_IP>"]}]` — only that IP; finalRules match before the default block, so all other private targets stay blocked — plus a WARN (Direct Exit / CDN asym / Hysteria links also carry the private IP and are unreachable for outside clients). Public exit IP → no `finalRules` (template unchanged). Notes:
- The rule goes on `fragment`, never on `proxy-exit`: xray ignores `finalRules` on a freedom outbound that itself has `sockopt.dialerProxy`.
- 3X-UI v3.11 seeder `FreedomFinalRulesPrivateEgressBlock` (one-shot) rewrites freedom outbounds whose finalRules are absent/empty/`[{action:allow}]`/legacy `[{allow, geoip:private}]` to `[block geoip:private, allow]`. Our rule has an `ip` key → not touched. On a public-IP relay it may rewrite `direct`/`fragment` to the explicit equivalent of the default — harmless.
- Rendered runtime config is `/usr/local/x-ui/bin/config.json`; 3X-UI redirects xray logs to `/var/log/x-ui/{access,error}.log` (the template's `/var/log/xray/*` paths are overridden). The symptom may show as `proxy/freedom: blocked target` in the error log; in Docker E2E on 26.10.21 at loglevel warning it did not appear — the reliable signal is relay access log `inbound-443 -> proxy-exit` with nothing arriving on exit.
- Docker E2E (exit on a docker network IP) is exactly this case.

### Custom SSH Port

`setup_security()` accepts `--ssh-port PORT` flag. `setup_ssh_hardening()` writes the sshd settings, `setup_fail2ban()` configures the port in jail config, and UFW opens the custom port. Update scripts (and the hardening rollback) detect the current port via `detect_ssh_port` (`security.sh`): first `port` of `sshd -T`, fallback to our drop-in, then `^Port` in `sshd_config`, then 22.

**sshd_config.d (#57):** Ubuntu/Debian put `Include /etc/ssh/sshd_config.d/*.conf` at the top of `sshd_config` and sshd keeps the first value it reads, so a provider's `50-cloud-init.conf` with `PasswordAuthentication yes` beat edits in the main file. Settings now go to `/etc/ssh/sshd_config.d/00-vpn-hardening.conf` (sorts first): `Port`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`, `PermitRootLogin prohibit-password`. The main file is still sed-edited for the auth options (authoritative when there is no Include, older Debian; we never prepend an Include ourselves — that would pull unknown drop-ins in). `Port` is cumulative (each line adds a listener), so it lives in exactly one place: all `Port` lines are removed from the main file (also cleans up the line ≤v1.12 appended), and it goes into the drop-in if the Include exists, else into the main file.

**UFW / fail2ban (#58):** after `setup_ufw`, `prune_stale_ssh_ufw_rules` deletes our own SSH rules (comment exactly `SSH` / `SSH-fallback`, read from `ufw show added`) on ports other than the current SSH port (+22 in fallback mode) — only if sshd is confirmed listening on the SSH port, and never for a port sshd still listens on. Rules with other comments are the admin's and stay. In fallback mode (sshd still on 22) the fail2ban `[sshd]` jail gets `port = <ssh_port>,22`.

`setup_ssh_hardening()` sequence (v1.12.0+, #54):
1. Backup `sshd_config` (and our drop-in, if present) into a `mktemp -d /run/vpn-ssh-hardening.*` dir (tmpfs — no leftovers in `/etc/ssh` if interrupted), edit it + write the drop-in, then `sshd -t` (after `install -d /run/sshd`), then `sshd -T` must show `passwordauthentication no`, `kbdinteractiveauthentication no` (a password path too under `UsePAM yes`), `permitrootlogin` without-password/prohibit-password/no and the expected port among the `port` lines (extra ports → WARN); the error names the sshd_config.d file that overrides it. From the backup until that check passes a `trap … INT HUP TERM` puts the files back (an interrupted edit could otherwise leave no custom Port while the /run backup is lost on reboot). In update-* (`setup_security --soft-ssh`) a mismatch restores the files and continues WITHOUT hardening with a WARN instead of `exit 1` — XRAY is already reconfigured by then; setup-* keep the fatal exit. `sshd -T` without `-C` does not evaluate `Match` blocks — `_ssh_warn_match_overrides` scans `sshd_config` + `sshd_config.d/*.conf` for Match blocks setting PasswordAuthentication/KbdInteractiveAuthentication/ChallengeResponseAuthentication/PermitRootLogin `yes` and WARNs with the file (never fatal: our drop-in can't override a Match block). sshd -T only reads files, so this is checked before the restart. Invalid config or mismatch → restore `sshd_config` + drop-in (restored on re-runs, removed on first run), **no restart**, exit 1.
2. If `ssh.socket` is active/enabled (Ubuntu 22.10+/24.04 socket activation — sshd ignores `Port` there): record socket active/enabled + `ssh.service` enabled, remove the migration drop-ins `ssh.service.d/00-socket.conf` (adds `Wants=ssh.socket` — without removal `systemctl restart ssh` brings the socket back) and `ssh.socket.d/addresses.conf` (backed up), `daemon-reload`, `disable --now` + **`mask`** `ssh.socket`, `enable ssh`. Any failure → rollback. To return to socket activation manually: `systemctl unmask ssh.socket && systemctl disable ssh && systemctl enable --now ssh.socket`.
3. `restart ssh`, wait for **sshd** (not the socket) on the port. Not bound → rollback: restore config + our sshd drop-in + socket drop-ins, unmask, restore `ssh.service` enablement, stop sshd (sessions survive, `KillMode=process`), re-enable/start the socket as it was. UFW is never touched before this succeeds.

### Setup Guard

`setup-exit.sh` and `setup-relay.sh` check for existing configuration before running. If found, they refuse and suggest the update command instead. `--force` overrides the check for intentional full reinstall.

### Logging

All setup/update scripts wrap `main` with `tee` to `/var/log/vpn-setup-<script>-<timestamp>.log`. Exit code preserved via `PIPESTATUS[0]`. The log is pre-created `install -m 0600 /dev/null "$LOG_FILE"` before `tee` (all four scripts) — on relay it captures 3X-UI installer output with credentials.

### apt

Every `apt-get update` in `scripts/` goes through `apt_update_retry` (common.sh): up to 30 × 10s, because `DPkg::Lock::Timeout` (written by `configure_apt_lock_timeout`) covers only the dpkg lock, not `/var/lib/apt/lists/lock` held by apt-daily on a fresh VM. Never chain `apt-get update && apt-get …` — set -e ignores a failure in a non-final element of `&&`.

### Selfcheck (issue #22, v1.10.0+)

`scripts/selfcheck.sh` — auto-detect role (exit/relay по `/usr/local/etc/xray/config.json` vs `/etc/x-ui/x-ui.db`) + extended verify. Запускается auto в конце setup-* / update-* (заменил собой `verify_exit_server` / `verify_relay_server` callsites). Manual: `./setup.sh selfcheck`. Exit code 1 если есть FAIL.

Три блока проверок:
1. **Local services** (через `lib/verify.sh`): xray (exit) / x-ui (relay) / caddy/hysteria/warp-svc/sub-proxy running, ports listening (TCP + Hysteria UDP; `verify_port_listening` использует фильтр `ss -H "sport = :PORT"`, не `ss | grep -q` — SIGPIPE под pipefail давал ложный FAIL). Плюс `check_xui_loopback` (только SelfSteal relay, #61): `webListen` и, при `subDomain`, `subListen` в БД = `127.0.0.1` и живой сокет порта только на loopback, иначе WARN с подсказкой `update-relay`. Плюс `check_xui_version` (только relay): 3X-UI старше `XUI_VERSION` → WARN с подсказкой `update-relay --upgrade`. На exit x-ui не проверяется (с v1.13.0 его там нет)
2. **System resources** (через `lib/selfcheck.sh`): cert expiry (<14 days = WARN, <7 = FAIL), disk >10% free, RAM >100MB free
3. **Outside probes**: curl на собственный external IP (hairpin NAT) → должен вернуть selfsteal HTML; CDN external probe через Cloudflare если CDN_DOMAIN настроен. Hairpin не везде работает — graceful degrade на WARN, не FAIL.

`local -n` nameref-паттерн используется для accumulate $fails/$warns между функциями. Convention: helper checks возвращают 0=OK, 1=WARN, 2=FAIL.

Не реализовано (out of scope для v1.10.0): `--notify` (Telegram), `--cron` flag, log scanning, JSON output. Если понадобится cron — пользователь добавляет crontab напрямую.

### vpn CLI (issue #23, v1.10.0+)

`scripts/vpn` — bash-CLI на relay для add/list/link/remove клиентов 3X-UI. Симлинк `/usr/local/bin/vpn` ставится в `setup-relay` и `update-relay`, удаляется в `uninstall`.

Под капотом — паттерн `x-ui stop / sqlite3+jq / x-ui start` (как в `patch_3xui_relay_inbound`), `sync_cdn_clients()` после add/remove, auto-rollback по health check `:443` через `ss -tln` (логика идентична `update-relay.sh`).

Защита от сноса `default-user`: это seed-клиент, без него CDN sync ломается. Имена валидируются regex'ом `^[a-zA-Z0-9_-]{1,32}$`.

Read-only команды (`list`, `link`) не делают `x-ui stop` — конкурентность с админом в веб-панели не страшна (мы только читаем).

`get_subscription_prefix()` читает `subURI` из `settings` table (выставлен в SelfSteal+CDN режиме); fallback — конструирует `https://${subDomain}:${subPort}${subPath}` для plain-режима с доменом. Без домена (setup-relay подписку не включает) — молча `return 1`, без ifconfig.me. Вызывающие печатают `print_no_subscription_hint` в stderr: `vpn link` → exit 1, `vpn add` → клиент создан, warn, exit 0 (#59).

stdout-контракт: всё, что забирается в `$(...)` (`get_subscription_prefix`, `xui_api_request` и обёртки `xui_api_*` в `lib/xui-api.sh`), логирует только в stderr — `log_*` пишут в stdout, иначе ошибка попадает в захваченное значение (и в `jq`). Setup/update делают `main 2>&1 | tee`, так что в лог stderr всё равно попадает.

`vpn list` выравнивает таблицу `printf '%-*s'` по посчитанным ширинам — без `column` (пакет `bsdextrautils`, нет на минимальном Ubuntu 24.04, #59).

На exit-сервере (нет `/etc/x-ui/x-ui.db`) — error «for relay only» и exit 1. Симлинк там не ставится.

CLI и веб-панель работают двунаправленно: добавил клиента в панели — `vpn list/link` видит сразу, и наоборот (3X-UI persist'ит каждое UI-изменение в БД синхронно). `x-ui stop/start` обёртка нужна только для writes, чтобы in-memory копия не перезатёрла наш UPDATE.

Persistent backup в `/var/lib/vpn-cli/backup-<op>-<ts>.json` пишется перед каждым DB-mutation и удаляется при успехе. При rollback'е (xray не поднялся) или Ctrl-C между stop/start — файл остаётся как safety net для ручного восстановления. Health-check 15×1s + `pgrep -f 'xray.*x-ui'` — xray внутри 3X-UI стартует медленнее самого x-ui.

Symlink-хелпер `install_vpn_cli_symlink()` в `lib/3xui.sh` — отказывается перезаписывать чужой не-симлинк в `/usr/local/bin/vpn`.

### Share page (issue #21, v1.10.0+)

Sub-proxy на relay отдаёт HTML share-page при `Accept: text/html` на запрос `/<subPath>/<subId>`. Тот же URL обслуживает и subscription для приложений (`Accept: */*` → base64 со списком VLESS/Hysteria URL'ов). Один URL на оба use-case'а — `subId` уже непредсказуемый, отдельный токен/Caddy-роут не нужен.

Шаблон `scripts/lib/templates/share-page.html` ставится в `/etc/sub-proxy/share-page.html` через `setup_sub_proxy()` в `lib/caddy.sh`. Lazy-load в sub-proxy.py с negative-cache (если шаблон не нашёлся — passthrough в 3X-UI HTML, не повторять чтение).

Пять плейсхолдеров с разным экранированием: `{{SUBSCRIPTION_URL_HTML}}` (html.escape для `<input value=...>`), `{{SUBSCRIPTION_URL_JSON}}` (json.dumps для JS-литерала), `{{HAPP_DEEPLINK}}` / `{{V2RAYTUN_DEEPLINK}}` / `{{SHADOWROCKET_DEEPLINK}}` (готовые URL для href).

QR генерится клиентом — vendored qrcode-generator (Kazuhiko Arase, MIT, ~10 KB minified). Никаких внешних ресурсов: фонтов, CDN, сторонних JS — страница работает без сети после первой загрузки.

Detection: regex `^/[^/]+/([a-fA-F0-9]{8,32})/?$` на `parsed.path` (без query/fragment) + `text/html` в Accept. Не-subscription пути (`/health`, `/<subPath>/` без ID) — не перехватываются, passthrough в 3X-UI.

Ограничения regex'а:
- subPath single-segment (`[^/]+`) — multi-segment subPath (типа `sub/v2`) не поддерживается. На практике 3X-UI генерит single-segment subPath, и менять его руками маловероятно.
- subId 8-32 hex chars. До v1.10.0 (включительно #23) генерили 16 hex (8 random bytes), regex покрывает.

Shadowrocket Module и .sgmodule по-прежнему доступны через query-параметр `?module=ru` (sub-proxy обрабатывает его до share-page-ветки) — admin/power-user URL: `https://sub.domain/anything?module=ru`. Это намеренно: share-page для нетехнического end-user'а, split-routing для админа.

Security headers (anti-leak `subId`): `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `X-Robots-Tag: noindex, nofollow`. Плюс `<meta name="robots" content="noindex,nofollow">` и `<meta name="referrer" content="no-referrer">` в HTML.

HEAD-метод: `BaseHTTPRequestHandler` НЕ подавляет body для HEAD автоматически. В share-page-ветке headers шлются всегда, body — только если `command != "HEAD"`.

### Versioning

`VERSION` file in repo root is the single source of truth. `common.sh` reads it into `PROJECT_VERSION`. All scripts display version in their banner. Bump version only when script behavior changes (not for docs/README changes).

## Code Conventions

- `set -euo pipefail` in all lib scripts
- Functions and variables: `snake_case`; exported/environment: `UPPER_CASE`
- All function params declared `local` at top of function body
- SQL string escaping: `xui_db_set()` handles it internally; direct `sqlite3` calls use `${var//\'/\'\'}`
- JSON building: `jq -n -c`; string values via `--rawfile k <(printf '%s' "$v")`, numbers/non-secret JSON via `--argjson`
- Secrets (UUIDs, subIds, keys, tokens, links) never on a child's argv — `/proc/*/cmdline` is world-readable. `printf` is a builtin (no exec): jq `--rawfile <(printf …)`, SQL on sqlite3 stdin (`sqlite3 "$XUI_DB" <<< "$sql"`), `url_quote` (python via stdin), `reality_public_key_from_private` (openssl via stdin, not `xray x25519 -i`). Known exception: `x-ui setting -password` in `configure_3xui` (3X-UI's own CLI, setup only)
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

## Working Practices

### Discuss vs act

Phrases like "давай X", "давай усовершенствуем Y", "можем Z", "стоит ли", "что думаешь", "let's do X", "could we Z", "what do you think" are **discussion/planning**, not a command to edit code. Before touching code, require either an explicit go-ahead ("правь", "делай", "вперёд", "фикс", "go", "do it", "ship it") or present the proposed diff as text and ask "apply?".

This applies extra strictly to infra operations (deploy, ssh, push) — explicit confirmation is required there in any case, even with command verbs.

### Deploy: git pull + restart is not enough

`setup-*` / `update-*` scripts copy files from `~/vless-relay-setup/scripts/lib/` into system paths (`/usr/local/bin/sub-proxy.py`, `/etc/sub-proxy/share-page.html`, `/etc/caddy/Caddyfile`, `/etc/hysteria/config.yaml`, `/usr/local/bin/vpn`). `git pull && systemctl restart` only updates the checkout — files are not copied into system locations and the service keeps running the old code.

If you edited `scripts/lib/sub-proxy.py` / `scripts/lib/templates/*` / `scripts/vpn`, or any `lib/*.sh` function that performs install/chmod/template-rendering, deploy via `update-relay` / `update-exit` (idempotent), or use an explicit `install -m 0755 source target && systemctl restart` for quick debugging. No `git pull` shortcuts.

### Review: check lib imports in callers

When adding a call to a function from `scripts/lib/*.sh`, verify that **every** caller script sources it. Do not assume "logically the lib must be there" and do not rely on `bash -n` alone — it checks syntax but does not catch undeclared functions.

```bash
grep -n "source.*lib/<module>.sh" scripts/setup-*.sh scripts/update-*.sh
```

Compare against the list of places where you call the function. For multi-agent reviews, explicitly ask reviewers to "verify that every script that now calls <new_function> sources <module>.sh".

### No infra leakage in public

Never publish in GitHub (issue comments, PR descriptions, release notes, README) anything that exposes infrastructure: hostnames from `~/.ssh/config`, IP addresses, specific domains, or ssh commands with real hosts.

- README/docs: use `relay.example.com`, `your-server`, `<HOSTNAME>` placeholders.
- User-facing commands: `ssh root@<your-relay>`, `cd ~/vless-relay-setup`.
- Issue close: no comment, or abstract phrasing ("deployed to prod").

In local Claude Code conversations, real names are fine.
