#!/bin/bash
# 3X-UI panel installation and configuration

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/xui-api.sh"

XUI_BIN="${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"

# NOTE: client/inbound writes are delegated to lib/xui-api.sh (REST API on v3.x).
# This module sources xui-api.sh directly (same as common.sh) so create_3xui_relay_inbound
# and sync_cdn_clients can call xui_api_*. Orchestration scripts that ALSO call xui_api_*
# directly still source xui-api.sh themselves (enforced by the lib-imports invariant).

# xhttp_extra_json() shared helper now lives in common.sh so xray.sh (exit)
# and 3xui.sh (relay) use the same values. This prevents mismatch between
# relay outbound scMaxEachPostBytes and exit inbound cap.

# XUI_VERSION (the pinned 3X-UI release) and xui_installed_version live in
# common.sh — selfcheck compares against them without pulling in this module.

# Run the pinned 3X-UI install.sh non-interactively. Same call for a fresh install
# and for an upgrade of an already-configured panel (install.sh skips the
# credentials/port setup when they're already set, then runs `x-ui migrate`).
#
# Verified against the v3.11.0 installer source: since v3.6.0 install.sh has a
# non-interactive mode (XUI_NONINTERACTIVE=1, or any non-TTY stdin) where every
# prompt is replaced by an env var or a default — the old answers-file feed is no
# longer read at all. We set explicitly what we rely on:
#   XUI_SSL_MODE=none          → Skip SSL; in NI mode "bind to 127.0.0.1?" is n.
#                                (The interactive default is an LE IP cert via
#                                acme.sh on :80, which collides with Caddy.)
#   XUI_DB_TYPE=sqlite         → we read/write /etc/x-ui/x-ui.db directly.
#   XUI_ENABLE_FAIL2BAN=false  → v3.11 otherwise runs `x-ui setup-fail2ban` (IP
#                                Limit): installs nftables, drops jail.d files incl.
#                                a global `backend = systemd` override and edits
#                                jail.local. fail2ban is ours (security.sh); we
#                                don't use IP Limit.
#   XUI_SERVER_IP              → when none of install.sh's IP-echo providers answer,
#                                NI mode takes this instead of looping on "Please
#                                enter your server's public IPv4 address" (v3.1.0 +
#                                answers file spun forever on EOF — issue #52). It
#                                only feeds the printed access URL, so empty is fine;
#                                our scripts don't detect the IP before install, the
#                                operator may export it.
# Panel port: XUI_PANEL_PORT unset → random port (same as before). `< /dev/null`
# keeps stdin a non-TTY so it never falls back to prompting, even when setup.sh
# runs in a terminal; on our path (SSL none, SQLite) every read in install.sh is
# behind the NONINTERACTIVE guard.
#
# install.sh is downloaded to a temp file first (curl -f + retries + non-empty
# check) instead of `bash <(curl -Ls …)`: that form ran an empty or HTML-error body
# as a "successful" no-op install. After the run the binary's own version must equal
# XUI_VERSION — otherwise we'd go on to write a DB the code wasn't verified against.
run_3xui_installer() {
    local tmp installed
    local url="https://raw.githubusercontent.com/mhsanaei/3x-ui/${XUI_VERSION}/install.sh"

    tmp=$(mktemp "${TMPDIR:-/tmp}/3x-ui-install.XXXXXX")
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url" || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        log_error "Failed to download 3X-UI ${XUI_VERSION} installer: $url"
        exit 1
    fi

    if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite XUI_ENABLE_FAIL2BAN=false \
        XUI_SERVER_IP="${XUI_SERVER_IP:-}" \
        bash "$tmp" "${XUI_VERSION}" < /dev/null; then
        rm -f "$tmp" "$XUI_INSTALL_RESULT"
        log_error "3X-UI ${XUI_VERSION} installer failed (see output above)"
        exit 1
    fi
    rm -f "$tmp"
    # install.sh writes the panel credentials + its "install" API token in plaintext
    # here (for cloud-init/MOTD). We never read it; the token is revoked separately.
    rm -f "$XUI_INSTALL_RESULT"

    installed=$(xui_installed_version)
    if [[ "$installed" != "${XUI_VERSION#v}" ]]; then
        log_error "3X-UI version mismatch after install: expected ${XUI_VERSION#v}, binary reports '${installed:-none}'"
        exit 1
    fi
    log_ok "3X-UI binary version ${installed} matches the pin"
}

