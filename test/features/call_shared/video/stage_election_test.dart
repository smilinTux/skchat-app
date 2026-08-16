import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/call_shared/video/stage_election.dart";

/// Shorthand for a plain camera participant with no video, matching the
/// common case of "just present, nothing active" used across the
/// never-empty and fail-safe tests below.
StageParticipant _plain(String identity, {bool isLocal = false}) =>
    StageParticipant(identity: identity, isLocal: isLocal);

void main() {
  group("electStage ladder ordering", () {
    test("local pin beats broadcast pin", () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("alice"),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        localPin: "alice",
        broadcastPin: "bob",
      );
      expect(result.identity, "alice");
    });

    test("broadcast pin beats an active screen share", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(identity: "alice", isScreenSharing: true),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        broadcastPin: "bob",
      );
      expect(result.identity, "bob");
      expect(result.kind, StageFeedKind.camera);
    });

    test("active screen share beats the dominant speaker", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(identity: "alice", isScreenSharing: true),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        activeSpeakers: ["bob"],
      );
      expect(result.identity, "alice");
      expect(result.kind, StageFeedKind.screenShare);
    });

    test("first sharer wins when more than one participant is sharing at "
        "once (the old rule, demoted to one rung instead of the whole "
        "decision)", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(identity: "alice", isScreenSharing: true),
        StageParticipant(identity: "bob", isScreenSharing: true),
      ];
      final result = electStage(participants: participants);
      expect(result.identity, "alice");
    });

    test("dominant speaker beats the last remote with video", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(identity: "alice", hasVideo: true),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        activeSpeakers: ["bob"],
      );
      expect(result.identity, "bob");
    });

    test("last remote with video beats the first-participant fallback", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(identity: "alice", hasVideo: true),
        StageParticipant(identity: "bob", hasVideo: true),
      ];
      final result = electStage(participants: participants);
      // "last" remote with video, not first: bob, not alice.
      expect(result.identity, "bob");
    });

    test("the local participant's own video is never picked by the "
        "last-remote-with-video rung", () {
      final participants = [
        StageParticipant(identity: "me", isLocal: true, hasVideo: true),
        _plain("alice"),
      ];
      final result = electStage(participants: participants);
      // No remote has video, so this falls all the way to the
      // first-participant fallback rather than featuring the local feed.
      expect(result.identity, "me");
    });
  });

  group("pin fail-safe", () {
    test("a local pin naming someone not on the call resolves as no pin",
        () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        localPin: "ghost",
        activeSpeakers: ["bob"],
      );
      // Falls through past the dead pin straight to the next rung that
      // actually matches, rather than freezing on "ghost" or going empty.
      expect(result.identity, "bob");
    });

    test("a broadcast pin naming someone not on the call resolves as no "
        "pin", () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("bob"),
        _plain("carol"),
      ];
      final result = electStage(
        participants: participants,
        broadcastPin: "ghost",
        activeSpeakers: ["carol"],
      );
      expect(result.identity, "carol");
    });
  });

  group("2-participant broadcast pin skip", () {
    test("a broadcast pin is ignored entirely in a 2-participant room", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(identity: "bob", hasVideo: true),
      ];
      final result = electStage(
        participants: participants,
        // Names the peer, and the peer IS on the call, so this is not the
        // fail-safe case above: the skip is what has to keep it from
        // winning.
        broadcastPin: "bob",
      );
      // Falls through the skipped rung 2 to rung 5 (last remote with
      // video), landing on bob anyway here, but via a different rung: the
      // broadcast pin itself must play no part in the decision.
      expect(result.identity, "bob");
    });

    test("a broadcast pin naming the ONLY candidate a lower rung would "
        "also pick still proves the skip, via a room where the lower rung "
        "picks someone else", () {
      final participants = [
        StageParticipant(identity: "me", isLocal: true, hasVideo: true),
        _plain("bob"),
      ];
      // If the broadcast pin were honored it would pick "bob". With it
      // skipped, no rung below matches (no screen share, no speaker, no
      // remote video: bob has none), so this falls to the first
      // participant, "me".
      final result = electStage(
        participants: participants,
        broadcastPin: "bob",
      );
      expect(result.identity, "me");
    });

    test("a local pin still applies in a 2-participant room", () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        localPin: "bob",
      );
      expect(result.identity, "bob");
    });
  });

  group("never empty", () {
    test("a room where nobody has spoken, shared, or published video still "
        "elects someone: the first participant", () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("alice"),
        _plain("bob"),
      ];
      final result = electStage(participants: participants);
      expect(result.identity, "me");
      expect(result.kind, StageFeedKind.camera);
    });

    test("an empty participant list elects no one rather than throwing",
        () {
      final result = electStage(participants: const []);
      expect(result.identity, isNull);
      expect(result.remainder, isEmpty);
    });
  });

  group("pinned screen-sharer", () {
    test("a locally pinned participant who is screen-sharing features "
        "their share, not their camera", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(
          identity: "alice",
          hasVideo: true,
          isScreenSharing: true,
        ),
      ];
      final result = electStage(
        participants: participants,
        localPin: "alice",
      );
      expect(result.identity, "alice");
      expect(result.kind, StageFeedKind.screenShare);
    });

    test("a broadcast-pinned participant who is screen-sharing features "
        "their share, not their camera", () {
      final participants = [
        _plain("me", isLocal: true),
        StageParticipant(
          identity: "alice",
          hasVideo: true,
          isScreenSharing: true,
        ),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        broadcastPin: "alice",
      );
      expect(result.identity, "alice");
      expect(result.kind, StageFeedKind.screenShare);
    });
  });

  group("remainder ordering", () {
    test("the remainder excludes the winner and keeps everyone else in "
        "their original relative order", () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("alice"),
        _plain("bob"),
        _plain("carol"),
      ];
      final result = electStage(
        participants: participants,
        localPin: "bob",
      );
      expect(result.identity, "bob");
      expect(result.remainder, ["me", "alice", "carol"]);
    });
  });

  group("dominant speaker fail-safe", () {
    test("an activeSpeakers entry no longer on the call is skipped in "
        "favor of the next one that is", () {
      final participants = [
        _plain("me", isLocal: true),
        _plain("bob"),
      ];
      final result = electStage(
        participants: participants,
        activeSpeakers: ["ghost", "bob"],
      );
      expect(result.identity, "bob");
    });
  });
}
