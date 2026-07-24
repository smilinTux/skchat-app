# Unified Conversations + In-Thread Calling + Voice Input: Design

**Date:** 2026-07-24
**Repo:** skchat-app (Flutter client), with a small server assist in skchat.
**Status:** Approved (design). Decomposed into a coord-board epic + 4 phased workstreams.

## 1. Goal

Move SKChat toward an iMessage-grade conversation experience while staying coherent
with the sovereign architecture and the M1b trust model already shipped:

1. **Unify** groups into the single conversation list (no separate Groups surface).
2. **Finish** in-conversation audio/video calling for 1:1, then groups, as a
   minimizable in-thread experience.
3. **Enable** a mic on the message input for sovereign speech-to-text, plus voice
   messages with auto-transcripts.

Design bias throughout: **fewest taps / least on-screen motion**, balanced against
screen clutter and logical grouping. Every trust surface reuses
`peerTrustTierProvider`; voice stays on your own infra; nothing weakens the
existing security posture.

## 2. Current state (grounding)

- **Lists are split.** `ChatsScreen` renders `chatsProvider` via `ConversationTile`
  (one list); a separate `GroupsScreen` (`GroupTile`) is bucketed under the **Ops**
  bottom-nav destination. The `Conversation` model already carries `isGroup` +
  `memberCount`, and group threads already flow into `chatsProvider`, so the data
  is half-unified; the split is mostly UI + navigation.
- **Calling is partially wired.** The conversation app bar already has voice/video
  buttons, the trust gate (`_startDirectCallGated` / `canCall`), and a
  "Group voice call" path, over `livekit_call_service` + `livekit_call_screen`.
  Ring/answer exists server-side (signed `CALL_INVITE`, `/call/start`,
  `/call/incoming`, `/call/answer`).
- **Input has no mic.** `conversation/widgets/input_bar.dart` is the composer. The
  sovereign stack has a faster-whisper STT server (`:18794`) and
  `transcribe_audio_file` / `record_voice_message` plumbing.

## 3. Phases

### Phase 1: Unified conversation list (iMessage-style)

**Data model.** Add a `members` list to `Conversation` (per member:
`identityUri`, `displayName`, `soulFingerprint`), populated for group conversations
from the server `/conversations` `participants` (server assist: include per-member
`soul_fingerprint`, reusing `fingerprint_for_identity` already shipped). Keep
`isGroup` / `memberCount`.

**UI.** `ConversationTile` renders:
- a **composite avatar** for groups (2-3 stacked member soul-color initials);
- the group name + a `sender: message` last line;
- one **aggregate trust badge** derived from members: red if any keyed member is
  unverified, amber if all keyed members are verified, none if keyless (memoized;
  reuse `peerTrustTierProvider` per member, fold to the tile). Per-member badges
  already render in the group header.

**Navigation.** Retire `GroupsScreen` from the shell/Ops. A group tile routes into
the existing `ConversationScreen` group mode (management already lives in the group
header via `group_info_screen`). The compose (pencil) FAB opens a
**"New chat / New group"** sheet (peer picker vs the existing `create_group_screen`).

**Tap-economy enrichments.**
- **Swipe actions** on tiles: one direction mute/archive, the other pin/mark-read.
- **Long-press → quick-action sheet** (Call, Mute, Pin, Verify, Mark read): act
  without opening the chat.
- **Pinned section** at top (agents auto-pin + user pins), persisted.
- **@mention badge** on group tiles (distinct dot when the group mentions you).
- **Unified search** (existing 🔍) across DMs + groups + message contents; a result
  taps straight to that message.
- **Perf:** memoize composite avatars + the group aggregate tier; keep lazy
  `ListView.builder`; pin/mute/read are optimistic like sends.

**Out of scope:** heavy list sectioning beyond Pinned/Recent.

### Phase 2: In-thread 1:1 calling (finish + minimizable)

- A **`CallSession` provider** (peer, room, audio/video, state:
  idle/ringing/connecting/active/ended) over `livekit_call_service`, the single
  funnel for all DM call entry (replacing the ad-hoc button handlers).
