# Native GuestIdentity keystore + neutral thick-client build: design

**Date:** 2026-07-21
**Status:** approved (design decisions confirmed with Chef)
**Priority:** #1 from `HANDOFF-skchat-thick-client-and-m1b-2026-07-21.md`

## Problem

All of M1 (self-identity + trust) is web-first. On the browser,
`guest_identity_web.dart` holds a real ECDSA P-256 device key in WebCrypto +
localStorage, so a browser can sign the operator-enrollment challenge and reach
the gated `/api/v1` surfaces (green/operator tier).

On every non-web target the app uses `guest_identity_stub.dart`: an in-memory
surrogate with **random bytes as a fake pubkey** and `sign()` returning
`'stub-sig:<hashCode>'`. Consequences on the native Linux desktop build:

- `OperatorSessionService.enroll()` / `ensureSession()` sign the device-key
  challenge with `GuestIdentity`. The stub cannot produce a real ECDSA
  signature, so the server's `verify_device_signature` rejects it. The thick
  client **cannot enroll as operator**, cannot go green, cannot reach gated
  `/api/v1`.
- Nothing persists, so the identity is fake and ephemeral.

The thick Linux client is therefore a second-class citizen. This work makes the
native `GuestIdentity` a real, persistent ECDSA keystore so the desktop app is a
first-class operator client, and separates the build config so the code ships
neutral (no baked private-infra URL) while Chef's own builds still point at
`.158`.

## The crypto contract (verified against the live server)

From `skchat/src/skchat/operator_auth.py`, the native impl MUST match all three
or enrollment/handshake fail:

1. **Public key**: `device_pubkey_b64` is `base64(DER SubjectPublicKeyInfo)`.
   The server does `serialization.load_der_public_key(base64.b64decode(...))`.
   So we export the P-256 public key as DER SPKI (`ecPublicKey` OID
   `1.2.840.10045.2.1` + `prime256v1` OID `1.2.840.10045.3.1.7` + the
   uncompressed EC point `04 || X || Y` in the BIT STRING) and base64 it.
   This is byte-identical to WebCrypto `exportKey('spki')`.

2. **Fingerprint**: `device_fingerprint = sha256(device_pubkey_b64.encode())[:16]`
   i.e. SHA-256 over the **base64 string** (ASCII bytes), first 16 hex chars.
   Identical to `guest_identity_web.dart`'s `_fingerprint()` and to the server.

3. **Signature**: `verify_device_signature` accepts **either**:
   - 64-byte raw `r || s` (WebCrypto P1363), which it converts to DER, **or**
   - already-DER ECDSA.
   Curve P-256, hash SHA-256 (`ec.ECDSA(hashes.SHA256())`).
   We emit the 64-byte raw `r || s` form to mirror the web impl exactly.

All primitives are already in `pubspec.yaml`: `pointycastle` (keygen / sign /
verify), `asn1lib` (SPKI DER encode/decode), `flutter_secure_storage`
(persistence), `cryptography` (available, not required for this path).

## Design decisions (confirmed with Chef)

- **Persistence:** `flutter_secure_storage` (libsecret / gnome-keyring) primary,
  with a **file-based fallback that still persists** (`~/.skchat-app/`, `0600`)
  when no Secret Service is available (headless box, locked keyring). Only if
  BOTH fail is the identity in-memory `degraded: true`. This differs
  deliberately from the web impl, where `degraded` means ephemeral: an operator
  device must stay green across restarts, so the fallback writes to disk.
- **Build:** this thick client is a **neutral build** (no baked URL). The
  runtime server picker already exists (`backend_config.dart` presets +
  `setCustomHost`, persisted in Hive, surfaced in the Profile screen and the
  onboarding flow). Neutral is the strategic/distributable posture: the *code*
  no longer hard-codes Chef's private `noroc2027` host; Chef's own web +
  operator builds inject it explicitly via a build config file.

## Architecture

### Component 1: `guest_identity_io.dart` (the real native impl)

Replaces the stub on native targets. Implements the existing `GuestIdentity`
interface (`ensure/hasCached/sign/clear` → `GuestKeypair{publicKeyB64,
fingerprint, degraded}`) with:

- **Keygen:** pointycastle `ECKeyGenerator` over `prime256v1` domain params,
  seeded from a `SecureRandom` (Fortuna seeded with `Random.secure()` bytes).
- **SPKI export:** build the DER `SubjectPublicKeyInfo` with `asn1lib` from the
  public point (uncompressed `04||X||Y`, X/Y fixed 32-byte big-endian), base64.
- **Fingerprint:** `sha256(spkiB64)[:16]` via pointycastle SHA-256. Matches the
  server and web formulas exactly.
- **Sign:** pointycastle `ECDSASigner(SHA-256)`; take the `ECSignature(r, s)`,
  serialize as raw `r||s` (each 32-byte big-endian, left-zero-padded), base64.
- **Persist:** the private scalar `d` (or a PKCS8 DER) + the public SPKI, through
  an injectable `GuestKeyStore` seam (see below). Written only after SPKI export
  and fingerprint succeed (same ordering discipline as the web impl, so a
  mid-failure never leaves a half-written real key while returning a degraded
  one).
- **degraded fallback:** if both stores throw on read AND write, generate a
  real, unique in-memory keypair flagged `degraded: true` so the user still gets
  a distinct id and can join, warned it will not persist.

### `GuestKeyStore` seam (testability + fallback)

```
abstract class GuestKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
```

- `SecureGuestKeyStore`: wraps `flutter_secure_storage`.
- `FileGuestKeyStore`: JSON file at `~/.skchat-app/guest_identity.json`, `0600`,
  atomic write (temp + rename), via `path_provider` / `dart:io`.
