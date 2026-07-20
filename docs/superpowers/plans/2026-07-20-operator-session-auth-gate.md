# Operator Session Auth Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the unauthenticated public exposure of the skchat daemon API by gating all sensitive `/api/v1` endpoints behind an operator session, established via a capauth-style device-key challenge-response and carried as an HS256 bearer JWT.

**Architecture:** Reuse the existing guest-subsystem primitives, promoted to an "operator" tier. The web client's existing ECDSA P-256 device key (`guest_identity`) is enrolled once on-tailnet through the existing `PairingGate` window, then proves possession off-tailnet by signing a server challenge to mint an operator-session JWT (modeled on `guest_groups.mint_guest_session`, own secret). A method+path-aware middleware on the webui FastAPI app enforces the existing `dataplane_auth` gate on every sensitive route, accepting that JWT as `Authorization: Bearer`. Everything ships DARK behind `SKCHAT_DATAPLANE_AUTH` (default off) until the client sends the header; the flip is the last task.

**Tech Stack:** Python 3, FastAPI + uvicorn (skchat webui :8765), PyJWT (HS256), `cryptography` (ECDSA P-256 verify), SQLite/JSON device store; Dart/Flutter + Dio + Riverpod (skchat-app); WebCrypto ECDSA (web).

**Repos:** server `~/clawd/skcapstone-repos/skchat` (`src/skchat/`); client `~/clawd/skcapstone-repos/skchat-app` (`lib/`). Server tests run from `~` (avoids the skmemory namespace collision, see CLAUDE.md): `cd ~ && python -m pytest ...`.

## Global Constraints

- **Ship dark.** Every server change keeps `SKCHAT_DATAPLANE_AUTH` OFF by default. With the flag off, behavior is byte-identical to today. The flag is flipped only in the final rollout task, after the client sends the credential. Never enable it mid-plan.
- **Web-first.** The device key (`guest_identity_web.dart`) is real only on web; native is an in-memory stub (`guest_identity_stub.dart`). This plan gates the funnel-fronted (web/remote) surface. Native (thick app on tailnet/localhost) keeps working via the existing operator-token / tailnet path until a native keystore lands (separate follow-on).
- **Separate secrets.** Operator sessions sign with `SKCHAT_OPERATOR_TOKEN_SECRET`, never the guest secret `SKCHAT_GUEST_TOKEN_SECRET`. Guest and operator tiers must not share a key.
- **Transport-agnostic.** The session JWT validates identically regardless of transport (localhost, tailnet, LAN, funnel). No code path may assume the funnel.
- **No em dashes or en dashes** in any code, comment, docstring, or commit message. Use commas, parentheses, or a new sentence. Regular hyphens are fine.
- **Commit trailer** on every commit: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **Reuse, do not reinvent.** Model operator session mint/verify on `guest_groups.mint_guest_session`/`verify_guest_session`; model the ECDSA verify on `pq_invites.verify_guest_binding`; reuse `PairingGate` for enrollment and `_is_revoked` for revocation.

## File Structure

**Server (skchat/src/skchat/):**
- Create `operator_auth.py` — device store, ECDSA challenge verify, operator-session JWT mint/verify, challenge-nonce store. One module, the operator-tier auth core.
- Create `operator_auth_routes.py` — the `/api/v1/auth/*` FastAPI routes (enroll/open, enroll, challenge, session).
- Modify `dataplane_auth.py` — validator accepts an operator-session JWT before the existing OpenPGP assertion path.
- Modify `webui.py` — register the auth routes; add the method+path-aware gate middleware.
- Modify `daemon_proxy.py` — add `Depends(require_dataplane_auth)` to the remaining sensitive routes.
- Tests under `skchat/tests/`.

**Client (skchat-app/lib/):**
- Create `services/operator_session_service.dart` — challenge-response, sign with `guest_identity`, store + refresh the JWT.
- Modify `services/skcomms_client.dart` — Dio interceptor attaching `Authorization: Bearer`, 401 re-auth.
- Remove/repoint `services/capauth_service.dart` (dead) and its providers/screen.
- Tests under `skchat-app/test/`.

---

### Task 1: Operator-session JWT mint + verify

**Files:**
- Create: `skchat/src/skchat/operator_auth.py`
- Test: `skchat/tests/test_operator_auth_session.py`

**Interfaces:**
- Produces: `mint_operator_session(*, device_fp: str, ttl: int | None = None) -> str` (HS256 JWT); `verify_operator_session(token: str) -> OperatorSession` (raises `OperatorAuthError` on invalid/expired/revoked); `OperatorSession` dataclass `{jti: str, device_fp: str, exp: int}`; `class OperatorAuthError(Exception)`.

