# Synced Playback Speed for Watch Together

## What was built

1. **Rate as shared room state.** A new `rate` action on the "watch" lane,
   additive on the wire (older clients ignore it via `applyWatchEvent`'s
   `default:` branch, exactly like `heartbeat`/`stop`):
   `{"lane":"watch","action":"rate","rate":1.5,"from":"<identity>"}`.
   `WatchSessionState` gained `rate` (default `1.0`). `WatchSession.setRate`
   sets the controller's rate, updates state, and publishes on the
   **persisted** path (like `load`/`play`/`pause`/`seek`, not
   `publishEphemeral`), so a late joiner's `catchUp` lands them at the
   room's current speed. A remote `rate` event is applied in `applyRemote`
   without republishing, same no-loop discipline as the other actions.

2. **Removed the two guards that made speed break sync**, per the task brief:
   - `WatchSession.onHeartbeatTick` no longer bails out when the snapshot's
     rate isn't 1.0. A host at 1.5x now keeps heartbeating.
   - `resolveDrift` (`watch_drift.dart`) no longer treats "any non-1.0 local
     rate" as a reason to stop correcting. See the design decision below.

3. **Wired `setRate` on both platforms**, added to the `WatchController`
   interface in `watch_sync.dart`:
   - Web YouTube iframe: `postMessage {"event":"command","func":"setPlaybackRate","args":[rate]}`
     to `https://www.youtube.com`, via the existing `_ytCommand` helper.
   - Web direct `<video>`: `videoEl.playbackRate = rate`.
   - Web Rumble: best-effort no-op, consistent with play/pause/seek there
     (no documented cross-origin command API).
   - Native `video_player` (direct file): `VideoPlayerController.setPlaybackSpeed(rate)`.
   - Native embed-only (YouTube/Rumble, no player exists): records a
     `_shadowRate` and does nothing else, consistent with how `play`/`pause`
     already treat that mode.
   - All four test fakes implementing `WatchController`
     (`watch_session_test.dart`, `watch_panel_test.dart`,
     `lane_sheet_dismiss_test.dart`) updated with `setRate`.

4. **UI**: a compact speed selector (1x/1.25x/1.5x/1.75x/2x) in
   `watch_panel.dart`, gated on `state.isActive` same as the transport
   controls. Current speed is highlighted (filled/bordered chip). Built as a
   small custom `_SpeedChip` (`GestureDetector` + `Container`) rather than
   `ChoiceChip`/`FilterChip`, since Material's chip widgets carry more
   padding/touch-target than five options need in a bottom-sheet row.

5. **Docs**: `docs/watch-together.md` wire-format table now lists `rate`,
   plus a new "Playback speed is shared, not personal: `rate`" section
   explaining the persisted-publish choice and, plainly, the two guards
   removed and why they were wrong once rate became shared state.

## The rate-mismatch design decision

`PlaybackSnapshot.rateIsNormal` (bool, "is this 1.0?") is gone, replaced by
`PlaybackSnapshot.rate` (double, the player's actual local rate).
`resolveDrift` gained a `sessionRate` parameter (default `1.0`, the room's
agreed speed) and compares `local.rate` against it directly:

```dart
if ((local.rate - sessionRate).abs() > 0.01) return DriftAction.none;
```

**Why this shape:** the old guard asked "is the local rate suspicious in the
abstract (i.e. not 1.0)?" That was the right question when speed was
unsynced and unknowable, but it's the wrong question once speed is shared
state: a room agreed on 1.5x has every viewer legitimately running at 1.5x,
and that must be corrected exactly like 1x, not suppressed. The right
question is relative: "does the local rate disagree with what the ROOM
agreed on?" A mismatch still means the same thing it always did (the viewer
changed it themselves outside the synced control, e.g. YouTube's own embed
speed menu, which the embed allows and this app cannot prevent), so it still
suppresses correction for that tick and lets the next `rate` lane event
resettle it, rather than fighting the choice the viewer just made. This
keeps the "don't seek-yank someone who changed speed on purpose" reasoning
completely intact while fixing the part that was actually broken (treating
the AGREED speed as itself suspicious).

`sessionRate` flows from `WatchSessionState.rate` at the one call site
(`WatchSession._applyHeartbeat`), so `resolveDrift` itself stays a pure,
Flutter-free function taking both numbers as plain parameters, same
testability posture the file already had.

