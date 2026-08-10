# Watch Together: Real Sync + Stage Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Watch Together behave like one stream everybody is inside: the video plays on the Space's main stage, everyone stays within ~1 second of each other automatically, and late joiners land at the current timestamp.

**Architecture:** Keep synced LOCAL playback (every client plays its own copy, kept aligned over the data lane). That is what Teleparty, Disney GroupWatch and Amazon Watch Party all do, and it is why the picture is source quality, costs the host no upload bandwidth, and scales. We do NOT restream the video through LiveKit. What changes is that the sync becomes real: a host-authoritative heartbeat carrying the host's true playback position, clients correcting only when drift exceeds a threshold, and the surface moving from the bottom-sheet panel onto the stage.

**Tech Stack:** Flutter (web + native), Riverpod, LiveKit data lanes, YouTube IFrame API (`postMessage` + `infoDelivery`), `video_player` on native, mocktail + flutter_test, CDP for two-browser verification.

## Why the current feature does not sync (measured, not assumed)

`watch_video_web.dart:213` states "iframe sources: we can't read player time cross-origin -> shadow value", and `position` therefore returns `_shadowPos`. That value changes ONLY on an explicit `seekTo` and never advances while the video plays. So every published `{"action":"play","t":...}` carries a stale position, usually 0, and remote clients seek to the wrong place. The feature degrades to sharing a link.

**The premise is false.** Verified live over CDP against Brave 150: after a `{"event":"listening"}` handshake the YouTube IFrame API pushes `infoDelivery` messages whose `info` carries:

```
playerState, currentTime, duration, videoData, videoLoadedFraction,
playbackRate, mediaReferenceTime, progressState, playlist, ...
```

Real position IS readable. Also verified: bare `{"event":"command","func":"playVideo"}` works without a prior handshake (both handshake and no-handshake trials reached `playerState=3`), so command sending is NOT the bug and must not be "fixed".

## Global Constraints

- The watch lane wire format is cross-client (web and native). Existing actions `load|play|pause|seek` MUST keep working unchanged so an un-upgraded client still follows along. New sync fields are ADDITIVE only.
- No em dashes or en dashes in any user-visible copy, comment, commit message, or doc. Use commas, parentheses, colons, or a new sentence. Regular hyphens are fine.
- The microphone stays an independent LiveKit track. Nothing here may mute, duck or gate it, so people talk over the movie. Host mute-all and demote keep working untouched.
- Do NOT restream the video as a LiveKit track. Synced local playback is the design.
- Never correct drift while the local player is buffering; fighting a buffering player causes a seek loop.
- Every task ends green: `flutter test` passes (1254 existing tests must not regress) and `flutter analyze lib/` shows no new issues in changed files.

## Design: the sync protocol

The host (the participant who loaded the video) publishes a heartbeat on the watch lane every 3 seconds:

```json
{"lane":"watch","action":"heartbeat","t":123.4,"playing":true,"from":"<identity>"}
```

**Heartbeats MUST be ephemeral: data channel only, never mirrored to the lane store.** `LaneService.publish` (lane_service.dart:40-47) POSTs every publish to the server store, and `catchUp` (lane_service.dart:51-61) replays that whole persisted list to late joiners. At 3 second intervals a two hour movie persists roughly 2400 heartbeats, and every late joiner would replay all of them through the drift correction path. The local snapshot does not change between replayed events, so drift stays above the dead band and each one issues a seek: a seek storm ending on a stale position. A late joiner does not need replayed heartbeats anyway, because a live one arrives within 3 seconds.

This requires an ephemeral publish path on `LaneService` that skips the Dio mirror. `load`, `play`, `pause` and `seek` keep their existing persisted behavior, since those ARE the state a late joiner must replay.

**Host authority rules** (a third authority notion next to `SpaceJoin.isHost` and the LiveKit publish grants, so it must be pinned down):

