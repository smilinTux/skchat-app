import "dart:collection";

import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/spaces/screen_share_helper.dart";
import "package:skchat/services/livekit_call_service.dart";

class _MockRoom extends Mock implements Room {}

class _MockLocalParticipant extends Mock implements LocalParticipant {}

class _MockRemoteParticipant extends Mock implements RemoteParticipant {}

class _MockLocalTrackPublication extends Mock
    implements LocalTrackPublication<LocalTrack> {}

class _MockRemoteTrackPublication extends Mock
    implements RemoteTrackPublication {}

class _FakeLocalVideoTrack extends Mock implements LocalVideoTrack {}

class _FakeRemoteVideoTrack extends Mock implements RemoteVideoTrack {}

LiveKitParticipantSnapshot _snap(String identity, {bool isLocal = false}) {
  return LiveKitParticipantSnapshot(
    identity: identity,
    isLocal: isLocal,
    isMuted: false,
    isCameraEnabled: false,
  );
}

UnmodifiableMapView<String, RemoteParticipant> _remotes(
  Map<String, RemoteParticipant> map,
) =>
    UnmodifiableMapView<String, RemoteParticipant>(map);

// CAM: the Space watch stage (_WatchStage, space_room_screen.dart) must
// render a camera go-live, not only a screen share. resolveCameraShares /
// resolveStageVideos (screen_share_helper.dart) generalize the existing
// resolveScreenShares room-graph lookup (TrackSource.screenShareVideo) to
// also cover TrackSource.camera, the same identity-keyed pattern the host
// "Mute mic" moderation lookup and resolveScreenShares itself already use.
void main() {
  group("resolveCameraShares", () {
    test("returns the local participant's own live camera track", () {
      final room = _MockRoom();
      final local = _MockLocalParticipant();
      final pub = _MockLocalTrackPublication();
      final track = _FakeLocalVideoTrack();
      when(() => room.localParticipant).thenReturn(local);
      when(() => local.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.track).thenReturn(track);
      when(() => pub.muted).thenReturn(false);

      final participants = [_snap("chef", isLocal: true)];
      final result = resolveCameraShares(room, participants);

      expect(result, hasLength(1));
      expect(result.single.identity, "chef");
      expect(result.single.track, same(track));
      expect(result.single.isLocal, isTrue);
    });

    test("returns a REMOTE participant's live camera track", () {
      final room = _MockRoom();
      final remote = _MockRemoteParticipant();
      final pub = _MockRemoteTrackPublication();
      final track = _FakeRemoteVideoTrack();
      when(() => room.remoteParticipants)
          .thenReturn(_remotes({"dana": remote}));
      when(() => remote.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.track).thenReturn(track);
      when(() => pub.muted).thenReturn(false);

      final participants = [_snap("dana")];
      final result = resolveCameraShares(room, participants);

      expect(result, hasLength(1));
      expect(result.single.identity, "dana");
      expect(result.single.track, same(track));
      expect(result.single.isLocal, isFalse);
    });

    test("a participant with no live camera publication is excluded", () {
      final room = _MockRoom();
      final remote = _MockRemoteParticipant();
      when(() => room.remoteParticipants)
          .thenReturn(_remotes({"dana": remote}));
      when(() => remote.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);

      final result = resolveCameraShares(room, [_snap("dana")]);

      expect(result, isEmpty);
    });

    test("with no room, returns an empty list", () {
      expect(resolveCameraShares(null, [_snap("dana")]), isEmpty);
    });

    // MUTED: resolveTileVideoTrack (call_tile_video_test.dart) already treats
    // a muted publication as no video, because the SFU stops forwarding a
    // muted track and drawing it would pin the last decoded frame. Before this
    // test, resolveCameraShares (via the shared _resolveTracksBySource lookup)
    // never checked `muted` at all, so the same participant at the same
    // instant would show "no video" on a call tile and "video" on the Spaces
    // stage. One room graph, two answers, and the mismatch would surface as a
    // layout bug once a shared layout engine renders both.
    test("a MUTED camera publication is excluded, not treated as live video",
        () {
      final room = _MockRoom();
      final remote = _MockRemoteParticipant();
      final pub = _MockRemoteTrackPublication();
      final track = _FakeRemoteVideoTrack();
      when(() => room.remoteParticipants)
          .thenReturn(_remotes({"dana": remote}));
      when(() => remote.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.track).thenReturn(track);
      when(() => pub.muted).thenReturn(true);

      final result = resolveCameraShares(room, [_snap("dana")]);

      expect(result, isEmpty);
    });
  });

  group("resolveStageVideos", () {
    test(
        "combines a screen share and a camera go-live from DIFFERENT "
        "participants, tagging isCamera correctly for each", () {
      final room = _MockRoom();
      final sharer = _MockRemoteParticipant();
      final sharerScreenPub = _MockRemoteTrackPublication();
      final screenTrack = _FakeRemoteVideoTrack();
      when(() =>
              sharer.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(sharerScreenPub);
      when(() => sharerScreenPub.track).thenReturn(screenTrack);
      when(() => sharerScreenPub.muted).thenReturn(false);
      when(() => sharer.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);

      final camper = _MockRemoteParticipant();
      final camperCameraPub = _MockRemoteTrackPublication();
      final cameraTrack = _FakeRemoteVideoTrack();
      when(() => camper.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(camperCameraPub);
      when(() => camperCameraPub.track).thenReturn(cameraTrack);
      when(() => camperCameraPub.muted).thenReturn(false);
      when(() =>
              camper.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);

      when(() => room.remoteParticipants)
          .thenReturn(_remotes({"sharer": sharer, "camper": camper}));

      final videos =
          resolveStageVideos(room, [_snap("sharer"), _snap("camper")]);

      expect(videos, hasLength(2));
      final screenVideo = videos.firstWhere((v) => v.identity == "sharer");
      final cameraVideo = videos.firstWhere((v) => v.identity == "camper");
      expect(screenVideo.isCamera, isFalse);
      expect(screenVideo.track, same(screenTrack));
      expect(cameraVideo.isCamera, isTrue);
      expect(cameraVideo.track, same(cameraTrack));
    });

    test("with only a camera go-live live (no screen share), returns just "
        "that one video tagged isCamera true", () {
      final room = _MockRoom();
      final camper = _MockRemoteParticipant();
      final pub = _MockRemoteTrackPublication();
      final track = _FakeRemoteVideoTrack();
      when(() => camper.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.track).thenReturn(track);
      when(() => pub.muted).thenReturn(false);
      when(() =>
              camper.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => room.remoteParticipants)
          .thenReturn(_remotes({"camper": camper}));

      final videos = resolveStageVideos(room, [_snap("camper")]);

      expect(videos, hasLength(1));
      expect(videos.single.isCamera, isTrue);
      expect(videos.single.track, same(track));
    });

    test("with nothing live, returns an empty list", () {
      final room = _MockRoom();
      final p = _MockRemoteParticipant();
      when(() => p.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => p.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => room.remoteParticipants).thenReturn(_remotes({"p": p}));

      expect(resolveStageVideos(room, [_snap("p")]), isEmpty);
    });

    // Same MUTED rule as the resolveCameraShares test above, exercised through
    // the combined stage resolver: a muted screen share drops out entirely
    // (screens and cameras are additive here, not a fallback chain like
    // resolveTileVideoTrack, so "excluded" just means it never joins the
    // list), while a separate participant's live camera go-live still renders.
    test(
        "a muted screen share is excluded, but a live camera go-live from "
        "another participant still renders", () {
      final room = _MockRoom();
      final sharer = _MockRemoteParticipant();
      final mutedScreenPub = _MockRemoteTrackPublication();
      when(() =>
              sharer.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(mutedScreenPub);
      when(() => mutedScreenPub.track).thenReturn(_FakeRemoteVideoTrack());
      when(() => mutedScreenPub.muted).thenReturn(true);
      when(() => sharer.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);

      final camper = _MockRemoteParticipant();
      final camPub = _MockRemoteTrackPublication();
      final camTrack = _FakeRemoteVideoTrack();
      when(() => camper.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(camPub);
      when(() => camPub.track).thenReturn(camTrack);
      when(() => camPub.muted).thenReturn(false);
      when(() =>
              camper.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);

      when(() => room.remoteParticipants)
          .thenReturn(_remotes({"sharer": sharer, "camper": camper}));

      final videos =
          resolveStageVideos(room, [_snap("sharer"), _snap("camper")]);

      expect(videos, hasLength(1));
      expect(videos.single.identity, "camper");
      expect(videos.single.isCamera, isTrue);
      expect(videos.single.track, same(camTrack));
    });
  });
}