- [ ] **Step 1: Write the failing test**

```python
# skchat/tests/test_operator_auth_session.py
import time, pytest
from skchat import operator_auth as oa

def test_mint_then_verify_roundtrip(monkeypatch):
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "test-secret")
    token = oa.mint_operator_session(device_fp="abc123", ttl=60)
    sess = oa.verify_operator_session(token)
    assert sess.device_fp == "abc123"
    assert sess.exp > int(time.time())

def test_expired_is_rejected(monkeypatch):
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "test-secret")
    token = oa.mint_operator_session(device_fp="abc123", ttl=-1)
    with pytest.raises(oa.OperatorAuthError):
        oa.verify_operator_session(token)

def test_wrong_secret_is_rejected(monkeypatch):
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "secret-a")
    token = oa.mint_operator_session(device_fp="abc123", ttl=60)
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "secret-b")
    with pytest.raises(oa.OperatorAuthError):
        oa.verify_operator_session(token)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~ && python -m pytest skchat/tests/test_operator_auth_session.py -v`
Expected: FAIL with `ModuleNotFoundError` / `AttributeError` (operator_auth not defined).

- [ ] **Step 3: Write minimal implementation**

```python
# skchat/src/skchat/operator_auth.py
"""Operator-tier device-key auth: challenge-response to an HS256 session JWT.

Models guest_groups.mint_guest_session / verify_guest_session but with its own
tier ("operator-session") and its own signing secret so operator and guest
tokens never share a key. Ships dark: nothing calls this until the middleware
gate is enabled in the final rollout task.
"""
from __future__ import annotations
import os, time, uuid, secrets
from dataclasses import dataclass
import jwt  # PyJWT, already a dependency (see guest_groups.py)

_TIER = "operator-session"
_DEFAULT_TTL = 12 * 3600
_MAX_TTL = 24 * 3600


class OperatorAuthError(Exception):
    pass


@dataclass
class OperatorSession:
    jti: str
    device_fp: str
    exp: int


def _secret() -> str:
    s = os.environ.get("SKCHAT_OPERATOR_TOKEN_SECRET", "")
    if not s:
        raise OperatorAuthError("SKCHAT_OPERATOR_TOKEN_SECRET not set")
    return s


def mint_operator_session(*, device_fp: str, ttl: int | None = None) -> str:
    now = int(time.time())
    ttl = _DEFAULT_TTL if ttl is None else min(ttl, _MAX_TTL)
    claims = {
        "jti": uuid.uuid4().hex,
        "tier": _TIER,
        "device_fp": device_fp,
        "iat": now,
        "exp": now + ttl,
    }
    return jwt.encode(claims, _secret(), algorithm="HS256")


def verify_operator_session(token: str) -> OperatorSession:
    try:
        claims = jwt.decode(
            token, _secret(), algorithms=["HS256"],
            options={"require": ["jti", "tier", "device_fp", "iat", "exp"]},
        )
    except jwt.PyJWTError as e:
        raise OperatorAuthError(f"invalid operator session: {e}") from e
    if claims.get("tier") != _TIER:
        raise OperatorAuthError("wrong tier")
    from .guest import _is_revoked  # reuse the guest revocation set
    if _is_revoked(claims["jti"]):
        raise OperatorAuthError("revoked")
    return OperatorSession(jti=claims["jti"], device_fp=claims["device_fp"], exp=claims["exp"])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~ && python -m pytest skchat/tests/test_operator_auth_session.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
cd ~/clawd/skcapstone-repos/skchat
git add src/skchat/operator_auth.py tests/test_operator_auth_session.py
git commit -m "feat(auth): operator-session HS256 JWT mint/verify (dark)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: ECDSA device-challenge verify + single-use nonce + device store

**Files:**
- Modify: `skchat/src/skchat/operator_auth.py`
- Test: `skchat/tests/test_operator_auth_device.py`

**Interfaces:**
- Consumes: nothing from Task 1 at runtime (same module).
- Produces: `issue_challenge() -> tuple[str, int]` (nonce, exp); `consume_challenge(nonce: str) -> bool` (True once, then False); `verify_device_signature(*, device_pubkey_b64: str, payload: bytes, sig_b64: str) -> bool`; `DeviceStore(path)` with `enroll(device_pubkey_b64: str) -> str` (returns device_fp), `is_enrolled(device_fp: str) -> bool`, `pubkey_for(device_fp: str) -> str | None`; `device_fingerprint(device_pubkey_b64: str) -> str` (first 16 hex of SHA-256 over the SPKI-b64, matching guest_identity_web.dart:121-130).

- [ ] **Step 1: Write the failing test**

```python
# skchat/tests/test_operator_auth_device.py
import base64, pytest
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from skchat import operator_auth as oa