# install.sh (v3.11) mints admin-scope API tokens for its own summary: "install" on a
# panel with no tokens, "cli-fallback" (rotated) on a later `-getApiToken`, i.e. a
# re-run that resets default credentials. Their plaintext goes to stdout — our tee'd
# /var/log/vpn-setup-*.log — and to install-result.env. We never use them (the relay
# has its own "vpn-cli" token, the exit panel needs none), so they are pure exposure.
# Exact names from main.go (installTokenName / cliFallbackTokenName); tokens the
# operator created in the panel are left alone.
XUI_INSTALLER_TOKEN_NAMES="'install','cli-fallback'"
XUI_INSTALL_RESULT="/etc/x-ui/install-result.env"

# Prints how many installer tokens are in the DB (0 when there is no DB or no
# api_tokens table). Read-only — safe while the panel runs.
count_installer_api_tokens() {
    local has_table n
    [[ -f "$XUI_DB" ]] || { echo 0; return 0; }
    has_table=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='api_tokens';" 2>/dev/null) || has_table=0
    if [[ "${has_table:-0}" -eq 0 ]]; then
        echo 0
        return 0
    fi
    n=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM api_tokens WHERE name IN (${XUI_INSTALLER_TOKEN_NAMES});" 2>/dev/null) || n=0
    echo "${n:-0}"
}

# Delete the installer tokens + install-result.env. Direct DB write, so it MUST run
# inside an `x-ui stop` ... `x-ui start` window (a running panel flushes its
# in-memory state over the DB on shutdown). Idempotent; quiet no-op without the table.
revoke_installer_api_tokens() {
    local n
    rm -f "$XUI_INSTALL_RESULT"
    n=$(count_installer_api_tokens)
    if [[ "$n" -gt 0 ]]; then
        sqlite3 "$XUI_DB" "DELETE FROM api_tokens WHERE name IN (${XUI_INSTALLER_TOKEN_NAMES});"
        log_info "Revoked ${n} installer-created API token(s) (install/cli-fallback)"
    fi
}

# No UFW juggling for port 80 here any more: with XUI_SSL_MODE=none the installer
# never runs ACME. SelfSteal gets :80 from setup_security (80:Caddy-ACME), and the
# old `ufw delete allow 80/tcp` could even drop that rule on a --force re-run.
install_3xui() {
    log_info "Installing 3X-UI panel..."

    run_3xui_installer

    if command -v x-ui &> /dev/null; then
        log_ok "3X-UI installed"
    else
        log_error "3X-UI installation failed"
        exit 1
    fi
}

# In SelfSteal mode Caddy owns all certs (its own + copied to Hysteria),
# so the acme.sh cron installed by 3X-UI's installer just spams the log
# with "port 80 already used by caddy" once a day. Drop it.
# Best-effort: if the operator runs acme.sh for unrelated sites on the same
# box, restore via `~/.acme.sh/acme.sh --install-cronjob`.
disable_acme_cron() {
    local acme="/root/.acme.sh/acme.sh"
    [[ -f "$acme" ]] || return 0

    # Skip if the cron entry isn't there (avoids a noisy log line on re-runs)
    if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
        return 0
    fi

    if "$acme" --uninstall-cronjob > /dev/null 2>&1; then
        log_ok "Disabled acme.sh cron (Caddy handles certs in SelfSteal mode)"
    else
        log_warn "acme.sh --uninstall-cronjob failed; cron may still fire on :80"
    fi
}

