#!/usr/bin/env python3
"""Subscription proxy: fetches from 3X-UI and appends extra VPN links.

Appends CDN VLESS, Direct Exit, and Hysteria 2 links to subscriptions.
Browser requests (Accept: text/html) are passed through as-is so the
3X-UI subscription page with QR codes works normally.

App requests (no Accept: text/html) get extra links appended to the
base64-encoded subscription response.

Split routing:
- Shadowrocket Module: ?module=ru endpoint (.sgmodule file)
- Happ: routing HTTP header with deeplink (auto-import on subscription update)
- HTML page: inject download buttons for Shadowrocket module
"""

import http.server
import urllib.request
import urllib.parse
import base64
import html
import json
import os
import re
import sqlite3
import sys

UPSTREAM = os.environ.get("SUB_UPSTREAM", "http://127.0.0.1:8443")
CDN_LINK = os.environ.get("CDN_VLESS_LINK", "")
CDN_LINK_ASYM = os.environ.get("CDN_VLESS_LINK_ASYM", "")
DIRECT_LINK = os.environ.get("DIRECT_VLESS_LINK", "")
HYSTERIA_LINK = os.environ.get("HYSTERIA_LINK", "")
# URL-encoded JSON with XHTTP extra params (xmux, padding, flow control).
# 3X-UI's built-in subscription generator does NOT emit xhttpSettings.extra
# into the VLESS URL — we inject it here for every relay-like URL so clients
# actually use xmux on the client→relay leg.
RELAY_EXTRA = os.environ.get("RELAY_XHTTP_EXTRA", "")
LISTEN_PORT = int(os.environ.get("SUB_PROXY_PORT", "18443"))
CONF_DIR = os.environ.get("SR_CONF_DIR", "/etc/sub-proxy")

SR_MODULE = ""
HAPP_ROUTING_HEADER = ""

# share-page (issue #21): один URL для подписки и для share-page,
# браузер vs apps различаются по Accept-заголовку.
# subId не ограничен по charset: 3X-UI native генерит base32-ish строки;
# админ может руками задать любой ASCII через панель. Достаточно матчить
# два непустых сегмента — domain Caddy уже изолировал нас на sub.*.
SHARE_PAGE_TEMPLATE_PATH = os.path.join(CONF_DIR, "share-page.html")
SHARE_PAGE_PATH_REGEX = re.compile(r"^/[^/]+/([^/]+)/?$")
XUI_DB_PATH = os.environ.get("XUI_DB_PATH", "/etc/x-ui/x-ui.db")
_share_page_template = None  # lazy-loaded; "" means "not available, don't retry"


def load_templates():
    """Load Shadowrocket module and Happ routing profile at startup."""
    global SR_MODULE, HAPP_ROUTING_HEADER

    # Shadowrocket module
    module_path = os.path.join(CONF_DIR, "sr-module-ru.sgmodule")
    try:
        with open(module_path) as f:
            SR_MODULE = f.read()
    except FileNotFoundError:
        pass

    # Happ routing profile → deeplink header
    happ_path = os.path.join(CONF_DIR, "happ-routing-ru.json")
    try:
        with open(happ_path) as f:
            profile = f.read()
        encoded = base64.b64encode(profile.encode()).decode()
        HAPP_ROUTING_HEADER = f"happ://routing/onadd/{encoded}"
    except FileNotFoundError:
        pass


HTML_SNIPPET = """\
<div style="margin:24px auto;max-width:600px;padding:16px 20px;background:#f0f4f8;
 border-radius:12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
 text-align:center">
 <div style="font-size:15px;font-weight:600;margin-bottom:8px;color:#1a1a1a">
  Split Routing</div>
 <div style="font-size:13px;color:#666;margin-bottom:14px">
  RU-сервисы напрямую, остальное через VPN</div>
 <div style="display:flex;gap:10px;justify-content:center;flex-wrap:wrap">
  <a href="shadowrocket://install?module=https%3A%2F%2F{host}{base_encoded}%3Fmodule%3Dru"
   style="display:inline-block;padding:10px 20px;background:#007aff;color:#fff;
   border-radius:8px;text-decoration:none;font-size:14px;font-weight:500">
   Shadowrocket</a>
  <a href="https://{host}{base}?module=ru"
   style="display:inline-block;padding:10px 20px;background:#8e8e93;color:#fff;
   border-radius:8px;text-decoration:none;font-size:12px;font-weight:500">
   Скачать .sgmodule</a>
 </div>
 <div style="font-size:11px;color:#999;margin-top:10px">
  Happ: routing подключается автоматически через подписку</div>
</div>
"""


