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
    this.rate = 1.0,
  });

  final double position;
  final bool playing;
  final bool buffering;

  /// The player's actual local playback rate. Speed is shared room state
  /// (see [resolveDrift]'s `sessionRate`), so this is compared against what
  /// the room agreed on, not against a hardcoded 1.0: a mismatch means the
  /// local player is racing ahead or behind for a reason the room's "rate"
  /// lane event did not cause, e.g. the viewer changed it directly in the
  /// YouTube embed's own speed menu, which the embed allows and this app
  /// cannot prevent.
  final double rate;
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
///
/// [sessionRate] is the room's agreed playback speed (see the "rate" lane
/// action, `WatchSession.setRate`). Speed used to be unsynced and
/// unknowable, so a non-1.0 local rate was always suspicious and correction
/// was suppressed outright. Now that rate is shared state, a local rate that
/// MATCHES [sessionRate] is the ordinary case, even at 1.5x or 2x, and must
/// be corrected exactly like 1x. Only a genuine mismatch (the local rate
/// disagrees with what the room agreed on) still suppresses correction: see
/// the check below.
DriftAction resolveDrift({
  required PlaybackSnapshot local,
  required double hostPosition,
  required bool hostPlaying,
  double deadBandSeconds = 2.0,
  double sessionRate = 1.0,
}) {
  // Correcting a buffering player restarts its buffer, so it never catches up
  // and never stops being corrected. Leave it alone until it settles.
  if (local.buffering) return DriftAction.none;

  // A local rate that disagrees with the room's agreed rate means the viewer
  // changed it themselves outside the synced control (e.g. the YouTube
  // embed's own speed menu, which this app cannot prevent), not that they
  // drifted out of sync. Seek-yanking that viewer back every heartbeat fights
  // the choice they just made instead of helping, the same reasoning that
  // leaves a buffering player alone above. The next "rate" lane event
  // resettles this rather than fighting it tick by tick.
  if ((local.rate - sessionRate).abs() > 0.01) return DriftAction.none;

  final drift = (local.position - hostPosition).abs();
  if (drift > deadBandSeconds) {
    return hostPlaying ? DriftAction.seekAndPlay : DriftAction.seekAndPause;
  }
  if (local.playing != hostPlaying) {
    return hostPlaying ? DriftAction.playOnly : DriftAction.pauseOnly;
  }
  return DriftAction.none;
}
