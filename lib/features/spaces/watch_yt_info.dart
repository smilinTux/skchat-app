import "dart:convert";

import "watch_drift.dart";

/// YouTube IFrame API player states: unstarted=-1, ended=0, playing=1,
/// paused=2, buffering=3, cued=5. Only the two states this parser branches on
/// get named constants; the rest fall through as "not playing".
const int _kPlaying = 1;
const int _kBuffering = 3;

/// The snapshot to report immediately after commanding a seek to [target].
///
/// Player state is read from the last `infoDelivery` frame, and frames stop
/// (or go stale) for as long as the seek is rebuffering. Leaving the old frame
/// in place means the drift loop's next beat measures where the player WAS
/// before the correction, decides it is still out of sync, and corrects again
/// on the strength of a reading it invalidated itself. Reporting the target
/// makes a commanded seek visible right away.
///
/// Only the position moves. Play state, buffering and rate all carry forward:
/// a seek says nothing about them, and inventing `buffering: true` here would
/// be worse than useless, since [parseYouTubeInfo] carries buffering forward
/// across every frame that omits `playerState` and most of them do, so it
/// could stick on and suppress correction for good.
///
/// Returns null when there is no previous frame to amend: before the first
/// one lands the caller's own shadow position is already the best answer.
PlaybackSnapshot? snapshotAfterSeek(PlaybackSnapshot? previous, double target) {
  if (previous == null) return null;
  return PlaybackSnapshot(
    position: target,
    playing: previous.playing,
    buffering: previous.buffering,
    rate: previous.rate,
  );
}

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