# xui_db_backup DEST — consistent snapshot of $XUI_DB into DEST (mode 0600: the DB
# holds panel credentials and client UUIDs). A plain `cp` of a WAL-mode DB while the
# panel runs misses commits that still sit in x-ui.db-wal and can copy a torn page
# set; sqlite's online backup API reads a consistent snapshot through the WAL and is
# safe against a running panel. Busy timeout covers a panel holding the write lock.
# Fallback (sqlite3 .backup failed): stop x-ui — a clean shutdown flushes memory to
# the DB and checkpoints the WAL — then `cp` the main file, then start it again.
# Either way the result must pass integrity_check, otherwise exit 1 (nothing has
# been modified yet, so refusing to continue without a usable backup is safe).
xui_db_backup() {
    local dest="$1" check=""
    if ! (umask 077 && sqlite3 -cmd ".timeout 10000" "$XUI_DB" ".backup '${dest//\'/\'\'}'") 2>/dev/null; then
        log_warn "sqlite3 .backup failed — falling back to x-ui stop + cp"
        rm -f "$dest"
        x-ui stop || true
        (umask 077 && cp "$XUI_DB" "$dest")
        x-ui start
    fi
    chmod 0600 "$dest"
    # .backup copies the WAL flag in the header too; switch the copy to rollback-
    # journal mode so it is one self-contained file (no DEST-wal to lose on restore).
    # The panel re-applies its own journal mode when it opens a restored DB.
    sqlite3 "$dest" "PRAGMA journal_mode=DELETE;" > /dev/null 2>&1 || true
    rm -f "${dest}-shm"
    check=$(sqlite3 "$dest" "PRAGMA integrity_check;" 2>/dev/null) || true
    if [[ "$check" != "ok" ]]; then
        log_error "DB backup $dest failed integrity_check (${check:-no output}) — aborting before any change"
        exit 1
    fi
}

# xui_db_restore SRC — put backup SRC back as $XUI_DB. Stops x-ui first: on shutdown
# the panel writes its in-memory state to the DB, so restoring under a running panel
# gets overwritten. Stale x-ui.db-wal / -shm / -journal are removed — sqlite would
# otherwise replay the post-backup WAL frames (or a hot rollback journal) on top of
# the restored file. The caller starts x-ui afterwards. Returns 1 if x-ui can't be
# stopped (restoring then would be pointless).
xui_db_restore() {
    local src="$1"
    x-ui stop || true
    if systemctl is-active --quiet x-ui; then
        systemctl stop x-ui || true
        if systemctl is-active --quiet x-ui; then
            log_error "x-ui still running — not restoring $src (its shutdown would overwrite it)"
            return 1
        fi
    fi
    rm -f "${XUI_DB}-wal" "${XUI_DB}-shm" "${XUI_DB}-journal"
    # cp onto the existing file keeps x-ui.db's own owner/mode
    cp "$src" "$XUI_DB"
}

# Set a key-value pair in x-ui settings database
xui_db_set() {
    local key="${1//\'/\'\'}"
    local value="${2//\'/\'\'}"

    local exists
    exists=$(sqlite3 "$XUI_DB" "SELECT COUNT(*) FROM settings WHERE key='$key';")

    if [[ "$exists" -gt 0 ]]; then
        sqlite3 "$XUI_DB" "UPDATE settings SET value='$value' WHERE key='$key';"
    else
        sqlite3 "$XUI_DB" "INSERT INTO settings (key, value) VALUES ('$key', '$value');"
    fi
}

configure_3xui() {
    local panel_port="$1"
    local panel_path="$2"
    local admin_user="$3"
    local admin_pass="$4"

    log_info "Configuring 3X-UI panel..."

    # Stop x-ui BEFORE changing settings.
    # The running process overwrites the DB on shutdown with its in-memory state,
    # so any changes made while it's running get lost on restart.
    x-ui stop

    # Set panel port
    "$XUI_BIN" setting -port "$panel_port"

    # Set panel URL path
    "$XUI_BIN" setting -webBasePath "/$panel_path/"

    # Set admin credentials
    "$XUI_BIN" setting -username "$admin_user" -password "$admin_pass"

    # Same window: drop the admin token install.sh minted and printed (both roles)
    revoke_installer_api_tokens

    # Start with new settings
    x-ui start

    log_ok "3X-UI configured:"
    log_info "  URL: http://<server-ip>:${panel_port}/${panel_path}/"
    log_info "  User: $admin_user"
}

