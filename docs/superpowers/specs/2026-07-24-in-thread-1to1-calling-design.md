# In-Thread 1:1 Calling (Phase 2): Design

**Date:** 2026-07-24
**Repo:** skchat-app (Flutter client), with server verification/wiring in skchat.
**Status:** Approved (design). Epic `4187787c`, coord card `1b3315d7`.
**Follows:** Phase 1 (unified conversation list), merged 2026-07-24.

## 1. Goal

Make 1:1 audio/video calling actually usable peer-to-peer and coherent with the
sovereign trust model:

1. **Ring** the peer through the existing signed `CALL_INVITE` server path so an
   incoming call surfaces as a ringing banner on the callee's device (today the
   caller just opens a room and the peer is never notified).
2. **Minimize** the in-conversation call to a floating pill that persists across
   navigation, expandable back to full screen.
3. **Unify** all 1:1 call entry behind one `CallSession` provider (retiring the
   dead parallel WebRTC path and its duplicate call-state model).

Design bias: fewest taps, least on-screen motion, no weakening of the existing
security posture. The 1:1 verify-before-call trust gate stays exactly as is.

## 2. Current state (grounding)

The map of the existing subsystem found two parallel, non-integrated 1:1 call
implementations:

- **Path A (legacy WebRTC, dead):** `callProvider` / `CallNotifier`
  (`lib/features/calls/call_provider.dart`) + `CallState` / `CallStatus` /
  `CallType` (`lib/models/call_state.dart`) + `WebRTCCallService`
  (`lib/services/webrtc_service.dart`) + `OutgoingCallScreen` /
  `IncomingCallScreen` / `InCallScreen` + **`PiPOverlay`**
  (`lib/features/calls/widgets/pip_overlay.dart`, a fully built draggable
  minimize pill). Ringing was a raw `__CALL_REQUEST__:<type>` chat sentinel. The
  conversation screen no longer invokes any of this; it is dead and untested.
- **Path B (LiveKit SFU, live):** `_startDirectCall` in
  `lib/features/conversation/conversation_screen.dart` derives a room name
  **client-side** (`sk-room-<sorted ids>`) and pushes `LiveKitCallScreen`
  (`lib/features/calls/livekit_call_screen.dart`) which mints a token via
  `POST /livekit/token` and joins. `LiveKitCallService`
  (`lib/services/livekit_call_service.dart`) is a pure "join a LiveKit room"
  abstraction: no ring, no answer, no signaling. This is what the app-bar
  Voice/Video buttons invoke today.

Consequences the design must address:
- **No ringing on the live path.** The peer is never notified; they only join if
  they independently open the same chat and tap call. The server has a complete
  ring path (`POST /call/start`, `POST /call/answer`, `GET /call/incoming`,
  signed `CALL_INVITE` with anti-spoof `from_fqid` cross-check, `derive_room()`),
  already used by group calls (`ring_members` in
  `src/skchat/daemon_proxy_groupcall.py`), but no Dart code calls it.
- **Room-naming mismatch.** Client `sk-room-<sorted ids>` never equals server
  `derive_room()` (`call-<base32 hash>`), so even a manually-coordinated call and
  a server invite would not share a room.
- **No minimize on the live path.** `LiveKitCallScreen`'s back chevron just
  `context.pop()`s. Worse, the `AutoDisposeNotifier`'s `onDispose` cancels only
  stream subscriptions, not the LiveKit room, so navigating away silently leaves
  the call connected with no UI (a latent orphaned-call bug).
- **Two `CallState` models** (`CallState` for Path A, `LiveKitCallState` for
  Path B) are the root of the confusion.

## 3. Approved decisions

1. **Full scope:** ring + minimize + unify (not UI-only, not ring-only).
2. **Server-authoritative rooms + tokens:** the caller uses `POST /call/start`'s
   returned `{room, token, livekit_url}` and joins that exact room; the
   client-side `sk-room-<ids>` derivation is retired for 1:1.
3. **Retire Path A:** delete the dead WebRTC provider, service, screens, and
   `CallState` model; retarget `PiPOverlay` to the new session. Removes the
   two-model confusion. Low risk (dead + untested).
4. **Poll `GET /call/incoming`** on a short interval while foregrounded to detect
   an incoming call (the sanctioned server endpoint), then answer via
   `POST /call/answer`.
5. **Trust gate unchanged:** `canCall(tier)` (red blocked), verify-to-unblock.

