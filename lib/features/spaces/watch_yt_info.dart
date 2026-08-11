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
    rate: rate is num ? rate.toDouble() : 1.0,
  );
}
