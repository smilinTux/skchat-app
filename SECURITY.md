# Security Policy — skchat-app

skchat-app is the Flutter **client** for the SKChat sovereign comms stack. It
renders, signs, and delegates: its security posture is mostly about **what it
holds locally** and **which backends it trusts**, not owned crypto. See
[`SOP.md`](./SOP.md) §9 for the honest maturity statement.

## Reporting a vulnerability

- **Primary:** GitHub **private vulnerability reporting** for this repo
  (`Security ▸ Report a vulnerability`). Keeps report, fix, and advisory in one place.
- **Secondary (out-of-band):** if GitHub is unavailable, contact the smilinTux
  maintainers and encrypt to the project's sovereign capauth / `sk_pgp` PGP
  identity. _(Publish the fingerprint here before first release.)_
- **Acknowledgement SLA:** we aim to acknowledge within **72 hours**. Silence
  before then is not a dismissal.

Please do not open a public issue for a suspected vulnerability until it has been
triaged and a fix or advisory is ready.

## Scope

**In scope:** the code in this repo and its built artifacts (web bundle, APK,
desktop binaries); the client-side handling of key material, tokens, daemon
trust, and the LiveKit data/media legs.

**Out of scope (report upstream):** the SKComms/SKChat daemon, LiveKit server,
CapAuth, `sk_pqc`, and third-party Flutter/Dart dependencies. Theoretical findings
with no realizable client-side impact, and issues already noted in
`CHANGELOG`/advisories.

## Threat model

### 1. Secure storage (key material at rest)
- The app stores the operator's **PGP keypair** (`pgp_public_key` /
  `pgp_private_key` / `pgp_fingerprint`) and the **PQ hybrid prekey**
  (`pqc_hybrid_*`, `pqc_device_id`) via `flutter_secure_storage`, backed by the
  platform keystore (iOS Keychain, Android Keystore, libsecret, DPAPI).
- **Assumption:** the device OS keystore and device lock are trusted. A rooted /
  jailbroken / compromised device, or a web build where the browser's storage is
  not hardware-backed, degrades this to the browser's storage guarantees.
- **Web caveat:** on web, secret material lives in browser-managed storage, which
  is **weaker** than a native keystore. Treat web as a convenience surface;
  high-value identities should pair on native.
- **Mitigations:** biometric gate (`local_auth` / `biometric_service.dart`) where
  available; keys never leave the device unencrypted; wiping the app clears them.

### 2. Daemon & backend trust
- The app trusts whatever URL `daemonUrlProvider` / `backendConfigProvider`
  resolve to (compile-time `--dart-define`, a built-in preset, or a
  user-entered custom host). **A malicious or spoofed daemon URL can observe
  metadata and serve hostile content.**
- **Mitigations / expectations:** the web build is served **same-origin behind
  the SKChat web-UI reverse proxy over the funnel/tailnet** — never a raw public
  port, never the daemon port exposed (see `SOP.md` §5). Message authenticity is
  enforced by PGP signatures verified against CapAuth identity, not by transport
  trust. Prefer tailnet/HTTPS hosts; treat a custom `http://` host on an untrusted
  network as unauthenticated.

### 3. LiveKit media & data legs
- **Media (audio/video/screen-share):** carried by LiveKit over **DTLS-SRTP**.
  This is a **classical** transport-encryption leg — encrypted point-to-SFU, and
  it is **not** end-to-end and **not** post-quantum. Room access is gated by a
  short-lived, role-scoped JWT minted at `POST /livekit/token`.
- **Data lanes (in-call chat / whiteboard / doc):** ride the LiveKit data channel
  and inherit the same DTLS-SRTP transport encryption; they are **not** separately
  end-to-end encrypted. Do not treat Spaces lane content as E2E-confidential.
- **Token handling:** room JWTs are held in memory only for the call session.

### 4. Direct-message confidentiality
- 1:1 DMs may be sealed with `PqDmCodec` (hybrid `x25519-mlkem768` KEM +
  HKDF-SHA256 + AES-256-GCM) via `sk_pqc`, interoperable with the daemon's
  `pqdm.py`. **This crypto is owned by `sk_pqc`/`skcomms`, not this app** — report
  primitive-level issues upstream. No claim of "quantum-proof" / "quantum-safe" /
  "unbreakable" is made: PQ protection is limited to this DM KEM surface.

## Honest-claims commitment

No advisory or doc in this repo will use a word the evidence can't back. The
call-media leg is DTLS-SRTP (classical); the DM PQ protection is a hybrid KEM
delegated to `sk_pqc`; everything else in the app is classical by design (`T0`).