## 4. Architecture and components

Each unit has one responsibility, a defined interface, and is testable in
isolation.

### 4.1 `CallApiClient` (thin transport, behind an interface)
`lib/services/call_api_client.dart`. Wraps the server `/call/*` routes over the
app's auth-gated dataplane:
- `Future<CallStartResult> startCall(String peer)` -> `POST /call/start`,
  returns `{room, token, livekitUrl, peerFqid, identity}`.
- `Future<CallStartResult> answerCall(String peer)` -> `POST /call/answer`
  (mints the callee token for the same room, no re-ring).
- `Future<List<CallInvite>> pollIncoming()` -> `GET /call/incoming`, returns
  signature-valid invites addressed to self (`{fromFqid, room, livekitUrl, topic,
  ts, nonce}`).
Interface `CallApi` so tests inject a fake. Tested with Dio route stubs, the
pattern in `test/services/group_call_service_test.dart`.

### 4.2 `CallSession` (the one funnel)
`lib/features/calls/call_session.dart`. A `Notifier<CallSessionState?>` that owns
all 1:1 call state and drives `LiveKitCallService` + `CallApiClient`.
- State model `CallSessionState { peer, peerName, room, token, livekitUrl,
  status, isVideo, isMicEnabled, isCameraEnabled, isMinimized, isIncoming,
  startedAt, error }`.
- `enum CallStatus { idle, ringing, connecting, active, minimized, ended, failed }`.
- Methods: `startOutgoing({required peer, required peerName, required bool
  video})` (calls `startCall`, then `LiveKitCallService.connectWithToken`),
  `acceptIncoming(CallInvite)` (calls `answerCall`, then connects),
  `declineIncoming(CallInvite)`, `minimize()`, `restore()`, `hangUp()` (always
  tears down the LiveKit room, fixing the orphaned-call bug), `toggleMic()`,
  `toggleCamera()`.
- `final callSessionProvider = NotifierProvider<CallSession, CallSessionState?>`.
Unit-tested over a fake `LiveKitCallService` and fake `CallApi` (no live Room),
the pattern in `test/features/calls/group_call_screen_test.dart`.

### 4.3 `IncomingCallWatcher`
`lib/features/calls/incoming_call_watcher.dart`. A provider that polls
`CallApi.pollIncoming()` on a short interval (default ~4s) while the app is
foregrounded, dedupes by `nonce`, and drives `CallSession` into the ringing
incoming state for the newest unhandled invite. Injectable clock/interval for a
deterministic fake-clock test. A poll failure retries silently (never spams the
ring).

### 4.4 Ring banner + answer UI
Retarget the app-shell incoming-call surface (`app_shell.dart`'s
`ref.listen<CallState?>(callProvider ...)`) to watch `callSessionProvider` for
`status == ringing && isIncoming`, showing a ringing banner with Accept / Decline
that call `CallSession.acceptIncoming` / `declineIncoming`.

### 4.5 Minimize: retarget `PiPOverlay` + in-thread `CallBanner`
- `PiPOverlay` (existing, already mounted globally in `AppShell`) is retargeted
  from `callProvider` to `callSessionProvider`: it shows the draggable floating
  pill when `status == minimized` (or active-but-off-screen), tap to restore.
- New `CallBanner` widget shown at the top of `conversation_screen` when a
  `CallSession` is active/minimized for that peer, tap to expand to
  `LiveKitCallScreen`. The full-screen call screen's chevron-down calls
  `CallSession.minimize()` (not `pop()` that orphans the room); explicit hang-up
  calls `CallSession.hangUp()`.

### 4.6 Tidy app bar: one Call control
Replace the Voice / Video / meeting-room buttons in `conversation_screen`'s app
bar with a single Call `IconButton`: tap = audio, long-press = video. Both route
through `CallSession.startOutgoing` after the existing `_checkCallAllowed` trust
gate. The group-call path (`isGroup`) is unchanged (Phase 3 territory).

### 4.7 Server
Verify `POST /call/start`, `POST /call/answer`, `GET /call/incoming` are reachable
through the app's auth-gated dataplane (the same front door the app already uses
for `/api/v1/*` and `/livekit/token`). If they are only mounted on the raw call
app and not proxied to the app's origin, add a thin passthrough proxy (no call
logic change). Confirm `derive_room()` is FQID-order-independent for the caller
and callee (it is). No new server call logic is expected.

## 5. Data flow