configure_3xui_relay_template() {
    local exit_ip="$1"
    local exit_port="$2"
    local exit_uuid="$3"
    local exit_pubkey="$4"
    local exit_short_id="$5"
    local exit_sni="$6"

    local api_port="${7:-$(shuf -i 10000-60000 -n1)}"

    log_info "Writing xray template config to 3X-UI database..."

    local extra_json
    extra_json=$(xhttp_extra_json)

    local template
    template=$(jq -n -c \
        --arg exit_ip "$exit_ip" \
        --argjson exit_port "$exit_port" \
        --arg exit_uuid "$exit_uuid" \
        --arg exit_pubkey "$exit_pubkey" \
        --arg exit_short_id "$exit_short_id" \
        --arg exit_sni "$exit_sni" \
        --argjson api_port "$api_port" \
        --argjson extra "$extra_json" \
        '{
            log: {
                loglevel: "warning",
                access: "/var/log/xray/access.log",
                error: "/var/log/xray/error.log"
            },
            api: {
                services: ["HandlerService", "LoggerService", "StatsService"],
                tag: "api"
            },
            inbounds: [
                {
                    tag: "api",
                    listen: "127.0.0.1",
                    port: $api_port,
                    protocol: "dokodemo-door",
                    settings: { address: "127.0.0.1" }
                }
            ],
            stats: {},
            policy: {
                levels: {"0": {statsUserUplink: true, statsUserDownlink: true}},
                system: {
                    statsInboundUplink: true,
                    statsInboundDownlink: true,
                    statsOutboundUplink: true,
                    statsOutboundDownlink: true
                }
            },
            outbounds: [
                {
                    tag: "proxy-exit",
                    protocol: "vless",
                    settings: {
                        vnext: [{
                            address: $exit_ip,
                            port: $exit_port,
                            users: [{
                                id: $exit_uuid,
                                encryption: "none",
                                flow: "xtls-rprx-vision"
                            }]
                        }]
                    },
                    streamSettings: {
                        network: "raw",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            fingerprint: "chrome",
                            serverName: $exit_sni,
                            publicKey: $exit_pubkey,
                            shortId: $exit_short_id
                        },
                        sockopt: {
                            dialerProxy: "fragment",
                            tcpKeepAliveInterval: 30
                        }
                    }
                },
                {
                    tag: "direct",
                    protocol: "freedom"
                },
                {
                    tag: "block",
                    protocol: "blackhole"
                },
                {
                    tag: "fragment",
                    protocol: "freedom",
                    settings: {
                        fragment: {
                            packets: "tlshello",
                            length: "100-200",
                            interval: "10-20"
                        }
                    }
                }
            ],
            routing: {
                rules: [
                    {
                        type: "field",
                        inboundTag: ["api"],
                        outboundTag: "api"
                    },
                    {
                        type: "field",
                        inboundTag: ["inbound-443"],
                        outboundTag: "proxy-exit"
                    }
                ]
            }
        }')

    mkdir -p /var/log/xray

    xui_db_set "xrayTemplateConfig" "$template"

    log_ok "Xray relay template written to 3X-UI database (API port: $api_port)"
}

