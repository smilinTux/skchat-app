#!/usr/bin/env python3
"""Measure real Watch Together drift between two live browsers over CDP.

WHY MEASUREMENT IS THE DELIVERABLE, NOT UI AUTOMATION:
The Spaces app is Flutter web rendered to a single <canvas>. There is no DOM
to click: joining a Space and loading a video happens through Flutter's own
canvas-drawn widgets, which have no stable selector a script can target.
Coordinate-based clicking against a canvas breaks the moment a layout
changes by a few pixels, and it breaks silently: the script would report
success while actually clicking nothing. A script that can lie about its own
result is worse than no script. So this tool does not drive the UI at all.
It assumes a human (or a separate, purpose-built harness) has already put
both browsers into a Watch Together session, and it measures what is
actually happening: the real playback position each browser's video element
reports, sampled from both sides at the same wall-clock moments.

WHY DRIFT GROWTH IS THE SIGNAL THAT MATTERS:
docs/watch-together.md documents a 2.0 second dead band (watch_drift.dart,
resolveDrift): corrections only fire once |local - host| exceeds it, because
constant micro-correction stutters playback worse than being briefly off.
That means healthy sync is NOT "drift is always near zero". Healthy sync is
bounded jitter: drift wanders up toward the dead band, a correction pulls it
back down, and it never runs away. The one failure mode that produces a
different shape entirely is the heartbeat not being applied: one player
just keeps playing while the other never gets corrected, so drift climbs
roughly one second of gap for every second of wall time and never comes
back down. A single max drift number cannot tell these apart: a healthy
run can touch 2.1 seconds once and come straight back, and a broken run
can sit under 2.5 seconds for the first ten samples before it takes off.
This script fits a trend line to drift-over-time and treats a sustained
upward slope, not a peak value, as the sign that the heartbeat is not
converging. Peak and mean are still reported because a release gate wants
both: is it currently drifting too far, and is it getting worse over time.

HOW THE REAL POSITION IS READ:
The YouTube IFrame API only pushes player state (currentTime, playerState)
to the parent window after the parent posts a {"event":"listening"}
handshake to the iframe. This technique was verified live over CDP against
Brave 150 on .41. The handshake and a message listener are installed ONCE
per page (not re-sent per sample): the listener accumulates the latest
infoDelivery payload into a variable on window, and each sample is a cheap
read of that variable rather than a fresh round trip through the iframe.

CDP MECHANICS, AND A DEVIATION FROM THE ORIGINAL GENEROUS-TIMEOUT ADVICE:
Neither machine this was built against had the `websockets` or
`websocket-client` package installed, so this vendors a minimal,
dependency-free websocket client (HTTP upgrade handshake, masked frame
writes, frame reads) rather than adding a new dependency for one script.
The implementation below is the same approach proven working at
/tmp/cdp_eval.py on .41; vendored here because /tmp is scratch space that
does not survive.

An earlier draft of this script used a single generous socket timeout
(120 seconds) on the theory that a short timeout could kill an in-flight
but merely slow probe. Running it for real showed the opposite failure: .41
keeps SEVERAL page targets open whose URL contains "/app/" (multiple
Spaces and Chats tabs at once), and Chrome throttles JavaScript in
backgrounded tabs, so a probe against an inactive tab can sit unanswered
for a very long time. Walking those targets serially with a 120 second
timeout on each one meant a single unresponsive tab could stall discovery
for minutes, and with several such tabs the whole run looked hung. A
release gate that can hang is strictly worse than one that fails fast with
a clear reason, because a hang blocks a pipeline with no diagnosis at all.

The fix has three parts, all deliberate:
  1. Every CDP operation (connect, evaluate, and the reads inside both) now
     carries a SHORT, purpose-specific timeout instead of one generous one.
     A live, foregrounded tab answers in well under a second; a few seconds
     is already a generous allowance, not a stingy one.
  2. Discovery caps how many "/app/" targets it will probe per browser and
     gives up on the whole search after a fixed wall-clock budget, so a pile
     of unrelated open tabs cannot multiply into an unbounded search.
  3. The whole run is wrapped in a hard wall-clock watchdog (SIGALRM) that
     is completely independent of every timeout above. If any code path
     anywhere still manages to block past the deadline, the watchdog
     interrupts it, reports which step it was in, and exits non-zero. This
     is the backstop of last resort: even a bug in the reasoning above
     cannot turn into a silent hang.

Reaching the remote browser (.41) is done by opening a local SSH port
forward and then talking to it exactly like a local endpoint. This keeps
one single code path for "local" and "remote" instead of two: once the
tunnel is up, 127.0.0.1:<local-port> behaves identically whether the real
Chrome is on this machine or across the tailnet.
"""

