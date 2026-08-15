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

/// The dead band actually applied at [sessionRate], in VIDEO seconds.
///
/// The band is a budget for real-world lag: how long a seek takes to rebuffer,
/// how old the last player sample is, how long a heartbeat spends in transit.
/// Every one of those is measured in wall-clock seconds and none of them gets
/// cheaper when the room speeds up. A band fixed in video seconds silently
/// shrinks against them: 2.0s of video is 1.6s of wall clock at 1.25x and 1.0s
/// at 2x. Scaling by the rate holds the real tolerance still.
///
/// Below 1x the band is NOT narrowed. Widening at speed is the correction;
/// tightening at half speed would just be a new way to over-correct, and 2.0s
/// is the perceptual floor at any rate.
double effectiveDeadBand(double baseSeconds, double sessionRate) =>
    baseSeconds * (sessionRate > 1.0 ? sessionRate : 1.0);

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
  if (drift > effectiveDeadBand(deadBandSeconds, sessionRate)) {
    return hostPlaying ? DriftAction.seekAndPlay : DriftAction.seekAndPause;
  }
  if (local.playing != hostPlaying) {
    return hostPlaying ? DriftAction.playOnly : DriftAction.pauseOnly;
  }
  return DriftAction.none;
}

/// [resolveDrift] plus the memory needed to stop a correction from feeding
/// itself. One instance per watch session, driven by the 3s heartbeat.
///
/// [resolveDrift] is stateless, so it re-decides from scratch every tick and
/// cannot tell "this viewer drifted" from "this viewer is drifting BECAUSE of
/// what I did last tick". Correcting costs a seek, a seek on an iframe embed
/// costs a rebuffer, and the viewer's clock is frozen for the whole stall
/// while the host's keeps running at [sessionRate]. A stall of S wall seconds
/// therefore manufactures `S * rate` seconds of brand new drift. Once that
/// exceeds the dead band, every correction re-arms the next one and the
/// viewer stutters on the heartbeat period for the rest of the movie. Scaling
/// the band by rate (see [effectiveDeadBand]) removes the rate's part of this,
/// but a player slow enough to blow the whole budget at 1x still gets stuck.
///
/// So: skip the tick right after a correction (it would only measure the
/// correction's own stall), and if corrections keep failing to settle, space
/// them further and further apart. A viewer whose player simply cannot keep
/// up ends up quietly a few seconds behind, which nobody notices, instead of
/// stuttering every 3s, which everybody does.
///
/// The back-off is capped rather than unbounded on purpose: backing off to
/// "never" would strand a viewer in the wrong scene if a host scrub's own
/// `seek` lane event were ever dropped. The cap is the worst-case recovery
/// time, and it is the only thing keeping this from being a mute button.
class DriftCorrector {
  DriftCorrector({this.deadBandSeconds = 2.0});

  final double deadBandSeconds;

  /// Ticks to wait after the Nth consecutive failed correction: 1, 2, 4, then
  /// held at [maxCooldownTicks]. At the 3s heartbeat that settles to one
  /// correction per 24s, which also bounds how long a genuine desync can last.
  static const int maxCooldownTicks = 8;

  int _cooldownTicks = 1;
  int _skipTicks = 0;
  int _consecutive = 0;

  /// Current back-off length in heartbeats. Diagnostic / test surface.
  int get cooldownTicks => _cooldownTicks;

  /// Consecutive corrections that have not brought this client into the band.
  int get consecutiveCorrections => _consecutive;

  /// Forget everything learned about this client's drift.
  ///
  /// Call on any event that re-aligns it by construction: a `load`, or an
  /// explicit `seek` / `play` / `pause` the host published. After one of
  /// those, the back-off describes a situation that no longer exists, and
  /// carrying it forward would leave the viewer un-correctable for up to
  /// [maxCooldownTicks] heartbeats right when they most need correcting.
  void reset() {
    _cooldownTicks = 1;
    _skipTicks = 0;
    _consecutive = 0;
  }

  /// Decide what to do with this heartbeat. Arguments match [resolveDrift].
  DriftAction onHeartbeat({
    required PlaybackSnapshot local,
    required double hostPosition,
    required bool hostPlaying,
    double sessionRate = 1.0,
  }) {
    final action = resolveDrift(
      local: local,
      hostPosition: hostPosition,
      hostPlaying: hostPlaying,
      deadBandSeconds: deadBandSeconds,
      sessionRate: sessionRate,
    );

    final isSeek =
        action == DriftAction.seekAndPlay || action == DriftAction.seekAndPause;

    if (!isSeek) {
      // Only a genuinely settled tick forgives the back-off. `none` also
      // comes back for a buffering player and for a local rate that disagrees
      // with the room, and a seek is exactly what puts a player INTO
      // buffering: treating that as "settled" would reset the back-off on the
      // very stall it exists to damp, so the cool-down could never grow past
      // its first step.
      final band = effectiveDeadBand(deadBandSeconds, sessionRate);
      if (!local.buffering && (local.position - hostPosition).abs() <= band) {
        reset();
      }
      // play / pause corrections are returned unsuppressed: they cost no
      // rebuffer, and a viewer still rolling through a pause the host called
      // is the loudest desync there is.
      return action;
    }

    if (_skipTicks > 0) {
      _skipTicks--;
      return DriftAction.none;
    }

    _consecutive++;
    _skipTicks = _cooldownTicks;
    // Doubled here rather than computed as 1 << n: this runs on web, where an
    // int is 32-bit under `<<` and a long enough stuck session would wrap the
    // shift back around to a SHORTER cool-down than the one before it.
    final doubled = _cooldownTicks * 2;
    _cooldownTicks = doubled > maxCooldownTicks ? maxCooldownTicks : doubled;
    return action;
  }
}
