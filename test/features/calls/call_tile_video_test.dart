// Remote video on the 1:1 call screen.
//
// The Lumina call agent publishes a still portrait video track AFTER her audio
// track (skchat transports/livekit.py, TrackSource.SOURCE_CAMERA). Server side
// that is proven: a test caller subscribes and decodes frames. The client was
// the gap, in two separate places:
//
//  1. `_ParticipantTile._resolveVideoTrack` refused to return a camera track
//     unless `snapshot.isCameraEnabled` was true. That is a value copied off
//     the participant snapshot when the SERVICE last emitted and read again at
//     a later build, so it could veto a track that was already subscribed and
//     decoding. The Spaces resolvers (resolveStageVideos) have never consulted
//     it. `resolveTileVideoTrack` puts the call grid on that same rule and
//     reads `muted` off the LIVE publication instead of off the snapshot.
//  2. The tile resolved once per build and never listened to the room, so a
//     track that arrives LATE (the only way the agent's video ever arrives)
//     had nothing of its own to trigger a repaint.
import "dart:collection";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/calls/livekit_call_screen.dart";
import "package:skchat/features/spaces/screen_share_helper.dart";
import "package:skchat/services/livekit_call_service.dart";

class _MockRoom extends Mock implements Room {}

class _MockCallService extends Mock implements LiveKitCallService {}

class _MockLocalParticipant extends Mock implements LocalParticipant {}

class _MockRemoteParticipant extends Mock implements RemoteParticipant {}

class _MockLocalTrackPublication extends Mock
    implements LocalTrackPublication<LocalTrack> {}

class _MockRemoteTrackPublication extends Mock
    implements RemoteTrackPublication {}

class _FakeRemoteVideoTrack extends Mock implements RemoteVideoTrack {}

class _FakeLocalVideoTrack extends Mock implements LocalVideoTrack {}

/// The agent's identity really does end in `#agent` (it joins as
/// `<fqid>#agent` so caller and agent never collide on one LiveKit identity),
/// so these tests key on that exact string rather than a tidy fake name.
const _kAgent = "lumina@chef.skworld.io#agent";

LiveKitParticipantSnapshot _snap(
  String identity, {
  bool isLocal = false,
  bool isCameraEnabled = false,
}) {
  return LiveKitParticipantSnapshot(
    identity: identity,
    isLocal: isLocal,
    isMuted: false,
    isCameraEnabled: isCameraEnabled,
  );
}

UnmodifiableMapView<String, RemoteParticipant> _remotes(
  Map<String, RemoteParticipant> map,
) =>
    UnmodifiableMapView<String, RemoteParticipant>(map);

/// A remote participant publishing a camera video track.
///
/// [track] null models a publication that exists but whose track has been torn
/// down (unsubscribed), which is what a track going away mid-call looks like.
_MockRemoteParticipant _remoteWithCamera({
  RemoteVideoTrack? track,
  bool muted = false,
}) {
  final participant = _MockRemoteParticipant();
  final pub = _MockRemoteTrackPublication();
  when(() => pub.track).thenReturn(track);
  when(() => pub.muted).thenReturn(muted);
  when(() => participant.getTrackPublicationBySource(TrackSource.camera))
      .thenReturn(pub);
  when(() =>
          participant.getTrackPublicationBySource(TrackSource.screenShareVideo))
      .thenReturn(null);
  return participant;
}

/// A notifier that exposes a fixed [LiveKitCallState] without touching a live
/// LiveKit room, mirroring the harness in group_call_screen_test.dart.
class _FixedCallNotifier extends LiveKitCallNotifier {
  _FixedCallNotifier(this._fixed);
  final LiveKitCallState _fixed;

  @override
  LiveKitCallState? build() => _fixed;

  @override
  Future<void> join({
    required String roomName,
    required String identity,
    bool withVideo = false,
  }) async {}

  @override
  Future<void> joinWithToken({
    required String roomName,
    required String identity,
    required String wsUrl,
    required String token,
    bool withVideo = false,
  }) async {}
}

