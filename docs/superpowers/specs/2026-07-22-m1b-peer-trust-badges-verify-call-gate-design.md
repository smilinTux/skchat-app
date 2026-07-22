# M1b: per-peer trust badges + safety-number verify + 1:1 call gate — design

**Date:** 2026-07-22
**Status:** approved (design + decisions confirmed with Chef)
**Continues:** M1 self-identity + trust ([[skchat-m1-self-identity-trust]]); the
thick-client handoff's highest-value M1b item.

## Problem

M1 gave every device its OWN identity with a red/amber/green self-trust tier
(`SelfTrustTier`, rendered by the `TrustBadge` widget). But trust is only shown
for SELF. When a user looks at a peer (a DM, an inbox row, a group member, a
Space speaker), there is no indication of whether that peer is verified, and
nothing stops a voice/video call to an unverified peer. M1b makes per-peer trust
visible and enforced.

## Decisions (confirmed with Chef)

- **Trust source:** a **local TOFU record** (trust-on-first-use), Signal-style,
  sovereign, no server changes. The app records the peer's CapAuth fingerprint
  (`conversation.soulFingerprint`) the first time it sees a peer. A peer starts
  **red**; a later fingerprint change flips it to red with a key-change warning.
- **Verify flow:** **safety-number compare**. A stable code derived from both
  fingerprints; users compare it out-of-band (read aloud or scan a QR), then tap
  "Mark verified" to promote the peer to **amber**. A key change breaks it back
  to red.
