# App-side: signed prekeys + data-plane capauth (light up SKCHAT_REQUIRE_SIGNED_PREKEYS + SKCHAT_DATAPLANE_AUTH)

**Goal:** Make the Flutter app (1) SIGN its published prekey bundle and (2) attach a capauth credential to chat data-plane requests, so the already-built, flag-gated server enforcement (`SKCHAT_REQUIRE_SIGNED_PREKEYS`, `SKCHAT_DATAPLANE_AUTH`) can be enabled without locking the app out.

**Build/deploy:** Flutter builds on `.41` only (`~/flutter/bin/flutter build web`). Deploy = copy `build/web` to the served location + reload. The current live app is served by `skchat-app-web.service` (static) / the webui.

**Risk model (drives sequencing):**
- The Dart changes are ADDITIVE: the app signing its prekey + sending a capauth header changes nothing while the server flags are OFF (server ignores the extra material). So build+deploy is safe on its own.
- The DANGER is only at the enforcing flip. `SKCHAT_REQUIRE_SIGNED_PREKEYS` wrong -> DMs downgrade to classical (degraded, NOT locked out). `SKCHAT_DATAPLANE_AUTH` wrong -> 401 on /api/send -> app CANNOT MESSAGE (locked out). So: prekeys flip first (low blast radius), dataplane-auth flip last, each behind a "does the app still work?" checkpoint, both instantly revertible via the systemd drop-ins.

## Server formats to match EXACTLY (from the code I built)
- **Prekey signature** (`prekey_sig.py`): a DETACHED OpenPGP signature (ASCII-armored, into the bundle's `signature` field) over `json.dumps(payload, sort_keys=True, separators=(",",":"))` of ONLY the identity-bound fields (identity + hybrid public key material; NOT device_id/ratchet). Verified by `verify_prekey_bundle`.
- **Data-plane credential** (`dataplane_auth.py`): a base64url-encoded signed FQID assertion `{claim, sig}` — the SAME wire form the access plane / `spaces/federation/assertion.verify_signed` already accepts. Sent as `Authorization: Bearer <token>` or `X-CapAuth-Token: <token>`. The app already mints this for the skos access plane (`access_token_signer.dart`).

---

### Task 1: Sign the published prekey bundle
**Files:** `lib/services/pq_prekey_service.dart` (the publish path), reuse the app's PGP identity signer (`guest_identity.dart` / `join_service.dart` sign helpers).
- [ ] Build the identity-bound payload EXACTLY as `_canonical_signed_bytes` does (same field subset, `sort_keys`, compact separators).
- [ ] Produce a detached ASCII-armored PGP signature over those bytes with the device/identity key.
- [ ] Set `bundle['signature']` to the armored signature (replacing `null`) before `POST /api/v1/prekey`.
- [ ] Verify locally: publish, then on the server `verify_prekey_bundle(bundle, identity)` returns True (a quick server-side check script).

### Task 2: Attach the capauth credential to chat data-plane requests
**Files:** `lib/core/transport/chat_transport_bridge.dart` (POST /api/v1/send) + the shared Dio/http for `/api/v1/prekey` + `/api/v1/inbox`; reuse `capauth_service.dart` / `access_token_signer.dart` to mint the token.
- [ ] Add an interceptor / header on the chat data-plane Dio: `Authorization: Bearer <capauth assertion>` for /api/send, /api/v1/prekey, /api/v1/inbox.
- [ ] The assertion is the same base64url `{claim, sig}` the access plane mints; reuse it, do not reinvent.
- [ ] Verify locally: with `SKCHAT_DATAPLANE_AUTH=1` on a test webui, the app's send returns 200 (not 401).

### Task 3: Build + deploy (on .41)
- [ ] `ssh cbrd21@.41 'cd ~/clawd/skcapstone-repos/skchat-app && ~/flutter/bin/flutter build web --release'`
- [ ] Deploy `build/web` to the served path; reload the static server / webui.
- [ ] CHECKPOINT: with BOTH flags still OFF, confirm the live app still sends/receives normally (no regression from the additive changes).

### Task 4: Enable, one flip at a time, each with a checkpoint
- [ ] Flip `SKCHAT_REQUIRE_SIGNED_PREKEYS=1` (webui drop-in) + restart. Verify a DM still negotiates hybrid (prekey accepted). Revert if it downgrades.
- [ ] CHECKPOINT with operator: confirm messaging works.
- [ ] Flip `SKCHAT_DATAPLANE_AUTH=1` (webui + daemon drop-in) + restart. Verify the app can still send (200, not 401). REVERT INSTANTLY if 401. This is the lock-out risk.
- [ ] Monitor.

## What Not To Touch
- The server side (already built + tested). Only the app produces the signature/credential; the server verifies.
- Don't flip both server flags at once; prekeys first (degrade-only), dataplane-auth last (lock-out risk).