from __future__ import annotations

import argparse
import atexit
import base64
import json
import math
import os
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ============================================================================
# Vendored dependency-free CDP websocket client.
# Ported from the proven /tmp/cdp_eval.py technique (Runtime.evaluate over a
# raw masked-frame websocket, no third-party libraries).
# ============================================================================


def ws_connect(host: str, port: int, path: str, timeout: float) -> socket.socket:
    """Open a websocket to a CDP target via the raw HTTP Upgrade handshake.

    timeout bounds the TCP connect AND every read inside the handshake: it is
    a per-operation deadline, not a hint, because socket.settimeout applies
    to every subsequent blocking call on this socket including the ones the
    caller makes later for Runtime.evaluate replies.
    """
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    hostport = f"{host}:{port}"
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {hostport}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError(f"CDP handshake to {hostport}{path} closed before completing")
        buf += chunk
    status_line = buf.split(b"\r\n", 1)[0]
    if b"101" not in status_line:
        raise ConnectionError(f"CDP handshake to {hostport}{path} failed: {status_line!r}")
    return s


def ws_send(s: socket.socket, text: str) -> None:
    """Write one masked text frame. Client-to-server frames must be masked per RFC 6455."""
    data = text.encode()
    n = len(data)
    hdr = b"\x81"  # FIN + opcode 0x1 (text)
    if n < 126:
        hdr += struct.pack("!B", 0x80 | n)
    elif n < 65536:
        hdr += struct.pack("!BH", 0x80 | 126, n)
    else:
        hdr += struct.pack("!BQ", 0x80 | 127, n)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    s.sendall(hdr + mask + masked)


def _recv_exact(s: socket.socket, n: int) -> bytes:
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            raise EOFError("CDP socket closed mid-frame")
        out += chunk
    return out


def ws_recv(s: socket.socket) -> str:
    """Read one text frame, skipping pings/etc. Raises on a close frame.

    Bounded by whatever timeout is already set on the socket (see
    ws_connect): a read that gets no bytes at all raises TimeoutError from
    the underlying socket call, it never blocks forever.
    """
    while True:
        b1, b2 = _recv_exact(s, 2)
        opcode = b1 & 0x0F
        ln = b2 & 0x7F
        if ln == 126:
            ln = struct.unpack("!H", _recv_exact(s, 2))[0]
        elif ln == 127:
            ln = struct.unpack("!Q", _recv_exact(s, 8))[0]
        payload = _recv_exact(s, ln)
        if opcode == 1:  # text frame
            return payload.decode()
        if opcode == 8:  # close
            raise EOFError("CDP websocket closed by remote")
        # ignore pings/pongs/binary continuation, keep reading