def _build_html_snippet(host, base):
    base_encoded = urllib.parse.quote(base, safe="")
    return HTML_SNIPPET.format(
        host=host, base=base, base_encoded=base_encoded).encode()


def _load_share_page_template():
    """Lazy-load HTML-шаблона. Negative-cache: пустая строка означает «не нашёлся, не пытаться повторно»."""
    global _share_page_template
    if _share_page_template is None:
        try:
            with open(SHARE_PAGE_TEMPLATE_PATH, "r", encoding="utf-8") as f:
                _share_page_template = f.read()
        except OSError:
            _share_page_template = ""
    return _share_page_template


def lookup_client_name(sub_id):
    """Look up client email/name in 3X-UI's SQLite DB by subId. Returns "" if not found or DB unavailable."""
    if not sub_id:
        return ""
    try:
        con = sqlite3.connect(f"file:{XUI_DB_PATH}?mode=ro", uri=True, timeout=2)
        try:
            for (settings_json,) in con.execute("SELECT settings FROM inbounds"):
                if not settings_json:
                    continue
                try:
                    clients = json.loads(settings_json).get("clients", [])
                except (ValueError, TypeError):
                    continue
                for c in clients:
                    if c.get("subId") == sub_id:
                        return c.get("email", "") or ""
        finally:
            con.close()
    except sqlite3.Error:
        pass
    return ""


def render_share_page(host, request_path):
    """Рендерит share-page HTML. Возвращает bytes или None если шаблон отсутствует."""
    template = _load_share_page_template()
    if not template:
        return None

    # Не стрипим trailing slash — 3X-UI subURI может его требовать,
    # клиенты обязаны принимать оба варианта но проще не ломать canon-форму.
    sub_url = f"https://{host}{request_path}"

    # Happ wants the plain URL after add/ — no base64, no urlencode.
    # Confirmed by Happ docs (Flyfrog-LLC/Happ-docs), 3X-UI PR #3863
    # ("Fix DeepLink for Happ, remove encoding URL"), Remnawave's
    # subscription-page. base64 is reserved for happ://crypt2/3/4 and
    # happ://routing/* — not for plain subscription import.
    sub_url_b64 = base64.urlsafe_b64encode(sub_url.encode()).decode().rstrip("=")
    happ_link = "happ://add/" + sub_url
    shadowrocket_link = "sub://" + sub_url_b64
    v2raytun_link = "v2raytun://import/" + urllib.parse.quote(sub_url, safe="")

    m = SHARE_PAGE_PATH_REGEX.match(request_path)
    sub_id = m.group(1).rstrip("/") if m else ""
    client_name = lookup_client_name(sub_id)
    if client_name:
        name_block = f'<div class="profile">Профиль: <b>{html.escape(client_name)}</b></div>'
    else:
        name_block = ""

    page = (template
        .replace("{{SUBSCRIPTION_URL_HTML}}", html.escape(sub_url))
        .replace("{{SUBSCRIPTION_URL_JSON}}", json.dumps(sub_url))
        .replace("{{HAPP_DEEPLINK}}", html.escape(happ_link))
        .replace("{{V2RAYTUN_DEEPLINK}}", html.escape(v2raytun_link))
        .replace("{{SHADOWROCKET_DEEPLINK}}", html.escape(shadowrocket_link))
        .replace("{{CLIENT_NAME_BLOCK}}", name_block)
    )
    return page.encode("utf-8")