def _keypair():
    priv = ec.generate_private_key(ec.SECP256R1())
    spki = priv.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return priv, base64.b64encode(spki).decode()

def _sign_p1363(priv, payload: bytes) -> str:
    der = priv.sign(payload, ec.ECDSA(hashes.SHA256()))
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    r, s = decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")  # WebCrypto r||s
    return base64.b64encode(raw).decode()

def test_verify_webcrypto_p1363_signature():
    priv, pub = _keypair()
    payload = b'{"nonce":"n1"}'
    sig = _sign_p1363(priv, payload)
    assert oa.verify_device_signature(device_pubkey_b64=pub, payload=payload, sig_b64=sig) is True
    assert oa.verify_device_signature(device_pubkey_b64=pub, payload=b"other", sig_b64=sig) is False

def test_challenge_nonce_is_single_use():
    nonce, _exp = oa.issue_challenge()
    assert oa.consume_challenge(nonce) is True
    assert oa.consume_challenge(nonce) is False

def test_device_store_enroll_and_lookup(tmp_path):
    store = oa.DeviceStore(tmp_path / "devices.json")
    _priv, pub = _keypair()
    fp = store.enroll(pub)
    assert store.is_enrolled(fp) is True
    assert store.pubkey_for(fp) == pub
    assert store.is_enrolled("not-a-device") is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~ && python -m pytest skchat/tests/test_operator_auth_device.py -v`
Expected: FAIL (attributes not defined).

- [ ] **Step 3: Write minimal implementation** (append to `operator_auth.py`)

```python
import base64, hashlib, json, threading
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.exceptions import InvalidSignature

_CHALLENGE_TTL = 120
_challenges: dict[str, int] = {}
_clock = threading.Lock()


def device_fingerprint(device_pubkey_b64: str) -> str:
    return hashlib.sha256(device_pubkey_b64.encode()).hexdigest()[:16]


def issue_challenge() -> tuple[str, int]:
    nonce = secrets.token_urlsafe(24)
    exp = int(time.time()) + _CHALLENGE_TTL
    with _clock:
        # opportunistic sweep of expired nonces
        now = int(time.time())
        for k in [k for k, v in _challenges.items() if v < now]:
            _challenges.pop(k, None)
        _challenges[nonce] = exp
    return nonce, exp


def consume_challenge(nonce: str) -> bool:
    with _clock:
        exp = _challenges.pop(nonce, None)
    return exp is not None and exp >= int(time.time())


