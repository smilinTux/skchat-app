#!/usr/bin/env bash
# deploy-web.sh — build + serve the SKChat Flutter web app on the DAEMON ORIGIN
# so the loopback-gated consent surface (`/api/v1/consent/*`, gate-5) works.
#
# WHY a wrapper instead of `python -m http.server`:
#   The Flutter web build calls `/api/v1/consent/*` relative to its OWN origin
#   (see lib/services/consent_service.dart). Those endpoints are loopback-gated
#   on the SKComms daemon (:9384) and are NOT proxied by the plain static server
#   (skchat-app-web.service :8088) nor by the skchat webui's daemon_proxy router
#   (:8765/app → /api/v1/consent 404). This script serves build/web AND
#   reverse-proxies /api/* → 127.0.0.1:9384 over loopback (scripts/_web_proxy.py),
#   making consent calls resolve same-origin with NO daemon-code edits.
#
# MODES:
#   --dry-run   (default) Preflight only: check build, key files, daemon reachable,
#               print the exact serve command. Mutates nothing, starts nothing.
#   --build     Run `flutter build web --release` first (then continue per mode).
#   --serve     LIVE: actually start the reverse-proxy server (foreground).
#               This is the live cutover — run it yourself; CI / agents must not.
#   --smoke     Self-contained test: spin a stub upstream + this proxy on ephemeral
#               loopback ports, assert /index + a proxied /api round-trip, tear down.
#               No real infra touched (no :9384, no public bind).
#   --to-webui  (with --serve omitted) Print the alternative: deploy build/web into
#               the skchat webui static dir; prints the rsync + restart commands
#               (does NOT run them — that touches the skchat repo / restarts a svc).
#
# ENV:
#   SKCHAT_WEB_PORT   serve port           (default 8090)
#   SKCHAT_WEB_HOST   bind host            (default 127.0.0.1 — loopback only)
#   SKCOMMS_API       daemon api base      (default http://127.0.0.1:9384)
#   SKCHAT_REPO       skchat repo path     (default ../skchat, for --to-webui)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WEB_DIR="$PROJECT_DIR/build/web"
PROXY_PY="$SCRIPT_DIR/_web_proxy.py"

PORT="${SKCHAT_WEB_PORT:-8090}"
HOST="${SKCHAT_WEB_HOST:-127.0.0.1}"
API="${SKCOMMS_API:-http://127.0.0.1:9384}"
SKCHAT_REPO="${SKCHAT_REPO:-$(cd "$PROJECT_DIR/.." && pwd)/skchat}"

PYTHON="${PYTHON:-python3}"
MODE="dry-run"
DO_BUILD=0
WANT_WEBUI=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)  MODE="dry-run" ;;
    --serve)    MODE="serve" ;;
    --smoke)    MODE="smoke" ;;
    --build)    DO_BUILD=1 ;;
    --to-webui) WANT_WEBUI=1 ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
  esac
done