create_3xui_relay_inbound() {
    local relay_uuid="$1"
    local private_key="$2"
    local public_key="$3"
    local short_id="$4"
    local dest="$5"
    local server_name="$6"

    log_info "Creating VLESS Reality relay inbound via 3X-UI API..."

    local sub_id="${7:-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')}"
    local exit_ip="${8:-}"
    local xver="${9:-0}"
    local relay_xhttp_path="${10:-$(generate_random_path)}"

    local relay_city exit_city remark
    relay_city=$(curl -s --max-time 3 "http://ip-api.com/json/?fields=city" | jq -r '.city // empty') || true
    if [[ -n "$exit_ip" ]]; then
        exit_city=$(curl -s --max-time 3 "http://ip-api.com/json/${exit_ip}?fields=city" | jq -r '.city // empty') || true
    fi
    remark="${relay_city:-Relay} → ${exit_city:-Exit}"

    # Inbound is created WITHOUT clients; the seed client is added via the API
    # (clients/add) so it lands in the normalized clients/client_inbounds tables.
    local settings stream_settings sniffing extra_json lf_json
    settings=$(jq -n -c '{clients: [], decryption: "none", fallbacks: []}')

    extra_json=$(xhttp_extra_json)
    lf_json=$(reality_limit_fallback_json)
    stream_settings=$(jq -n -c \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg dest "$dest" \
        --arg server_name "$server_name" \
        --argjson xver "$xver" \
        --arg relay_path "$relay_xhttp_path" \
        --argjson extra "$extra_json" \
        --argjson lf "$lf_json" \
        '{
            network: "xhttp",
            security: "reality",
            realitySettings: ({
                show: false,
                dest: $dest,
                xver: $xver,
                serverNames: [$server_name],
                privateKey: $private_key,
                publicKey: $public_key,
                shortIds: [$short_id],
                settings: { publicKey: $public_key, fingerprint: "chrome", spiderX: "" }
            } + $lf),
            xhttpSettings: { path: ("/"+$relay_path), mode: "auto", extra: $extra }
        }')

    sniffing=$(jq -n -c '{enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}')

    # v3 inbounds/add: settings/streamSettings/sniffing are escaped JSON STRINGS.
    local inbound_json
    inbound_json=$(jq -n -c \
        --arg remark "$remark" \
        --arg settings "$settings" \
        --arg stream "$stream_settings" \
        --arg sniffing "$sniffing" \
        '{
            remark: $remark, port: 443, protocol: "vless",
            enable: true, expiryTime: 0, total: 0, listen: "",
            tag: "inbound-443",
            settings: $settings, streamSettings: $stream, sniffing: $sniffing
        }')

    local inbound_id
    inbound_id=$(xui_api_add_inbound "$inbound_json") || { log_error "Failed to create relay inbound"; return 1; }
    log_ok "VLESS Reality XHTTP relay inbound created (port 443, tag inbound-443, id $inbound_id)"

    # Add the seed default-user client via the API so it lands in the normalized
    # clients/client_inbounds tables (fixes #44). Done here (not in the caller) so
    # the inbound id stays internal and this function returns nothing on stdout —
    # log_* write to stdout, which would otherwise pollute a captured return value.
    local seed_client
    seed_client=$(jq -n -c --arg id "$relay_uuid" --arg s "$sub_id" \
        '{id:$id, email:"default-user", flow:"", limitIp:0, totalGB:0, expiryTime:0, enable:true, subId:$s, tgId:0, reset:0, comment:""}')
    xui_api_add_client "$inbound_id" "$seed_client" \
        || { log_error "Failed to create seed client (default-user)"; return 1; }
    log_ok "Seed client default-user created (subId $sub_id)"
}

configure_3xui_subscription() {
    local domain="$1"
    local sub_port="$2"
    local sub_path="$3"

    log_info "Configuring subscription service..."

    # Subscription settings are not available via CLI flags,
    # configure directly in the x-ui SQLite database
    xui_db_set "subEnable" "true"
    xui_db_set "subPort" "$sub_port"
    xui_db_set "subPath" "/$sub_path/"
    xui_db_set "subDomain" "$domain"

    log_ok "Subscription configured:"
    log_info "  URL: https://${domain}:${sub_port}/${sub_path}/"
}