I did not "fix" a pre-existing, unrelated inaccuracy I found while touching
this: the web controller's direct-`<video>`-mode `playbackSnapshot` fallback
always reports `playing: false` regardless of actual play state (only the
YouTube `infoDelivery` path ever sets a real `playing` value). That bug
predates this task, isn't part of the speed feature, and fixing it would
have been scope creep with its own test surface; flagging it here instead.

## Tests (TDD: failing first, then implemented)

All required cases from the task, run individually to confirm compile-time
failures before implementation, then green after:

- `test/features/spaces/watch_drift_test.dart`: rate-mismatch suppresses
  correction; drift correction still runs when local/session rate agree
  (including at 1.5x, both `seekAndPlay` and `playOnly` cases).
- `test/features/spaces/watch_info_delivery_test.dart`: YouTube
  `infoDelivery`'s `playbackRate` now feeds `PlaybackSnapshot.rate` directly
  (was: collapsed into a bool).
- `test/features/spaces/watch_session_test.dart`: `setRate` publishes
  `{"action":"rate","rate":1.5}` on the persisted path and updates
  `state.rate`; a remote `rate` event applies locally and publishes nothing;
  a host at 1.5x still publishes heartbeats (the regression guard for the
  removed trap); `catchUp` replay of load-then-rate leaves the session at
  the right speed for a late joiner.
- `test/features/spaces/watch_panel_test.dart`: the speed selector
  (`watchSpeedSelectorKey`) is absent with no active session and appears
  once one is loaded; tapping a speed option publishes `rate` on the
  persisted path and updates the shared session state.

### Commands and output

```
flutter test test/features/spaces/watch_drift_test.dart          # 7 passed
flutter test test/features/spaces/watch_info_delivery_test.dart  # 6 passed
flutter test test/features/spaces/watch_session_test.dart \
  test/features/spaces/watch_panel_test.dart \
  test/features/spaces/lane_sheet_dismiss_test.dart \
  test/features/spaces/watch_video_test.dart \
  test/features/spaces/watch_sync_test.dart \
  test/features/spaces/watch_stage_test.dart                     # 63 passed
flutter test test/features/spaces/                                # 199 passed
flutter test                                                      # 1321 passed, 1 skipped, 0 failed
```

Each new/changed test was first run against the pre-implementation code and
failed to compile for the expected reason (missing named parameter / missing
member: `rate`, `sessionRate`, `setRate`, `watchSpeedSelectorKey`), confirmed
before writing the corresponding implementation.

### Full suite

**1321 passed, 1 skipped, 0 failed.** (Baseline was 1309 passing / 1
skipped; the delta is the ~12 new tests added for this feature, no
regressions.)

`flutter analyze lib/` shows the same pre-existing 43 info-level issues the
codebase already had (checked before/after); the only hits inside a file
this task touched are two pre-existing `dart:html` deprecation infos in
`watch_video_web.dart` (the file's existing `dart:html` import, unrelated to
this change).

## Commits (on `main`, in order)

1. `ab7eaaa` refactor(watch): replace rateIsNormal bool with a shared
   session rate compare
2. `b2ff44a` feat(watch): sync playback speed as shared room state
3. `94348b6` feat(watch): speed selector in the Watch Together panel
4. `25f5722` docs(watch): document synced playback speed and the removed
   rate trap

(`5948bdb`, on top of these in `git log`, is Chef's concurrent
`space_room_screen.dart` fix from the parallel session mentioned in the
brief; not part of this work, not touched by it.)

## Concerns / follow-ups (not blockers)

- **Rate does not reset on `stop`/fresh `load`.** If a room watches one
  video at 1.5x, stops it, and loads a different video, the new video
  starts at whatever rate was last agreed, not 1x. This wasn't specified
  either way in the brief and no test covers it; flagging the choice in case
  Chef wants a reset-to-1x-on-load instead.
- **Rumble has no rate control at all** (same pre-existing gap as its
  play/pause/seek): `setRate` is a best-effort no-op there on web, and
  embed-only on native. This matches the existing Rumble posture throughout
  the file, not a new limitation introduced here.
- **The pre-existing `playing: false` inaccuracy** in the web controller's
  direct-`<video>`-mode `playbackSnapshot` fallback (noted above) is
  unrelated to this task and left alone.