- `FallbackGuestKeyStore`: tries secure first; on any throw, delegates to file;
  surfaces "both failed" so the impl can go degraded.
- Tests inject an in-memory fake, so `flutter test` never touches a platform
  channel or the real filesystem.

The impl takes an optional `GuestKeyStore` (defaults to the fallback chain), so
construction is side-effect-free (no eager channel/file I/O; I/O happens on
`ensure`/`sign`/`clear`).

### Platform seam wiring

`guest_identity.dart` currently:
```
import 'guest_identity_stub.dart' if (dart.library.html) 'guest_identity_web.dart';
```
Change to prefer the io impl on native, web impl on web, stub only where neither
`dart:io` nor `dart:html` exists (effectively never, but keeps the compile-safe
default):
```
import 'guest_identity_stub.dart'
  if (dart.library.io) 'guest_identity_io.dart'
  if (dart.library.html) 'guest_identity_web.dart';
```
`flutter test` runs on the Dart VM (has `dart:io`) → exercises the real io impl,
which is why the store seam must be injectable for tests.

### Component 2: neutral build config

- **Code defaults go neutral.** Change the `String.fromEnvironment` defaults in
  `backend_config.dart` (and any sibling `SKCHAT_WEBUI_URL` default, e.g.
  `daemon_config.dart` if it hard-codes the host) from the baked
  `https://noroc2027...` to an **empty** default. The public edition then ships
  pointing nowhere until the user picks an instance.
- **Chef's builds inject the host explicitly** via
  `--dart-define-from-file=config/lumina.json` (a new file holding
  `SKCHAT_WEBUI_URL`, `LIVEKIT_URL`, `SKCAPSTONE_URL`, etc. = the `.158`
  values). This keeps the existing **web deploy** working (its build recipe
  gains the `--dart-define-from-file` flag) and gives the operator linux build
  the same host.
- **First-run guard.** When `skchatWebuiUrl` is empty (neutral build, not yet
  configured), the app must route to the onboarding / server-picker instead of
  firing requests at an empty base. Verify the existing onboarding flow
  (`lib/features/onboarding/`) can set the backend (preset or custom host) and
  that no gated client crashes on an empty base URL; add a minimal guard if not.
- `config/lumina.json` is committed (it is public tailnet info already in the
  repo) but the point is that it is now *opt-in at build time*, not the code
  default.

### Component 3: operator linux build + media parity

- `scripts/build-linux-lumina.sh`: `flutter build linux --release
  --dart-define-from-file=config/lumina.json`. Confirms the pinned
  `flutter_webrtc` fork ref (`a7db44d9…`, the LoopbackCapturer/PR #2115 fork) is
  resolved for the native build.
- `scripts/build-linux-neutral.sh`: `flutter build linux --release` (no host
  baked) for the distributable edition.
- Media-parity smoke on Chef's box: launch, pick `lumina @ .158` (or confirm the
  baked lumina build), enroll as operator (over the tailnet the server trusts
  loopback/tailnet without the operator token), confirm the M1 self-identity
  shows the **operator/green** tier, and camera + screen-share + the
  camera-stop-unpublish fix behave natively.

## Testing

Native unit tests (`flutter test`, NOT `@TestOn('browser')`):

1. **Generate + persist + reuse:** first `ensure()` generates; a second impl
   over the SAME injected store returns the SAME `publicKeyB64` + `fingerprint`
   (no regeneration). `clear()` wipes; the next `ensure()` regenerates a
   different key.
2. **SPKI validity:** the exported DER parses back to a P-256 public point;
   `fingerprint` equals a local re-derivation of `sha256(spkiB64)[:16]`.
3. **Sign → verify:** the raw `r||s` signature verifies against the public key
   with a pointycastle ECDSA verifier (proves crypto correctness locally).
4. **degraded fallback:** with a store that throws on read AND write, `ensure()`
   returns a unique keypair flagged `degraded: true` and does not throw.
5. **Fallback ordering:** secure-store failure falls through to the file store
   and STILL persists (second instance reads the same key back).

Cross-language wire-compat (the strongest guarantee that enrollment will
actually verify server-side):

6. **Fixture round-trip:** a small Dart entrypoint emits
   `{pubkey_b64, payload, sig}` from the real io impl; a pytest in the `skchat`
   repo feeds it straight into `operator_auth.verify_device_signature(...)` and
   asserts `True`, plus asserts the Dart `fingerprint` equals
   `operator_auth.device_fingerprint(pubkey_b64)`. This nails the SPKI + P1363
   contract end-to-end across both codebases.

## Out of scope (deferred to M1b backlog)

Per-peer trust badges, 1:1 call gate, recovery phrase (BIP39), full onboarding
redesign, neutral-build CI (windows/macos), DuckDuckGo note. This spec is only:
native keystore + neutral build config + operator linux build/smoke.

## Risks / notes

- **libsecret at runtime:** flutter_secure_storage's Linux backend needs the
  Secret Service; the file fallback covers the box where it is missing. The
  fallback file is protected by `0600` perms only (not the OS keyring). This is
  an accepted trade for "operator stays green on any Linux box."
- **P1363 vs DER:** we emit raw `r||s`; the server accepts it. If a future
  server tightens to DER-only, switch the serializer to `asn1lib`
  `ECDSASignature` DER (the server already accepts DER, so this is a one-line
  swap, not a contract break).
- **Empty-URL neutral build:** the first-run guard is the one place a neutral
  build can regress into a confusing "nothing loads" state; the plan must verify
  the onboarding path actually configures the backend.
- **Web deploy coupling:** flipping the code default to empty means the existing
  web build recipe MUST gain `--dart-define-from-file=config/lumina.json` in the
  same change, or the deployed web app loses its host. Land them together.
```