issue_domain_cert() {
    local domain="$1"

    log_info "Issuing SSL certificate for ${domain}..."

    # Check if valid cert already exists for this domain
    local cert_dir="/root/cert/domain"
    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        local cert_domain
        cert_domain=$(openssl x509 -in "$cert_dir/fullchain.pem" -noout -subject -nameopt multiline 2>/dev/null \
            | sed -n 's/\s*commonName\s*=\s*//p')
        local cert_expiry
        cert_expiry=$(openssl x509 -in "$cert_dir/fullchain.pem" -noout -enddate 2>/dev/null \
            | cut -d= -f2)
        if [[ "$cert_domain" == "$domain" ]] && \
           openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkend 2592000 2>/dev/null; then
            log_ok "Valid SSL certificate found for ${domain} (expires: $cert_expiry)"
            # Still configure 3X-UI to use the existing cert
            xui_db_set "webCertFile" "$cert_dir/fullchain.pem"
            xui_db_set "webKeyFile" "$cert_dir/privkey.pem"
            xui_db_set "subCertFile" "$cert_dir/fullchain.pem"
            xui_db_set "subKeyFile" "$cert_dir/privkey.pem"
            return 0
        fi
    fi

    # Verify DNS resolves to this server before attempting ACME
    local server_ip domain_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null) || server_ip=""
    domain_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1) || domain_ip=""

    if [[ -z "$domain_ip" ]]; then
        log_warn "DNS for ${domain} does not resolve yet"
        log_warn "Set A-record: ${domain} → ${server_ip}"
        log_warn "Then issue cert manually: ~/.acme.sh/acme.sh --issue -d $domain --standalone"
        return 1
    fi

    if [[ -n "$server_ip" && "$domain_ip" != "$server_ip" ]]; then
        log_warn "DNS for ${domain} resolves to ${domain_ip}, but this server is ${server_ip}"
        log_warn "Fix the A-record, then issue cert manually:"
        log_warn "  ~/.acme.sh/acme.sh --issue -d $domain --standalone"
        return 1
    fi

    # acme.sh is already installed by the 3X-UI installer
    local acme="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme" ]]; then
        log_warn "acme.sh not found, skipping SSL cert (configure manually)"
        return 1
    fi

    # Port 80 must be open for HTTP-01 validation
    ufw allow 80/tcp comment "ACME validation" > /dev/null 2>&1 || true

    if "$acme" --issue -d "$domain" --standalone; then
        mkdir -p "$cert_dir"
        "$acme" --install-cert -d "$domain" \
            --fullchain-file "$cert_dir/fullchain.pem" \
            --key-file "$cert_dir/privkey.pem"

        # Configure 3X-UI to use the domain cert for panel and subscription
        xui_db_set "webCertFile" "$cert_dir/fullchain.pem"
        xui_db_set "webKeyFile" "$cert_dir/privkey.pem"
        xui_db_set "subCertFile" "$cert_dir/fullchain.pem"
        xui_db_set "subKeyFile" "$cert_dir/privkey.pem"

        log_ok "SSL certificate issued and configured for ${domain}"
    else
        log_warn "Failed to issue SSL cert for ${domain}"
        log_warn "Ensure DNS A-record points to this server, then run:"
        log_warn "  $acme --issue -d $domain --standalone"
        return 1
    fi

    ufw delete allow 80/tcp > /dev/null 2>&1 || true
}

