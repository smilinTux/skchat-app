// Conference video rendering (card V14).
//
// conf_screen.dart used to draw every participant as a bare 64px avatar
// circle in a Wrap, with no VideoTrackRenderer, no track resolution and no
// Room track walk anywhere in the file. The camera toggle in the control bar
// was real: it called ConfNotifier.toggleCamera -> lk.setCameraEnabled(true)
// and the track genuinely published to the SFU. Nobody, including the
// publisher, ever saw it: a control that appears to work and silently does
// nothing visible.
//
// This is the regression net for adopting the shared multi-party grid
// (features/call_shared/video/participant_grid.dart), the same grid the
// calls screen already uses. The mocked Room graph mirrors
// test/features/calls/call_tile_video_test.dart's pattern: the DI seam is
// callVideoRendererBuilderProvider, which lets a video surface be asserted on
// without the flutter_webrtc platform channel VideoTrackRenderer needs.
import "dart:collection";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/call_shared/video/participant_grid.dart";
import "package:skchat/features/call_shared/video/participant_video.dart";
import "package:skchat/features/conf/conf_screen.dart";
import "package:skchat/services/conf_service.dart";
import "package:skchat/services/livekit_call_service.dart";

class MockConfService extends Mock implements ConfService {}

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

class _MockRoom extends Mock implements Room {}

class _MockLocalParticipant extends Mock implements LocalParticipant {}

class _MockRemoteParticipant extends Mock implements RemoteParticipant {}

class _MockLocalTrackPublication extends Mock
    implements LocalTrackPublication<LocalTrack> {}

class _MockRemoteTrackPublication extends Mock
    implements RemoteTrackPublication {}

class _FakeRemoteVideoTrack extends Mock implements RemoteVideoTrack {}

class _FakeLocalVideoTrack extends Mock implements LocalVideoTrack {}

LiveKitParticipantSnapshot _snap(
  String identity, {
  bool isLocal = false,
  bool isCameraEnabled = false,
}) =>
    LiveKitParticipantSnapshot(
      identity: identity,
      isLocal: isLocal,
      isMuted: false,
      isCameraEnabled: isCameraEnabled,
    );

UnmodifiableMapView<String, RemoteParticipant> _remotes(
  Map<String, RemoteParticipant> map,
) =>
    UnmodifiableMapView<String, RemoteParticipant>(map);

void main() {
  late MockConfService conf;
  late MockLiveKitCallService lk;
  late _MockRoom room;
  late EventsEmitter<RoomEvent> emitter;

  const hostArgs = ConfArgs(
    identity: "chef@dk.skworld",
    room: "conf-1",
    name: "Chef",
    role: "host",
  );

  ConfToken hostToken() => const ConfToken(
        room: "conf-1",
        url: "wss://lk.test/ws",
        token: "jwt-host",
        identity: "chef@dk.skworld",
        role: "host",
        title: "Town Hall",
      );

  setUp(() {
    conf = MockConfService();
    lk = MockLiveKitCallService();
    room = _MockRoom();
    emitter = EventsEmitter<RoomEvent>();
    // ParticipantVideo (behind every ParticipantTile) subscribes to the
    // room's event bus on mount; unstubbed, mocktail returns null and the
    // subscription throws on build.
    when(() => room.createListener())
        .thenAnswer((_) => EventsListener<RoomEvent>(emitter));

    when(() => conf.token("conf-1",
            identity: any(named: "identity"),
            name: any(named: "name"),
            role: any(named: "role")))
        .thenAnswer((_) async => hostToken());
    when(() => conf.waitingList("conf-1")).thenAnswer((_) async => const []);

    when(() => lk.room).thenReturn(room);
    when(() => lk.dataChannel).thenAnswer((_) => const Stream.empty());
    when(() => lk.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).thenAnswer((_) async {});
    when(() => lk.setMicEnabled(any())).thenAnswer((_) async {});
    when(() => lk.setCameraEnabled(any())).thenAnswer((_) async {});
    when(() => lk.setScreenShareEnabled(any(),
        sourceId: any(named: "sourceId"))).thenAnswer((_) async {});
    when(() => lk.leaveRoom()).thenAnswer((_) async {});
    when(() => lk.connectionState)
        .thenAnswer((_) => Stream.value(ConnectionState.connected));
  });

  tearDown(() async => emitter.dispose());

  Widget wrap(ConfArgs args) {
    return ProviderScope(
      overrides: [
        confServiceProvider.overrideWithValue(conf),
        liveKitCallServiceProvider.overrideWithValue(lk),
        callVideoRendererBuilderProvider.overrideWithValue(
          (track) => const ColoredBox(
            key: Key("video-marker"),
            color: Color(0xFF00FF00),
          ),
        ),
      ],
      child: MaterialApp(home: ConfScreen(args: args)),
    );
  }

  testWidgets(
      "conf renders the shared multi-party grid, not a private avatar-only "
      "tile", (tester) async {
    when(() => room.remoteParticipants)
        .thenReturn(_remotes(<String, RemoteParticipant>{}));
    when(() => room.localParticipant).thenReturn(null);
    final parts = [_snap("chef@dk.skworld", isLocal: true)];
    when(() => lk.participants).thenAnswer((_) => Stream.value(parts));
    when(() => lk.currentParticipants).thenReturn(parts);

    await tester.pumpWidget(wrap(hostArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ParticipantGrid), findsOneWidget);
  });

  testWidgets(
      "a participant whose camera is ON renders a video surface for them, "
      "not an avatar", (tester) async {
    final remote = _MockRemoteParticipant();
    final pub = _MockRemoteTrackPublication();
    final track = _FakeRemoteVideoTrack();
    when(() => pub.track).thenReturn(track);
    when(() => pub.muted).thenReturn(false);
    when(() => remote.getTrackPublicationBySource(TrackSource.camera))
        .thenReturn(pub);
    when(() =>
            remote.getTrackPublicationBySource(TrackSource.screenShareVideo))
        .thenReturn(null);
    when(() => room.remoteParticipants)
        .thenReturn(_remotes({"guest@dk.skworld": remote}));
    when(() => room.localParticipant).thenReturn(null);

    final parts = [
      _snap("chef@dk.skworld", isLocal: true),
      _snap("guest@dk.skworld", isCameraEnabled: true),
    ];
    when(() => lk.participants).thenAnswer((_) => Stream.value(parts));
    when(() => lk.currentParticipants).thenReturn(parts);

    await tester.pumpWidget(wrap(hostArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The camera-on remote participant draws the video surface...
    expect(find.byKey(const Key("video-marker")), findsOneWidget);
    // ...not just their avatar initial.
    expect(find.text("G"), findsNothing);
  });

  testWidgets(
      "the local participant's own published camera renders a self preview, "
      "not just an avatar", (tester) async {
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
    when(() => room.remoteParticipants)
        .thenReturn(_remotes(<String, RemoteParticipant>{}));

    final parts = [
      _snap("chef@dk.skworld", isLocal: true, isCameraEnabled: true),
    ];
    when(() => lk.participants).thenAnswer((_) => Stream.value(parts));
    when(() => lk.currentParticipants).thenReturn(parts);

    await tester.pumpWidget(wrap(hostArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key("video-marker")), findsOneWidget);
    expect(find.text("C"), findsNothing);
  });
}
