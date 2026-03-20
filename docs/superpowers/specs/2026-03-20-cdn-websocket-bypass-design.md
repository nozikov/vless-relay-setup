# CDN WebSocket Bypass — Design Spec

## Problem

Reality + SelfSteal bypass DPI and IP/SNI mismatch, but fail against ISP domain whitelisting. If the ISP only allows traffic to known domains (Google, Yandex, etc.), custom domains are blocked regardless of valid certificates or matching IP/SNI.

## Solution

Add an optional CDN path (Cloudflare + WebSocket) as a fallback alongside existing Reality path. Cloudflare IPs are universally whitelisted because blocking them breaks half the internet.

## Architecture

Two parallel paths to exit server. User gets both profiles in subscription, switches if needed.

```
Reality path (primary, fast):
  Client -> Relay:443 (Reality TCP, fragment) -> Exit:443 (Reality XHTTP) -> Internet

CDN path (fallback, whitelist-resistant):
  Client -> Cloudflare -> Exit:443 -> XRAY Reality fallback -> Caddy
    -> /ws-path -> XRAY WS inbound (127.0.0.1:<random-port>) -> Internet
    -> everything else -> real website
```

### How port 443 handles both protocols

XRAY Reality on port 443 inspects each TLS ClientHello:
- Reality client (has auth markers) -> XRAY processes as VLESS Reality XHTTP
- Non-Reality TLS (Cloudflare, browser, probe) -> fallback to Caddy (unix socket)

Caddy then routes by path:
- Secret WebSocket path -> reverse proxy to XRAY WS inbound on localhost
- Any other request -> serves static website

This means everything runs on port 443. No suspicious non-standard ports.

### CDN requires SelfSteal

CDN mode needs Caddy to handle TLS termination and WebSocket routing. SelfSteal already installs and configures Caddy. Therefore CDN is only available when SelfSteal is enabled.

SelfSteal does NOT require CDN (works standalone as before).

### Separate domains

SelfSteal domain: direct A-record to exit IP (no Cloudflare proxy).
CDN domain: A-record to exit IP through Cloudflare (orange cloud, proxy ON).

Two domains = two independent entry points. If one domain is blocked, the other still works. Same static content served on both.

### Client management

CDN path uses the same shared UUID as the relay->exit connection. No per-client tracking on CDN path. Relay remains the central point for client management and subscriptions. Relay generates both profiles (Reality + CDN) in each user's subscription.

## Installation Flow

### setup-exit.sh

```
Existing questions:
  - Panel port, path, admin, password
  - SSH port

Modified question:
  - "Domain for SelfSteal SNI (Enter to skip, required for CDN mode):"

New question (only if SelfSteal domain provided):
  - "CDN domain for Cloudflare (Enter to skip):"

If CDN domain provided:
  - Generate random ws-path
  - Generate random ws-port (with collision check)
  - Configure XRAY WS inbound on 127.0.0.1:<ws-port>
  - Add CDN domain block to Caddyfile
  - Output Cloudflare setup instructions at the end

exit-server-info.txt adds:
  CDN_DOMAIN=cdn-domain.com
  CDN_WS_PATH=random-path
  CDN_WS_PORT=random-port
```

### setup-relay.sh

```
New questions (if CDN configured on exit):
  - "Exit CDN domain:"
  - "Exit CDN WebSocket path:"

Subscription generates two profiles per client:
  1. Reality (via relay) - primary
  2. VLESS+WS (via Cloudflare to exit) - fallback
```

## File Changes

### common.sh

`generate_random_port()` gains port collision checking. Before returning a port, verifies it is not already in use (via `ss -tlnp`) and not in the list of ports already allocated during this setup session.

```bash
generate_random_port() {
    local excluded_ports=("$@")
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        # Check not already listening
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            continue
        fi
        # Check not in excluded list
        local collision=false
        for ep in "${excluded_ports[@]}"; do
            if [[ "$port" == "$ep" ]]; then
                collision=true
                break
            fi
        done
        if [[ "$collision" == false ]]; then
            echo "$port"
            return
        fi
    done
}
```

Callers pass already-allocated ports to avoid collisions:
```bash
panel_port=$(generate_random_port)
sub_port=$(generate_random_port "$panel_port")
ws_port=$(generate_random_port "$panel_port" "$sub_port")
```

### xray.sh

`configure_xray_exit()` gains optional CDN parameters. When CDN is enabled, adds a second inbound:

```json
{
    "tag": "vless-ws-in",
    "listen": "127.0.0.1",
    "port": "<ws-port>",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "<exit-uuid>"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "ws",
        "wsSettings": {
            "path": "/<ws-path>"
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
    }
}
```

No TLS on this inbound — Caddy handles TLS termination. Same sniffing settings as Reality inbound. Same routing applies (geoip:private -> block, everything else -> direct).

### caddy.sh

`generate_caddyfile()` gains CDN domain parameter. When provided, adds:

```caddyfile
cdn-domain.com {
    @websocket {
        path /<ws-path>
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @websocket localhost:<ws-port>
    root * /var/www/html/selfsteal
    file_server
}
```

Same static content directory as SelfSteal domain.

### setup-exit.sh

- Modified SelfSteal prompt with CDN hint
- New CDN domain prompt (conditional on SelfSteal)
- CDN domain validation and DNS check
- Generate ws-port with collision check (excluded: panel_port)
- Pass CDN params to configure_xray_exit() and generate_caddyfile()
- Cloudflare setup instructions in final output
- CDN fields in exit-server-info.txt

### setup-relay.sh

- New prompts for CDN domain and ws-path
- Generate CDN profile in subscription alongside Reality profile

### 3xui.sh — CDN subscription profile

3X-UI generates subscriptions from its inbound entries. CDN profile is NOT a real relay inbound — it connects directly to exit via Cloudflare. Two approaches:

**Approach A (recommended): Fake inbound entry.** Insert a second inbound row in 3X-UI database with tag `inbound-cdn`. Protocol: vless, network: ws, TLS: enabled, address: CDN domain, port: 443. 3X-UI treats it as a regular inbound and generates subscription links. The inbound is not actually used by the relay's XRAY — it's purely for subscription generation. Clients in this inbound mirror the real inbound's client list (same UUIDs/emails, different subIds).

**Approach B: External subscription script.** A script that intercepts 3X-UI's subscription output and appends CDN profiles. More fragile, depends on 3X-UI's subscription URL format.

Approach A is simpler and uses existing 3X-UI mechanics. The fake inbound needs the same two-restart normalization cycle as the real inbound.

### update-exit.sh

- Detect CDN mode: check if XRAY config has "vless-ws-in" inbound
- Read CDN params (ws-port, ws-path) from current config
- Preserve CDN domain, ws-path, ws-port during update
- With --upgrade: update Caddy if CDN mode active

### update-relay.sh

- Detect CDN inbound (`inbound-cdn`) in DB
- Preserve CDN profile in subscription during update

### verify.sh

- When CDN mode: check ws-port is listening on localhost

## TLS Certificate for CDN Domain

Caddy needs a valid TLS cert for the CDN domain to complete the handshake with Cloudflare.

Caddy obtains certs automatically via Let's Encrypt (ACME HTTP-01 challenge on port 80). When the CDN domain is behind Cloudflare, the ACME challenge flows through CF:

```
Let's Encrypt -> http://cdn-domain.com/.well-known/acme-challenge/...
  -> Cloudflare (proxies to origin port 80)
  -> Caddy (responds to challenge)
  -> cert issued
```

This works because Cloudflare passes `.well-known/acme-challenge/*` through to the origin.

**Cloudflare SSL mode: "Full" (not Strict).** "Full" accepts any cert on the origin during initial setup. Once Caddy obtains the LE cert, upgrading to "Full (Strict)" is optional but not required.

Setup instructions updated accordingly.

## Cloudflare Instructions (shown after setup)

```
CDN setup requires manual Cloudflare configuration:
  1. Add cdn-domain.com to Cloudflare (free plan is fine)
  2. DNS: A cdn-domain.com -> <exit-ip> (Proxy: ON, orange cloud)
  3. SSL/TLS -> Full
  4. Network -> WebSockets: ON
  5. Port 80 must be reachable for certificate issuance
```

## What Does NOT Change

- Reality path: fully unchanged
- Installation without SelfSteal: fully unchanged
- uninstall.sh: Caddy and XRAY already handled
- Static content: same setup_selfsteal_content(), one directory, both domains

## Dependencies

- CDN requires SelfSteal (needs Caddy)
- CDN requires a separate domain from SelfSteal domain
- CDN requires manual Cloudflare setup (not automated)

## Security Considerations

- WebSocket path is random and secret (like panel path)
- No TLS on WS inbound (127.0.0.1 only, Caddy handles TLS)
- CDN UUID is the same shared exit UUID (no additional credentials)
- Static site content should be impersonal (no real identity connection)
- Port collision check prevents accidental conflicts between services