def verify_device_signature(*, device_pubkey_b64: str, payload: bytes, sig_b64: str) -> bool:
    try:
        spki = base64.b64decode(device_pubkey_b64)
        pub = serialization.load_der_public_key(spki)
        raw = base64.b64decode(sig_b64)
        if len(raw) == 64:  # WebCrypto P1363 r||s
            r = int.from_bytes(raw[:32], "big")
            s = int.from_bytes(raw[32:], "big")
            der = encode_dss_signature(r, s)
        else:  # already DER
            der = raw
        pub.verify(der, payload, ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False


class DeviceStore:
    def __init__(self, path: Path):
        self._path = Path(path)
        self._lock = threading.Lock()
        self._data: dict[str, str] = {}
        if self._path.exists():
            self._data = json.loads(self._path.read_text() or "{}")

    def enroll(self, device_pubkey_b64: str) -> str:
        fp = device_fingerprint(device_pubkey_b64)
        with self._lock:
            self._data[fp] = device_pubkey_b64
            self._path.parent.mkdir(parents=True, exist_ok=True)
            self._path.write_text(json.dumps(self._data))
        return fp

    def is_enrolled(self, device_fp: str) -> bool:
        return device_fp in self._data

    def pubkey_for(self, device_fp: str) -> str | None:
        return self._data.get(device_fp)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~ && python -m pytest skchat/tests/test_operator_auth_device.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
cd ~/clawd/skcapstone-repos/skchat
git add src/skchat/operator_auth.py tests/test_operator_auth_device.py
git commit -m "feat(auth): ECDSA device-challenge verify, single-use nonce, device store

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: The `/api/v1/auth/*` routes

**Files:**
- Create: `skchat/src/skchat/operator_auth_routes.py`
- Modify: `skchat/src/skchat/webui.py:191-195` (register the router)
- Test: `skchat/tests/test_operator_auth_routes.py`

**Interfaces:**
- Consumes: all of `operator_auth` (Tasks 1-2); `guest._require_operator` (existing operator gate); `pairing_gate.PairingGate`.
- Produces: `router` (FastAPI `APIRouter(prefix="/api/v1/auth")`) with `POST /enroll/open` (operator-gated, opens a PairingGate window, returns `{window_nonce, exp}`), `POST /enroll {device_pubkey, window_nonce, sig}` (verifies the window + the device sig over canonical `{"nonce","device_pubkey"}`, enrolls, returns `{device_fp}`), `GET /challenge` (returns `{nonce, exp}`), `POST /session {device_fp, nonce, sig}` (consumes the nonce, verifies the sig over canonical `{"nonce","device_fp"}` against the enrolled pubkey, mints, returns `{session_token, expires_at}`). Canonical payload = `json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()`.

- [ ] **Step 1: Write the failing test**

```python
# skchat/tests/test_operator_auth_routes.py
import base64, json, pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from skchat import operator_auth as oa
from skchat.operator_auth_routes import register_operator_auth_routes

def _canon(obj): return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()

def _kp():
    priv = ec.generate_private_key(ec.SECP256R1())
    spki = priv.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return priv, base64.b64encode(spki).decode()

def _sig(priv, payload):
    der = priv.sign(payload, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode()

@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "sec")
    monkeypatch.delenv("SKCHAT_GUEST_OPERATOR_TOKEN", raising=False)  # loopback-allowed operator
    app = FastAPI()
    register_operator_auth_routes(app, device_store=oa.DeviceStore(tmp_path / "d.json"))
    return TestClient(app)

def test_full_enroll_then_session(client):
    priv, pub = _kp()
    w = client.post("/api/v1/auth/enroll/open").json()
    sig = _sig(priv, _canon({"nonce": w["window_nonce"], "device_pubkey": pub}))
    e = client.post("/api/v1/auth/enroll",
                    json={"device_pubkey": pub, "window_nonce": w["window_nonce"], "sig": sig})
    assert e.status_code == 200
    fp = e.json()["device_fp"]
    ch = client.get("/api/v1/auth/challenge").json()
    ssig = _sig(priv, _canon({"nonce": ch["nonce"], "device_fp": fp}))
    r = client.post("/api/v1/auth/session", json={"device_fp": fp, "nonce": ch["nonce"], "sig": ssig})
    assert r.status_code == 200
    assert oa.verify_operator_session(r.json()["session_token"]).device_fp == fp

def test_session_rejects_unenrolled_device(client):
    priv, _pub = _kp()
    ch = client.get("/api/v1/auth/challenge").json()
    ssig = _sig(priv, _canon({"nonce": ch["nonce"], "device_fp": "deadbeef"}))
    r = client.post("/api/v1/auth/session", json={"device_fp": "deadbeef", "nonce": ch["nonce"], "sig": ssig})
    assert r.status_code == 401

def test_session_rejects_replayed_nonce(client):
    priv, pub = _kp()
    w = client.post("/api/v1/auth/enroll/open").json()
    client.post("/api/v1/auth/enroll", json={"device_pubkey": pub, "window_nonce": w["window_nonce"],
                                             "sig": _sig(priv, _canon({"nonce": w["window_nonce"], "device_pubkey": pub}))})
    fp = oa.device_fingerprint(pub)
    ch = client.get("/api/v1/auth/challenge").json()
    ssig = _sig(priv, _canon({"nonce": ch["nonce"], "device_fp": fp}))
    ok = client.post("/api/v1/auth/session", json={"device_fp": fp, "nonce": ch["nonce"], "sig": ssig})
    assert ok.status_code == 200
    replay = client.post("/api/v1/auth/session", json={"device_fp": fp, "nonce": ch["nonce"], "sig": ssig})
    assert replay.status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~ && python -m pytest skchat/tests/test_operator_auth_routes.py -v`
Expected: FAIL (`register_operator_auth_routes` not defined).

- [ ] **Step 3: Write minimal implementation**

```python
# skchat/src/skchat/operator_auth_routes.py
"""FastAPI routes for the operator device-key auth handshake. Ships dark: these
routes exist but nothing is gated on their output until the middleware is enabled.
Enrollment is operator-gated (loopback/tailnet or SKCHAT_GUEST_OPERATOR_TOKEN)
via the existing guest._require_operator; challenge/session are open by design
(they only mint for a device whose key is already enrolled).
"""
from __future__ import annotations
import json
from fastapi import APIRouter, FastAPI, HTTPException, Request
from . import operator_auth as oa
from .guest import _require_operator
from .pairing_gate import PairingGate

_pairing = PairingGate()


def _canon(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def register_operator_auth_routes(app: FastAPI, *, device_store: oa.DeviceStore) -> None:
    router = APIRouter(prefix="/api/v1/auth")

    @router.post("/enroll/open")
    async def enroll_open(request: Request):
        _require_operator(request)  # loopback/tailnet or operator token
        window = _pairing.open_window()
        return {"window_nonce": window.nonce, "exp": window.exp}

    @router.post("/enroll")
    async def enroll(request: Request):
        body = await request.json()
        pub, wnonce, sig = body.get("device_pubkey"), body.get("window_nonce"), body.get("sig")
        if not (pub and wnonce and sig):
            raise HTTPException(400, "device_pubkey, window_nonce, sig required")
        if not _pairing.check(wnonce):
            raise HTTPException(401, "enrollment window closed or invalid")
        if not oa.verify_device_signature(
                device_pubkey_b64=pub, payload=_canon({"nonce": wnonce, "device_pubkey": pub}), sig_b64=sig):
            raise HTTPException(401, "device signature invalid")
        _pairing.consume(wnonce)
        return {"device_fp": device_store.enroll(pub)}

    @router.get("/challenge")
    async def challenge():
        nonce, exp = oa.issue_challenge()
        return {"nonce": nonce, "exp": exp}

    @router.post("/session")
    async def session(request: Request):
        body = await request.json()
        fp, nonce, sig = body.get("device_fp"), body.get("nonce"), body.get("sig")
        if not (fp and nonce and sig):
            raise HTTPException(400, "device_fp, nonce, sig required")
        if not oa.consume_challenge(nonce):
            raise HTTPException(401, "challenge nonce invalid or expired")
        pub = device_store.pubkey_for(fp)
        if not pub:
            raise HTTPException(401, "device not enrolled")
        if not oa.verify_device_signature(
                device_pubkey_b64=pub, payload=_canon({"nonce": nonce, "device_fp": fp}), sig_b64=sig):
            raise HTTPException(401, "challenge signature invalid")
        token = oa.mint_operator_session(device_fp=fp)
        sess = oa.verify_operator_session(token)
        return {"session_token": token, "expires_at": sess.exp}

    app.include_router(router)
```

Note: confirm `PairingGate.open_window()` returns an object with `.nonce`/`.exp` and that `check`/`consume` take the nonce (see `pairing_gate.py:50-78`). Adjust attribute access to the real API if it differs (e.g. a dict).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~ && python -m pytest skchat/tests/test_operator_auth_routes.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Register the router in webui and commit**

In `webui.py`, next to the existing `app.include_router(daemon_api_router)` (line ~193), add:

```python
from .operator_auth import DeviceStore
from .operator_auth_routes import register_operator_auth_routes
import os
_device_store = DeviceStore(os.path.expanduser("~/.skchat/state/operator_devices.json"))
register_operator_auth_routes(app, device_store=_device_store)
```

```bash
cd ~/clawd/skcapstone-repos/skchat
git add src/skchat/operator_auth_routes.py tests/test_operator_auth_routes.py src/skchat/webui.py
git commit -m "feat(auth): /api/v1/auth enroll + challenge + session routes (dark)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Teach the gate to accept the operator-session JWT

**Files:**
- Modify: `skchat/src/skchat/dataplane_auth.py:75-92` (`_verify_capauth_credential`)
- Test: `skchat/tests/test_dataplane_accepts_operator_session.py`

**Interfaces:**
- Consumes: `operator_auth.verify_operator_session` (Task 1).
- Produces: `_verify_capauth_credential(token)` now returns truthy for a valid operator-session JWT, still falls back to the existing OpenPGP `{claim,sig}` assertion path for daemon/agent callers.

- [ ] **Step 1: Write the failing test**

```python
# skchat/tests/test_dataplane_accepts_operator_session.py
import pytest
from skchat import operator_auth as oa
from skchat.dataplane_auth import CapAuthValidator

def test_validator_accepts_operator_session(monkeypatch):
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "sec")
    token = oa.mint_operator_session(device_fp="abc123", ttl=60)
    assert CapAuthValidator().validate(token) is True