log() { printf '\033[36m[deploy-web]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[deploy-web] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

flutter_build() {
  log "flutter build web --release"
  command -v flutter >/dev/null 2>&1 || die "flutter not on PATH"
  ( cd "$PROJECT_DIR" && flutter build web --release )
}

# ── key files the build MUST contain (PQC web interop included) ───────────────
REQUIRED=(index.html main.dart.js flutter_bootstrap.js sk_pqc_noble.js)

preflight() {
  local ok=1
  command -v "$PYTHON" >/dev/null 2>&1 || die "$PYTHON not found"
  [ -f "$PROXY_PY" ] || die "missing $PROXY_PY"
  if [ ! -d "$WEB_DIR" ]; then
    die "no build at $WEB_DIR — run with --build (or: flutter build web)"
  fi
  for f in "${REQUIRED[@]}"; do
    if [ -f "$WEB_DIR/$f" ]; then
      log "  ok   $f"
    else
      log "  MISS $f"; ok=0
    fi
  done
  [ "$ok" = 1 ] || die "build/web is incomplete — rebuild with --build"

  # Daemon reachability is advisory (consent is opt-in / may be off).
  if curl -s -m 3 -o /dev/null "$API/api/v1/consent/requests" 2>/dev/null; then
    local code
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$API/api/v1/consent/requests" 2>/dev/null || echo "000")
    log "  daemon $API → /api/v1/consent/requests HTTP $code"
  else
    log "  daemon $API not reachable yet (consent stays dark until it is — OK)"
  fi
}

serve_cmd() {
  printf '%s %q --root %q --api %q --host %q --port %s\n' \
    "$PYTHON" "$PROXY_PY" "$WEB_DIR" "$API" "$HOST" "$PORT"
}

webui_deploy_cmds() {
  local app_dir="$SKCHAT_REPO/src/skchat/static/app"
  cat <<EOF
# ── Alternative: deploy into the skchat webui static dir (origin :8765/app/) ──
# (Use ONLY if the webui's daemon_proxy is wired to forward /api/v1/consent/*;
#  today it 404s those, so the reverse-proxy serve above is the working path.)
rm -rf '$app_dir' && mkdir -p '$app_dir'
rsync -a --delete '$WEB_DIR'/ '$app_dir'/
systemctl --user restart skchat-webui@lumina.service
EOF
}

# ── smoke test: stub upstream + proxy on ephemeral loopback ports ─────────────
smoke() {
  preflight
  local stub_port proxy_port stub_pid="" proxy_pid="" tmp
  tmp="$(mktemp -d)"
  # Trap-referenced state is exported to script scope so the EXIT trap (which
  # fires AFTER this function returns) can still see it under `set -u`.
  SMOKE_TMP="$tmp"
  trap 'rm -rf "${SMOKE_TMP:-}"; kill ${SMOKE_STUB_PID:-0} ${SMOKE_PROXY_PID:-0} 2>/dev/null || true' EXIT

  # Minimal stub standing in for skcomms-api :9384 (so smoke needs no real daemon).
  cat > "$tmp/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path == "/api/v1/consent/requests":
            b = json.dumps({"agent":"lumina","requests":[]}).encode()
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(404); self.end_headers()
srv = HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
print("stub-ready", flush=True); srv.serve_forever()
PY
  stub_port=$("$PYTHON" - <<'PY'
import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()
PY
)
  proxy_port=$("$PYTHON" - <<'PY'
import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()
PY
)
  "$PYTHON" "$tmp/stub.py" "$stub_port" >/dev/null 2>&1 & stub_pid=$!; SMOKE_STUB_PID=$stub_pid
  "$PYTHON" "$PROXY_PY" --root "$WEB_DIR" --api "http://127.0.0.1:$stub_port" \
      --host 127.0.0.1 --port "$proxy_port" >/dev/null 2>&1 & proxy_pid=$!; SMOKE_PROXY_PID=$proxy_pid

  # Wait for the proxy to accept connections.
  local up=0 i
  for i in $(seq 1 50); do
    if curl -s -m 1 -o /dev/null "http://127.0.0.1:$proxy_port/index.html" 2>/dev/null; then up=1; break; fi
    sleep 0.1
  done
  [ "$up" = 1 ] || die "smoke: proxy did not come up"

  local fails=0
  _check() { # desc  expected-substr  actual
    if printf '%s' "$3" | grep -q "$2"; then log "  PASS $1"; else log "  FAIL $1 (got: $3)"; fails=$((fails+1)); fi
  }
  _check "static index served"      "200" "$(curl -s -m3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/index.html")"
  _check "SPA fallback (/requests)" "200" "$(curl -s -m3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/requests")"
  _check "pqc web interop present"  "200" "$(curl -s -m3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/sk_pqc_noble.js")"
  _check "api proxied → upstream"   "200" "$(curl -s -m3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/api/v1/consent/requests")"
  _check "consent body proxied"     '"requests"' "$(curl -s -m3 "http://127.0.0.1:$proxy_port/api/v1/consent/requests")"

  if [ "$fails" = 0 ]; then log "SMOKE OK (5/5)"; else die "SMOKE FAILED ($fails check(s))"; fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────
[ "$DO_BUILD" = 1 ] && flutter_build

case "$MODE" in
  dry-run)
    preflight
    log "DRY RUN — nothing started. To serve build/web on the daemon origin run:"
    echo
    serve_cmd
    echo
    [ "$WANT_WEBUI" = 1 ] && webui_deploy_cmds
    log "(or re-run this script with --serve to start it; --smoke to self-test)"
    ;;
  serve)
    preflight
    log "LIVE serve on http://$HOST:$PORT  (/api/* → $API). Ctrl-C to stop."
    exec "$PYTHON" "$PROXY_PY" --root "$WEB_DIR" --api "$API" --host "$HOST" --port "$PORT"
    ;;
  smoke)
    smoke
    ;;
esac