def patch_relay_vless(line):
    """Inject &extra=<RELAY_EXTRA> into relay-like VLESS URLs.

    Targets URLs that:
      - start with vless://
      - carry type=xhttp
      - carry security=reality
      - don't already have extra= (Direct Exit / CDN Asymmetric skip)
    This covers the main relay link generated by 3X-UI, which otherwise ships
    without xmux/padding and loses the client→relay TSPU TLS-policing defense.
    Symmetric CDN links (security=tls) are intentionally not patched — CF
    doesn't handle aggressive mux well.
    """
    if not RELAY_EXTRA:
        return line
    if not line.startswith("vless://"):
        return line
    if "type=xhttp" not in line:
        return line
    if "security=reality" not in line:
        return line
    if "extra=" in line:
        return line
    if "#" in line:
        url_part, fragment = line.split("#", 1)
        return f"{url_part}&extra={RELAY_EXTRA}#{fragment}"
    return f"{line}&extra={RELAY_EXTRA}"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        # Shadowrocket Module endpoint
        if query.get("module", [None])[0] == "ru" and SR_MODULE:
            body = SR_MODULE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition",
                             'attachment; filename="split-ru.sgmodule"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        accept = self.headers.get("Accept", "")
        ua = self.headers.get("User-Agent", "")
        # Apps (Happ, v2rayN, Shadowrocket, etc.) часто шлют Accept с text/html
        # — поэтому одного Accept мало. Реальный браузер ВСЕГДА содержит
        # "Mozilla" в UA (даже Safari/Edge/Chrome — все маскируются под него
        # с 90-х). Такого нет в UA app-клиентов.
        is_browser = "text/html" in accept and "Mozilla" in ua

        # Browser → /<subPath>/<subId> → отдаём share-page вместо 3X-UI HTML.
        # Используем parsed.path (без query/fragment) для матчинга — иначе
        # bookmark с ?refresh=1 проваливается мимо.
        if is_browser and SHARE_PAGE_PATH_REGEX.match(parsed.path):
            host = self.headers.get("Host", "")
            page = render_share_page(host, parsed.path)
            if page is not None:
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.send_header("Cache-Control", "no-store")
                # Anti-leak: subId в URL не должен утечь в Referer
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("X-Frame-Options", "DENY")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("X-Robots-Tag", "noindex, nofollow")
                self.end_headers()
                # BaseHTTPRequestHandler не подавляет body для HEAD автоматически
                if self.command != "HEAD":
                    self.wfile.write(page)
                return
            # Если шаблон не загрузился — fallback на старое поведение (passthrough)

        # Если запрос к subscription URL приходит от app (UA без Mozilla),
        # форсим Accept: */* upstream — иначе 3X-UI отдаст HTML по их
        # Accept: text/html, и мы не сможем подмешать CDN/Hysteria-ссылки
        # в base64 список.
        upstream_accept = accept
        if SHARE_PAGE_PATH_REGEX.match(parsed.path) and not is_browser:
            upstream_accept = "*/*"

        try:
            headers = {
                "Host": self.headers.get("Host", "localhost"),
                "User-Agent": self.headers.get("User-Agent", ""),
                "Accept": upstream_accept,
            }
            req = urllib.request.Request(
                f"{UPSTREAM}{self.path}",
                headers=headers,
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read()
                ct = resp.headers.get("Content-Type", "text/plain")
        except Exception:
            self.send_error(502, "Upstream unavailable")
            return

        is_html = b"<!DOCTYPE" in body[:100] or b"<html" in body[:100]
        is_sub = not is_browser and not is_html and "text/plain" in ct

        # HTML page → inject split routing buttons
        if not is_sub:
            if is_html and SR_MODULE:
                host = self.headers.get("Host", "localhost")
                base = parsed.path
                snippet = _build_html_snippet(host, base)
                if b"</a-layout-content>" in body:
                    body = body.replace(
                        b"</a-layout-content>",
                        snippet + b"</a-layout-content>", 1)
                elif b"</body>" in body:
                    body = body.replace(b"</body>", snippet + b"</body>", 1)
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Subscription response (base64): patch 3X-UI relay link (inject extra=)
        # + append CDN/Direct/Hysteria links + set Happ routing header.
        extra_links = []
        if CDN_LINK_ASYM:
            extra_links.append(CDN_LINK_ASYM)
        if CDN_LINK:
            extra_links.append(CDN_LINK)
        if HYSTERIA_LINK:
            extra_links.append(HYSTERIA_LINK)
        if DIRECT_LINK:
            extra_links.append(DIRECT_LINK)
        if extra_links or RELAY_EXTRA:
            try:
                decoded = base64.b64decode(body).decode("utf-8", errors="replace")
                patched = [patch_relay_vless(ln)
                           for ln in decoded.rstrip("\n").split("\n")
                           if ln.strip()]
                patched.extend(extra_links)
                combined = "\n".join(patched) + "\n"
                body = base64.b64encode(combined.encode()).rstrip(b"=")
            except Exception:
                pass

        self.send_response(200)
        self.send_header("Content-Type", ct)
        if HAPP_ROUTING_HEADER:
            self.send_header("routing", HAPP_ROUTING_HEADER)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    # HEAD is used by some clients for conditional refresh (304 probing).
    # http.server drops the body automatically when method=HEAD.
    do_HEAD = do_GET

    def log_message(self, fmt, *args):
        pass  # silent


if __name__ == "__main__":
    load_templates()
    loaded = []
    if SR_MODULE:
        loaded.append("Shadowrocket module")
    if HAPP_ROUTING_HEADER:
        loaded.append("Happ routing")
    if loaded:
        print(f"sub-proxy: loaded split routing: {', '.join(loaded)}")
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    print(f"sub-proxy listening on 127.0.0.1:{LISTEN_PORT} -> {UPSTREAM}")
    sys.stdout.flush()
    server.serve_forever()
