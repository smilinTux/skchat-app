/// Pure hysteresis policy deciding which call participants earn the
/// promoted (big-tile) slots, ported from Nextcloud Talk's
/// `useActiveSpeakers`, the best-reasoned implementation of this problem in
/// any comparable product.
///
/// WHY HYSTERESIS AT ALL: stable Nextcloud Talk has none. It moves the big
/// tile the instant anyone speaks, so a one-word interjection ("mhm",
/// "yeah") reorders the whole view for everyone on the call. That flicker is
/// the failure this module exists to prevent: the delays below are not an
/// implementation detail bolted on afterward, they are the feature.
///
/// This file is deliberately Flutter-free (no `flutter`, no `dart:ui`) so it
/// runs on the bare Dart VM and can be exercised with a scripted timeline
/// instead of a widget test. Time is never read internally
/// (no `DateTime.now()`): the caller passes "now" into [update], which is
/// what makes a deterministic, replayable test timeline possible at all.
library;

/// One call participant's speaking state as of the instant [update] is
/// called. This mirrors the LiveKit "who is speaking right now" signal, not
/// a promotion decision: promotion/demotion state lives inside
/// [ActiveSpeakerPolicy], not here.
class SpeakerState {
  const SpeakerState({required this.identity, required this.isSpeaking});

  final String identity;
  final bool isSpeaking;
}

/// Tracks per-participant speaking history and decides, tick by tick, who
/// occupies the promoted slots.
///
/// Call [update] once per participants emission with the full current
/// roster (everyone still on the call, speaking or not) and the current
/// time. A participant simply absent from that roster is treated as having
/// left the call, see [update].
class ActiveSpeakerPolicy {
  ActiveSpeakerPolicy({
    this.promoteAfter = const Duration(seconds: 3),
    this.demoteAfter = const Duration(seconds: 30),
    this.maxPromoted = 3,
  });

  /// How long a participant must speak with zero gaps before they earn a
  /// slot. Short: interjections must never disturb the view, so this has to
  /// be long enough that "yeah" or a cough cannot cross it, but short enough
  /// that someone who has actually started talking is not left off-camera
  /// for an awkward stretch.
  final Duration promoteAfter;

  /// How long a promoted participant must be silent before they lose their
  /// slot. Long, and deliberately so: someone who is mostly listening for a
  /// while (a pause to think, someone else being asked a question) should
  /// not be yanked out just because a handful of quiet seconds elapsed.
  /// They make room again on their own, without a hard cutoff. LiveKit
  /// speaking-state updates can also be lossy over an interruption in the
  /// data channel, so a short timer would misfire on transport noise, not
  /// just on genuine silence.
  final Duration demoteAfter;

  /// How many big-tile slots exist at once. Beyond this, promoting someone
  /// new means evicting someone already promoted (see [update]).
  final int maxPromoted;

  // When the participant's CURRENT uninterrupted speaking run started.
  // Cleared the instant they stop speaking, so a fresh run always starts
  // counting from zero: this is what makes the promotion rule "3 seconds
  // UNINTERRUPTED" rather than "3 seconds total."
  final Map<String, DateTime> _speakingSince = {};

  // The most recent instant this participant was observed speaking, updated
  // every tick they are speaking (including while already promoted). This
  // is both the demotion clock (silence = time since this) and the eviction
  // ranking (see below): someone speaking THIS tick has this set to `now`,
  // which is why they are effectively unevictable except against other
  // participants also speaking this exact tick.
  final Map<String, DateTime> _lastSpoke = {};

  // Promoted identities, oldest promotion first. List order is also the
  // eviction tie-break (see _pickEvictionVictim) and the order returned to
  // the caller, so tiles do not reflow in the UI just because someone in an
  // already-promoted slot happens to speak again.
  final List<String> _promoted = [];

  /// Currently promoted identities, oldest promotion first. A defensive
  /// copy: callers can hold onto this without it changing under them.
  List<String> get promoted => List.unmodifiable(_promoted);