def test_validator_rejects_garbage(monkeypatch):
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "sec")
    assert CapAuthValidator().validate("not-a-token") is False
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ~ && python -m pytest skchat/tests/test_dataplane_accepts_operator_session.py -v`
Expected: FAIL on the accept case (validator only knows the OpenPGP path today).

- [ ] **Step 3: Implement** — at the top of `_verify_capauth_credential` (before the existing base64url `{claim,sig}` decode), add:

```python
        # Operator-session JWT (the app's Bearer credential). Try this first;
        # fall through to the OpenPGP assertion path for daemon/agent callers.
        try:
            from .operator_auth import verify_operator_session, OperatorAuthError
            verify_operator_session(token)
            return True
        except OperatorAuthError:
            pass
        except Exception:
            pass
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ~ && python -m pytest skchat/tests/test_dataplane_accepts_operator_session.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
cd ~/clawd/skcapstone-repos/skchat
git add src/skchat/dataplane_auth.py tests/test_dataplane_accepts_operator_session.py
git commit -m "feat(auth): dataplane gate accepts operator-session JWT before OpenPGP path

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: The method+path-aware gate middleware

**Files:**
- Modify: `skchat/src/skchat/webui.py` (add middleware next to `_debug_log_app_requests`, line ~46-77)
- Create helper: `skchat/src/skchat/dataplane_paths.py` (sensitive/exempt classification)
- Test: `skchat/tests/test_gate_middleware.py`

