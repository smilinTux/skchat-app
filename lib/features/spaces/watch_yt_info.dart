import "dart:convert";

import "watch_drift.dart";

/// YouTube IFrame API player states: unstarted=-1, ended=0, playing=1,
/// paused=2, buffering=3, cued=5. Only the two states this parser branches on
/// get named constants; the rest fall through as "not playing".
const int _kPlaying = 1;
const int _kBuffering = 3;

/// Parse one `infoDelivery` frame from the YouTube IFrame API.
///
/// The app used to assume player time was unreadable cross-origin and faked a
/// "shadow" position that never advanced, which is why nothing ever stayed in
/// sync. Verified live over CDP: after a `{"event":"listening"}` handshake the
/// API pushes these frames carrying playerState, currentTime, duration and
/// playbackRate.
///
/// Returns null for frames that carry no usable playback state.
PlaybackSnapshot? parseYouTubeInfo(String raw, {PlaybackSnapshot? previous}) {
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
  // A frame must at least move the clock or the state on; one carrying
  // neither tells us nothing.
  if (time is! num && state is! num) return null;

  // playerState is NOT sent on every frame. Measured against the live app:
  // of 26 frames the API pushed while a video played, the great majority
  // carried currentTime with playerState absent. Requiring both discarded
  // those, so position never left its 0 fallback and every play, seek and
  // heartbeat published t=0. Carry the last known state forward instead of
  // dropping the frame or inventing a state.
  final prevPlaying = previous?.playing ?? false;
  final prevBuffering = previous?.buffering ?? false;
  final prevRate = previous?.rate ?? 1.0;
  final rate = info["playbackRate"];
  return PlaybackSnapshot(
    position: time is num ? time.toDouble() : (previous?.position ?? 0),
    playing: state is num ? state.toInt() == _kPlaying : prevPlaying,
    buffering: state is num ? state.toInt() == _kBuffering : prevBuffering,
    rate: rate is num ? rate.toDouble() : prevRate,
  );
}
