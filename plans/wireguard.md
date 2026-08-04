# WireGuard as relay↔exit backhaul

## Key context that shapes this whole plan

**The exit side is not built or managed by this repo.** For this feature, "exit"
means an already-running WireGuard server on hardware outside this project's
control (concretely: a UniFi Express router on a residential IP, already capable
of terminating WireGuard peers). This repo's scripts never touch it — no
`setup-exit.sh`/`update-exit.sh` changes, no NAT/forwarding setup, no key
generation on that side, no selfcheck against it. It's a black box that the admin
configures through its own UI, and the ONLY interface between this repo and that
box is a handful of values the admin copies over by hand (peer public key,
endpoint, assigned tunnel address, etc.) — same trust model as any "bring your
own server" config.

**This makes the feature entirely relay-side.** Relay gains a new, mutually
exclusive alternative to its current "Exit Server Connection Details" setup step:
instead of pointing at a VPS running this project's `setup-exit.sh` (VLESS+Reality
+xtls-rprx-vision), it points at an external WireGuard peer. Nothing on the
exit/router side is provisioned, verified, or torn down by these scripts.

## Decisions locked in (from earlier Q&A, still valid)

1. **DPI resistance not needed on this hop.** Vanilla (un-obfuscated) WireGuard is
   fine for relay→router traffic.
2. **Opt-in, not a replacement.** VLESS+Reality+xtls-rprx-vision against a
   this-repo-managed exit VPS remains the default and fully supported path. The
   WireGuard-to-external-peer mode is a second, mutually exclusive choice at
   relay setup time — picking one means not using the other for that relay.
3. **No AI/geoip domain routing on this path**, and for a stronger reason than
   originally scoped: the "exit" is now a home router, not a VPS. There is no
   XRAY process on the other end at all — just a NAT gateway — so there is no
   place left to apply WARP-for-AI or VLESS-level domain routing regardless.
   `geoip:private` protection has to be reinstated on **relay**, and matters more
   here than in the VPS case (see Security note below).