**Interfaces:**
- Produces: `is_gated(method: str, path: str) -> bool` in `dataplane_paths.py`; an `@app.middleware("http")` that, when `dataplane_auth_enabled()` and `is_gated(method, path)`, calls `enforce_dataplane_auth(request)` and returns its 401 on failure, else passes through.

- [ ] **Step 1: Write the failing test** (drives both the classifier and the middleware)

```python
# skchat/tests/test_gate_middleware.py
import pytest
from skchat.dataplane_paths import is_gated

def test_sensitive_paths_are_gated():
    assert is_gated("GET", "/api/v1/conversations") is True
    assert is_gated("POST", "/api/v1/send") is True
    assert is_gated("GET", "/api/v1/peers") is True

def test_exempt_paths_are_open():
    assert is_gated("GET", "/health") is False
    assert is_gated("GET", "/api/health") is False
    assert is_gated("POST", "/api/v1/inbox") is False      # federation S2S
    assert is_gated("GET", "/api/v1/auth/challenge") is False  # bootstrap
    assert is_gated("POST", "/api/v1/auth/session") is False   # bootstrap
    assert is_gated("GET", "/app/index.html") is False
    assert is_gated("GET", "/.well-known/skfed/directory") is False

def test_method_specific_inbox():
    assert is_gated("GET", "/api/v1/inbox") is True    # reading YOUR inbox
    assert is_gated("POST", "/api/v1/inbox") is False  # peers delivering to you
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ~ && python -m pytest skchat/tests/test_gate_middleware.py -v`
Expected: FAIL (`dataplane_paths` not defined).

- [ ] **Step 3: Implement the classifier**

```python
# skchat/src/skchat/dataplane_paths.py
"""Classify (method, path) as gated (needs operator auth) or exempt.

Exempt = genuinely public or auth-bootstrap: health, static app, federation
inbound (POST /api/v1/inbox), signed discovery, invite/pair/guest join, livekit
signaling, and the /api/v1/auth/* handshake itself. Everything else under
/api/v1 (plus the sensitive webui routes) is gated.
"""

_EXEMPT_EXACT = {
    ("GET", "/health"), ("GET", "/api/health"),
    ("POST", "/api/v1/inbox"),                 # federation S2S inbound
    ("GET", "/api/v1/auth/challenge"),
    ("POST", "/api/v1/auth/session"),
    ("POST", "/api/v1/auth/enroll"),
    ("POST", "/api/v1/auth/enroll/open"),      # itself operator-gated in-route
}
_EXEMPT_PREFIX = (
    "/app", "/static", "/favicon", "/.well-known/",
    "/join", "/guest", "/pair", "/livekit", "/ws/",
)


def is_gated(method: str, path: str) -> bool:
    method = method.upper()
    if (method, path) in _EXEMPT_EXACT:
        return False
    if path == "/" :
        return False
    for p in _EXEMPT_PREFIX:
        if path.startswith(p):
            return False
    return path.startswith("/api/v1") or path.startswith("/api/send") or path in (
        "/inbox", "/send", "/messages", "/groups", "/upload", "/agent/state")
```

- [ ] **Step 4: Run to verify the classifier passes**

Run: `cd ~ && python -m pytest skchat/tests/test_gate_middleware.py -v`
Expected: PASS.

- [ ] **Step 5: Add the middleware in webui.py** (after the app is created, near `_debug_log_app_requests`)

```python
from starlette.responses import JSONResponse
from .dataplane_auth import dataplane_auth_enabled, enforce_dataplane_auth
from .dataplane_paths import is_gated

@app.middleware("http")
async def _operator_auth_gate(request, call_next):
    if dataplane_auth_enabled() and is_gated(request.method, request.url.path):
        try:
            enforce_dataplane_auth(request)
        except Exception:
            return JSONResponse({"detail": "capauth authentication required"}, status_code=401)
    return await call_next(request)
```