- loading a video locally sets `isHostOfVideo = true`
- receiving a REMOTE `load` clears it, so two loaders never both heartbeat and fight
- a `load` seen in catch-up replay whose `from` equals our own identity restores it (LiveKit does not loop your own data back, but `catchUp` does replay it)
- if the video host leaves, heartbeats simply stop and everyone keeps playing from where they are. No failover in this pass; note it in the docs as a known limit rather than inventing an election.

Clients compare their own real position to `t`:

- drift = |localPosition - t|
- drift <= 2.0s: do nothing. This dead band is what stops constant micro-seeking, which is far more annoying than being half a second off.
- drift > 2.0s: `seekTo(t)`, and match play/pause state.

**Deliberate simplification: no wall-clock math.** A naive design sends the host's epoch timestamp and has clients extrapolate, which then depends on the two machines' clocks agreeing. They do not. Transport on the tailnet is well under 100ms, which is an order of magnitude below the 2 second dead band, so comparing positions directly is both simpler and more robust than trusting clock sync.

`playbackRate` is assumed 1.0. If a player reports otherwise, sync is skipped for that tick rather than guessed at.

---

### Task 1: Pure sync decision logic

The whole correction policy as testable pure functions, with no Flutter, no timers, no player.

**Files:**
- Create: `lib/features/spaces/watch_drift.dart`
- Test: `test/features/spaces/watch_drift_test.dart`

**Interfaces:**
- Produces:
  - `class PlaybackSnapshot { final double position; final bool playing; final bool buffering; }`
  - `enum DriftAction { none, seekAndPlay, seekAndPause, playOnly, pauseOnly }`
  - `DriftAction resolveDrift({required PlaybackSnapshot local, required double hostPosition, required bool hostPlaying, double deadBandSeconds = 2.0})`

- [ ] **Step 1: Write the failing test**

```dart
// test/features/spaces/watch_drift_test.dart
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_drift.dart";

PlaybackSnapshot snap(double p,
        {bool playing = true, bool buffering = false}) =>
    PlaybackSnapshot(position: p, playing: playing, buffering: buffering);

void main() {
  test("small drift inside the dead band is left alone", () {
    // Correcting constantly is worse than being slightly off: every seek
    // stutters the picture for the viewer.
    expect(
        resolveDrift(local: snap(100.5), hostPosition: 100.0, hostPlaying: true),
        DriftAction.none);
  });

  test("drift past the dead band seeks and matches play state", () {
    expect(
        resolveDrift(local: snap(90.0), hostPosition: 100.0, hostPlaying: true),
        DriftAction.seekAndPlay);
    expect(
        resolveDrift(local: snap(120.0), hostPosition: 100.0, hostPlaying: false),
        DriftAction.seekAndPause);
  });

  test("a buffering local player is NEVER corrected", () {
    // Seeking a player that is still buffering restarts the buffer and can
    // livelock: it never catches up, so it never stops being corrected.
    expect(
        resolveDrift(
            local: snap(10.0, buffering: true),
            hostPosition: 100.0,
            hostPlaying: true),
        DriftAction.none);
  });

  test("in-band position but wrong play state fixes only the play state", () {
    expect(
        resolveDrift(
            local: snap(100.2, playing: false),
            hostPosition: 100.0,
            hostPlaying: true),
        DriftAction.playOnly);
    expect(
        resolveDrift(
            local: snap(100.2, playing: true),
            hostPosition: 100.0,
            hostPlaying: false),
        DriftAction.pauseOnly);
  });

  test("dead band is configurable and boundary is inclusive", () {
    expect(
        resolveDrift(
            local: snap(102.0),
            hostPosition: 100.0,
            hostPlaying: true,
            deadBandSeconds: 2.0),
        DriftAction.none);
    expect(
        resolveDrift(
            local: snap(102.01),
            hostPosition: 100.0,
            hostPlaying: true,
            deadBandSeconds: 2.0),
        DriftAction.seekAndPlay);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/spaces/watch_drift_test.dart`