create_3xui_cdn_inbound() {
    local exit_uuid="$1"
    local cdn_domain="$2"
    local cdn_path="$3"
    local sub_id="$4"
    local cdn_port="${5:-}"

    log_info "Creating CDN fallback inbound in 3X-UI database..."

    # Use a random localhost port — XRAY will listen but nothing connects externally
    if [[ -z "$cdn_port" ]]; then
        cdn_port=$(generate_random_port)
    fi

    # Validate port is numeric
    if ! [[ "$cdn_port" =~ ^[0-9]+$ ]]; then
        log_error "Invalid CDN port: $cdn_port"
        return 1
    fi

    local settings stream_settings sniffing

    settings=$(jq -n -c \
        --arg uuid "$exit_uuid" \
        --arg sub_id "$sub_id" \
        '{
            clients: [{
                id: $uuid,
                email: "cdn-fallback",
                limitIp: 0,
                totalGB: 0,
                expiryTime: 0,
                enable: true,
                subId: $sub_id,
                tgId: 0,
                reset: 0
            }],
            decryption: "none",
            fallbacks: []
        }')

    stream_settings=$(jq -n -c \
        --arg cdn_path "$cdn_path" \
        '{
            network: "xhttp",
            security: "none",
            xhttpSettings: {
                path: ("/"+$cdn_path),
                mode: "packet-up"
            }
        }')

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'

    local external_proxy
    external_proxy=$(jq -n -c \
        --arg dest "$cdn_domain" \
        '[{
            forceTls: "tls",
            dest: $dest,
            port: 443,
            remark: ""
        }]')

    # Escape single quotes for SQLite
    local s_settings="${settings//\'/\'\'}"
    local s_stream="${stream_settings//\'/\'\'}"
    local s_sniffing="${sniffing//\'/\'\'}"
    local s_external="${external_proxy//\'/\'\'}"

    # Check if externalProxy column exists
    local has_external_proxy
    has_external_proxy=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM pragma_table_info('inbounds') WHERE name='externalProxy';")

    if [[ "$has_external_proxy" -gt 0 ]]; then
        sqlite3 "$XUI_DB" "INSERT INTO inbounds (
            user_id, up, down, total, remark, enable, expiry_time,
            listen, port, protocol, settings, stream_settings,
            tag, sniffing, externalProxy
        ) VALUES (
            1, 0, 0, 0, 'CDN Fallback', 1, 0,
            '127.0.0.1', ${cdn_port}, 'vless',
            '${s_settings}', '${s_stream}',
            'inbound-cdn', '${s_sniffing}', '${s_external}'
        );"
        log_ok "CDN inbound created with externalProxy -> ${cdn_domain}:443"
    else
        log_warn "externalProxy column not found in 3X-UI database"
        log_warn "CDN profile will not appear in subscriptions automatically"
        log_warn "Upgrade 3X-UI to latest version for full CDN subscription support"
        # Still create inbound without externalProxy
        sqlite3 "$XUI_DB" "INSERT INTO inbounds (
            user_id, up, down, total, remark, enable, expiry_time,
            listen, port, protocol, settings, stream_settings,
            tag, sniffing
        ) VALUES (
            1, 0, 0, 0, 'CDN Fallback', 1, 0,
            '127.0.0.1', ${cdn_port}, 'vless',
            '${s_settings}', '${s_stream}',
            'inbound-cdn', '${s_sniffing}'
        );"
        log_ok "CDN inbound created (configure externalProxy manually in panel)"
    fi
}

patch_3xui_cdn_inbound() {
    local sub_id="$1"

    log_info "Patching CDN inbound subscription fields..."

    local current_settings
    current_settings=$(sqlite3 "$XUI_DB" \
        "SELECT settings FROM inbounds WHERE tag='inbound-cdn';") || return 0

    if [[ -z "$current_settings" ]]; then
        log_warn "CDN inbound not found, skipping patch"
        return 0
    fi

    local patched_settings
    patched_settings=$(echo "$current_settings" | jq -c \
        --arg sub_id "$sub_id" \
        '.clients[0].subId = $sub_id | .clients[0].tgId = 0 | .clients[0].reset = 0')
    local s_settings="${patched_settings//\'/\'\'}"
    sqlite3 "$XUI_DB" \
        "UPDATE inbounds SET settings='${s_settings}' WHERE tag='inbound-cdn';"

    log_ok "CDN inbound patched (subId for subscriptions)"
}