void main() {
  group("resolveTileVideoTrack", () {
    test(
        "returns a remote camera track even when the snapshot says the camera "
        "is OFF (the regression: a server-published track vetoed by a stale "
        "snapshot field)", () {
      final room = _MockRoom();
      final track = _FakeRemoteVideoTrack();
      final remotes = _remotes({_kAgent: _remoteWithCamera(track: track)});
      when(() => room.remoteParticipants).thenReturn(remotes);

      // isCameraEnabled: false is the whole point. The old tile resolver
      // returned null here and drew the avatar over live video.
      final resolved = resolveTileVideoTrack(
        room,
        _snap(_kAgent, isCameraEnabled: false),
      );

      expect(resolved, same(track));
    });

    test("returns null once the publication's track is torn down", () {
      final room = _MockRoom();
      final remotes = _remotes({_kAgent: _remoteWithCamera(track: null)});
      when(() => room.remoteParticipants).thenReturn(remotes);

      expect(resolveTileVideoTrack(room, _snap(_kAgent)), isNull);
    });

    test(
        "treats a MUTED publication as no video, so the tile falls back "
        "instead of freezing on the last decoded frame", () {
      final room = _MockRoom();
      final remotes = _remotes({
        _kAgent: _remoteWithCamera(track: _FakeRemoteVideoTrack(), muted: true),
      });
      when(() => room.remoteParticipants).thenReturn(remotes);

      expect(resolveTileVideoTrack(room, _snap(_kAgent)), isNull);
    });

    test("prefers a screen share over a camera track", () {
      final room = _MockRoom();
      final participant = _MockRemoteParticipant();
      final screenPub = _MockRemoteTrackPublication();
      final camPub = _MockRemoteTrackPublication();
      final screenTrack = _FakeRemoteVideoTrack();
      when(() => screenPub.track).thenReturn(screenTrack);
      when(() => screenPub.muted).thenReturn(false);
      final otherCamTrack = _FakeRemoteVideoTrack();
      when(() => camPub.track).thenReturn(otherCamTrack);
      when(() => camPub.muted).thenReturn(false);
      when(() => participant
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(screenPub);
      when(() => participant.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(camPub);
      final remotes = _remotes({"dana": participant});
      when(() => room.remoteParticipants).thenReturn(remotes);

      expect(resolveTileVideoTrack(room, _snap("dana")), same(screenTrack));
    });

    test("falls through a muted screen share to a live camera track", () {
      final room = _MockRoom();
      final participant = _MockRemoteParticipant();
      final screenPub = _MockRemoteTrackPublication();
      final camPub = _MockRemoteTrackPublication();
      final camTrack = _FakeRemoteVideoTrack();
      final mutedScreenTrack = _FakeRemoteVideoTrack();
      when(() => screenPub.track).thenReturn(mutedScreenTrack);
      when(() => screenPub.muted).thenReturn(true);
      when(() => camPub.track).thenReturn(camTrack);
      when(() => camPub.muted).thenReturn(false);
      when(() => participant
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(screenPub);
      when(() => participant.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(camPub);
      final remotes = _remotes({"dana": participant});
      when(() => room.remoteParticipants).thenReturn(remotes);

      expect(resolveTileVideoTrack(room, _snap("dana")), same(camTrack));
    });

    test("resolves the LOCAL participant's own camera track", () {
      final room = _MockRoom();
      final local = _MockLocalParticipant();
      final pub = _MockLocalTrackPublication();
      final track = _FakeLocalVideoTrack();
      when(() => pub.track).thenReturn(track);
      when(() => pub.muted).thenReturn(false);
      when(() => local.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() =>
              local.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => room.localParticipant).thenReturn(local);

      expect(
        resolveTileVideoTrack(room, _snap("chef", isLocal: true)),
        same(track),
      );
    });

    test("a participant who is not in the room resolves to null", () {
      final room = _MockRoom();
      final remotes = _remotes(<String, RemoteParticipant>{});
      when(() => room.remoteParticipants).thenReturn(remotes);

      expect(resolveTileVideoTrack(room, _snap("ghost")), isNull);
    });

    test("with no room at all, returns null", () {
      expect(resolveTileVideoTrack(null, _snap(_kAgent)), isNull);
    });
  });

  // ── The late-arrival wire ────────────────────────────────────────────────
  //
  // These drive the REAL room event bus (EventsEmitter<RoomEvent>, the same
  // type Room.createListener() hands out), so the assertion is about the tile
  // reacting to a track event rather than about a test re-pumping it by hand.
  group("the call tile reacts to live room events", () {
    late EventsEmitter<RoomEvent> emitter;
    late _MockRoom room;
    late _MockCallService svc;

    setUp(() {
      emitter = EventsEmitter<RoomEvent>();
      room = _MockRoom();
      svc = _MockCallService();
      when(() => room.createListener())
          .thenAnswer((_) => EventsListener<RoomEvent>(emitter));
      when(() => room.localParticipant).thenReturn(null);
      when(() => svc.room).thenReturn(room);
    });

    tearDown(() async => emitter.dispose());

    LiveKitCallState state() => LiveKitCallState(
          roomName: "call-test",
          identity: "chef@skworld.io",
          // Just the agent, so the single-tile full-screen layout is used and
          // the assertions below are unambiguous.
          participants: [_snap(_kAgent)],
          isMicEnabled: true,
          isCameraEnabled: false,
          isConnected: true,
        );

    /// Mounts the real call screen against [room], substituting a marker for
    /// the platform-channel-backed VideoTrackRenderer (flutter_webrtc cannot
    /// initialize a renderer under `flutter test`).
    Widget wrap({Widget? home}) {
      return ProviderScope(
        overrides: [
          liveKitCallProvider.overrideWith(() => _FixedCallNotifier(state())),
          liveKitCallServiceProvider.overrideWithValue(svc),
          callVideoRendererBuilderProvider.overrideWithValue(
            (track) => const ColoredBox(
              key: Key("video-marker"),
              color: Color(0xFF00FF00),
            ),
          ),
        ],
        child: MaterialApp(
          home: home ??
              const LiveKitCallScreen(
                args: LiveKitCallArgs(
                  roomName: "call-test",
                  identity: "chef@skworld.io",
                  displayName: "Lumina",
                ),
              ),
        ),
      );
    }

    /// Push [event] through the real bus and let the tile settle.
    Future<void> fire(WidgetTester tester, RoomEvent event) async {
      emitter.streamCtrl.add(event);
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
        "a track published AFTER the tile is built paints, with no rebuild "
        "from anywhere else", (tester) async {
      // Start with no video publication at all: audio-only, avatar showing.
      final participant = _MockRemoteParticipant();
      RemoteTrackPublication? cameraPub;
      when(() => participant.getTrackPublicationBySource(TrackSource.camera))
          .thenAnswer((_) => cameraPub);
      when(() => participant
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      final remotes = _remotes({_kAgent: participant});
      when(() => room.remoteParticipants).thenReturn(remotes);

      await tester.pumpWidget(wrap());
      await tester.pump();

      expect(find.byKey(const Key("video-marker")), findsNothing,
          reason: "audio-only until the agent publishes her portrait");
      expect(find.text("L"), findsOneWidget,
          reason: "the existing avatar presentation is what shows meanwhile");

      // The agent publishes her portrait: the publication appears, then the
      // track is subscribed. The call state is deliberately NOT touched, so
      // only the room event can drive this repaint.
      final pub = _MockRemoteTrackPublication();
      final portrait = _FakeRemoteVideoTrack();
      when(() => pub.track).thenReturn(portrait);
      when(() => pub.muted).thenReturn(false);
      cameraPub = pub;

      await fire(
        tester,
        TrackSubscribedEvent(
          participant: participant,
          track: _FakeRemoteVideoTrack(),
          publication: pub,
        ),
      );

      expect(find.byKey(const Key("video-marker")), findsOneWidget,
          reason: "the late track must paint on the subscribe event");
      expect(find.text("L"), findsNothing);
    });

    testWidgets(
        "a track torn down mid-call falls back to the avatar rather than "
        "leaving the last frame frozen", (tester) async {
      final participant = _MockRemoteParticipant();
      final pub = _MockRemoteTrackPublication();
      RemoteVideoTrack? live = _FakeRemoteVideoTrack();
      when(() => pub.track).thenAnswer((_) => live);
      when(() => pub.muted).thenReturn(false);
      when(() => participant.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => participant
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      final remotes = _remotes({_kAgent: participant});
      when(() => room.remoteParticipants).thenReturn(remotes);

      await tester.pumpWidget(wrap());
      await tester.pump();
      expect(find.byKey(const Key("video-marker")), findsOneWidget);

      // Unsubscribe nulls the publication's track (and disposes it), so the
      // tile must stop drawing it.
      final gone = live;
      live = null;
      await fire(
        tester,
        TrackUnsubscribedEvent(
          participant: participant,
          track: gone,
          publication: pub,
        ),
      );

      expect(find.byKey(const Key("video-marker")), findsNothing);
      // The audio-only presentation is what comes back: the soul-ringed
      // initial, unchanged.
      expect(find.text("L"), findsOneWidget);
    });

    testWidgets(
        "muting the remote video falls back too, and unmuting brings it "
        "straight back", (tester) async {
      final participant = _MockRemoteParticipant();
      final pub = _MockRemoteTrackPublication();
      var muted = false;
      final portrait = _FakeRemoteVideoTrack();
      when(() => pub.track).thenReturn(portrait);
      when(() => pub.muted).thenAnswer((_) => muted);
      when(() => participant.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => participant
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      final remotes = _remotes({_kAgent: participant});
      when(() => room.remoteParticipants).thenReturn(remotes);

      await tester.pumpWidget(wrap());
      await tester.pump();
      expect(find.byKey(const Key("video-marker")), findsOneWidget);

      muted = true;
      await fire(
        tester,
        TrackMutedEvent(participant: participant, publication: pub),
      );
      expect(find.byKey(const Key("video-marker")), findsNothing);

      muted = false;
      await fire(
        tester,
        TrackUnmutedEvent(participant: participant, publication: pub),
      );
      expect(find.byKey(const Key("video-marker")), findsOneWidget);
    });

    testWidgets("the tile disposes its room listener when it leaves the tree",
        (tester) async {
      final participant = _MockRemoteParticipant();
      when(() => participant.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => participant
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      final remotes = _remotes({_kAgent: participant});
      when(() => room.remoteParticipants).thenReturn(remotes);

      await tester.pumpWidget(wrap());
      await tester.pump();

      await tester.pumpWidget(
        wrap(home: const Scaffold(body: SizedBox())),
      );
      await tester.pump();

      // Emitting after teardown must not blow up: setState on an unmounted
      // State is a hard error in Flutter.
      await fire(
        tester,
        TrackSubscribedEvent(
          participant: participant,
          track: _FakeRemoteVideoTrack(),
          publication: _MockRemoteTrackPublication(),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
