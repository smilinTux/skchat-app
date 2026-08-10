import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/spaces/screen_share_helper.dart";
import "package:skchat/features/spaces/stage_content.dart";

class _FakeVideoTrack extends Mock implements VideoTrack {}

void main() {
  test("no live video and no watch session leaves the stage empty", () {
    expect(
        resolveStageKind(videos: const [], watchActive: false), StageKind.none);
  });

  test("a watch session alone owns the stage", () {
    expect(
        resolveStageKind(videos: const [], watchActive: true), StageKind.watch);
  });

  test("a live screen share or camera OUTRANKS the watch session", () {
    // Going live is deliberate and interruptive, and the watch video keeps
    // playing and staying synced underneath, so a host can cut in over a
    // movie without ending it for the room.
    final videos = <StageVideo>[
      (
        identity: "chef",
        track: _FakeVideoTrack(),
        isLocal: true,
        isCamera: true,
      ),
    ];

    expect(resolveStageKind(videos: videos, watchActive: true),
        StageKind.liveVideo);
  });

  test("a live screen share or camera wins the stage even with no watch "
      "session at all", () {
    // Guards against an implementation that only checks watchActive on the
    // "true" branch and defaults to StageKind.none whenever videos is
    // non-empty and watchActive is false: that would (wrongly) hide a live
    // share/camera whenever nobody happens to also be watching a video.
    final videos = <StageVideo>[
      (
        identity: "dana",
        track: _FakeVideoTrack(),
        isLocal: false,
        isCamera: false,
      ),
    ];

    expect(resolveStageKind(videos: videos, watchActive: false),
        StageKind.liveVideo);
  });
}
