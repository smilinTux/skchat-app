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
- **Native device key (GuestIdentity, ECDSA P-256):** persisted via
  `FallbackGuestKeyStore(SecureGuestKeyStore, EncryptedFileGuestKeyStore)`. When
  the OS keyring works it is used directly. When it is **absent** (headless /
  minimal Linux), the file fallback is now **encrypted at rest with AES-256-GCM**
  (`guest_keystore_crypto.dart`): the wrapping key is HKDF-SHA256 derived from
  `/etc/machine-id` (outside the home dir) + a separate 0600 salt file kept out
  of the envelope. This **defeats casual exfiltration** (a filesystem backup, a
  home-dir sync, or a copied `guest_identity.json`) but is explicitly
  **reduced-assurance**: a privileged / same-UID attacker who can read both the
  salt and `/etc/machine-id` can re-derive the key. The OS keyring is always
  preferred. Legacy plaintext stores are read + re-encrypted transparently;
  reads fail safe (tamper/wrong-key surfaces as a GCM-tag failure, the file is
  sidecar-preserved, the key reported absent, never partial bytes).
- **Recovery phrase (native only):** the device key can be backed up as a 24-word
  BIP39 phrase (the raw P-256 scalar as entropy). The phrase IS the private key;
  the reveal is gated (biometric where present, an explicit confirmation dialog
  where not, e.g. Linux) and warns against screenshots. Restore validates the
  scalar is in `[1, n)` and self-heals a priv/pub mismatch. Web / non-extractable
  keys deliberately cannot export a phrase.

### 1a. Peer trust display (M1b badges)
- Trust badges (red = keyed-unverified, amber = verified) render only from a
  **server-set `soul_fingerprint`** carried in the peer/member record or LiveKit
  participant metadata. The client never resolves an identity string to a
  fingerprint locally, so a peer/participant cannot forge a badge by choosing an
  identity. The server stamps the fingerprint only from a cryptographically-proven
  identity (see skchat `SECURITY.md`). A keyless peer shows no badge; your own
  tile is never badged.
- **Aggregate group badge (unified conversation list).** The single trust badge
  shown on a group tile folds each member's `peerTrustTierProvider` tier over
  the member's SERVER-set `soul_fingerprint`, the same fingerprint source as
  the 1:1 and participant badges above. There is no client-side identity to
  fingerprint resolution anywhere in the fold, so the M1b unspoofability
  invariant holds unchanged for groups: a keyless member contributes no key
  and cannot raise a group's aggregate badge to verified.

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

### 3a. Call signaling (ringing, in-thread calling Phase 2)
- Ringing for a 1:1 call rides the server's signed `CALL_INVITE` (the
  `/call/start`, `/call/answer`, `/call/incoming` routes), with an anti-spoof
  `from_fqid` cross-check against the signature so a caller cannot ring as
  someone else's identity.
- The 1:1 verify-before-call gate (`canCall` plus the trust/verify sheet) is
  unchanged: placing a call is still gated on the same peer-verification
  state as before this feature.
- Server-side, `/call/start`, `/call/answer`, and `/call/incoming` are now
  gated by the same `_gate_token_mint` check as `/livekit/token`
  (loopback/tailnet, or a valid `SKCHAT_GUEST_OPERATOR_TOKEN` off-tailnet),
  closing a gap where those routes minted a full-publish LiveKit JWT (or, for
  `/call/incoming`, disclosed who is calling whom) with no auth check at all
  (see skchat `CHANGELOG.md`).
- Call media stays DTLS-SRTP (see §3 above): this change is about who may
  ring or mint a call token, not the media transport.
- Retiring the `__CALL_REQUEST__` chat-sentinel path (the old client-side
  trick of sending a special chat message to start a call) removes a second,
  unauthenticated way to trigger a call and reduces client attack surface.

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
