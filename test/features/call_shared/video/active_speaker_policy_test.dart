import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/call_shared/video/active_speaker_policy.dart";

/// One scripted timeline step: at [offset] from the simulation's start,
/// [identity]'s speaking state becomes [speaking], or, if [leave] is true,
/// [identity] drops out of the roster entirely (a departure, not merely
/// going quiet).
///
/// This is deliberately modeled on Nextcloud Talk's `speakerSimulation`:
/// the hysteresis this policy exists for (see active_speaker_policy.dart's
/// doc comment) can only be exercised by replaying a continuous timeline,
/// never by isolated one-shot calls, because every rule in it is about the
/// relationship between two points in time.
class TimelineEvent {
  const TimelineEvent(this.offset, this.identity,
      {this.speaking = false, this.leave = false});

  final Duration offset;
  final String identity;
  final bool speaking;
  final bool leave;
}

/// Replays [TimelineEvent]s through an [ActiveSpeakerPolicy], maintaining a
/// live roster of "who is on the call and are they currently speaking" so
/// each replayed event (or plain time advance via [tick]) can call
/// `policy.update` with the full roster the policy's contract requires.
class SpeakerSimulation {
  SpeakerSimulation(this.policy, {DateTime? start})
      : t0 = start ?? DateTime(2026, 1, 1);

  final ActiveSpeakerPolicy policy;
  final DateTime t0;
  final Map<String, bool> _roster = {};

  List<String> _run(Duration offset) {
    final now = t0.add(offset);
    final participants = _roster.entries
        .map((e) => SpeakerState(identity: e.key, isSpeaking: e.value))
        .toList();
    return policy.update(participants, now);
  }

  /// Apply [event] to the roster, then run the policy at that instant and
  /// return the resulting promoted set.
  List<String> apply(TimelineEvent event) {
    if (event.leave) {
      _roster.remove(event.identity);
    } else {
      _roster[event.identity] = event.speaking;
    }
    return _run(event.offset);
  }

  /// Advance to [offset] with no roster change, so a pure silence or
  /// promotion-timer checkpoint can be asserted without also editing who is
  /// speaking.
  List<String> tick(Duration offset) => _run(offset);
}