  /// Advance the policy to [now] given the full current roster in
  /// [participants], and return the resulting promoted set.
  ///
  /// A participant who is simply not present in [participants] this tick is
  /// treated as having left the call. If they were promoted, their slot is
  /// freed immediately, skipping the silence timer entirely: LiveKit does
  /// not guarantee a "stopped speaking" event fires on disconnect, so
  /// waiting out [demoteAfter] on a departed participant would strand a
  /// tile on someone no longer in the room.
  List<String> update(List<SpeakerState> participants, DateTime now) {
    final presentIds = participants.map((p) => p.identity).toSet();

    // Departure: drop tracking state and free the slot immediately, ahead
    // of every other rule below. A departed identity must not linger in
    // _lastSpoke either, otherwise a rejoin would inherit a stale "recently
    // spoke" timestamp it never earned in the new session.
    _promoted.removeWhere((id) => !presentIds.contains(id));
    _speakingSince.removeWhere((id, _) => !presentIds.contains(id));
    _lastSpoke.removeWhere((id, _) => !presentIds.contains(id));

    // Update speaking bookkeeping for everyone still present, promoted or
    // not: an already-promoted participant still needs _lastSpoke kept
    // fresh while they talk, or they would look "least recently spoken" and
    // get evicted out from under themselves mid-sentence.
    for (final p in participants) {
      if (p.isSpeaking) {
        _speakingSince.putIfAbsent(p.identity, () => now);
        _lastSpoke[p.identity] = now;
      } else {
        // Any gap resets the uninterrupted-run clock. The next time they
        // speak, promotion eligibility starts counting from zero again.
        _speakingSince.remove(p.identity);
      }
    }

    // Promotion: not-yet-promoted participants who have been speaking,
    // without a gap, for at least promoteAfter. Order candidates by when
    // their run started so that if several cross the line on the same
    // tick, whoever has been talking longest is considered first.
    final candidates = participants
        .where((p) => p.isSpeaking && !_promoted.contains(p.identity))
        .where((p) {
          final since = _speakingSince[p.identity];
          return since != null && !now.difference(since).isNegative &&
              now.difference(since) >= promoteAfter;
        })
        .toList()
      ..sort((a, b) => _speakingSince[a.identity]!
          .compareTo(_speakingSince[b.identity]!));

    for (final candidate in candidates) {
      if (_promoted.length < maxPromoted) {
        _promoted.add(candidate.identity);
        continue;
      }
      final victim = _pickEvictionVictim();
      if (victim != null) {
        _promoted.remove(victim);
        _promoted.add(candidate.identity);
      }
    }

    // Demotion: promoted participants silent for at least demoteAfter,
    // measured from the last instant they were seen speaking.
    _promoted.removeWhere((id) {
      final lastSpoke = _lastSpoke[id];
      if (lastSpoke == null) return true; // defensive: should not happen
      return now.difference(lastSpoke) >= demoteAfter;
    });

    return List.unmodifiable(_promoted);
  }

  /// Find who to evict to make room for a new promotion: the promoted
  /// participant with the OLDEST _lastSpoke, i.e. the least recently spoken,
  /// never the one who has simply been promoted the longest.
  ///
  /// Someone speaking THIS tick has _lastSpoke == now, the maximum possible
  /// value, so they can only ever be the minimum (and thus the victim) in a
  /// tie against every other promoted participant also speaking this exact
  /// tick. That tie is broken in favor of evicting whoever was promoted
  /// first (earliest in _promoted, scanned first below): the one case where
  /// a genuinely mid-sentence speaker loses their slot, and it only happens
  /// when every promoted slot is talking at once and the set is still full.
  String? _pickEvictionVictim() {
    String? victim;
    DateTime? victimLastSpoke;
    for (final id in _promoted) {
      final lastSpoke = _lastSpoke[id];
      if (lastSpoke == null) return id; // defensive: should not happen
      if (victimLastSpoke == null || lastSpoke.isBefore(victimLastSpoke)) {
        victim = id;
        victimLastSpoke = lastSpoke;
      }
    }
    return victim;
  }
}