Expected: FAIL, "Not found: 'package:skchat/features/spaces/watch_drift.dart'".

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/features/spaces/watch_drift.dart
/// Pure drift-correction policy for Watch Together.
///
/// No Flutter, no timers, no player: the whole "when do we yank the viewer to
/// a new position" decision lives here so it can be unit tested exhaustively.
library;

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.position,
    required this.playing,
    this.buffering = false,
  });

  final double position;
  final bool playing;
  final bool buffering;
}

enum DriftAction { none, seekAndPlay, seekAndPause, playOnly, pauseOnly }

/// Decide what to do with [local] given the host's authoritative state.
///
/// [deadBandSeconds] exists because constant micro-correction is worse than a
/// small offset: every seek visibly stutters the picture. Two seconds is below
/// the threshold where people notice they are out of step with the room, and
/// far above tailnet transport delay, which is why positions are compared
/// directly instead of extrapolated from wall-clock timestamps (the two
/// machines' clocks cannot be trusted to agree).
DriftAction resolveDrift({
  required PlaybackSnapshot local,
  required double hostPosition,
  required bool hostPlaying,
  double deadBandSeconds = 2.0,
}) {
  // Correcting a buffering player restarts its buffer, so it never catches up
  // and never stops being corrected. Leave it alone until it settles.
  if (local.buffering) return DriftAction.none;

  final drift = (local.position - hostPosition).abs();
  if (drift > deadBandSeconds) {
    return hostPlaying ? DriftAction.seekAndPlay : DriftAction.seekAndPause;
  }
  if (local.playing != hostPlaying) {
    return hostPlaying ? DriftAction.playOnly : DriftAction.pauseOnly;
  }
  return DriftAction.none;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/spaces/watch_drift_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/watch_drift.dart test/features/spaces/watch_drift_test.dart
git commit -m "feat(spaces): pure drift-correction policy for watch-together"
```

---

### Task 2: Read the YouTube player's REAL position

Replaces the shadow position with live state from the IFrame API.

**Files:**
- Modify: `lib/features/spaces/watch_video_web.dart` (add the listening handshake, an `infoDelivery` message listener, and real `position` / `playbackSnapshot`)
- Test: `test/features/spaces/watch_info_delivery_test.dart`

**Interfaces:**
- Produces:
  - `PlaybackSnapshot? parseYouTubeInfo(String raw)` as a top-level pure function in a NEW file `lib/features/spaces/watch_yt_info.dart` so it is testable off-browser
  - `PlaybackSnapshot get playbackSnapshot` on BOTH controllers (web and native)

- [ ] **Step 1: Write the failing test**

```dart
// test/features/spaces/watch_info_delivery_test.dart
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_yt_info.dart";

void main() {
  test("parses currentTime and playerState from a real infoDelivery frame", () {
    // Shape captured live over CDP from Brave 150 against the IFrame API.
    const raw =
        '{"event":"infoDelivery","info":{"playerState":1,"currentTime":42.5,'
        '"duration":212.0,"playbackRate":1}}';
    final s = parseYouTubeInfo(raw)!;
    expect(s.position, 42.5);
    expect(s.playing, isTrue);
    expect(s.buffering, isFalse);
  });

  test("playerState 3 is buffering, and buffering is NOT playing", () {
    const raw =
        '{"event":"infoDelivery","info":{"playerState":3,"currentTime":10.0}}';
    final s = parseYouTubeInfo(raw)!;
    expect(s.buffering, isTrue);
    expect(s.playing, isFalse);
  });

  test("paused, cued and unstarted are not playing", () {
    for (final st in [2, 5, -1]) {
      final s = parseYouTubeInfo(
          '{"event":"infoDelivery","info":{"playerState":$st,"currentTime":1.0}}')!;
      expect(s.playing, isFalse, reason: "playerState $st must not be playing");
    }
  });

  test("a non-1.0 playback rate is reported so sync can skip the tick", () {
    const raw =
        '{"event":"infoDelivery","info":{"playerState":1,"currentTime":5.0,'
        '"playbackRate":1.5}}';
    expect(parseYouTubeInfo(raw)!.rateIsNormal, isFalse);
  });

  test("unrelated or malformed frames return null instead of throwing", () {
    expect(parseYouTubeInfo('{"event":"initialDelivery"}'), isNull);
    expect(parseYouTubeInfo("not json"), isNull);
    expect(parseYouTubeInfo('{"event":"infoDelivery","info":{}}'), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/spaces/watch_info_delivery_test.dart`
Expected: FAIL, missing `watch_yt_info.dart`.

- [ ] **Step 3: Write minimal implementation**

Add `rateIsNormal` to `PlaybackSnapshot` in `watch_drift.dart` (default true), then:

```dart
// lib/features/spaces/watch_yt_info.dart
import "dart:convert";

import "watch_drift.dart";

/// YouTube IFrame API player states.
const int _kUnstarted = -1, _kEnded = 0, _kPlaying = 1, _kPaused = 2;
const int _kBuffering = 3, _kCued = 5;

/// Parse one `infoDelivery` frame from the YouTube IFrame API.
///
/// The app used to assume player time was unreadable cross-origin and faked a
/// "shadow" position that never advanced, which is why nothing ever stayed in
/// sync. Verified live over CDP: after a `{"event":"listening"}` handshake the
/// API pushes these frames carrying playerState, currentTime, duration and
/// playbackRate.
///
/// Returns null for frames that carry no usable playback state.
PlaybackSnapshot? parseYouTubeInfo(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded["event"] != "infoDelivery") return null;
  final info = decoded["info"];
  if (info is! Map) return null;
  final state = info["playerState"];
  final time = info["currentTime"];
  if (state is! num || time is! num) return null;
  final rate = info["playbackRate"];
  return PlaybackSnapshot(
    position: time.toDouble(),
    playing: state.toInt() == _kPlaying,
    buffering: state.toInt() == _kBuffering,
    rateIsNormal: rate is! num || (rate.toDouble() - 1.0).abs() < 0.01,
  );
}
```

In `watch_video_web.dart`:
- after building the iframe, add a `window.onMessage` listener that ignores messages whose `source` is not `iframeEl?.contentWindow`, feeds the rest to `parseYouTubeInfo`, and stores the latest snapshot in a `PlaybackSnapshot? _latest` field. Keep the `StreamSubscription` on the controller and expose a real `dispose()` that cancels it (today's `dispose` is an empty no-op, watch_video_web.dart:220), so the session's `ref.onDispose` can tear it down
- post `{"event":"listening","id":"<viewType>"}` on EVERY iframe `onLoad`, not once. Each `load()` swaps the iframe `src`, and a stage-kind flip can reload it, so a one-shot handshake stops delivery for the rest of the session
- change `position` to return `_latest?.position ?? _shadowPos` for youtube mode, keeping `_shadowPos` only as the pre-handshake fallback
- add `PlaybackSnapshot get playbackSnapshot` returning `_latest ?? PlaybackSnapshot(position: position, playing: false)`

In `watch_video_stub.dart` add the parallel getter built from `video_player` state:

```dart
  PlaybackSnapshot get playbackSnapshot => PlaybackSnapshot(
        position: position,
        playing: _vp?.value.isPlaying ?? false,
        buffering: _vp?.value.isBuffering ?? false,
      );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/spaces/watch_info_delivery_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/watch_yt_info.dart lib/features/spaces/watch_drift.dart lib/features/spaces/watch_video_web.dart lib/features/spaces/watch_video_stub.dart test/features/spaces/watch_info_delivery_test.dart
git commit -m "feat(spaces): read the real YouTube playback position

The controller faked a shadow position that never advanced while the
video played, so every published play/seek carried a stale timestamp and
nobody ever ended up at the same place. The IFrame API does deliver
currentTime after a listening handshake, verified live over CDP."
```

---

### Task 3: Heartbeat and drift correction on the lane

**Files:**
- Create: `lib/features/spaces/watch_session.dart`
- Test: `test/features/spaces/watch_session_test.dart`

**Also modify:** `lib/services/lane_service.dart` to add an ephemeral publish that sends over the data channel WITHOUT the Dio mirror to the lane store. Keep `publish` exactly as-is for `load`/`play`/`pause`/`seek`, which ARE the state a late joiner must replay.

**Interfaces:**
- Consumes: `resolveDrift`, `PlaybackSnapshot` (Task 1); the controller's `playbackSnapshot` (Task 2); `LaneService` plus its new ephemeral publish.
- `LaneLike` gains `Future<void> publishEphemeral(Map<String, dynamic> payload)` so the fake lane can assert heartbeats never hit the persisted path.
- Produces:
  - `class WatchSessionState { String? url; bool isPlaying; bool isHostOfVideo; }`
  - `class WatchSession extends AutoDisposeFamilyNotifier<WatchSessionState, WatchSessionArgs>` with `controller`, `loadUrl`, `play`, `pause`, `syncPosition`, `applyRemote`, `onHeartbeatTick`
  - `final watchSessionProvider = AutoDisposeNotifierProviderFamily<...>`, `final laneServiceFactoryProvider`, `class WatchSessionArgs`, `abstract class LaneLike`

**It MUST be autoDispose**, matching `spaceRoomProvider` (space_room_screen.dart:519) and `confProvider` (conf_screen.dart:184). A keepAlive family member never runs `ref.onDispose`, so leaving the Space would leave the 3 second Timer firing heartbeats into a disconnected room forever, and two Spaces would leak two timers and two lane subscriptions. The stage watches this provider (Task 4 needs `watchActive`), which is what keeps it alive while the room is open.

**`WatchSessionArgs` MUST have value equality** (the `==` / `hashCode` shown below). It is a family key: without it the panel and the stage build two different notifiers, with two lane subscriptions and a split host flag. `spaceRoomProvider` only avoids this because a single `widget.join` instance flows everywhere.

`ref.onDispose` must cancel the lane subscription, cancel the heartbeat Timer, cancel the web message listener, AND dispose the controller (the native controller is a real `ChangeNotifier` owning a `video_player`, watch_video_stub.dart:163-167).

The session owns the controller AND the lane subscription. Both currently live in `_WatchPanelState`, which is why closing the panel kills remote sync as well as playback.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/spaces/watch_session_test.dart
// FakeLane implements LaneLike, records published payloads, and lets the test
// push inbound events. Covers:
//  1. loadUrl publishes {"lane":"watch","action":"load","url":...,"from":...}
//     and marks this client the video host.
//  2. applyRemote on a "load" updates state and publishes NOTHING (no loop).
//  3. onHeartbeatTick publishes {"action":"heartbeat","t":<real position>,
//     "playing":<bool>} ONLY when this client is the video host.
//  4. A non-host receiving a heartbeat 10s ahead seeks (drift > dead band).
//  5. A non-host receiving a heartbeat 0.5s off does NOT seek.
//  6. catchUp replay lands a late joiner on the current url, and the FIRST live
//     heartbeat puts them at the right position (NOT replayed heartbeats).
//  7. onHeartbeatTick uses publishEphemeral, never publish: assert the fake
//     lane's PERSISTED list stays free of heartbeat actions no matter how many
//     ticks fire. This is the guard against flooding the lane store.
//  8. A remote "load" from someone else CLEARS isHostOfVideo, so two loaders
//     never both heartbeat.
//  9. A catch-up "load" whose from == our identity RESTORES isHostOfVideo.
```

Write these as real tests using a fake controller implementing the small surface (`load`, `play`, `pause`, `seekTo`, `position`, `playbackSnapshot`) and asserting recorded calls.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/spaces/watch_session_test.dart`
Expected: FAIL, missing `watch_session.dart`.

- [ ] **Step 3: Write minimal implementation**

Build `WatchSession` per the interfaces above. Key behaviors:

```dart
  /// Only the client that loaded the video publishes heartbeats. Two authorities
  /// would fight: each would correct toward the other and the room would
  /// oscillate.
  ///
  /// EPHEMERAL on purpose. A persisted heartbeat every 3s would put ~2400
  /// events in the lane store for a two hour movie, and catchUp replays the
  /// whole list to every late joiner, which is a seek storm ending on a stale
  /// position. Live heartbeats arrive within 3s anyway.
  void onHeartbeatTick() {
    if (!state.isHostOfVideo) return;
    final s = controller.playbackSnapshot;
    if (!s.rateIsNormal) return; // do not guess at a non-1.0 rate
    _publishEphemeral(
        {"action": "heartbeat", "t": s.position, "playing": s.playing});
  }

  void _applyHeartbeat(double hostPosition, bool hostPlaying) {
    if (state.isHostOfVideo) return; // never correct the authority
    final action = resolveDrift(
      local: controller.playbackSnapshot,
      hostPosition: hostPosition,
      hostPlaying: hostPlaying,
    );
    switch (action) {
      case DriftAction.none:
        break;
      case DriftAction.seekAndPlay:
        controller..seekTo(hostPosition)..play();
        break;
      case DriftAction.seekAndPause:
        controller..seekTo(hostPosition)..pause();
        break;
      case DriftAction.playOnly:
        controller.play();
        break;
      case DriftAction.pauseOnly:
        controller.pause();
        break;
    }
  }
```

`applyRemote` routes `action == "heartbeat"` to `_applyHeartbeat` and everything else to the existing `applyWatchEvent`, so an older client that only understands load/play/pause/seek still follows along.

Drive `onHeartbeatTick` from a `Timer.periodic(const Duration(seconds: 3))` started in `build`, cancelled in `ref.onDispose`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/spaces/watch_session_test.dart`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/watch_session.dart test/features/spaces/watch_session_test.dart
git commit -m "feat(spaces): host-authoritative heartbeat keeps the room in sync

One authority publishes its real position every 3s and clients correct
only past a 2s dead band, so the room stays together without the
constant micro-seeking that makes the picture stutter."
```

---

### Task 4: Put the video on the stage

**Files:**
- Create: `lib/features/spaces/stage_content.dart`
- Modify: `lib/features/spaces/space_room_screen.dart` (stage composition around `:995-1012`, new `_WatchTogetherStage` near `:1226`)
- Modify: `lib/features/spaces/watch_video_web.dart` (idempotent view-factory registration)
- Test: `test/features/spaces/watch_stage_test.dart`

**Interfaces:**
- Produces: `enum StageKind { none, liveVideo, watch }` and `StageKind resolveStageKind({required List<StageVideo> videos, required bool watchActive})`

`resolveStageVideos` (`screen_share_helper.dart:206`) returns ONLY LiveKit screen shares and cameras, and the stage renders `if (videos.isNotEmpty)`, so a watch session has no path to the stage at all. That is the placement bug.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/spaces/watch_stage_test.dart
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/stage_content.dart";

void main() {
  test("no live video and no watch session leaves the stage empty", () {
    expect(resolveStageKind(videos: const [], watchActive: false), StageKind.none);
  });

  test("a watch session alone owns the stage", () {
    expect(resolveStageKind(videos: const [], watchActive: true), StageKind.watch);
  });

  test("a live screen share or camera OUTRANKS the watch session", () {
    // Going live is deliberate and interruptive, and the watch video keeps
    // playing and staying synced underneath, so a host can cut in over a movie
    // without ending it for the room.
    // Build the StageVideo fixture with a MockVideoTrack exactly as
    // space_room_screen_test.dart already does.
  }, skip: "fill in with the MockVideoTrack fixture");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/spaces/watch_stage_test.dart`
Expected: FAIL, missing `stage_content.dart`.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/features/spaces/stage_content.dart
import "screen_share_helper.dart";

enum StageKind { none, liveVideo, watch }

/// Live video outranks a watch session on purpose: going live is a deliberate,
/// interruptive act, and the watch video keeps playing and staying synced
/// underneath, so a host can cut in without ending the movie for everyone.
StageKind resolveStageKind({
  required List<StageVideo> videos,
  required bool watchActive,
}) {
  if (videos.isNotEmpty) return StageKind.liveVideo;
  if (watchActive) return StageKind.watch;
  return StageKind.none;
}
```

In `space_room_screen.dart`, branch the stage slot on `resolveStageKind` and add a `_WatchTogetherStage` `ConsumerWidget` that renders `WatchVideo(controller: ...)` inside `AspectRatio(16/9)` with a "Watching together" chip.

In `watch_video_web.dart`, reuse `widget.controller.container` when it already exists instead of rebuilding the DOM nodes. `_WatchVideoState.initState` currently constructs fresh elements and reassigns them on EVERY mount (watch_video_web.dart:271-313), but the registered view factory closed over the FIRST container, so after a remount the factory hands back an orphaned node and the stage renders an empty box.

Do NOT add a registration guard: duplicate `registerViewFactory` does not throw, it returns false (Flutter engine `content_manager.dart:103-105`). An earlier draft of this plan claimed otherwise and was wrong. Reusing the container is the actual fix.

**Keep the watch surface mounted when live video takes the stage.** Unmounting the `HtmlElementView` detaches the container, and a detached YouTube iframe stops and reloads when remounted, so the movie would restart every time someone goes live. Render the watch surface inside an `Offstage` (or a zero-height `SizedBox` wrapper) during `StageKind.liveVideo` rather than dropping it from the tree, so playback and sync continue underneath.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/spaces/watch_stage_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/stage_content.dart lib/features/spaces/space_room_screen.dart lib/features/spaces/watch_video_web.dart test/features/spaces/watch_stage_test.dart
git commit -m "feat(spaces): render Watch Together on the main stage"
```

---

### Task 5: Panel becomes controls only

**Files:**
- Modify: `lib/features/spaces/watch_panel.dart`
- Test: `test/features/spaces/watch_panel_test.dart`

A browser DOM element can exist in one place only, so the stage owns the player and the panel must not build a second surface.

- [ ] **Step 1: Write the failing test**

Assert `find.byType(WatchVideo)` is `findsNothing` inside the panel, and that tapping Load publishes `{"lane":"watch","action":"load","url":<typed>}` to the fake lane.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/spaces/watch_panel_test.dart`
Expected: FAIL, the panel still builds a `WatchVideo`.

- [ ] **Step 3: Write minimal implementation**

Delete the `_vc` and `_lane` fields, the `initState` lane wiring, `_applyRemote` and `_publish`. Route controls through `ref.read(watchSessionProvider(args).notifier)`. Replace the video slot with a short status line ("Playing on the main stage above." / "Load a video URL to watch together."). `dispose()` disposes only `_urlCtl`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/spaces/watch_panel_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/watch_panel.dart test/features/spaces/watch_panel_test.dart
git commit -m "refactor(spaces): watch panel is controls only, stage owns the player"
```

---

### Task 6: Honest native copy, docs, full suite

**Files:**
- Modify: `lib/features/spaces/watch_video_stub.dart` (placeholder copy + `isEmbedOnly`)
- Create: `docs/watch-together.md`

Native (`watch_video_stub.dart:106`) treats YouTube and Rumble as `embedOnly`: there is NO inline player, only a text placeholder. Sync still propagates. Moving to the stage does not change that, and the copy must not pretend otherwise. Inline native YouTube needs a webview dependency that is deliberately avoided today and is out of scope here.

- [ ] **Step 1: Write the failing test**

```dart
  test("native YouTube reports embed-only so the UI can say so", () {
    final c = WatchVideoController();
    c.load("https://youtu.be/abc");
    expect(c.isEmbedOnly, isTrue);
    c.load("https://example.com/clip.mp4");
    expect(c.isEmbedOnly, isFalse);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/spaces/watch_surface_test.dart`
Expected: FAIL, `isEmbedOnly` undefined.

- [ ] **Step 3: Write minimal implementation**

Add `bool get isEmbedOnly => _mode == _WatchMode.embedOnly;` (native) and `bool get isEmbedOnly => false;` (web, which plays both inline). Update the placeholder copy to say plainly that this device keeps play, pause and seek in sync and that inline YouTube playback is on the web client. Write `docs/watch-together.md` covering the wire format including the new `heartbeat` action, the dead-band rationale, why positions are compared directly rather than extrapolated from wall clocks, why the video is not restreamed, and the native limitation.

- [ ] **Step 4: Run the FULL suite and analyzer**

Run: `flutter test`
Expected: all pass, no regression in the existing 1254.

Run: `flutter analyze lib/`
Expected: no new issues in changed files.

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/watch_video_stub.dart docs/watch-together.md test/features/spaces/watch_surface_test.dart
git commit -m "docs(spaces): document watch-together sync and native limits"
```

---

### Task 7: Two-browser sync verification over CDP

Prove the room actually stays together, with numbers, instead of asserting it does.

**Files:**
- Create: `scripts/verify-watch-sync.py`

Two real browsers are available: **.41** Brave on `127.0.0.1:9222` (reachable as `cbrd21@100.86.156.5`) and **.158** Chrome on `127.0.0.1:9223` and `:9229`.

- [ ] **Step 1: Write the verification script**

`scripts/verify-watch-sync.py` drives both browsers over CDP:

1. Point both at `https://noroc2027.tail204f0c.ts.net/app/#/spaces` and join the same Space.
2. On browser A, load a YouTube URL through the panel and press Play.
3. Every 2 seconds for 60 seconds, read each browser's real player position by evaluating a `listening` handshake plus an `infoDelivery` capture in the page (the same technique used to diagnose this, see `docs/watch-together.md`).
4. Report max drift, mean drift, and the number of samples outside the 2 second dead band.

Reuse the dependency-free CDP websocket client already proven in this work (`/tmp/cdp_eval.py` on .41); vendor it into the script rather than depending on a file in /tmp.

- [ ] **Step 2: Run it**

Run: `python3 scripts/verify-watch-sync.py`
Expected: max drift under ~2.5 seconds, mean well under 2, and no unbounded growth over the minute. Unbounded growth means the heartbeat is not being applied.

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-watch-sync.py
git commit -m "test(spaces): two-browser CDP watch-sync verification"
```

---

## Manual verification (Chef, after Task 7)

1. Space in a browser, Watch Together, paste a YouTube URL, Load. Video appears on the MAIN STAGE, panel says it is playing above.
2. Second device joins: it lands on the same video AND near the same timestamp, not at 0.
3. Seek on the host: everyone else follows within a couple of seconds.
4. Close the panel on the host: playback and sync continue (this is what room-scoped session state buys).
5. Talk over the movie: mic is a separate track. Host mute-all still silences people without touching the video.
6. Someone goes live on camera: that takes the stage, the movie keeps playing underneath (this is what the Offstage mount buys, an unmounted iframe would restart), and when they stop the movie comes back at the right place.
7. Host of the video leaves: heartbeats stop, everyone keeps playing from where they are. Known limit, no failover in this pass.
