# Changelog

All notable changes to skchat-app are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning per SemVer.

## [Unreleased]

### Added
- **1:1 calls now ring the peer (in-thread calling, Phase 2).** A call now
  rings the callee via the server's signed `CALL_INVITE` (the `/call/*`
  routes) instead of the retired `__CALL_REQUEST__` chat-sentinel path, is
  minimizable to a floating pill without dropping the call, and flows through
  one `CallSession` funnel shared by the outgoing/incoming/minimize/restore
  paths (see `SECURITY.md` for the anti-spoof + gating notes).
- **Unified conversation list.** Group conversations now render inline in the
  single Chats list alongside 1:1s, with a composite group avatar and one
  aggregate trust badge folded from each member's peer trust tier over the
  server-set `soul_fingerprint`. The standalone Groups surface is retired:
  group management stays reachable from `group_info`, and New chat/New group
  compose from the existing Chats compose sheet. Server-side, `Conversation`
  gained a `members` list and the daemon proxy resolves per-member
  `soul_fingerprint` for group threads (see skchat `CHANGELOG.md`).
- **M1b trust-badge trilogy.** A compact TrustBadge (red = keyed-but-unverified,
  amber = verified) now renders on every peer surface, anchored to the peer's
  real capauth fingerprint via `peerTrustTierProvider`: 1:1 conversation tiles +
  header, group-member rows (`group_info_screen`), and conf/Space/call
  participants (`conf_screen`, Space `_SpeakerRing`, call `_ParticipantTile`).
  A keyless peer shows nothing; your own tile is never badged.
- **Device-key recovery phrase.** Back up + restore the native operator identity
  (ECDSA P-256) as a 24-word BIP39 mnemonic derived from the private scalar
  (vendored 2048-word list, no `bip39` dep). Reveal (`recovery_phrase_screen`)
  and restore (`restore_from_phrase_screen`) screens; a discoverable "Device
  recovery" section in the Me screen; native-only.
- **First-run onboarding wizard.** Wired the previously-orphaned wizard into the
  router (Welcome → Server URL → device-key enrollment → done), with a pure,
  unit-tested `startupRedirect`.

### Fixed
- **PQC grey-screen on devices without liboqs.** `HybridKemImpl()` loaded its
  ML-KEM backend eagerly in a constructor inside the pq provider bodies, so a
  device without liboqs threw and Flutter rendered a grey ErrorWidget in place
  of the app bar. New guarded `hybridKemProvider` degrades to the classical path.
- **Guest-invite bounce + async-Hive cold-start misroute** in the router
  (guest deep-links `/g/`,`/join`,`/conf` are exempt; a `RouterRefreshListenable`
  re-evaluates once persisted state hydrates; boxes pre-opened fail-safe).
- **Keystore self-heal:** `ensure()` derives the public key from the stored
  private scalar and rewrites a stale/mismatched pub (a partial restore could
  otherwise advertise one identity while signing as another).

### Security
- **Fallback file keystore is encrypted at rest (AES-256-GCM).** When the OS
  keyring is unavailable the private scalar was written base64-plaintext to
  `guest_identity.json`; it is now sealed with a key HKDF-SHA256-derived from
  `/etc/machine-id` + a separate 0600 salt file (salt kept out of the envelope).
  Legacy plaintext files are read + migrated transparently; reads fail safe.
  Threat model in `SECURITY.md`: defeats casual exfil (backup/sync/copied file),
  not a privileged same-UID attacker; the OS keyring is always preferred.
- **Participant/group trust badges are unspoofable.** The badge fingerprint is
  read only from server-set metadata (never from a client-resolvable identity),
  and the server stamps it only from a cryptographically-proven identity.

## [1.1.1] - 2026-07-03

### Added
- GPL-3.0-or-later `LICENSE` file (matches the README license claim).

## [1.1.0] - 2026-07-03

### Fixed
- **LiveKit data-channel receive path**: `LiveKitCallService._dataCtl` was declared and
  consumed by `LaneService` but never fed — Spaces lanes (in-call chat, whiteboard, docs)
  could send/persist but never received live peer events. Added a per-connection
  `EventsListener` on `DataReceivedEvent` that republishes `{topic, data, sender}` onto
  `_dataCtl`, disposed with the room. This repairs upstream's own lane features.

### Added
- Full sk-standards doc-set: `SOP.md` (9-section + mermaid architecture), `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`.
