/// Pure stage-election policy: decides which single call participant
/// occupies the big video slot, and the order everyone else fills the
/// strip beneath it.
///
/// This replaces two rules that made this decision independently and could
/// disagree about the same room:
///   - Spaces (`space_room_screen.dart`'s `_WatchStage`) took `videos.first`
///     off a screens-then-cameras concatenation, so a screen share always
///     won and nothing else, ever, mattered.
///   - Calls (`livekit_call_screen.dart`) took the first participant with
///     `isScreenSharing` true off `participants.indexWhere`, documented
///     there as "if several people share at once, the first sharer takes
///     the stage": the same idea, written twice, with no way to keep the
///     two in sync.
///
/// Neither rule considered who was actually talking, and neither knew about
/// a viewer's own choice or a moderator's. Wiring either call site to defer
/// to this module is a later card; this file only contains the decision
/// itself.
///
/// Like `active_speaker_policy.dart` and `grid_geometry.dart` in this same
/// directory, this file is deliberately Flutter-free (no `flutter`, no
/// `dart:ui`) so it runs on the bare Dart VM and is exercised with plain
/// unit tests.
library;

/// One call participant as seen by the stage-election ladder.
class StageParticipant {
  const StageParticipant({
    required this.identity,
    this.isLocal = false,
    this.hasVideo = false,
    this.isScreenSharing = false,
  });

  /// LiveKit participant identity. Unique within a room; [electStage] uses
  /// it as the sole key for pins, the active-speaker list, and the
  /// remainder.
  final String identity;

  /// True for the local participant (the viewer running this app), false
  /// for every remote participant. Only affects rung 5, "last remote with
  /// video": the local feed is never a candidate there, see [electStage].
  final bool isLocal;

  /// True if this participant currently has a camera track published.
  final bool hasVideo;

  /// True if this participant currently has a screen-share track
  /// published.
  final bool isScreenSharing;
}

/// Which of the elected participant's feeds the big slot should show.
enum StageFeedKind {
  /// The participant's camera.
  camera,

  /// The participant's screen share. Always preferred over that same
  /// participant's camera once they are elected, whichever rung elected
  /// them: see [electStage].
  screenShare,
}

/// The result of running the ladder: who is big, which of their feeds to
/// show, and everyone else, in strip order.
class StageSelection {
  const StageSelection({
    required this.identity,
    required this.kind,
    required this.remainder,
  });

  /// Identity of the participant in the big slot. Null only when the
  /// `participants` list passed to [electStage] was itself empty, meaning
  /// there is no one to feature. A joined call always includes at least
  /// the local participant, so this should not happen in practice.
  final String? identity;

  /// Which of [identity]'s feeds is shown. Meaningless when [identity] is
  /// null.
  final StageFeedKind kind;

  /// Every other participant, in the same relative order they were passed
  /// to [electStage], for the strip beneath the stage.
  final List<String> remainder;
}

/// Decide who occupies the big video slot, and the strip order for
/// everyone else.
///
/// Ladder, evaluated top to bottom, first match wins:
///   1. [localPin] — a viewer's own explicit choice. Highest: never yank
///      someone off a tile a viewer chose for themselves.
///   2. [broadcastPin] — a moderator's choice for everyone. Beats every
///      heuristic below, but never a viewer's own pin, and is skipped
///      outright in a 2-participant room (see below).
///   3. Active screen share — whichever participant is currently sharing;
///      if more than one is, the first in [participants] order wins. This
///      is the old Calls rule, alive but demoted from "the whole decision"
///      to "one rung of it".
///   4. Dominant speaker — the first identity in [activeSpeakers] (the
///      hysteresis-promoted set from `active_speaker_policy.dart`,
///      `ActiveSpeakerPolicy.promoted`) that is still present in
///      [participants].
///   5. Last remote participant with video — the most recently added
///      remote video feed, local excluded, so a room that has settled with
///      nobody speaking or sharing still shows a face rather than freezing
///      forever on whoever happened to join first.
///   6. First participant — Nextcloud Talk's own fallback chain ends here
///      on purpose: the stage must never be empty, even before anyone has
///      spoken or shared, and an arbitrary occupant is a smaller failure
///      than no occupant at all.
///
/// FAIL-SAFE: a pin naming an identity that is not in [participants]
/// resolves as if that pin were null, falling through to the next rung.
/// Without this, a pinned participant leaving the call would freeze the big
/// slot on a ghost forever, since nothing else would ever un-pin it.
///
/// Whichever rung wins, the elected participant's feed kind follows them:
/// if they are currently screen-sharing, their share is shown, never their
/// camera underneath it. The pin picks the PERSON; this picks which of
/// their feeds is on stage, which is what makes a locally or
/// broadcast-pinned screen-sharer show their share instead of their face.
///
/// [participants] should be empty only for a room the caller has not
/// populated yet (e.g. before the local participant has joined); in that
/// case [StageSelection.identity] is null and [StageSelection.remainder]
/// is empty. A real, joined call always includes at least the local
/// participant, so every rung below assumes at least one entry.
StageSelection electStage({
  required List<StageParticipant> participants,
  List<String> activeSpeakers = const [],
  String? localPin,
  String? broadcastPin,
}) {
  if (participants.isEmpty) {
    return const StageSelection(
      identity: null,
      kind: StageFeedKind.camera,
      remainder: [],
    );
  }

  final byIdentity = {for (final p in participants) p.identity: p};

  String? winner;

  // Rung 1: local pin. The fail-safe (winner stays null when the pinned
  // identity is absent) is what lets this fall through to rung 2 instead
  // of resolving to a ghost.
  if (localPin != null && byIdentity.containsKey(localPin)) {
    winner = localPin;
  }

  // Rung 2: broadcast pin. Skipped outright in a 2-participant room: with
  // two people, each viewer's big slot already shows the other by
  // construction, so a broadcast pin here could only be forcing the PEER's
  // own layout onto them, which is hostile rather than useful.
  if (winner == null &&
      broadcastPin != null &&
      participants.length != 2 &&
      byIdentity.containsKey(broadcastPin)) {
    winner = broadcastPin;
  }

  // Rung 3: active screen share, first sharer in participant order.
  if (winner == null) {
    for (final p in participants) {
      if (p.isScreenSharing) {
        winner = p.identity;
        break;
      }
    }
  }

  // Rung 4: dominant speaker, first still-present identity in
  // activeSpeakers order. Same fail-safe idea as the pins: a stale
  // identity in the caller's speaker list is skipped, not treated as a
  // match.
  if (winner == null) {
    for (final identity in activeSpeakers) {
      if (byIdentity.containsKey(identity)) {
        winner = identity;
        break;
      }
    }
  }

  // Rung 5: last remote participant with video.
  if (winner == null) {
    for (final p in participants.reversed) {
      if (!p.isLocal && p.hasVideo) {
        winner = p.identity;
        break;
      }
    }
  }

  // Rung 6: first participant. Never empty.
  winner ??= participants.first.identity;

  final elected = byIdentity[winner]!;
  final kind = elected.isScreenSharing
      ? StageFeedKind.screenShare
      : StageFeedKind.camera;
  final remainder = [
    for (final p in participants)
      if (p.identity != winner) p.identity,
  ];

  return StageSelection(identity: winner, kind: kind, remainder: remainder);
}