**Outgoing:** tap Call -> `_checkCallAllowed` (red blocked) ->
`CallSession.startOutgoing` -> `CallApi.startCall(peer)` (server derives room,
mints caller token, sends signed `CALL_INVITE`, returns `{room, token,
livekitUrl}`) -> `LiveKitCallService.connectWithToken` -> status `active` ->
`LiveKitCallScreen` (or minimized pill).

**Incoming:** `IncomingCallWatcher` poll returns an invite -> `CallSession`
status `ringing`+`isIncoming` -> ring banner -> Accept -> `CallApi.answerCall`
(same room, callee token, no re-ring) -> `connectWithToken` -> `active`.

**Minimize / restore:** chevron-down -> `minimize()` (room stays live, pill
shows) -> tap pill or in-thread banner -> `restore()` -> full screen.

**Hang up:** hang-up button (full screen or pill) -> `hangUp()` -> LiveKit room
torn down -> status `ended` -> UI dismissed.

## 6. Error handling

- `startCall` / `answerCall` failure: surface an error toast, set status
  `failed`, do NOT open a dead call screen.
- ICE fetch failure: degrade via the existing `fetchIceConfig` fallback.
- Auth-gate 401 on `/call/*`: surface the same "enroll/verify" prompt the
  dataplane already uses; do not silently swallow.
- Poll failure: silent retry on the next interval; never surface a phantom ring.
- Explicit hang-up always tears down the room even on a partial/failed connect.

## 7. Security / trust coherence

- The 1:1 verify-before-call gate is unchanged: `canCall(tier)` blocks `red`
  (unverified keyed peer), verify-to-unblock via the existing sheet.
- Ringing rides the existing signed `CALL_INVITE` with the server's anti-spoof
  `from_fqid == envelope.from_fqid` cross-check; the client trusts only
  signature-valid invites the server returns from `/call/incoming`.
- Call media stays DTLS-SRTP (classical, already documented in `SECURITY.md`); no
  new plaintext at rest, no new identity resolution on the client.
- Retiring Path A removes an unused `__CALL_REQUEST__` chat-sentinel ring path,
  reducing surface area.

## 8. Testing

- `CallApiClient`: Dio-stub tests for `startCall` / `answerCall` / `pollIncoming`
  (success + error shapes).
- `CallSession`: state-machine unit tests over fakes (idle -> ringing ->
  connecting -> active -> minimized -> restore -> ended; outgoing; accept
  incoming; decline; hang-up tears down the room; failed start does not open a
  screen).
- `IncomingCallWatcher`: fake-clock test (poll surfaces newest invite, dedupes by
  nonce, silent retry on failure).
- Widget tests: ring banner Accept/Decline fire the right intent; retargeted
  `PiPOverlay` shows on minimize and restores on tap; single Call button (tap =
  audio, long-press = video) routes through `CallSession`; trust gate blocks a
  red peer and unblocks after verify.
- No regression in the existing group-call and LiveKit suites; the retirement of
  Path A deletes its (nonexistent) tests without affecting others.

## 9. Delivery

Decomposes into a coord-and-plan sequence of roughly 8 tasks, TDD, merged via PR
to `main`, deployed, and the `.41` build refreshed (matching the Phase 1
cadence):

1. `CallApiClient` + `CallStartResult` / `CallInvite` models + tests.
2. `CallSession` provider + state machine + tests (fakes).
3. Wire the outgoing caller: single app-bar Call button (tap/long-press) + trust
   gate through `CallSession.startOutgoing`; join via `connectWithToken`.
4. `IncomingCallWatcher` poll + ring banner + accept/decline via `answerCall`.
5. Minimize: retarget `PiPOverlay` to `callSessionProvider`, in-thread
   `CallBanner`, chevron-down = minimize, fix the orphaned-call teardown.
6. Retire Path A (delete `call_provider`, `webrtc_service`, `CallState` model,
   Outgoing/Incoming/InCall screens + their routes; update `app_shell`).
7. Server: verify/proxy `/call/*` through the auth-gated dataplane.
8. Regression + docs (`CHANGELOG.md`, `SECURITY.md`).

Sequence: 1 -> 2 -> 3 -> 4 -> 5, then 6 (retire) once 3-5 prove the new path,
7 alongside 3-4, 8 last.

**Out of scope (later phases):** group calling and escalate-1:1-to-group
(Phase 3); one-tap call from the conversation list via a long-press quick action
(Phase 1b enrichment); voice input (Phase 4).
