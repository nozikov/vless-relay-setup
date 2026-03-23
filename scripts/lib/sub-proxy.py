#!/usr/bin/env python3
"""Subscription proxy: fetches from 3X-UI and appends CDN VLESS link.

Browser requests (Accept: text/html) are passed through as-is so the
3X-UI subscription page with QR codes works normally.

App requests (no Accept: text/html) get the CDN link appended to the
base64-encoded subscription response.
"""

import http.server
import urllib.request
import base64
import os
import sys

UPSTREAM = os.environ.get("SUB_UPSTREAM", "http://127.0.0.1:8443")
CDN_LINK = os.environ.get("CDN_VLESS_LINK", "")
CDN_LINK_ASYM = os.environ.get("CDN_VLESS_LINK_ASYM", "")
LISTEN_PORT = int(os.environ.get("SUB_PROXY_PORT", "18443"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        accept = self.headers.get("Accept", "")
        is_browser = "text/html" in accept

        try:
            headers = {
                "Host": self.headers.get("Host", "localhost"),
                "User-Agent": self.headers.get("User-Agent", ""),
                "Accept": accept,
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

        # Non-subscription content (HTML pages, CSS, JS, images) → pass through as-is
        is_html = b"<!DOCTYPE" in body[:100] or b"<html" in body[:100]
        is_sub = not is_browser and not is_html and "text/plain" in ct

        if not is_sub:
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Subscription response (base64) → append CDN links
        cdn_links = []
        if CDN_LINK_ASYM:
            cdn_links.append(CDN_LINK_ASYM)
        if CDN_LINK:
            cdn_links.append(CDN_LINK)
        if cdn_links:
            try:
                decoded = base64.b64decode(body).decode("utf-8", errors="replace")
                combined = decoded.rstrip("\n") + "\n" + "\n".join(cdn_links) + "\n"
                body = base64.b64encode(combined.encode()).rstrip(b"=")
            except Exception:
                pass  # non-base64 response, return as-is

        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def log_message(self, fmt, *args):
        pass  # silent


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    print(f"sub-proxy listening on 127.0.0.1:{LISTEN_PORT} -> {UPSTREAM}")
    sys.stdout.flush()
    server.serve_forever()
