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
{"lane": "watch", "action": "stop",                     "from": "<identity>"}
{"lane": "watch", "action": "rate",      "rate": 1.5,   "from": "<identity>"}
```

`load`/`play`/`pause`/`seek` are the original, wire-compatible mapping
(`applyWatchEvent` in `lib/features/spaces/watch_sync.dart`): an older client
that has never heard of `heartbeat`, `stop` or `rate` still understands all
four. `heartbeat`, `stop` and `rate` are purely additive on top of that, all
three handled separately in `WatchSession.applyRemote`
(`lib/features/spaces/watch_session.dart`) before any of them ever reaches
`applyWatchEvent`: an older client's copy of `applyWatchEvent` has no `case`
for them, so its `default:` branch silently ignores them.

### Playback speed is shared, not personal: `rate`

Chef chose "sync the speed to everyone" over letting each viewer run their
own: there is one speed for the room, and everyone's player is expected to
actually run at it, not just agree on paper. The panel
(`lib/features/spaces/watch_panel.dart`) offers 1x/1.25x/1.5x/1.75x/2x,
gated on the session being active same as the transport controls.

`WatchSession.setRate` sets the local controller's rate, updates
`WatchSessionState.rate`, and publishes on the PERSISTED path, same as
`load`/`play`/`pause`/`seek`, NOT the ephemeral path `heartbeat` uses. This
is deliberate, the same reasoning `stop` uses: a late joiner's `catchUp`
must replay the room's current speed, or they would default to 1x until the
next live `rate` event happened to fire. A REMOTE `rate` event is applied
the mirror-image way in `applyRemote`: the controller and local state update
WITHOUT re-publishing, or every client that ever received one would echo it
right back onto the lane.

Speed used to be neither synced nor persisted, and that broke sync in two
places at once, both now fixed:

- `resolveDrift` (`watch_drift.dart`) used to bail out (`DriftAction.none`)
  the instant a viewer's local rate was anything but 1.0, on the theory that
  an unsynced rate was unknowable and therefore not safe to correct against.
  That theory made a viewer at 1.5x stop being drift-corrected entirely, at
  ANY speed, the moment their rate diverged from a hardcoded 1.0. Now that
  rate is shared state, `resolveDrift` takes a `sessionRate` parameter and
  compares the local player's ACTUAL rate against it: a match, even at 1.5x
  or 2x, corrects normally like any other drift. Only a genuine mismatch
  (the local rate disagrees with what the room agreed on, e.g. a viewer who
  changed it directly in the YouTube embed's own speed menu, which the embed
  allows and this app cannot prevent) still suppresses correction for that
  tick, letting the next `rate` lane event resettle it instead of fighting
  the viewer's own action.
- `WatchSession.onHeartbeatTick` used to skip publishing ENTIRELY whenever
  the host's own snapshot reported a non-1.0 rate, on the same theory. That
  made a host running at 1.5x go silent: no heartbeats meant the whole room
  had nothing to correct against and drifted apart with no error, no crash,
  nothing visibly wrong until someone noticed the picture was out of step.
  `onHeartbeatTick` now publishes at any rate; the host's own rate is exactly
  as knowable and exactly as worth reporting as its position always was.

### Ending a session: `stop`

Any participant can end the watch session for the whole room with the
"Stop watching" control in the watch panel (`lib/features/spaces/
watch_panel.dart`), shown only while a session is active. It calls
`WatchSession.stopWatching`, which clears the session's `url` (so
`WatchSessionState.isActive` goes false and `resolveStageKind` falls back
to `StageKind.none`), clears `isHostOfVideo`, pauses local playback, and
publishes `{"action": "stop"}` on the PERSISTED path, the same path `load`/
`play`/`pause`/`seek` use, not the ephemeral one `heartbeat` uses. This is
deliberate: a late joiner's `catchUp` must replay the stop, or a stale
persisted `load` from before the session ended would re-establish it for
every future joiner. A REMOTE `stop` is applied the mirror-image way in
`applyRemote`: local state clears and playback pauses WITHOUT
re-publishing, or every client that ever received a stop would echo it
right back onto the lane.

Without this control, nothing in the system ever clears `url` once it is
set: the 16:9 surface would own the main stage for every participant for
the life of the room, with no way to reclaim it. The old, pre-refactor
watch panel was at least dismissible; `stop` is the real equivalent for the
persistent, shared-session design.

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
room, UNLESS someone else loads a video within the same round trip (see the
simultaneous-load case below, which this is not true for):

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
- **If two people load a video within the same round trip, NOBODY ends up
  the authority.** Each load's `applyRemote` sets `isHostOfVideo: e["from"]
  == arg.identity` on the OTHER client, so A's load clears B's flag and B's
  load clears A's, and neither replay restores it because neither `from`
  matches the local identity. Heartbeats then stop entirely (nobody
  publishes them) until someone loads again, same visible symptom as the
  host-leaves case above but reached a different way. This is a known
  limitation, not a bug to chase down with a leader election: fixing it
  properly needs conflict resolution (e.g. last-load-wins by a shared
  ordering) that is out of scope here.

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

## Web platform-view registration never releases

`_WatchVideoState.initState` (`watch_video_web.dart`) registers one platform
view factory per controller instance, keyed on
`"watch-video-${identityHashCode(widget.controller)}"`. A fresh
`WatchVideoController` is created every time a Space is joined (the
`watchControllerFactoryProvider` default in `watch_session.dart`), so every
join registers another view factory. Flutter web exposes no API to
unregister a platform view factory once registered, so these accumulate for
the life of the page (a long-running tab that joins and leaves many Spaces
across a session). This is an inherent limit of `ui_web.platformViewRegistry`
as of this writing, not a bug in this feature: it is recorded here plainly
rather than left to be discovered. `WatchVideoController.dispose` (see
above) still tears down what it CAN: the message listener, the iframe load
listener, the paused video element, and the blanked iframe src, so a left
Space stops decoding and stops listening even though its now-orphaned view
factory closure stays registered.

## Stage precedence

Watch Together shares the Space's main stage with live video (screen share
or camera). `resolveStageKind` (`lib/features/spaces/stage_content.dart`)
picks `StageKind.liveVideo` whenever any live video track exists, falling
back to `StageKind.watch` only when there is none: a live screen share or
camera always outranks the watch session for the stage's top slot.

Losing the stage TO LIVE VIDEO does not stop the movie. In
`space_room_screen.dart`, the watch surface (`_WatchTogetherStage`) stays
mounted underneath an `Offstage` widget whenever `watchActive` is true,
even while live video is on top of it. Tearing the surface down and
rebuilding it on a later demote would mean a fresh `WatchVideoController`,
a fresh mount, and for a YouTube iframe specifically, a full reload from
position zero. Keeping it alive but invisible means the movie is exactly
where it should be the moment live video ends and the watch surface
reclaims the stage.

That resilience is scoped to the stage-precedence swap above, not to the
connection underneath it. `_Stage` (which `_WatchTogetherStage` lives
inside) is only built while `st.isConnected` is true
(`space_room_screen.dart`'s `st.isConnected ? Stack(...) : _buildConnecting()`
branch). A connection flap while the watch panel is closed unmounts `_Stage`
entirely, not just offstages it, which leaves `WatchSession`
(`AutoDisposeFamilyNotifier`, nothing else watching it) with no more
watchers and lets it autoDispose. Reconnecting rebuilds `_Stage` from
scratch: a fresh `WatchVideoController`, a fresh mount, and for a YouTube
iframe a full reload from position zero, exactly the case the paragraph
above says is avoided, except here the connection itself was the thing
torn down, not the stage precedence. The host flag is lost too, until
`catchUp` replays the persisted `load` event and, if this client is still
the host, restores it. So the accurate claim is narrower than "the movie
never restarts": a live-video stage swap never restarts it, a connection
flap can.

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