- A **call banner in the thread** that expands to full-screen (`livekit_call_screen`)
  or shrinks to a **floating pill** that persists across navigation ("tap to return
  to call").
- **Ring/answer** through the existing signed `CALL_INVITE` / `/call/incoming`; the
  **trust gate stays** (verify an unverified peer before calling).
- **Tidy app bar:** one Call control (audio default, long-press for video) instead
  of two buttons.
- **One-tap call from the list** via the Phase-1 long-press quick-action.

### Phase 3: Group calling

- Extend `CallSession` to a **LiveKit conf room**; member fan-out via the token
  mint that now embeds per-member `soul_fingerprint` (proven-identity stamping from
  the M1b work).
- Expanded call uses the **`conf_screen` participant grid** with the trust badges
  already shipped; ring group members via `CALL_INVITE` fan-out.
- **Escalate a 1:1 into a group call** by adding a person mid-call (no
  hang-up-and-recreate): promote the 1:1 room to a conf room, invite the new member.
- Per-group trust policy: warn (do not hard-block) on unverified participants; the
  1:1 hard-gate does not extend to a multi-party room (documented decision).

### Phase 4: Voice input (mic STT + voice messages)

- `input_bar.dart` gains a **dual-mode mic, one button**:
  - **tap** = dictate-to-text: record, POST to faster-whisper (`:18794`, via the
    `transcribe_audio_file` path / daemon), drop an **editable** transcript into the
    field;
  - **hold** = record a **voice message**, sent with an auto-transcript caption.
- **Auto-transcribe inbound voice notes** inline (whisper on your box) so a voice
  message can be skimmed without listening; accessibility win.
- **"Transcribing…" state**; graceful-degrade (disable mic + tooltip) if the STT
  URL is unreachable. STT URL via the existing backend config.

**Out of scope:** live streaming partial transcripts (server whisper is not
streaming).

## 4. Architecture & isolation

- **`CallSession` provider** is the one place call state lives; the banner, pill,
  full-screen screen, and list quick-action all read/drive it. Testable in
  isolation (unit tests over a fake `livekit_call_service`).
- **`Conversation.members`** is the one new data seam; composite avatar + aggregate
  badge are pure functions of it (widget-testable with an in-memory trust store,
  the pattern proven in the M1b badge tests).
- **STT service** is a thin client (`SttService`: record -> POST -> transcript)
  behind an interface so tests inject a fake endpoint; the input bar depends on the
  interface, not the transport.
- Reuse, do not fork: `peerTrustTierProvider`, `TrustBadge`, `livekit_call_service`,
  `create_group_screen`, `group_info_screen`, `OperatorEnrollmentSection`.

## 5. Security / trust coherence

- Composite group badge + in-call participant badges + the call gate all read the
  **server-set `soul_fingerprint`** via `peerTrustTierProvider`; no client-side
  identity->fingerprint resolution (the unspoofability invariant from M1b holds).
- Voice audio goes only to **your** faster-whisper server (sovereign; no third
  party). Call media stays **DTLS-SRTP** (classical, already documented in
  `SECURITY.md`); no new plaintext at rest.
- Group-call trust: warn-not-block on unverified participants is an explicit,
  documented reduced-assurance decision (a multi-party room cannot enforce the 1:1
  verify-before-call gate without excluding unverified members).
- Each phase updates `CHANGELOG.md` + `SECURITY.md` per the sk-standards doc SOP.

## 6. Testing

- **Phase 1:** widget tests for the unified tile (composite avatar renders N member
  initials; aggregate badge red/amber/none per member mix; pinned ordering; swipe +
  long-press actions fire the right intent); provider test for pin/mute persistence.
- **Phase 2/3:** `CallSession` unit tests (state machine: ring -> connect -> active
  -> minimized -> return -> end; escalate 1:1 -> group); widget test for the
  banner/pill; gate test (unverified peer blocked, verify unblocks).
- **Phase 4:** `SttService` unit test with a fake endpoint (record -> transcript,
  failure -> graceful degrade); input-bar widget test (tap = dictate, hold = voice
  message); inbound-voice auto-transcript render test.
- No regressions in the existing chats/groups/conversation/calls suites.

## 7. Delivery

- Coord-board epic **"SKChat Unified Conversations + Calling + Voice"** with 4 phase
  cards (P1 unified list, P2 1:1 in-thread calling, P3 group calling, P4 voice
  input), sequenced P1 -> P2 -> P3 with P4 parallelizable after P1. Each card lists
  its acceptance criteria and dependencies.
- Each phase is TDD'd, merged via PR to `main`, deployed, and the `.41` build
  refreshed, matching this session's cadence.