- [ ] **Step 6: Integration test the middleware end to end**

```python
# append to test_gate_middleware.py
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.responses import JSONResponse
from skchat.dataplane_auth import dataplane_auth_enabled, enforce_dataplane_auth
from skchat.dataplane_paths import is_gated
from skchat import operator_auth as oa

def _build_app():
    app = FastAPI()
    @app.get("/api/v1/conversations")
    async def convos(): return [{"peer_id": "x"}]
    @app.get("/health")
    async def health(): return {"ok": True}
    @app.middleware("http")
    async def gate(request, call_next):
        if dataplane_auth_enabled() and is_gated(request.method, request.url.path):
            try: enforce_dataplane_auth(request)
            except Exception: return JSONResponse({"detail": "capauth authentication required"}, 401)
        return await call_next(request)
    return app

def test_flag_off_passthrough(monkeypatch):
    monkeypatch.delenv("SKCHAT_DATAPLANE_AUTH", raising=False)
    c = TestClient(_build_app())
    assert c.get("/api/v1/conversations").status_code == 200

def test_flag_on_blocks_unauthed(monkeypatch):
    monkeypatch.setenv("SKCHAT_DATAPLANE_AUTH", "1")
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "sec")
    c = TestClient(_build_app())
    assert c.get("/api/v1/conversations").status_code == 401
    assert c.get("/health").status_code == 200

def test_flag_on_allows_valid_session(monkeypatch):
    monkeypatch.setenv("SKCHAT_DATAPLANE_AUTH", "1")
    monkeypatch.setenv("SKCHAT_OPERATOR_TOKEN_SECRET", "sec")
    tok = oa.mint_operator_session(device_fp="abc", ttl=60)
    c = TestClient(_build_app())
    assert c.get("/api/v1/conversations", headers={"Authorization": f"Bearer {tok}"}).status_code == 200
```

Run: `cd ~ && python -m pytest skchat/tests/test_gate_middleware.py -v`
Expected: PASS (all).

- [ ] **Step 7: Commit**

```bash
cd ~/clawd/skcapstone-repos/skchat
git add src/skchat/dataplane_paths.py src/skchat/webui.py tests/test_gate_middleware.py
git commit -m "feat(auth): method+path-aware operator-auth gate middleware (dark)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: Client OperatorSessionService (challenge-response + store)

**Files:**
- Create: `skchat-app/lib/services/operator_session_service.dart`
- Test: `skchat-app/test/services/operator_session_service_test.dart`

**Interfaces:**
- Consumes: the existing `guest_identity` (`sign(String)`, `publicKeyB64`, `fingerprint`); a `Dio` for the daemon base URL.
- Produces: `class OperatorSessionService { Future<String> ensureSession(); Future<void> enroll(String windowNonce); }` where `ensureSession()` returns a cached unexpired JWT or runs `GET /api/v1/auth/challenge` -> sign canonical `{"device_fp","nonce"}` with guest_identity -> `POST /api/v1/auth/session` -> cache the JWT (via the existing `operator_token` localStorage/secure seam).

- [ ] **Step 1: Write the failing test** (Dio mocked via `http_mock_adapter` or a fake interceptor)

```dart
// skchat-app/test/services/operator_session_service_test.dart
import 'package:flutter_test/flutter_test.dart';
// ... imports: dio, http_mock_adapter, the service, a fake guest identity
void main() {
  test('ensureSession runs challenge-response and returns a token', () async {
    // Arrange: mock GET /api/v1/auth/challenge -> {nonce, exp};
    //          mock POST /api/v1/auth/session -> {session_token: "jwt", expires_at};
    //          fake guest identity that returns a deterministic sig.
    // Act: final t = await service.ensureSession();
    // Assert: expect(t, "jwt"); and the signed payload was canonical {device_fp,nonce}.
  });
  test('ensureSession returns the cached token when unexpired', () async {
    // Arrange: prime the store with an unexpired token; assert no HTTP calls fire.
  });
}
```

Fill the test body against the project's existing Dio-mock helper (see other `*_service_test.dart`).

- [ ] **Step 2: Run to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/services/operator_session_service_test.dart`
Expected: FAIL (service not defined).

- [ ] **Step 3: Implement `operator_session_service.dart`** — challenge-response, canonical JSON `jsonEncode` with sorted keys helper, sign via guest_identity, cache the JWT + expiry in the `operator_token` seam, return cached when `expiresAt` is in the future.