- **Call gate (Chef's rule):** a 1:1 call to a **red** peer is blocked with a
  "Verify to call" affordance. No voice/video unless the peer is amber+.

## The tier model (per-peer)

Reuses `SelfTrustTier {red, amber, green}` semantics but applied to peers via a
parallel `PeerTrustTier`:
- **red** = TOFU (seen, not verified) OR the peer's fingerprint changed since
  first-seen (a distinct `keyChanged` danger sub-state the UI surfaces loudly).
- **amber** = safety-number verified by the user.
- **green** = reserved (self/operator only); a peer never shows green in this
  cut. (A future capauth-anchored-peer tier could earn green.)

`TrustBadge` already renders red/amber/green; we feed it the peer tier mapped
onto `SelfTrustTier` (red/amber) so the widget is reused unchanged, plus a
compact-mode `Semantics` label fix (a review flagged the bare-dot a11y gap).

## Architecture

### Component 1 — `PeerTrustStore` (local TOFU)

`lib/services/peer_trust_store.dart`.

```
class PeerTrustRecord {
  final String peerId;
  final String fingerprint;   // capauth soulFingerprint first seen
  final bool verified;        // amber once true
  final DateTime firstSeenAt;
}

enum PeerTrustTier { red, amber }   // green is self-only

abstract class PeerTrustStore {
  Future<PeerTrustRecord?> get(String peerId);
  Future<void> put(PeerTrustRecord r);
}
```

- `record(peerId, fingerprint)` — called whenever a peer is observed (inbox
  load, conversation open, group member, Space participant). First sight
  persists `{fingerprint, verified:false, firstSeenAt:now}`. If a record exists
  with a DIFFERENT fingerprint, it is a **key change**: keep the record but mark
  it unverified and flag `keyChanged` so the tier resolves to red-danger until
  re-verified.
- `tierFor(peerId, currentFingerprint)` — resolves the tier: no record or
  key-changed or unverified => red; verified and fingerprint matches => amber.
- `markVerified(peerId, fingerprint)` — promotes to amber (only for the current
  fingerprint; a stale fingerprint cannot be verified).
- Persistence: the shared Hive `settings` box (same backend the other prefs
  use), one JSON blob keyed `peer_trust_records`, through an injectable seam so
  tests use an in-memory fake and never touch Hive. Best-effort throughout (a
  storage error never breaks chat).

A Riverpod `peerTrustTierProvider.family(peerId, fingerprint)` exposes the tier
to every surface; `peerTrustControllerProvider` exposes `record` / `markVerified`
and invalidates the family on change.

### Component 2 — safety number

`lib/services/safety_number.dart`, a pure function:

```
String safetyNumber(String selfFingerprint, String peerFingerprint);
```

Deterministic: sort the two fingerprints (so both sides compute the SAME
number regardless of direction), `SHA-256` the concatenation, and render the
digest as a grouped 60-digit decimal string (Signal-style: 12 groups of 5),
plus a short 8-char hex "compare code" for the compact affordance. Pure, no
I/O, fully unit-testable. Both sides display the identical value.

### Component 3 — verify flow

`lib/features/identity/verify_peer_sheet.dart`, a bottom sheet reached from the
peer's identity affordance and from the call gate's "Verify to call":
- Shows the peer's display name, current tier badge, and the safety number
  (large, grouped) with the peer's fingerprint.
- "Mark verified" -> `peerTrustControllerProvider.markVerified(peerId, fp)` ->
  the peer flips amber everywhere (family invalidation).
- When the record is `keyChanged`, the sheet leads with a red "Safety number
  changed - the peer's key is different from what you verified before. Only mark
  verified again if you trust this change." warning.
- A QR of the peer fingerprint is shown for in-person scan (reuses the existing
  `qr_flutter` dependency); scanning is a later enhancement, out of scope here.

### Component 4 — per-peer badges

Place `TrustBadge(tier: peerTier, compact: true)` (with the a11y `Semantics`
label) on:
- **DM header** — `conversation_screen.dart` app bar, next to the peer name.
- **Inbox rows** — `ConversationTile` (`chats_screen.dart` list), a small dot on
  the avatar/name row. Skip group rows (groups are not 1:1 peers).
- **Group member list** — each member row (`groups/` member surface).
- **Space participant tiles** — speaker avatars in `space_room_screen.dart`.

Each surface reads `peerTrustTierProvider(peerId, soulFingerprint)` and calls
`record(...)` on first observation so the TOFU store is populated as peers are
seen. Group/Space members without a resolvable capauth fingerprint show no badge
(nothing to anchor trust to) rather than a misleading red.

### Component 5 — 1:1 call gate

In the 1:1 call initiation path (`conversation_screen.dart` call button ->
`svc.startCall(peerId)` and `call_provider.dart` `initiateCall`):
- Before starting, resolve the peer tier. If **red**, do NOT start the call;
  instead show the "Verify to call" affordance (a snackbar/dialog with a
  "Verify" button that opens the verify sheet). Amber+ proceeds normally.
- The call button itself renders disabled/greyed with a small lock hint when the
  peer is red, so the block is discoverable, not a dead tap.
- Gate ONLY the 1:1 call path. Spaces (many-party, host-gated) and group calls
  are out of scope for this cut.

## Testing

- **PeerTrustStore** (in-memory fake): first-sight records red; second identical
  sight stays red until verified; `markVerified` -> amber; a changed fingerprint
  -> red + keyChanged and cannot be verified against the stale fingerprint;
  persistence round-trips via a fake store.
- **safety_number**: deterministic and symmetric (`safetyNumber(a,b) ==
  safetyNumber(b,a)`); stable format (60 digits, 12 groups); different inputs
  differ; a known vector locks the format.
- **Call gate** (pure predicate): `canCall(tier)` is false for red, true for
  amber/green; a widget test that a red peer's call button is disabled and a
  tap surfaces the verify affordance rather than starting a call.
- **Badge a11y**: compact `TrustBadge` exposes a `Semantics` label per tier
  (colorblind/screen-reader gap fix).

## Out of scope (deferred M1b tail)

Recovery phrase (BIP39) export/import, first-run onboarding wizard, QR-scan
verification (show-only QR ships here), a capauth-anchored green peer tier,
group-call gating. Each is its own follow-up.

## Risks / notes

- **Fingerprint availability:** the badge/gate need `soulFingerprint` per peer.
  Where a surface lacks it (an unresolved guest), show no badge and treat the
  call as red (cannot verify what has no key). Verify the conversation/participant
  models actually carry the fingerprint at each site during implementation.
- **TOFU population timing:** `record(...)` must fire on observation without
  spamming writes (no write when unchanged). The store's put is create-or-update
  by peerId with an unchanged-skip, mirroring the GTD upsert discipline.
- **Reused widget:** `TrustBadge` takes `SelfTrustTier`; map `PeerTrustTier.red
  -> SelfTrustTier.red`, `amber -> amber`. Do not widen the enum into the widget;
  keep the peer/self tier types distinct and map at the call site.
