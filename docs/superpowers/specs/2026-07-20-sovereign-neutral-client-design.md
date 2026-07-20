# Design: Sovereign, server-neutral skchat client (X-style) with trust-tiered anonymous identity

Status: DRAFT for Chef review. Date: 2026-07-20.
Scope of THIS doc: the product north-star + the M1 (foundation) sub-project in
detail. M2-M4 are roadmap stubs and get their own specs later.

## 1. Overview / north-star

A single skchat client (web + Windows/macOS/Linux thick app) that anyone can open
with zero signup. On first run they pick a display name and get a keypair-based
identity minted and stored locally. From there they can find people in an
active-users directory, DM anyone (E2E encrypted), do 1:1 voice/video, spin up
groups, and join Spaces. There are no email accounts.

Trust is a separate, always-visible axis from encryption. Everything is E2E
encrypted regardless of who you talk to (the lock). Trust (the badge) says whether
sovereign trust has been established, and it gates the sensitive capabilities.

The same binary ships to everyone. Trust, not a build edition, decides what is
visible and usable. The build only differs in one thing: public builds bake no
server URL and none of the operator's private config.

Distribution model (chosen): **hybrid** - sovereign now, accounts later. M1-M3
ship the sovereign, verification-based client. M4+ can add a shared-account tier.

## 2. Trust model

Three tiers, wired into the existing sovereign trust layer (trust graph /
`did_verify_peer` / capauth), NOT a new parallel score. Shown everywhere an id
appears (DM header, inbox rows, group member list, Space stage, directory).

- **Red / untrusted (default):** fresh key, trust-on-first-use. The id is shown
  but carries no sovereign trust ("as good as junk").
- **Amber / provisional (earned):** earned by EITHER
  - safety-number verification: two peers compare a short fingerprint out of band
    (read on a call or scan a QR), elevating that relationship; or
  - a vouch from a green (sovereign) user.
- **Green / sovereign:** capauth/DID-verified identity in the trust graph. Unlocks
  the operator surfaces and the real identity.

### 2.1 Capability-by-tier matrix (the enforcement contract)

| Capability | Red | Amber | Green |
|---|---|---|---|
| E2E text DM (1:1) | Yes | Yes | Yes |
| Appear in / query active-users directory | Yes | Yes | Yes |
| Be added to a group + group text | Yes | Yes | Yes |
| Join a Space as listener | Yes | Yes | Yes |
| **Initiate 1:1 voice/video call** | **No** | Yes | Yes |
| Speak in a Space | host-consent (existing raise-hand) | host-consent | host-consent |
| SKOS / file read-write / `run` / fleet control | No | No | **Yes (capauth)** |
| Real sovereign identity displayed | No | No | Yes |

**The call gate (Chef rule):** initiating a 1:1 voice/video call requires the
target peer to be amber-or-green in the initiator's trust. A red peer's call
button is disabled with a "Verify to call" affordance that opens the
safety-number / vouch flow. (Symmetric-vs-one-sided is a one-line policy knob;
default: the initiator must hold amber-or-green trust in the callee.)

### 2.2 Encryption vs trust are orthogonal (UI rule)
Every DM/group/call is E2E encrypted; a lock icon states that. The trust badge is
a separate element and must never be conflated with the lock. "Encrypted" must
never read as "trusted." This is the single most important visual invariant.

## 3. Identity (keypair-based)

Chosen: **keypair-based**, reusing `guest_identity.dart` (ECDSA P-256) + the
`sk_pqc` hybrid (X25519 + ML-KEM-768) that the E2E DM codec already uses. The id
is the key fingerprint; the display name is user-editable; the 32-hex random
handle from `spaces_identity_service.dart` stays only as the LiveKit participant
handle.

- **App-wide (extension):** today `spaces_identity_service.dart` is Spaces-scoped
  by design. Promote a keypair identity to the app-wide identity used for DM,
  groups, calls, and Spaces uniformly.
- **Storage:** reuse the existing pattern - `flutter_secure_storage` on native,
  AES-GCM-in-`localStorage` on web (per-origin, survives reload). Generate-once /
  idempotent.
- **Backup: recovery phrase only (chosen).** A BIP39-style mnemonic that
  deterministically derives the identity keypair. Restore by entering the phrase.
  Local-only; the phrase and private key never touch the server. A one-time
  "write down your recovery phrase" prompt fires right after first-run (wallet
  pattern), because a browser-storage wipe is exactly when people discover they
  never backed up. Loud warning: this phrase is the identity AND the key to DM
  history; whoever holds it is you.

## 4. Neutral build + first-run onboarding

- **Strip the baked URL + private preset.** `kDefaultSkchatWebuiUrl` default
  changes from `noroc2027...` to empty. The private `lumina` preset leaves the
  compiled-in `kBackendPresets`. The operator's config moves to a gitignored
  `lumina.local.json` injected via `--dart-define-from-file` (Flutter's native
  "env file"). Public builds pass a neutral `public.json` (or nothing).
- **First-run screen (X aesthetic):** if no server is configured, show a
  "Connect to your server" screen (URL field + Test-connection health check),
  then a "Pick a display name" step that mints the identity, then the recovery
  phrase backup prompt. Leaving the server blank / "run locally" uses `localhost`
  and the bundled daemon (the sovereign path).