- [ ] **Step 4: Run to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/services/operator_session_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/clawd/skcapstone-repos/skchat-app
git add lib/services/operator_session_service.dart test/services/operator_session_service_test.dart
git commit -m "feat(auth): client OperatorSessionService challenge-response + cache

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Dio interceptor attaches the session + 401 re-auth

**Files:**
- Modify: `skchat-app/lib/services/skcomms_client.dart:22-28` (the Dio setup)
- Test: `skchat-app/test/services/skcomms_client_auth_test.dart`

**Interfaces:**
- Consumes: `OperatorSessionService.ensureSession()` (Task 6).
- Produces: every `/api/v1` request carries `Authorization: Bearer <session>`; a 401 clears the cached token and retries once.

- [ ] **Step 1: Write the failing test** — assert the outgoing request has the `Authorization` header, and that a single 401 triggers one refresh + retry.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Add an `InterceptorsWrapper` to `_dio`** that awaits `ensureSession()` in `onRequest` and sets the header; in `onError`, if `response?.statusCode == 401` and not already retried, clear the cache, re-run `ensureSession()`, and retry the request once.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** (`feat(auth): attach operator session to daemon requests, refresh on 401`).

---

### Task 8: Remove the dead capauth_service scaffolding

**Files:**
- Delete: `skchat-app/lib/services/capauth_service.dart`, `lib/features/.../qr_login_screen.dart`, `capauth_provider.dart` (confirm no live consumers first with a grep).
- Modify: `app_router.dart:331` (remove the dead route), any imports.

- [ ] **Step 1:** `grep -rn "capAuthServiceProvider\|CapAuthService\|qr_login" lib/` and confirm the only references are the dead trio + the route.
- [ ] **Step 2:** Delete the files and the route; run `flutter analyze` and the full `flutter test` to confirm nothing referenced them.
- [ ] **Step 3: Commit** (`chore(auth): remove dead capauth_service scaffolding (superseded by OperatorSessionService)`).

---

### Task 9: Gate the remaining sensitive routes + rollout

**Files:**
- Modify: `skchat/src/skchat/daemon_proxy.py` (the middleware in Task 5 covers everything, so this task is verification + the flip)
- Test: a live smoke script.

- [ ] **Step 1:** Confirm the middleware (Task 5) already covers every sensitive route (it is app-level, not per-route), so no per-route `Depends` are needed. Grep for any route that bypasses the ASGI middleware (e.g. mounted sub-apps) and note them.
- [ ] **Step 2: Enrollment dry-run (still flag off).** On the tailnet: open a window (`POST /api/v1/auth/enroll/open`), enroll the web client's device key, run challenge -> session, confirm a JWT comes back. The gate is still off, so nothing else changes.
- [ ] **Step 3: Flip the flag in the operator deploy.** Set `SKCHAT_OPERATOR_TOKEN_SECRET` (strong random) and `SKCHAT_DATAPLANE_AUTH=1` in the webui service env (drop-in), restart `skchat-webui@lumina`.
- [ ] **Step 4: Smoke test the funnel.** From an unauthenticated context: `GET https://noroc2027.tail204f0c.ts.net/api/v1/conversations` -> expect **401**. From the authed web client -> expect **200** and normal operation. `POST /api/v1/inbox` (federation) still reachable. `GET /health` still 200.
- [ ] **Step 5: Commit + document** the flip in `docs/SPACES.md` security section and the spec's section 5, and close GTD `741b32bc9235`.

---

## Self-Review

- **Spec coverage:** section 5 (security spine) + 5b (transport-agnostic token) are implemented by Tasks 1-9; the capability-by-tier SKOS gate (section 2.1) is a separate M1 task (this plan is the API auth foundation it builds on).
- **Type consistency:** `device_fp` (str) and the canonical `{nonce, device_pubkey}` / `{nonce, device_fp}` payload shapes are consistent across Tasks 2, 3, 4, 6, 7. `mint_operator_session`/`verify_operator_session` signatures match across Tasks 1, 3, 4, 5.
- **Ship-dark invariant:** Tasks 1-8 never enable the flag; only Task 9 Step 3 flips it, after the client (Tasks 6-7) can satisfy it.
- **Open flag to resolve at execution:** confirm the real `PairingGate.open_window()` return shape (attribute vs dict) and adapt Task 3; confirm the client's Dio-mock helper for Tasks 6-7.

## Execution Handoff

Two execution options:
1. **Subagent-Driven (recommended)** - fresh subagent per task, two-stage review between tasks.
2. **Inline Execution** - batch with checkpoints.
