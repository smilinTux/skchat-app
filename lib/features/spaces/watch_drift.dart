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
