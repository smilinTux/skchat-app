# Watch Together

Synced playback of a shared video (YouTube, Rumble, or a direct media file)
across everyone in a Space. This document is the record of how the sync
actually works, and of one false assumption that used to break it entirely.

## The wire format

Watch Together rides its own "watch" lane on top of the room's existing
data-channel + server-mirrored lane substrate (`lib/services/lane_service.dart`).
Every event is a JSON map:

```json
{"lane": "watch", "action": "load",      "url": "...",  "from": "<identity>"}
{"lane": "watch", "action": "play",      "t": 12.3,     "from": "<identity>"}
{"lane": "watch", "action": "pause",     "t": 12.3,     "from": "<identity>"}
{"lane": "watch", "action": "seek",      "t": 42.0,     "from": "<identity>"}
{"lane": "watch", "action": "heartbeat", "t": 88.4,     "from": "<identity>", "playing": true}
```

`load`/`play`/`pause`/`seek` are the original, wire-compatible mapping
(`applyWatchEvent` in `lib/features/spaces/watch_sync.dart`): an older client
that has never heard of `heartbeat` still understands all four. `heartbeat`
is purely additive on top of that, handled separately in
`WatchSession.applyRemote` (`lib/features/spaces/watch_session.dart`) before
it ever reaches `applyWatchEvent`.

### Heartbeats are ephemeral, and that is deliberate

`load`/`play`/`pause`/`seek` go through `LaneService.publish`, which does two
things: sends live over the LiveKit data channel, and mirrors the event to a
server-side lane store. `LaneService.catchUp` replays that whole stored list
to a client joining late, so the room's history is exactly what a late
joiner needs to reconstruct: what is loaded, and its last known play state.

`heartbeat` never goes through that path. `WatchSession.onHeartbeatTick`
calls `LaneService.publishEphemeral` instead, which sends live over the data
channel and stops there, with no server mirror and nothing added to the
catch-up list. The reason is arithmetic, not taste: a heartbeat fires every 3
seconds. A two hour movie is 7200 seconds, so a persisted heartbeat would
write roughly 2400 events into the lane store for that one movie alone. Every
late joiner's `catchUp` would then replay all 2400 of them through drift
correction in a tight loop, a seek storm that lands on whatever position the
LAST persisted heartbeat happened to hold, which is already stale by the time
it replays. A late joiner instead gets aligned by the load/play/pause/seek
history (real state, correctly ordered) and then by the next LIVE heartbeat,
which arrives within 3 seconds regardless.

## The 2 second dead band

Drift correction lives in `lib/features/spaces/watch_drift.dart`
(`resolveDrift`), decoupled from any Flutter or platform dependency so it can
be unit tested exhaustively. It only acts once `|local.position - hostPosition|`
exceeds `deadBandSeconds`, which defaults to 2.0.

The dead band exists because constant micro-correction is worse than being
slightly off. Every correction is a seek, and every seek visibly stutters the
picture: the frame freezes, the buffer sometimes has to refill, and the
viewer notices a hitch even when the actual offset is imperceptible. Two
seconds is small enough that nobody in the room notices they have drifted,
and large enough that ordinary jitter (a heartbeat landing a few hundred
milliseconds late, a frame of buffering) never crosses it and triggers a
needless correction. A player that is currently buffering is left alone
entirely (`local.buffering` short-circuits to `DriftAction.none`), because
correcting a buffering player restarts its buffer, so it never catches up and
never stops being corrected.

## Positions are compared directly, not extrapolated from timestamps

`resolveDrift` compares `local.position` to `hostPosition` as two plain
numbers. It does not read a wall-clock timestamp off either event and
extrapolate "where the video should be now" from elapsed time. Two things
make that the right call:

- The two machines' clocks cannot be trusted to agree. NTP drift, sleep/wake
  skew, and plain clock-setting mean a timestamp-based extrapolation has to
  either trust an unreliable clock or spend effort reconciling clock skew
  between peers, effort a live position value does not need.
- Tailnet transport delay is an order of magnitude below the 2 second dead
  band. A heartbeat's `t` value is already close enough to "now" by the time
  it is read that extrapolating for network delay would be correcting for an
  error smaller than the dead band itself, which is to say, correcting for
  nothing.

Direct comparison is simpler to reason about, has no clock-skew failure mode
to debug, and is already accurate enough for the dead band it feeds.

## Why the video is not restreamed through LiveKit

The video plays locally on every device, driven into sync by the lane
events above. It is never captured and republished as a LiveKit media track
the way a screen share is. Three things follow from that:

- **Source quality for everyone.** Every viewer decodes the original
  YouTube/Rumble/file stream at whatever quality their own connection
  supports, instead of everyone being capped at whatever quality the
  restreaming step could re-encode and everyone else could receive.