sync_cdn_clients() {
    log_info "Syncing clients to CDN inbound (via API)..."

    local cdn_id exit_uuid
    cdn_id=$(xui_api_inbound_id "inbound-cdn") || true
    if [[ -z "$cdn_id" ]]; then
        log_warn "CDN inbound not found, nothing to sync"
        return 0
    fi

    # Shared exit UUID = the UUID of the existing CDN inbound's client set.
    # Read it from the CDN inbound's settings JSON (read-only, sqlite is fine).
    exit_uuid=$(sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE tag='inbound-cdn';" \
        | jq -r 'first(.clients[]?.id) // empty') || true
    if [[ -z "$exit_uuid" ]]; then
        log_warn "Cannot determine CDN exit UUID — skipping CDN sync"
        return 0
    fi

    # Desired: one "<email>-cdn" per relay client, same subId, exit UUID.
    local relay_clients
    # Read relay clients from inbound-443 settings JSON: on v3 the API's clients/add
    # back-writes this JSON in addition to the normalized tables, so it stays current.
    relay_clients=$(sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE tag='inbound-443';" \
        | jq -c '[.clients[]? | {email: (.email + "-cdn"), subId: .subId, enable: .enable}]') || true
    [[ -z "$relay_clients" || "$relay_clients" == "null" ]] && relay_clients='[]'
    # Safety: a relay always has >=1 client (default-user). An empty desired set
    # here means an anomalous/empty read — do NOT proceed to the remove-extra loop,
    # which would purge every existing -cdn client. Bail without mutating.
    if [[ "$relay_clients" == "[]" ]]; then
        log_warn "CDN sync: relay client set read as empty — skipping (no add/remove) to avoid purging CDN clients"
        return 0
    fi

    # Current CDN client emails (from clients/list, filtered to the "-cdn" convention).
    local current_cdn
    current_cdn=$(xui_api_list_clients | jq -c '[.[]? | select(.email|endswith("-cdn")) | .email]') || current_cdn='[]'

    # Add missing.
    local desired_emails email
    desired_emails=$(printf '%s' "$relay_clients" | jq -r '.[].email')
    while IFS= read -r email; do
        [[ -z "$email" ]] && continue
        if ! printf '%s' "$current_cdn" | jq -e --arg e "$email" 'index($e) != null' >/dev/null; then
            local sub_id client_json
            sub_id=$(printf '%s' "$relay_clients" | jq -r --arg e "$email" 'first(.[]|select(.email==$e).subId)')
            client_json=$(jq -n -c --arg id "$exit_uuid" --arg e "$email" --arg s "$sub_id" \
                '{id:$id, email:$e, flow:"", limitIp:0, totalGB:0, expiryTime:0, enable:true, subId:$s, tgId:0, reset:0, comment:""}')
            xui_api_add_client "$cdn_id" "$client_json" \
                || log_warn "CDN sync: failed to add $email (continuing)"
        fi
    done <<< "$desired_emails"

    # Remove extra (present on CDN but no matching relay client).
    local cur_email
    while IFS= read -r cur_email; do
        [[ -z "$cur_email" ]] && continue
        if ! printf '%s' "$relay_clients" | jq -e --arg e "$cur_email" 'any(.[]; .email==$e)' >/dev/null; then
            xui_api_del_client "$cur_email" || log_warn "CDN sync: failed to remove $cur_email"
        fi
    done < <(printf '%s' "$current_cdn" | jq -r '.[]')

    log_ok "CDN inbound synced (via API)"
}

# Идемпотентная установка симлинка /usr/local/bin/vpn → <path-to-vpn>.
# Проверяет существование source и предупреждает если в /usr/local/bin/vpn
# лежит чужой не-симлинк (другая программа в PATH с таким именем).
install_vpn_cli_symlink() {
    local src="$1"
    local target="/usr/local/bin/vpn"

    if [[ ! -f "$src" || ! -x "$src" ]]; then
        log_warn "vpn CLI source not found or not executable at $src — skipping symlink"
        return 0
    fi

    if [[ -e "$target" && ! -L "$target" ]]; then
        log_warn "$target exists and is not a symlink — leaving in place. Remove it manually if you want vpn CLI."
        return 0
    fi

    ln -sf "$(realpath "$src")" "$target"
    log_ok "Installed 'vpn' CLI symlink at $target"
}