4. **A narrow LAN-host exception is supported on top of that block** (opt-in).
   Because the "exit" is the admin's own home router, remote access to specific
   LAN devices — concretely the UniFi admin panel at `192.168.2.1` — is a wanted
   use case. This is expressed as an explicit per-host `/32` allow rule placed
   *before* the `geoip:private` block, so exactly the listed hosts pass through
   `wg-out` and the rest of RFC1918 stays blocked. Default is empty (block
   everything private, as #3 alone). Requires matching router-side scoping (see
   Security note #2).

## What this does NOT touch

- Relay's client-facing inbound (VLESS Reality **XHTTP**) — unchanged.
- Subscription generation, `sub-proxy.py`, share-page, `vpn` CLI — no changes to
  their logic, though see below: **Direct Exit / CDN / Hysteria 2 channels don't
  apply to this mode** (they assume a VPS reachable inbound on 443, which a
  residential router behind CGNAT / dynamic IP generally isn't). When a relay is
  configured in WireGuard-to-external-peer mode, the setup flow simply never asks
  for `exit_ip`/CDN domain/Hysteria port, so those channels are absent from
  subscriptions — no new code needed to suppress them, it falls out naturally
  from skipping those prompts.
- `setup-exit.sh`, `update-exit.sh`, exit-side anything — untouched, full stop.

## Current backhaul (for contrast, VLESS mode — unchanged, still the default)

```
relay inbound-443 (client traffic, already decrypted VLESS)
  → routing rule: inboundTag inbound-443 → outbound "proxy-exit"
  → proxy-exit: VLESS Reality RAW + xtls-rprx-vision, dialerProxy: "fragment"
  → fragment: freedom outbound, splits TLS ClientHello (DPI evasion)
  → exit main inbound (this-repo-managed VPS): VLESS Reality RAW + xtls-rprx-vision
  → exit routing: geoip:private → block; AI domains → warp; else → freedom (UseIP)
```

Defined in `configure_3xui_relay_template()` (`scripts/lib/3xui.sh:127-253`).

## New backhaul (WireGuard-to-external-peer mode)

Relay uses **XRAY's native `wireguard` outbound protocol** — a userspace
WireGuard client built into xray-core (the same mechanism community configs use
to reach Cloudflare WARP directly without `warp-svc`). No new system network
interface, no kernel WG module, no `wg-quick` service, no root-level network
namespace work, no new long-running daemon on relay at all. It's a config-only
addition to the same `xrayTemplateConfig` JSON that already holds
`proxy-exit`/`fragment`/`direct`/`block`.

```
relay inbound-443 (client traffic, already decrypted VLESS)
  → routing rules:
      ip: [<allowed LAN hosts, e.g. 192.168.2.1/32>] → "wg-out"  (NEW — LAN-exception, precedes block)
      ip: [geoip:private] → block            (NEW — reinstated here, see Security note)
      inboundTag [inbound-443] → "wg-out"
  → wg-out: XRAY-native wireguard outbound (userspace), dials <router_endpoint>:<port>
       (UDP, standard WireGuard handshake, encrypts per-connection IP packets)
  → external WireGuard peer (UniFi Express router, admin-managed, out of scope)
       terminates WG, routes/NATs out the residential WAN connection
  → real internet destination (egress IP = residential, not datacenter)
```

Example `wg-out` outbound (values are whatever the admin got from the router's
peer-creation UI, pasted in verbatim):
```jsonc
{
  "tag": "wg-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "<relay_wg_private_key>",
    "address": ["<relay_tunnel_address>/32"],
    "peers": [{
      "publicKey": "<router_wg_public_key>",
      "endpoint": "<router_endpoint_host>:<router_wg_port>",
      "allowedIPs": ["0.0.0.0/0"],
      "keepAlive": 25
    }],
    "mtu": 1380
  }
}
```

Because `wg-out` is a pure userspace outbound, the very same block can be stood
up in isolation for a real end-to-end test: a throwaway `xray run` carrying only
this outbound plus a scratch `socks5` inbound dials the tunnel, completes the
WireGuard handshake, and lets a single `curl` confirm traffic egresses via the
residential IP — with no network interface, no root, and zero effect on the live
relay's XRAY-in-3X-UI. This is the one honest way to verify hand-copied peer
values actually work (a raw UDP probe can't — WireGuard deliberately ignores
non-handshake packets), so both the setup/update pre-flight and selfcheck below
reuse it rather than settling for a blind reachability check.

## Bootstrapping — much simpler than a repo-managed exit would be

Because the router isn't set up by us, there's no two-way coordination problem:

1. **Admin, outside this repo:** creates a WireGuard peer for "relay" on the
   UniFi controller. Depending on what the UniFi Express UI offers, this yields
   either (a) a complete generated client config (private key, assigned address,
   router public key, endpoint, allowed-ips — UniFi's typical "road warrior"
   config download/QR flow), or (b) just a slot where the admin registers a
   public key they generated themselves. Either way this step is entirely manual
   and entirely outside this repo's scope — plan does not automate it.
2. **Admin runs `setup-relay.sh`** and picks WireGuard-to-external-peer mode in
   the (restructured) "Exit Server Connection Details" step. Two ways to supply
   the peer values:

   **(a) Import a UniFi `.conf` (preferred when the router hands one out).** UniFi's
   "road warrior" download/QR flow yields a standard `wg-quick` INI file, e.g.:
   ```ini
   [Interface]
   PrivateKey = <relay_wg_private_key>
   Address = 192.168.2.4/32
   DNS = 192.168.2.1

   [Peer]
   PublicKey = <router_wg_public_key>
   AllowedIPs = 0.0.0.0/0
   Endpoint = my-dyndns-domain.mooo.com:8264
   ```
   The admin passes its path (prompt: "Path to WireGuard .conf, or blank to enter
   values manually") or `--wg-conf <path>`; `parse_wg_conf()` maps it directly onto
   the six params below (see field mapping in `lib/wireguard.sh`). Fields absent
   from the file fall back to defaults (`PersistentKeepalive`→25, `MTU`→1380). The
   `DNS =` line is deliberately ignored — XRAY's `wireguard` outbound has no
   in-tunnel DNS setting; the relay resolves names itself. Parsed values are shown
   back for confirmation with the private key masked.

   **(b) Enter values manually.** Prompts:
   - Relay's WG private key (from the router's generated config, or self-generated)
   - Relay's tunnel address (assigned by the router, e.g. `192.168.2.4/32`)
   - Router's WG public key
   - Router's WG endpoint (`host:port` — likely a DDNS hostname given the
     residential/dynamic-IP context, e.g. `my-dyndns-domain.mooo.com:8264`; note this
     in the prompt help text)
   - Allowed IPs (default `0.0.0.0/0`), keepalive (default `25`), MTU (default `1380`)

   Both paths converge on the same param set. Note the tunnel subnet
   (`192.168.2.x` in UniFi's example) is distinct from the router's LAN subnet —
   the router's in-tunnel address (`192.168.2.1`, its DNS/gateway) is the address
   the admin panel is typically reachable at *through the tunnel*, so that's the
   natural LAN-exception host (decision #4).

   Before any of these values touch the relay's config, `setup-relay.sh`
   pre-flights them with the userspace dry-run described above and refuses to
   proceed if the tunnel doesn't come up — so a transposed key or wrong endpoint
   fails fast, before the `xrayTemplateConfig` is rewritten or `x-ui` restarted.
3. If the admin wants to self-generate a keypair instead of using one the router
   handed out (path (b) above): reuse `generate_reality_keypair()`'s underlying
   tool — `xray x25519` produces a raw Curve25519 keypair in the same base64
   encoding WireGuard uses, so it's directly usable as a WG keypair. **No new
   `wireguard-tools` dependency needed anywhere in this feature** — relay already
   has `xray` installed for Reality key generation, and there is no exit-side
   server to install `wireguard-tools`/kernel module for. This is a real
   simplification versus assuming a repo-managed WG server on both ends: the
   entire feature adds zero new packages and zero new services.

No secrets flow from this repo to the router or back — the admin is the only
channel, matching how they already manually copy exit values between SSH
sessions today.

## Security note (elevate this in docs — more important than in the VPS case)

If the "exit" is the admin's actual home router serving their household LAN (not
a dedicated single-purpose box), a naive WireGuard tunnel could let relay-routed
VPN clients reach into that LAN (printers, NAS, IoT, the router's own admin
panel) unless scoped carefully. Two independent layers should both hold:

1. **Relay-side `geoip:private` block** (this plan adds it to
   `configure_3xui_relay_template`'s routing rules) — stops relay from ever
   dialing an RFC1918/private destination through `wg-out` in the first place,
   *except* for any host explicitly listed in the LAN-exception allow rule
   (decision #4). That list is empty by default; when populated (e.g.
   `192.168.2.1/32` for the UniFi panel) it is a deliberate, narrow hole in this
   layer — one `/32` at a time, never a whole subnet — for wanted remote LAN
   access. Everything not listed stays blocked.
2. **Router-side scoping** (entirely the admin's responsibility, outside this
   repo): the WG peer's `AllowedIPs`/firewall rules on the UniFi controller
   should restrict that peer to WAN egress **plus only the specific LAN hosts the
   admin intends to reach remotely** — not full LAN access. Note the two layers
   must agree: a relay-side allow rule for `192.168.2.1` does nothing if the
   router-side peer scoping drops it, and vice-versa. Call this out explicitly and
   prominently in the README and in `setup-relay.sh`'s prompt/summary output for
   this mode — something like: "This repo blocks private-IP destinations on the
   relay side except the LAN hosts you allow-listed; you must also scope your
   router's WireGuard peer to reach exactly those hosts and nothing more of your
   home LAN."

Both are cheap to state; only #1 is actually implemented by this plan. #2 cannot
be enforced by anything in this repo since the router is out of scope — the plan
should not imply otherwise.

## Component-by-component changes

### New: `scripts/lib/wireguard.sh` (small — relay-only, no services)

- `wg_outbound_json(private_key, address, peer_pubkey, endpoint, allowed_ips, keepalive, mtu)`
  — jq helper building the `wg-out` outbound JSON block, same factoring style as
  `xhttp_extra_json()`/`reality_limit_fallback_json()` in this repo.
- `generate_wg_keypair()` — optional convenience for admins choosing to
  self-generate rather than use a router-issued config. Wraps `xray x25519`
  (already installed, already used for Reality keys) rather than introducing
  `wireguard-tools`. Exports `WG_PRIVATE_KEY`/`WG_PUBLIC_KEY`.
- `wg_dry_run(private_key, address, peer_pubkey, endpoint, allowed_ips, keepalive, mtu)`
  — the pre-flight/selfcheck workhorse. Renders a throwaway config (the
  `wg_outbound_json()` block routed from a scratch `socks5` inbound on
  `127.0.0.1:<random>`), launches a disposable `xray run` against it, `curl`s an
  echo-IP service through the socks port with a bounded timeout, and returns
  0/non-zero on whether the handshake completed and traffic egressed. Tears the
  instance down on exit (trap). Touches nothing on the live relay — no config
  write, no `x-ui` restart, no interface. Surfaces the observed egress IP so
  callers can show `egress = <residential IP>` and flag a datacenter IP as a
  likely mis-scoped/misrouted peer.
- `parse_wg_conf(path)` — parses a UniFi/`wg-quick` INI config and exports the
  peer params. Field mapping:
  | INI field | exported var | fallback |
  |---|---|---|
  | `[Interface] PrivateKey` | `WG_PRIVATE_KEY` | required |
  | `[Interface] Address` | `WG_ADDRESS` | required (split comma list into array; keep `/NN`) |
  | `[Peer] PublicKey` | `WG_PEER_PUBKEY` | required |
  | `[Peer] Endpoint` | `WG_ENDPOINT` | required (keep DDNS hostname, do not resolve) |
  | `[Peer] AllowedIPs` | `WG_ALLOWED_IPS` | `0.0.0.0/0` |
  | `[Peer] PersistentKeepalive` | `WG_KEEPALIVE` | `25` |
  | `[Interface] MTU` | `WG_MTU` | `1380` |
  Simple line parser (awk/bash): `key = value`, `#`/`;` comments, `[Interface]`/
  `[Peer]` section headers; trim whitespace around `=`. `[Interface] DNS` is
  read-and-discarded (no XRAY equivalent). **Require exactly one `[Peer]`
  section** — error clearly if the file has zero or multiple (this feature is
  single-peer; a multi-peer `.conf` is out of scope, not silently truncated).
  Validate the required fields are present and non-empty; error naming the missing
  key. Never echo `WG_PRIVATE_KEY` — the summary/confirmation output masks it.
- `validate_wg_lan_allow(list)` — parses the comma/space-separated LAN-exception
  list, validates each entry is a well-formed host IP or CIDR (reuse
  `validate_ip`; accept an optional `/NN` suffix), and rejects entries broader
  than a single host beyond a sane bound (refuse `/16` and `/8`-scale private
  supernets — a narrow per-host exception is the whole point). Returns the
  normalized list (each bare IP promoted to `/32`) for both setup-relay and
  update-relay to consume, so the accept/reject rules live in one place. Emits a
  clear error naming the offending entry.
- Nothing else. No `install_wireguard`, no `configure_wg_exit`,
  no NAT/forwarding, no systemd unit, no `uninstall_wireguard` — the dry-run is a
  transient child process, not a service; none of that persistent machinery
  applies when the far end isn't ours to configure.

### `scripts/lib/3xui.sh` — `configure_3xui_relay_template()`

Add a `backhaul_mode` parameter (`vless` default / `wireguard`). When
`wireguard`, the function takes the WG peer params instead of
exit_ip/exit_port/exit_uuid/exit_pubkey/exit_short_id/exit_sni, plus an optional
`wg_lan_allow` param (space- or comma-separated CIDR list, default empty), and:
- Outbounds: replace `proxy-exit` + `fragment` with the single `wg-out` block
  from `wg_outbound_json()`. Keep `direct`/`block` as-is (used by the `api` rule).
- Routing rules:
  ```jsonc
  [
    { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
    // LAN-exception rule — emitted ONLY when wg_lan_allow is non-empty:
    { "type": "field", "ip": ["192.168.2.1/32"], "outboundTag": "wg-out" },
    { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
    { "type": "field", "inboundTag": ["inbound-443"], "outboundTag": "wg-out" }
  ]
  ```
  Rule order is load-bearing: the LAN-exception rule must precede the
  `geoip:private` block (first-match wins), and the block must precede the
  inbound-443 catch-all. When `wg_lan_allow` is empty the exception rule is
  omitted entirely — behaviour is identical to decision #3 alone. Build the
  `ip` array for the exception rule with `jq --argjson` from the parsed CIDR
  list; skip the rule (not emit an empty-array rule, which would match nothing
  but is noise) when the list is empty. Validate each entry as an IP or CIDR
  before it reaches the template.

### `scripts/setup-relay.sh`

Restructure the "Exit Server Connection Details" step (currently
`exit_ip`/`exit_uuid`/`exit_pubkey`/`exit_short_id`/`exit_sni` + CDN + Hysteria
prompts) to branch on a new leading prompt:

```
Backhaul to exit: (1) VLESS+Reality to a this-repo-managed exit VPS [default]
                  (2) WireGuard to an externally-managed peer (e.g. home router)
```

- Path (1): existing prompts, unchanged, including CDN/Hysteria (both assume a
  VPS exit and stay gated behind it as today).
- Path (2): skip `exit_ip`/`exit_uuid`/`exit_pubkey`/`exit_short_id`/`exit_sni`
  and the CDN/Hysteria prompts entirely (none apply — see "What this does NOT
  touch"). First offer the `.conf` import (prompt for a path, or `--wg-conf
  <path>`): if given, `parse_wg_conf()` pre-fills all six peer params and the flow
  shows them back (private key masked) for confirmation; if blank, fall through to
  the manual prompts for the WG peer values listed in the Bootstrapping section.
  Either way, validate the endpoint host (reuse `validate_domain`/`validate_ip`
  as appropriate) and the tunnel address (basic IP/CIDR validation) after parsing —
  the `.conf` path is not trusted to be well-formed just because it parsed.
- After the peer values, prompt for the LAN-exception list (decision #4):
  ```
  LAN hosts to allow through the tunnel (remote access to devices behind the
  router, e.g. the UniFi admin panel). Comma-separated IPs/CIDRs, blank for none
  [default: none]: 
  ```
  Default empty = block all private destinations. Validate each entry as an
  IP/CIDR; reject broad private ranges pasted whole (e.g. refuse a bare
  `192.168.0.0/16` or `10.0.0.0/8` — the point is narrow per-host exceptions, and
  allow-listing the entire LAN defeats layer #1). Store as `wg_lan_allow` and pass
  through to `configure_3xui_relay_template`. When non-empty, the summary block
  (below) must echo the Security-note #2 reminder that the router-side peer has to
  be scoped to reach exactly these hosts.
- Pre-flight the collected peer values with `wg_dry_run()` before touching any
  relay config. On failure, print the specific reason (no handshake / no egress /
  unexpected egress IP) and abort the setup without writing the template or
  restarting `x-ui` — a hard gate, since a broken backhaul would take the relay's
  only channel down. The prompt validators above already cover static shape (key
  length/base64), so the dry-run is purely the live check.
- Pass `backhaul_mode` + the relevant param set through to
  `configure_3xui_relay_template`.
- Final summary block: when in WG mode, print the router endpoint instead of
  "Exit: ${exit_ip}", and print the Security-note reminder about scoping the
  router-side peer to WAN-only.

### `scripts/update-relay.sh`

- Auto-detect current mode by inspecting the template
  (`jq -e '.outbounds[] | select(.tag=="wg-out")'`), same style as existing
  `is_selfsteal`/`is_cdn`/`current_network` detection — a plain re-run just
  regenerates the template in whatever mode is already active, no flag needed
  for the common case.
- **The LAN-exception list survives a plain re-run** — unlike the other-mode
  params, it *is* recoverable from the live template. Read it back from the
  active routing rules (the `ip` array of the rule whose `outboundTag` is
  `wg-out` and that sits before the `geoip:private` block) and feed it back into
  `configure_3xui_relay_template` as `wg_lan_allow`, so re-running update-relay
  in WG mode never silently drops the admin's UniFi-panel exception. Same recovery
  pattern as reading current WG peer values back from the `wg-out` outbound.
- A `--wg-lan-allow <cidr[,cidr...]>` flag overrides that recovered list (and
  `--wg-lan-allow ''` / `--wg-lan-allow none` clears it back to block-everything).
  Independent of the peer-value flags — you can retune the LAN exception without
  re-supplying keys. Validated identically to the setup prompt.
- New flags to switch modes or update WG params in place:
  `--wg-backhaul <private_key> <address> <peer_pubkey> <endpoint> [allowed_ips] [keepalive] [mtu]`
  (enable/update WG mode). `--wg-conf <path>` is accepted as a shorthand for
  `--wg-backhaul` — it runs `parse_wg_conf()` and fills the same params from a
  UniFi `.conf` (handy when the router reissues a config, e.g. a rotated key). And
  `--vless-backhaul <exit_ip> <exit_uuid> <exit_pubkey>
  <exit_short_id> <exit_sni>` (switch back to the VPS-exit path). Both are
  explicit because — unlike every other update-relay auto-detected value — the
  *other* mode's parameters aren't recoverable from the currently active
  template (if relay is in WG mode, the VLESS-mode exit pubkey/short_id/sni
  simply aren't stored anywhere once overwritten). Document this plainly: mode
  switches require re-supplying the target mode's parameters from scratch, same
  as a fresh relay setup would. No attempt to persist both parameter sets
  simultaneously — added complexity not justified when mode switches are rare.
- `--wg-backhaul` (and a plain re-run that regenerates an already-WG template)
  runs the same `wg_dry_run()` pre-flight as fresh setup before applying: the new
  peer values must handshake and egress first, otherwise the update aborts and
  leaves the current template untouched. This fits update-relay's existing
  backup-and-rollback discipline but is cheaper — it never has to roll back a bad
  config it declined to write. A `--vless-backhaul` switch stays on the existing
  VLESS-mode verification path; the WG dry-run doesn't apply there.

### `scripts/lib/selfcheck.sh` / `scripts/selfcheck.sh`

Relay-only checks when WG mode is detected (nothing to check on an exit we don't
manage):
- Template sanity: `wg-out` outbound present with non-empty
  `secretKey`/`peers[0].publicKey`/`peers[0].endpoint`.
- Handshake + egress: run the shared `wg_dry_run()` against the template's live
  peer values. Because the outbound is userspace, this stands up a throwaway
  `xray` tunnel and actually completes a WireGuard handshake and egress check —
  not the blind UDP probe a raw socket would be limited to (WG deliberately
  ignores non-handshake packets, so `nc -u -z` proves nothing). PASS confirms the
  configured peer handshakes and routes out the residential IP right now;
  FAIL/WARN carries the specific reason (no handshake / no egress / datacenter
  egress IP). Same helper the setup/update pre-flight uses — one code path, one
  definition of "the backhaul works".
- Honest scope of that check: the dry-run validates a *fresh, ephemeral* tunnel
  built from the configured params — it proves the params + router are good, but
  it is **not** introspection of the live `wg-out` outbound's current counters.
  There is no `wg show`-equivalent on relay: the running tunnel lives inside the
  XRAY process, not a `wg0` interface, so its live handshake/traffic state isn't
  visible from the OS. For that dimension the only signals are XRAY's own
  access/error logs — optionally grep recent xray error log for wireguard
  failures as a supplementary WARN.
- A passing dry-run says the tunnel and residential egress work; it says nothing
  about whether the router-side peer is LAN-scoped (Security note #2). Keep that
  caveat in the PASS text so a green check isn't misread as "the home LAN is
  safe".
- When the template carries a LAN-exception list, echo the allow-listed hosts in
  the output (INFO, not PASS/FAIL) so the admin can see exactly which private
  hosts are punched through — a green check must not hide the fact that
  `192.168.2.1` (or whatever) is intentionally reachable. The dry-run does not
  probe those hosts (it only checks WAN egress); state that they're allow-listed
  on the relay side but their reachability depends on the un-inspectable
  router-side scoping.
- Skip WARP-AI-routing-related checks entirely in this mode (not applicable,
  no exit XRAY process exists to check).

### `scripts/uninstall.sh`

No new teardown needed. WG mode is just JSON inside `xrayTemplateConfig`,
removed along with the rest of the relay's config during normal uninstall —
there's no separate service/package/interface this mode introduces that could
be left behind.

### `README.md`

New subsection under whatever documents relay setup: "WireGuard backhaul to an
externally-managed peer" — explain it's mutually exclusive with the VPS-exit
path, that Direct Exit/CDN/Hysteria don't apply, and the Security note about
scoping the router-side peer. Show both ways to supply peer values — importing a
UniFi `.conf` (`--wg-conf` / path prompt) and manual entry — and note the `DNS =`
line is ignored and the tunnel subnet differs from the router LAN. Document the
LAN-exception (decision #4): how to
allow remote access to specific devices behind the router — motivating example
being the UniFi admin panel at `192.168.2.1` — via the setup prompt or
`--wg-lan-allow`, that it defaults to none, must be narrow per-host `/32`s, and
requires the matching router-side peer scoping to actually work (both layers must
agree). Note that setup/update pre-flight the tunnel (real handshake + egress
check) before applying, so mis-copied peer values fail fast without disrupting the
relay — but that a green check confirms egress, not LAN-scoping, and does not
verify the allow-listed hosts are actually reachable through the router. Keep the
existing exit-VPS docs as the primary/default path.

### `VERSION`

Bump on merge.

## Known limitations (state explicitly in README + setup output)

1. No AI-domain routing or exit-side inspection for this path — there is no
   exit XRAY process at all in this mode, just a NAT gateway. IP-level
   `geoip:private` blocking on relay is the only protection this repo provides,
   minus any host explicitly allow-listed via the LAN-exception (default none);
   LAN-scoping the peer is the admin's responsibility on the router, and the two
   must agree for an allow-listed host to actually be reachable.
2. Direct Exit / CDN Fallback / Hysteria 2 channels are unavailable when a relay
   is in WireGuard-to-external-peer mode (they all assume a VPS exit reachable
   inbound on 443). Only channel 1 (relay main) exists for such a relay.
3. Switching a relay between VLESS-backhaul and WireGuard-backhaul via
   `update-relay` requires re-supplying the target mode's full parameter set —
   the previous mode's params are not retained once overwritten.
4. Health checking is possible but bounded: the userspace dry-run (throwaway
   `xray` instance, shared by setup/update pre-flight and selfcheck) confirms a
   real WireGuard handshake and residential egress on demand. What it can't do is
   introspect the *live* `wg-out` outbound's current tunnel state — there is no
   `wg0` interface or `wg show` on relay — so it verifies the params by standing
   up a fresh ephemeral tunnel, not by reading the running one's counters.
   Continuous liveness is still only observable through client-traffic success
   and XRAY logs.
5. Single external peer per relay (one `wg-out` outbound) — no fan-out to
   multiple candidate exits/load-balancing in scope here.

## Rough implementation order

1. `lib/wireguard.sh` (new, small) — `wg_outbound_json`, `wg_dry_run` (the
   pre-flight/selfcheck workhorse), `parse_wg_conf`, `validate_wg_lan_allow`, +
   optional `generate_wg_keypair`. Build and test `wg_dry_run` early against the
   real router: everything downstream leans on it as the definition of "the
   backhaul works". Verify `parse_wg_conf` against a real UniFi-exported `.conf`.
2. `3xui.sh` `configure_3xui_relay_template` mode switch.
3. `setup-relay.sh` restructured Exit Connection Details step (fresh-install
   path first), with the `wg_dry_run` pre-flight gate before the template write.
4. `update-relay.sh` `--wg-backhaul`/`--vless-backhaul` flags + auto-detection;
   `--wg-backhaul` and WG re-runs gated by the same pre-flight.
5. `selfcheck.sh` relay-only WG checks, reusing `wg_dry_run`.
6. README docs + VERSION bump.
7. Manual E2E: configure a peer on the actual UniFi Express router, run
   `setup-relay.sh` in WG mode, confirm client traffic egresses via the
   residential IP; confirm a VLESS-mode relay is completely unaffected by any of
   these changes (regression check on the default path).