- **No host upload bandwidth.** Restreaming would mean one participant's
  device decodes the video AND re-encodes AND uploads it to every other
  participant, the same bandwidth and CPU bill a screen share pays. Playing
  the same source URL locally on every device costs the "host" nothing beyond
  publishing small JSON events.
- **It scales.** A restreamed watch party is bounded by one person's upload
  bandwidth no matter how many people join. A locally-played, lane-synced
  watch party is bounded by nothing but each viewer's own connection to
  YouTube/Rumble/the file host, so it scales the same whether the room has 3
  people or 30.

This is the same architecture Teleparty, Disney GroupWatch and Amazon Watch
Party all use: sync signaling over a thin channel, real playback local to
each viewer.

## Host authority

Whoever loads a video becomes its authority for as long as they stay in the
room:

- `WatchSession.loadUrl` sets `isHostOfVideo = true` on the client that
  called it, and only that client's `onHeartbeatTick` publishes heartbeats
  (`if (!state.isHostOfVideo) return;`). Every other client only ever
  corrects toward what it hears; two simultaneous authorities would each
  correct toward the other and the room would oscillate forever.
- A REMOTE `load` event clears the flag on every other client
  (`isHostOfVideo: e["from"] == arg.identity` in `applyRemote`): once someone
  else loads a new video, you are no longer the authority for whatever you
  had loaded.
- A catch-up `load` replay whose `from` equals your own identity restores the
  flag. `catchUp` replays your own past events same as anyone else's, and
  LiveKit never loops a LIVE data-channel send back to its own sender, so a
  live `load` event's `from` can never equal your own identity; only the
  replay path can. That one `from == arg.identity` check is what makes both
  the clear and the restore fall out of the same line instead of needing a
  separate catch-up-vs-live branch.
- **If the video's host leaves the room, heartbeats simply stop.** There is
  no failover to a new authority. This is a known limitation, stated here
  plainly rather than left to be discovered: the room keeps playing whatever
  position it was last corrected to, un-synced, until someone starts a fresh
  load.

## Native embed-only limitation

On native (mobile/desktop), YouTube and Rumble have no inline player at all.
`lib/features/spaces/watch_video_stub.dart` detects those sources and puts
the controller into `_WatchMode.embedOnly`, exposed as `isEmbedOnly` on the
controller. Direct media files still play for real, decoded locally via
`video_player` with full play/pause/seek. Sync still propagates for
embed-only sources (the lane events above do not care whether a native peer
can render a picture), but there is no picture to show: only a text
placeholder that plainly says the device keeps play, pause and seek in sync,
and that inline YouTube/Rumble playback is on the web client, with a
prompt to open the Space in a browser to see it.

Inline native YouTube playback would need a webview dependency this project
deliberately avoids, and adding one is out of scope here. `isEmbedOnly`
exists so the UI can say this outright instead of leaving a blank stage the
viewer has to puzzle out. The web controller exposes the same getter,
hardcoded to `false`, since web plays both YouTube and Rumble inline via
iframe and never hits this gap.

## Stage precedence

Watch Together shares the Space's main stage with live video (screen share
or camera). `resolveStageKind` (`lib/features/spaces/stage_content.dart`)
picks `StageKind.liveVideo` whenever any live video track exists, falling
back to `StageKind.watch` only when there is none: a live screen share or
camera always outranks the watch session for the stage's top slot.

Losing the stage does not stop the movie. In `space_room_screen.dart`, the
watch surface (`_WatchTogetherStage`) stays mounted underneath an `Offstage`
widget whenever `watchActive` is true, even while live video is on top of
it. Tearing the surface down and rebuilding it on a later demote would mean
a fresh `WatchVideoController`, a fresh mount, and for a YouTube iframe
specifically, a full reload from position zero. Keeping it alive but
invisible means the movie is exactly where it should be the moment live
video ends and the watch surface reclaims the stage.

## The false assumption that broke sync

`lib/features/spaces/watch_yt_info.dart` (`parseYouTubeInfo`) parses
`infoDelivery` frames from the YouTube IFrame API: after a client posts
`{"event":"listening"}` to the iframe, the API responds with frames carrying
`playerState`, `currentTime`, `duration` and `playbackRate`, verified live
over CDP.

An earlier version of this code never sent that handshake, on the wrong
assumption that a cross-origin iframe's player time was simply unreadable.
Instead it tracked a "shadow" position it set locally on every seek and never
otherwise advanced, so the reported position stood still while the actual
video kept playing. Position never matched, drift correction never
converged, and Watch Together never actually stayed in sync. It is worth
recording plainly: the fix was not a smarter drift algorithm, it was reading
real player state that was there to be read all along. Do not reintroduce
the shadow-only assumption for YouTube once the listening handshake has run.