class CdpSession:
    """One persistent websocket to one page target, used for repeated evals.

    Persistent so the listening handshake and its accumulator variable
    survive across every sample in the run: re-navigating or reconnecting
    per sample would lose the accumulated infoDelivery state and defeat
    the whole "install once, poll cheaply" design.
    """

    def __init__(self, http_host: str, http_port: int, ws_debugger_url: str, connect_timeout: float):
        # The target's own webSocketDebuggerUrl reports whatever host:port the
        # browser itself is listening on. When http_host/http_port is really a
        # local SSH tunnel entry point, that reported host:port is wrong to
        # dial directly, so only the PATH is kept and re-combined with the
        # host:port we actually used to reach this browser.
        path = urllib.parse.urlsplit(ws_debugger_url).path
        self.sock = ws_connect(http_host, http_port, path, timeout=connect_timeout)
        self._next_id = 1

    def eval(self, expression: str, timeout: float):
        """Runtime.evaluate the expression, return its value, raise on a JS exception.

        timeout is a per-call deadline, explicit at every call site on
        purpose: discovery probes and live sampling reads have very
        different legitimate latencies, so there is no single safe default.
        """
        self.sock.settimeout(timeout)
        msg_id = self._next_id
        self._next_id += 1
        ws_send(
            self.sock,
            json.dumps(
                {
                    "id": msg_id,
                    "method": "Runtime.evaluate",
                    "params": {"expression": expression, "returnByValue": True, "awaitPromise": True},
                }
            ),
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            raw = ws_recv(self.sock)
            msg = json.loads(raw)
            if msg.get("id") == msg_id:
                result = msg.get("result", {})
                if "exceptionDetails" in result:
                    raise RuntimeError(f"JS exception: {json.dumps(result['exceptionDetails'])[:500]}")
                return result.get("result", {}).get("value")
            # not our reply (a leftover event from a domain we never enabled
            # should not normally arrive, but keep reading defensively)
        raise TimeoutError(f"CDP eval timed out after {timeout}s waiting for id={msg_id}")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# ============================================================================
# Endpoint abstraction: local direct, or remote via an SSH local port forward.
# Both resolve to a plain (host, port) pair that behaves identically from
# here on, which is the entire point: one code path for local and remote.
# ============================================================================


class ResolvedEndpoint:
    def __init__(self, host: str, port: int, cleanup=None):
        self.host = host
        self.port = port
        self._cleanup = cleanup

    def close(self) -> None:
        if self._cleanup:
            self._cleanup()


def _free_local_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def resolve_endpoint(spec: str, ssh_connect_timeout: float) -> ResolvedEndpoint:
    """Parse one endpoint spec and return a ready-to-use (host, port).

    Spec forms:
      local:PORT                a CDP endpoint already reachable on this machine
      ssh:user@host:PORT        a CDP endpoint on a remote machine, tunneled in
    """
    if spec.startswith("local:"):
        port = int(spec.split(":", 1)[1])
        return ResolvedEndpoint("127.0.0.1", port)

    if spec.startswith("ssh:"):
        rest = spec[len("ssh:") :]
        ssh_target, _, port_str = rest.rpartition(":")
        remote_port = int(port_str)
        if not ssh_target:
            raise ValueError(f"malformed ssh endpoint spec (need ssh:user@host:PORT): {spec!r}")
        local_port = _free_local_port()
        proc = subprocess.Popen(
            [
                "ssh",
                "-N",
                "-o",
                f"ConnectTimeout={int(ssh_connect_timeout)}",
                "-o",
                "ExitOnForwardFailure=yes",
                "-L",
                f"{local_port}:127.0.0.1:{remote_port}",
                ssh_target,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

        # Wait for the tunnel to actually accept connections rather than a
        # fixed sleep: ssh -N prints nothing on success, so "can we connect"
        # is the only reliable readiness signal.
        deadline = time.monotonic() + ssh_connect_timeout
        last_err = None
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                stderr = proc.stderr.read().decode(errors="replace") if proc.stderr else ""
                raise ConnectionError(
                    f"ssh tunnel to {ssh_target} for port {remote_port} exited early: {stderr.strip()}"
                )
            try:
                probe = socket.create_connection(("127.0.0.1", local_port), timeout=1.0)
                probe.close()
                break
            except OSError as exc:
                last_err = exc
                time.sleep(0.2)
        else:
            proc.terminate()
            raise ConnectionError(
                f"ssh tunnel to {ssh_target} for port {remote_port} never became reachable: {last_err}"
            )

        def cleanup():
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

        atexit.register(cleanup)
        return ResolvedEndpoint("127.0.0.1", local_port, cleanup=cleanup)

    raise ValueError(f"unrecognized endpoint spec (want local:PORT or ssh:user@host:PORT): {spec!r}")


def list_page_targets(endpoint: ResolvedEndpoint, timeout: float):
    """GET /json/list from a CDP endpoint. Returns [] (not an error) if unreachable,
    since a browser side legitimately offering multiple candidate ports means
    some of them are expected to be closed."""
    url = f"http://{endpoint.host}:{endpoint.port}/json/list"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.load(resp)
    except (urllib.error.URLError, OSError, TimeoutError):
        return []


# ============================================================================
# Watch-surface discovery and drift sampling.
# ============================================================================

APP_PATH_DEFAULT = "/app/"
EMBED_MARKER = "/embed/"

# Discovery timeouts are short on purpose: a foregrounded, live tab answers a
# querySelector in well under a second. A few seconds is already generous.
# These are what actually prevents the hang described in the module
# docstring, the hard wall-clock watchdog in main() is only the backstop.
CONNECT_TIMEOUT = 6.0
DISCOVERY_EVAL_TIMEOUT = 6.0
LIST_TARGETS_TIMEOUT = 8.0

# Sampling reads should also be near-instant on a live, connected page. This
# is more generous than discovery because a browser under real load (video
# decode, LiveKit tracks) is doing more work than an idle tab, but it is
# still an order of magnitude below the old 120s figure.
SAMPLE_EVAL_TIMEOUT = 10.0

# A browser can have several tabs whose URL matches "/app/" open at once
# (multiple Spaces or Chats tabs). Probing all of them without a cap is what
# turned one slow tab into a multi-minute stall; cap the count AND give the
# whole search a wall-clock budget independent of how many targets exist.
MAX_APP_TARGETS_TO_PROBE = 4
DISCOVERY_BUDGET_SECONDS = 20.0

# If a browser stops answering sample polls for several ticks in a row, stop
# the whole run instead of grinding through the remaining duration one slow
# timeout at a time: that is a real connectivity failure, and the human
# running this needs to know NOW, not after paying for every remaining tick.
CONSECUTIVE_SAMPLE_FAILURE_LIMIT = 3

FIND_WATCH_IFRAME_JS = f"""
(function() {{
  var f = document.querySelector('iframe[src*="{EMBED_MARKER}"]');
  return f ? f.src : null;
}})();
"""

INSTALL_LISTENER_JS = f"""
(function() {{
  if (window.__watchSyncProbe) return "already-installed";
  var iframe = document.querySelector('iframe[src*="{EMBED_MARKER}"]');
  if (!iframe) return "no-iframe";
  window.__watchSyncProbe = {{currentTime: null, playerState: null, tsMs: null, count: 0}};
  window.addEventListener("message", function(e) {{
    if (e.source !== iframe.contentWindow) return;
    var d;
    try {{ d = JSON.parse(e.data); }} catch (err) {{ return; }}
    if (d && d.event === "infoDelivery" && d.info && typeof d.info.currentTime === "number") {{
      window.__watchSyncProbe.currentTime = d.info.currentTime;
      window.__watchSyncProbe.playerState = d.info.playerState;
      window.__watchSyncProbe.tsMs = Date.now();
      window.__watchSyncProbe.count += 1;
    }}
  }});
  iframe.contentWindow.postMessage(JSON.stringify({{event: "listening", id: "verify-watch-sync"}}), "https://www.youtube.com");
  return "installed";
}})();
"""

POLL_JS = """
(function() {
  var p = window.__watchSyncProbe;
  if (!p) return null;
  return {currentTime: p.currentTime, playerState: p.playerState, tsMs: p.tsMs, count: p.count};
})();
"""


# ============================================================================
# Hard wall-clock watchdog. Independent of every timeout above: if any code
# path anywhere still manages to block, this is what guarantees the process
# still exits. current_step is a plain 1-element list, mutated right before
# every operation that could conceivably block, so the alarm handler can
# report exactly what was in flight when it fired.
# ============================================================================

current_step = ["startup"]


class HardDeadlineExceeded(Exception):
    pass


def _set_step(description: str) -> None:
    current_step[0] = description


def _alarm_handler(signum, frame):
    raise HardDeadlineExceeded(current_step[0])


# ============================================================================
# One browser side, possibly reachable on more than one CDP port.
# ============================================================================


class BrowserSide:
    """.158 in this epic runs two separate Chrome CDP listeners (9223 and
    9229); which one currently has the Spaces tab open is not fixed, so a
    side is a list of candidate endpoints, not a single one."""

    def __init__(self, label: str, endpoints: list[ResolvedEndpoint]):
        self.label = label
        self.endpoints = endpoints
        self.session: CdpSession | None = None
        self.target_url: str | None = None
        self.iframe_src: str | None = None

    def find_app_targets(self):
        """All page targets across all candidate endpoints whose URL matches
        the app path filter. Returns list of (endpoint, target_dict)."""
        found = []
        for ep in self.endpoints:
            _set_step(f"{self.label}: listing targets on {ep.host}:{ep.port}")
            for tgt in list_page_targets(ep, timeout=LIST_TARGETS_TIMEOUT):
                if tgt.get("type") == "page" and APP_PATH_DEFAULT in tgt.get("url", ""):
                    found.append((ep, tgt))
        return found

    def find_watch_surface(self):
        """Locate a page target with a live YouTube embed iframe, open a
        persistent CDP session to it, and install the polling listener.
        Returns None on success (state is stored on self), or a human
        readable diagnostic string on failure.

        Bounded on two axes at once: at most MAX_APP_TARGETS_TO_PROBE
        targets are ever probed, and the whole search gives up after
        DISCOVERY_BUDGET_SECONDS regardless of how many targets remain.
        Either bound alone would have prevented the original hang; both are
        kept because they fail for different reasons (too many targets vs.
        each one being individually slow) and a fix for one does not cover
        the other.
        """
        app_targets = self.find_app_targets()
        if not app_targets:
            return (
                f"{self.label}: no page with '{APP_PATH_DEFAULT}' in its URL was found on any "
                f"of its CDP ports ({', '.join(f'{e.host}:{e.port}' for e in self.endpoints)}). "
                "The Spaces app does not appear to be open in this browser at all."
            )

        # Watch Together only ever runs on the Spaces route, so a target
        # already on that route is far more likely to be the right one.
        # Checking it first means the probe budget is spent where it is
        # most likely to pay off, instead of being spent in open-tab order.
        app_targets.sort(key=lambda pair: 0 if "#/spaces" in pair[1].get("url", "") else 1)

        capped = app_targets[:MAX_APP_TARGETS_TO_PROBE]
        skipped_by_cap = len(app_targets) - len(capped)

        budget_deadline = time.monotonic() + DISCOVERY_BUDGET_SECONDS
        checked = []
        stopped_on_budget = False

        for ep, tgt in capped:
            if time.monotonic() > budget_deadline:
                stopped_on_budget = True
                break

            _set_step(f"{self.label}: probing {tgt.get('url')}")
            try:
                probe = CdpSession(ep.host, ep.port, tgt["webSocketDebuggerUrl"], connect_timeout=CONNECT_TIMEOUT)
                src = probe.eval(FIND_WATCH_IFRAME_JS, timeout=DISCOVERY_EVAL_TIMEOUT)
            except (OSError, RuntimeError, TimeoutError, EOFError) as exc:
                checked.append(f"  - {tgt.get('url')} (did not answer within the discovery timeout: {exc})")
                continue

            if not src:
                checked.append(f"  - {tgt.get('url')} (open, but no {EMBED_MARKER} iframe on it)")
                probe.close()
                continue

            # Found it: keep this session alive, install the listener now
            # while we already have the iframe present and the socket open.
            _set_step(f"{self.label}: installing listener on {tgt.get('url')}")
            install_result = probe.eval(INSTALL_LISTENER_JS, timeout=DISCOVERY_EVAL_TIMEOUT)
            if install_result not in ("installed", "already-installed"):
                checked.append(f"  - {tgt.get('url')} (iframe found but listener install said {install_result!r})")
                probe.close()
                continue

            self.session = probe
            self.target_url = tgt.get("url")
            self.iframe_src = src
            return None

        if stopped_on_budget:
            checked.append(
                f"  - (discovery budget of {DISCOVERY_BUDGET_SECONDS:.0f}s exceeded, stopped before "
                "checking the remaining targets)"
            )
        if skipped_by_cap:
            checked.append(
                f"  - ({skipped_by_cap} additional '{APP_PATH_DEFAULT}' target(s) not checked, "
                f"capped at {MAX_APP_TARGETS_TO_PROBE})"
            )

        detail = "\n".join(checked) if checked else "  (no page targets matched at all)"
        return (
            f"{self.label}: found {len(app_targets)} page(s) under '{APP_PATH_DEFAULT}' but none has a live "
            f"Watch Together surface (an iframe whose src contains '{EMBED_MARKER}'):\n{detail}\n"
            f"{self.label}: a human needs to open the Space in this browser and start a Watch Together "
            "video (paste a YouTube URL into the panel and press Load) before this script can measure anything."
        )

    def sample(self):
        """One poll of the accumulated player state. Returns dict or None."""
        assert self.session is not None
        return self.session.eval(POLL_JS, timeout=SAMPLE_EVAL_TIMEOUT)

    def close(self):
        if self.session:
            self.session.close()


# ============================================================================
# Drift statistics.
# ============================================================================


def linreg_slope(xs, ys):
    """Ordinary least squares slope, pure python (no numpy dependency).
    Used to characterize drift-over-time as bounded jitter vs. runaway growth."""
    n = len(xs)
    if n < 2:
        return 0.0
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    num = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    den = sum((x - mean_x) ** 2 for x in xs)
    if den == 0:
        return 0.0
    return num / den


def format_report(samples, dead_band, max_drift_gate, growth_slope_threshold):
    """samples: list of (elapsed_seconds, drift_seconds). Returns (report_text, ok: bool)."""
    if not samples:
        # Zero samples is a hard failure, never a silent pass: it means every
        # single poll round trip failed, which is a broken measurement run,
        # not a "drift was fine" result.
        return "No samples were collected. This is a measurement failure, not a passing result.", False

    drifts = [d for _, d in samples]
    n = len(drifts)
    max_drift = max(drifts)
    mean_drift = sum(drifts) / n
    over_band = sum(1 for d in drifts if d > dead_band)
    slope = linreg_slope([t for t, _ in samples], drifts)

    # "Unbounded growth" is a sustained rate, not a single big number: a
    # slope this high sustained across the whole run means the gap between
    # the two players is opening roughly in lockstep with wall time, which
    # is exactly what happens when nothing is correcting it (see module
    # docstring). Bounded jitter around the dead band has a slope near zero
    # even though individual samples bounce around.
    growing_unbounded = slope > growth_slope_threshold

    lines = [
        f"Samples collected: {n}",
        f"Max drift: {max_drift:.3f}s",
        f"Mean drift: {mean_drift:.3f}s",
        f"Samples over the {dead_band:.1f}s dead band: {over_band}/{n}",
        f"Drift trend: {slope:+.4f}s per second of wall time"
        + (" (GROWING, looks unbounded)" if growing_unbounded else " (bounded)"),
    ]

    ok = True
    if max_drift > max_drift_gate:
        lines.append(f"FAIL: max drift {max_drift:.3f}s exceeds the {max_drift_gate:.1f}s gate.")
        ok = False
    if growing_unbounded:
        lines.append(
            f"FAIL: drift is growing at {slope:.4f}s/s, above the {growth_slope_threshold:.4f}s/s "
            "threshold. This is the signature of the heartbeat not being applied."
        )
        ok = False
    if ok:
        lines.append("PASS: drift stayed bounded and within gate for the whole run.")

    return "\n".join(lines), ok


# ============================================================================
# Main.
# ============================================================================


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument(
        "--browser-a",
        default="ssh:cbrd21@100.86.156.5:9222",
        help="comma-separated endpoint specs for browser A (default: .41 Brave over ssh tunnel)",
    )
    p.add_argument(
        "--browser-b",
        default="local:9223,local:9229",
        help="comma-separated endpoint specs for browser B (default: .158 Chrome, both known CDP ports)",
    )
    p.add_argument("--duration", type=float, default=60.0, help="total sampling window in seconds (default 60)")
    p.add_argument("--interval", type=float, default=2.0, help="seconds between samples (default 2)")
    p.add_argument("--dead-band", type=float, default=2.0, help="drift dead band in seconds, matches watch_drift.dart")
    p.add_argument("--max-drift", type=float, default=5.0, help="hard fail gate for max observed drift, seconds")
    p.add_argument(
        "--growth-slope-threshold",
        type=float,
        default=0.1,
        help="drift growth rate (seconds/second) above which the run is flagged as unbounded",
    )
    p.add_argument("--ssh-connect-timeout", type=float, default=15.0, help="seconds to wait for an ssh tunnel to come up")
    p.add_argument(
        "--max-runtime",
        type=float,
        default=None,
        help="hard wall-clock ceiling for the entire run, seconds (default: auto-computed from --duration)",
    )
    return p.parse_args(argv)


def build_side(label: str, spec: str, ssh_connect_timeout: float) -> BrowserSide:
    _set_step(f"{label}: resolving endpoint(s) {spec!r}")
    endpoints = [resolve_endpoint(s.strip(), ssh_connect_timeout) for s in spec.split(",") if s.strip()]
    if not endpoints:
        raise ValueError(f"{label}: --browser spec resolved to zero endpoints ({spec!r})")
    return BrowserSide(label, endpoints)


def run(args) -> int:
    print("verify-watch-sync: connecting to both browsers over CDP...")
    side_a = build_side("Browser A", args.browser_a, args.ssh_connect_timeout)
    side_b = build_side("Browser B", args.browser_b, args.ssh_connect_timeout)

    try:
        print(f"verify-watch-sync: looking for a live Watch Together surface on {side_a.label}...")
        err_a = side_a.find_watch_surface()
        print(f"verify-watch-sync: looking for a live Watch Together surface on {side_b.label}...")
        err_b = side_b.find_watch_surface()

        if err_a or err_b:
            print("\nPRECONDITION NOT MET: cannot measure drift yet.\n", file=sys.stderr)
            if err_a:
                print(err_a + "\n", file=sys.stderr)
            if err_b:
                print(err_b + "\n", file=sys.stderr)
            print(
                "What to do: open the Space in both browsers at "
                "https://noroc2027.tail204f0c.ts.net/app/#/spaces, then in one of them open the "
                "Watch Together panel, paste a YouTube URL, and press Load. Once the video is "
                "playing on the main stage in both browsers, re-run this script.",
                file=sys.stderr,
            )
            return 1

        print(f"verify-watch-sync: {side_a.label} watch surface: {side_a.target_url}")
        print(f"verify-watch-sync: {side_a.label} iframe: {side_a.iframe_src}")
        print(f"verify-watch-sync: {side_b.label} watch surface: {side_b.target_url}")
        print(f"verify-watch-sync: {side_b.label} iframe: {side_b.iframe_src}")

        n_ticks = max(1, int(args.duration // args.interval))
        print(
            f"verify-watch-sync: sampling every {args.interval:.1f}s for {args.duration:.0f}s "
            f"({n_ticks} samples)..."
        )

        samples = []  # (elapsed_seconds, drift_seconds)
        start = time.monotonic()
        missed_a = 0
        missed_b = 0
        consecutive_missed_a = 0
        consecutive_missed_b = 0
        aborted_early = None

        for i in range(n_ticks):
            target_time = start + i * args.interval
            now = time.monotonic()
            if target_time > now:
                _set_step(f"pacing to sample tick {i}")
                time.sleep(target_time - now)

            elapsed = time.monotonic() - start
            _set_step(f"{side_a.label}: sampling tick {i}")
            try:
                a = side_a.sample()
            except (OSError, RuntimeError, TimeoutError, EOFError) as exc:
                print(f"  [{elapsed:6.1f}s] {side_a.label} sample failed: {exc}", file=sys.stderr)
                a = None

            _set_step(f"{side_b.label}: sampling tick {i}")
            try:
                b = side_b.sample()
            except (OSError, RuntimeError, TimeoutError, EOFError) as exc:
                print(f"  [{elapsed:6.1f}s] {side_b.label} sample failed: {exc}", file=sys.stderr)
                b = None

            pos_a = a.get("currentTime") if a else None
            pos_b = b.get("currentTime") if b else None

            consecutive_missed_a = 0 if pos_a is not None else consecutive_missed_a + 1
            consecutive_missed_b = 0 if pos_b is not None else consecutive_missed_b + 1
            if pos_a is None:
                missed_a += 1
            if pos_b is None:
                missed_b += 1

            if pos_a is None or pos_b is None:
                print(
                    f"  [{elapsed:6.1f}s] {side_a.label}={pos_a!r}  {side_b.label}={pos_b!r}  "
                    "(no infoDelivery yet from at least one side)"
                )
            else:
                drift = abs(pos_a - pos_b)
                samples.append((elapsed, drift))
                flag = " *** OVER DEAD BAND ***" if drift > args.dead_band else ""
                print(
                    f"  [{elapsed:6.1f}s] {side_a.label}={pos_a:8.3f}s  {side_b.label}={pos_b:8.3f}s  "
                    f"drift={drift:6.3f}s{flag}"
                )

            # A real connectivity failure should stop the run, not be paid
            # for one slow timeout at a time across every remaining tick.
            if consecutive_missed_a >= CONSECUTIVE_SAMPLE_FAILURE_LIMIT:
                aborted_early = f"{side_a.label} stopped responding for {consecutive_missed_a} consecutive samples"
                break
            if consecutive_missed_b >= CONSECUTIVE_SAMPLE_FAILURE_LIMIT:
                aborted_early = f"{side_b.label} stopped responding for {consecutive_missed_b} consecutive samples"
                break

        print()
        if aborted_early:
            print(f"Sampling stopped early: {aborted_early}.", file=sys.stderr)
        if missed_a or missed_b:
            print(
                f"Note: {side_a.label} had {missed_a} sample(s) with no player state yet, "
                f"{side_b.label} had {missed_b}. A couple in the first few ticks can be normal "
                "while the YouTube IFrame API sends its first infoDelivery frame; many, or an abort "
                "above, means the connection to that browser is not healthy.",
            )

        report, ok = format_report(samples, args.dead_band, args.max_drift, args.growth_slope_threshold)
        print(report)
        if aborted_early:
            ok = False
        return 0 if ok else 1

    finally:
        side_a.close()
        side_b.close()
        for ep in side_a.endpoints:
            ep.close()
        for ep in side_b.endpoints:
            ep.close()


def main(argv=None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if args.max_runtime is not None:
        max_runtime = args.max_runtime
    else:
        # Generous but finite: startup (ssh tunnels), two independent
        # discovery budgets, the sampling window itself, and headroom for
        # the consecutive-failure breaker to trip on both sides before
        # giving up. This is a backstop, not the primary defense, so it
        # errs toward not firing early on a legitimately slow but working
        # run rather than being tight.
        max_runtime = (
            args.ssh_connect_timeout
            + 10
            + 2 * DISCOVERY_BUDGET_SECONDS
            + args.duration
            + (CONSECUTIVE_SAMPLE_FAILURE_LIMIT * SAMPLE_EVAL_TIMEOUT * 2)
            + 30
        )

    signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(max(1, int(math.ceil(max_runtime))))
    try:
        return run(args)
    except HardDeadlineExceeded as step:
        print(
            f"\nFATAL: hard wall-clock deadline of {max_runtime:.0f}s exceeded while: {step}",
            file=sys.stderr,
        )
        print(
            "This is a defect signal, not a passing result: a release gate must never hang, "
            "so a deadline trip is reported as a failed run with the step it stalled on.",
            file=sys.stderr,
        )
        return 2
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