void main() {
  group("promotion", () {
    test("a sub-3s interjection never promotes", () {
      final policy = ActiveSpeakerPolicy();
      final sim = SpeakerSimulation(policy);

      expect(
          sim.apply(TimelineEvent(Duration.zero, "a", speaking: true)), []);
      expect(
          sim.apply(TimelineEvent(
              const Duration(seconds: 2), "a", speaking: false)),
          []);
      // Long silence afterward must not somehow retroactively promote them:
      // the run was interrupted, so it never reached 3 uninterrupted
      // seconds and never will unless they start speaking again from zero.
      expect(sim.tick(const Duration(seconds: 30)), []);
    });

    test("a speaker is promoted once they cross 3 uninterrupted seconds",
        () {
      final policy = ActiveSpeakerPolicy();
      final sim = SpeakerSimulation(policy);

      expect(
          sim.apply(TimelineEvent(Duration.zero, "a", speaking: true)), []);
      expect(sim.tick(const Duration(milliseconds: 2999)), []);
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);
    });
  });

  group("demotion", () {
    test("a promoted speaker is demoted only after 30s of silence", () {
      final policy = ActiveSpeakerPolicy();
      final sim = SpeakerSimulation(policy);

      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]); // promoted here

      sim.apply(
          TimelineEvent(const Duration(seconds: 3, milliseconds: 100), "a",
              speaking: false));

      // Last spoke at t=3s, so the demotion boundary is t=33s.
      expect(sim.tick(const Duration(seconds: 32, milliseconds: 900)), ["a"]);
      expect(sim.tick(const Duration(seconds: 33)), []);
    });

    test("intermittent speech under the 30s gap never demotes", () {
      final policy = ActiveSpeakerPolicy();
      final sim = SpeakerSimulation(policy);

      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);

      // Goes quiet, but speaks again well inside the 30s window each time,
      // so the silence clock keeps resetting and demotion never fires.
      sim.apply(
          TimelineEvent(const Duration(seconds: 20), "a", speaking: false));
      sim.apply(
          TimelineEvent(const Duration(seconds: 25), "a", speaking: true));
      expect(sim.tick(const Duration(seconds: 45)), ["a"]);
      expect(sim.tick(const Duration(seconds: 54, milliseconds: 900)), ["a"]);
    });
  });

  group("cap", () {
    test("the promoted set never exceeds the default cap of 3", () {
      final policy = ActiveSpeakerPolicy();
      final sim = SpeakerSimulation(policy);

      // Four speakers, staggered starts, each reaching 3s at a distinct
      // tick so promotion order is unambiguous. Events are applied in
      // non-decreasing offset order throughout, matching how a real
      // timeline of "now" only ever moves forward.
      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      sim.apply(
          TimelineEvent(const Duration(seconds: 1), "b", speaking: true));
      sim.apply(
          TimelineEvent(const Duration(seconds: 2), "c", speaking: true));

      expect(sim.tick(const Duration(seconds: 3)), ["a"]);
      expect(sim.tick(const Duration(seconds: 4)), ["a", "b"]);
      expect(sim.tick(const Duration(seconds: 5)), ["a", "b", "c"]);

      sim.apply(
          TimelineEvent(const Duration(seconds: 10), "d", speaking: true));
      final result = sim.tick(const Duration(seconds: 13));
      expect(result.length, 3);
      expect(result, contains("d"));
    });
  });

  group("eviction", () {
    test("eviction picks the least-recently-spoken, not the oldest-promoted",
        () {
      final policy = ActiveSpeakerPolicy(maxPromoted: 2);
      final sim = SpeakerSimulation(policy);

      // "a" is promoted first (oldest tenure) and keeps talking until t=10,
      // so its last-spoke instant (10s) is recent.
      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);

      // "b" is promoted second (newer tenure) but immediately goes quiet,
      // so its last-spoke instant (8s) is older than "a"'s.
      sim.apply(
          TimelineEvent(const Duration(seconds: 5), "b", speaking: true));
      expect(sim.tick(const Duration(seconds: 8)), ["a", "b"]);
      sim.apply(TimelineEvent(
          const Duration(seconds: 8, milliseconds: 100), "b",
          speaking: false));

      sim.apply(
          TimelineEvent(const Duration(seconds: 9), "a", speaking: false));

      // "c" qualifies at t=13. The set is full (a, b). Oldest-promoted is
      // "a", but least-recently-spoken is "b" (last spoke at 8s vs a's 9s).
      // Eviction must remove "b", not "a".
      sim.apply(
          TimelineEvent(const Duration(seconds: 10), "c", speaking: true));
      expect(sim.tick(const Duration(seconds: 13)), ["a", "c"]);
    });

    test("a speaker mid-sentence survives while a quieter promoted speaker "
        "is evicted", () {
      final policy = ActiveSpeakerPolicy(maxPromoted: 2);
      final sim = SpeakerSimulation(policy);

      // "a" and "b" both start speaking early (offsets before the first
      // tick, so the timeline stays non-decreasing throughout). "a" never
      // stops talking through the whole scenario: it is always
      // mid-sentence, so its last-spoke instant is always "now" at every
      // tick that follows.
      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      sim.apply(
          TimelineEvent(const Duration(seconds: 1), "b", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);
      expect(sim.tick(const Duration(seconds: 4)), ["a", "b"]);

      // "b" goes quiet right after being promoted and stays quiet (but
      // under the 30s demotion boundary), so it is the quieter promoted
      // speaker.
      sim.apply(TimelineEvent(
          const Duration(seconds: 4, milliseconds: 100), "b",
          speaking: false));

      // "c" qualifies at t=13, while "a" is still speaking (mid-sentence,
      // last-spoke == now == 13s) and "b" has been silent since t=4s.
      sim.apply(
          TimelineEvent(const Duration(seconds: 10), "c", speaking: true));
      final result = sim.tick(const Duration(seconds: 13));

      expect(result, contains("a")); // mid-sentence, survives
      expect(result, isNot(contains("b"))); // quieter, evicted
      expect(result, contains("c"));
    });

    test("every promoted slot talking at once still evicts exactly one, "
        "breaking the tie toward the oldest-promoted", () {
      final policy = ActiveSpeakerPolicy(maxPromoted: 2);
      final sim = SpeakerSimulation(policy);

      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      sim.apply(
          TimelineEvent(const Duration(seconds: 1), "b", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);
      expect(sim.tick(const Duration(seconds: 4)), ["a", "b"]);

      // Both "a" and "b" are still speaking continuously. "c" qualifies at
      // t=13 while every promoted slot is simultaneously "talking right
      // now": the only circumstance in which a mid-sentence speaker can
      // still be evicted. The tie is broken toward whichever was promoted
      // first, "a".
      sim.apply(
          TimelineEvent(const Duration(seconds: 10), "c", speaking: true));
      final result = sim.tick(const Duration(seconds: 13));

      expect(result, isNot(contains("a")));
      expect(result, containsAll(["b", "c"]));
    });
  });

  group("departure", () {
    test("leaving the call frees a promoted slot immediately, ignoring the "
        "30s silence timer", () {
      final policy = ActiveSpeakerPolicy();
      final sim = SpeakerSimulation(policy);

      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);

      // "a" is still speaking (last-spoke is effectively "now") when they
      // leave: if the silence timer applied, this would stay promoted for
      // another 30s. It must not.
      expect(
          sim.apply(TimelineEvent(
              const Duration(seconds: 3, milliseconds: 500), "a",
              leave: true)),
          []);
    });

    test("a departure frees exactly one slot, leaving the rest untouched",
        () {
      final policy = ActiveSpeakerPolicy(maxPromoted: 2);
      final sim = SpeakerSimulation(policy);

      sim.apply(TimelineEvent(Duration.zero, "a", speaking: true));
      sim.apply(
          TimelineEvent(const Duration(seconds: 1), "b", speaking: true));
      expect(sim.tick(const Duration(seconds: 3)), ["a"]);
      expect(sim.tick(const Duration(seconds: 4)), ["a", "b"]);

      final result = sim.apply(
          TimelineEvent(const Duration(seconds: 5), "a", leave: true));
      expect(result, ["b"]);
    });
  });
}