## 5. Security spine (client gate + server enforcement)

The audit found the client operator gate is currently **cosmetic**
(`app_drawer_sheet.dart` only groups modules under an "Operator" label, it never
checks identity), so SKOS/file surfaces are visible to everyone. Fix in BOTH
places:

- **Client:** tie the operator/SKOS modules in `core/modules/module_registry.dart`
  to a real green (capauth-verified) trust check, not just a label.
- **Server (the real boundary):** enforce capauth on the SKOS / access-plane /
  file / `run` endpoints so a hostile client that ignores the menu still cannot
  reach them. Verify and close any gap. This is what actually closes "everyone
  can browse my filesystem," and it must land before any binary is distributed.

## 6. X design language (from the screenshots)

Dark theme throughout. Adopt X's layout vocabulary, adapted to our two axes.

- **Bottom nav** (thick + web): Home/Chats, Search, Spaces, Notifications, DMs
  (badge). (X's "Grok" slot maps to our own assistant surface if/when wanted.)
- **Chat inbox** ("Chat" screen): title + inbox/filter, search bar, conversation
  rows (avatar, name + trust dot, last-message preview, timestamp, unread dot),
  floating new-message button.
- **Conversation view (DM + group):** header = avatar, name + trust badge, a
  **security-state chip** reading "Encrypted" (inverse of X's "Unencrypted"), a
  **call icon gated per section 2.1**, and an overflow menu. Composer shows an
  "Encrypted message" placeholder. Message long-press = emoji reaction bar +
  Reply / Forward / Copy / Info / Report / Delete.
- **Spaces lobby:** Recording pill + consent note, participant grid (Host /
  Co-host / Speaker with trust badges + mute icons), "+N other listeners",
  "Listen anonymously" toggle, gradient "Start Listening" button. (Our Spaces
  already implements most of this; this aligns the styling.)
- **Live Space:** participant grid, Leave Space, bottom action bar (Request/mic,
  share, react, chat count).
- **Left drawer:** identity header (avatar, display name, id + trust badge), an
  account/identity switcher, then the module list (gated by trust), then
  Settings, Backup recovery phrase, dark-mode toggle.
- **Trust badge replaces the blue check.** Where X shows a paid verified check, we
  show the red/amber/green trust dot. Loud and consistent in every id location.

## 7. M1 scope (build / extend / reuse)

Grounded in the audit map. M1 delivers the foundation; it does NOT yet build the
active-users directory (M2) or the calling-a-stranger unblock (M3).

**Reuse as-is:** per-device identity storage pattern, presence engine (server),
DM send/threads, group create, LiveKit/call plumbing, the capability-gating module
framework.

**Build / extend in M1:**
1. Keypair identity promoted app-wide (extend `spaces_identity_service.dart` model
   + `guest_identity.dart`), used across DM/groups/calls/Spaces.
2. Trust-state model + badges: a trust tier per peer id, surfaced in every id
   location per section 6; wire reads into the existing trust graph.
3. Recovery-phrase backup + restore (mnemonic derive/restore, local-only, one-time
   prompt).
4. Neutral build: strip baked URL + preset, `--dart-define-from-file` wiring,
   `build-lumina.sh` for the operator build.
5. First-run onboarding flow (connect server -> pick name -> back up phrase).
6. Make the operator/SKOS gate real: client trust check + server capauth
   enforcement (section 5).
7. The call-gate (section 2.1): disable call initiation for red peers with a
   "Verify to call" affordance (the verify flow itself is M4; M1 ships the gate +
   the disabled state).
8. X visual pass on the surfaces above (inbox, conversation header, drawer).

## 8. CI pipeline (M1b)

GitHub Actions, `windows-latest` + `macos-latest`, builds the public edition
(neutral config, operator surfaces gated) on a `vX.Y.Z` tag and publishes to
GitHub Releases. Windows `.zip`/installer + macOS `.dmg`. Unsigned for v1 (users
click through SmartScreen / Gatekeeper); signing + notarization is a later add
(needs Apple Developer + Windows certs).

## 9. Roadmap (own specs later)

- **M2:** expose the presence directory over HTTP (`GET /api/v1/who-is-online`),
  active-users list UI, arbitrary-identity lookup, start-a-DM-with-a-stranger
  (make the pairing gate optional for the open tier).
- **M3:** 1:1 voice/video + group creation from the directory; unblock the
  `peer not paired` 404 for amber-verified peers (respecting the section 2.1 call
  gate).
- **M4:** the trust-elevation flows themselves - safety-number verification UI and
  the vouch path (to amber), capauth verification (to green) - plus the operator's
  ability to vouch. Possibly the shared-account tier.

## 10. Open items

- The X screenshots drive exact spacing/typography; this doc captures structure,
  not pixels.
- Server-side capauth enforcement on SKOS endpoints needs a reachability check
  (is the access-plane currently exposed off-tailnet without auth?). Offered;
  pending Chef go.
- Call-gate symmetry (initiator-only vs both-sides amber) is a policy knob,
  defaulted to initiator-holds-amber-in-callee.
