#!/usr/bin/env python3
"""Same-origin static + /api reverse-proxy for the SKChat Flutter web build.

The consent surface (gate-5: ``/api/v1/consent/*``) is **loopback-gated** on the
SKComms daemon (:9384) — it 403s any non-loopback caller. The Flutter *web* build
calls those endpoints **relative to its own origin** (see
``lib/services/consent_service.dart``), so the build must be served from an origin
that reverse-proxies ``/api/*`` to the daemon over loopback. The standalone
``python -m http.server`` (skchat-app-web.service :8088) does NOT proxy ``/api``,
so consent calls 404 there; the webui (:8765) serves ``/app/`` but its
``daemon_proxy`` router does not forward ``/api/v1/consent/*`` either (returns
404). This tiny server closes that gap with **no edits to any daemon code**:

  * ``/api/*``           → forwarded to ``--api`` (default ``http://127.0.0.1:9384``)
  * any existing file    → served from ``--root`` (the ``build/web`` dir)
  * anything else        → ``index.html`` (SPA fallback; ``base href="/"``)

Stdlib only — no third-party deps, so it runs anywhere python3 does. Binds to
loopback by default (the consent endpoints are loopback-only anyway).
"""
from __future__ import annotations

import argparse
import sys
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Hop-by-hop headers must not be forwarded (RFC 7230 §6.1).
_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
}


class _Handler(SimpleHTTPRequestHandler):
    """Serve build/web; reverse-proxy /api/* to the loopback daemon."""

    api_base: str = "http://127.0.0.1:9384"
    root: str = "."

    # SimpleHTTPRequestHandler resolves paths against `directory`.
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=type(self).root, **kwargs)

    # Quieter logs (one line, stderr).
    def log_message(self, fmt: str, *args) -> None:  # noqa: A002
        sys.stderr.write("[web-proxy] " + (fmt % args) + "\n")

    # ---- proxy ---------------------------------------------------------------
    def _is_api(self) -> bool:
        return self.path.split("?", 1)[0].startswith("/api/")

    def _proxy(self, method: str) -> None:
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        url = self.api_base.rstrip("/") + self.path
        fwd = {
            k: v for k, v in self.headers.items() if k.lower() not in _HOP
        }
        req = urllib.request.Request(url, data=body, method=method, headers=fwd)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                self._relay(resp.status, resp.headers.items(), resp.read())
        except urllib.error.HTTPError as e:  # upstream 4xx/5xx — relay as-is.
            self._relay(e.code, e.headers.items(), e.read())
        except Exception as e:  # daemon down / refused.
            msg = f'{{"error":"upstream_unreachable","detail":{e!r}}}'.encode()
            self._relay(502, [("Content-Type", "application/json")], msg)

    def _relay(self, status: int, headers, body: bytes) -> None:
        self.send_response(status)
        for k, v in headers:
            if k.lower() in _HOP:
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # ---- static + SPA fallback ----------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        if self._is_api():
            return self._proxy("GET")
        path = self.translate_path(self.path)
        if not Path(path).is_file() and not Path(path).is_dir():
            # SPA deep-link (e.g. /requests) → serve the Flutter shell.
            self.path = "/index.html"
        return super().do_GET()

    def do_HEAD(self) -> None:  # noqa: N802
        if self._is_api():
            return self._proxy("HEAD")
        return super().do_HEAD()

    def do_POST(self) -> None:  # noqa: N802
        if self._is_api():
            return self._proxy("POST")
        self.send_error(405)

    def do_PUT(self) -> None:  # noqa: N802
        if self._is_api():
            return self._proxy("PUT")
        self.send_error(405)

    def do_DELETE(self) -> None:  # noqa: N802
        if self._is_api():
            return self._proxy("DELETE")
        self.send_error(405)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", required=True, help="build/web directory to serve")
    ap.add_argument("--api", default="http://127.0.0.1:9384",
                    help="loopback daemon base (default skcomms-api :9384)")
    ap.add_argument("--host", default="127.0.0.1", help="bind host")
    ap.add_argument("--port", type=int, default=8090, help="bind port")
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    if not (root / "index.html").is_file():
        ap.error(f"no index.html under --root {root} (run `flutter build web`)")

    _Handler.api_base = args.api
    _Handler.root = str(root)
    httpd = ThreadingHTTPServer((args.host, args.port), _Handler)
    sys.stderr.write(
        f"[web-proxy] serving {root} on http://{args.host}:{args.port}  "
        f"(/api/* → {args.api})\n"
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
