import "dart:async";
import "dart:collection";
import "dart:io";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/call_shared/screen_share_source.dart";
import "package:skchat/features/spaces/space_chat_panel.dart";
import "package:skchat/features/spaces/space_models.dart";
import "package:skchat/features/spaces/space_room_screen.dart";
import "package:skchat/features/spaces/watch_session.dart"
    show laneServiceFactoryProvider, watchSessionProvider, WatchSessionArgs;
import "package:skchat/features/spaces/watch_video_stub.dart"
    if (dart.library.html) "package:skchat/features/spaces/watch_video_web.dart";
import "package:skchat/services/lane_service.dart" show LaneLike;
import "package:skchat/services/livekit_call_service.dart";
import "package:skchat/services/spaces_service.dart";

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

class MockSpacesService extends Mock implements SpacesService {}

/// Deterministic stand-in for the real `LaneService`. `_Stage` now watches
/// `watchSessionProvider` on every render (space_room_screen.dart), which
/// builds a real `WatchSession` even though none of these tests ever load a
/// video, and the real `LaneService` fires a live Dio GET (`catchUp`) plus
/// subscribes to a data channel. These tests currently get away with the
/// real service only because `kDefaultSkchatWebuiUrl` is empty in a plain
/// `flutter test` run, so the GET URL is schemeless and fails fast into a
/// swallowing catch; that is an accident of the test environment, not a
/// seam. This fake answers instantly and does nothing, so every room test
/// stays deterministic regardless of that URL.
class _NoopLane implements LaneLike {
  @override
  Stream<Map<String, dynamic>> get inbound => const Stream.empty();

  @override
  Future<void> publish(Map<String, dynamic> payload) async {}

  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async {}

  @override
  Future<List<Map<String, dynamic>>> catchUp(String lane) async => const [];
}

// Room graph mocks used to resolve a remote speaker's live mic track sid
// (the host "Mute mic" moderation call needs the publication sid for the
// server's MuteRoomTrackRequest).
class MockRoom extends Mock implements Room {}

class MockRemoteParticipant extends Mock implements RemoteParticipant {}

class MockRemoteTrackPublication extends Mock
    implements RemoteTrackPublication {}

// Watch Together stage placement: a fake RemoteVideoTrack is enough to make
// resolveStageVideos (screen_share_helper.dart) see a live camera (matches
// stage_video_resolver_test.dart's _FakeRemoteVideoTrack). Actually
// rendering it goes through livekit_client's VideoTrackRenderer, which on
// this VM test target awaits a flutter_webrtc platform-channel call inside a
// FutureBuilder; with no channel handler registered, that Future resolves to
// an error the FutureBuilder swallows into an empty Container, so nothing
// here needs its own platform-channel mocking.
class _FakeVideoTrack extends Mock implements RemoteVideoTrack {}

LiveKitParticipantSnapshot _snap(
  String identity, {
  bool isLocal = false,
  bool isMuted = false,
  bool isSpeaking = false,
  bool canPublish = false,
  // SHARECTL-app: defaults true, matching LiveKitParticipantSnapshot's own
  // default (an empty canPublishSources list means no source restriction
  // has been applied yet). Tests that exercise the host-disabled-sharing
  // path pass this false explicitly.
  bool canPublishVideo = true,
  bool handRaised = false,
  bool invitedToStage = false,
  bool isCameraEnabled = false,
  bool isScreenSharing = false,
}) {
  return LiveKitParticipantSnapshot(
    identity: identity,
    isLocal: isLocal,
    isMuted: isMuted,
    isCameraEnabled: isCameraEnabled,
    isScreenSharing: isScreenSharing,
    isSpeaking: isSpeaking,
    canPublish: canPublish,
    canPublishVideo: canPublishVideo,
    handRaised: handRaised,
    invitedToStage: invitedToStage,
  );
}

void main() {
  late MockLiveKitCallService svc;
  late MockSpacesService spaces;

  setUpAll(() {
    // W1's Share sheet watches backendConfigProvider (skchatWebuiUrl), which
    // opens a Hive box best-effort on build; on the test VM Hive has no
    // default path without this (mirrors conversation_history_reply_test.dart).
    Hive.init(Directory.systemTemp.createTempSync("skchat_test_hive").path);
    // CAM: mocktail needs a dummy CameraPosition to satisfy any()/
    // captureAny() used with the named cameraPosition argument below.
    registerFallbackValue(CameraPosition.front);
    // Watch Together stage placement: mocktail needs a dummy GlobalKey for
    // the any() match on _FakeVideoTrack.removeViewKey below.
    registerFallbackValue(GlobalKey<State<StatefulWidget>>());
  });

  final join = const SpaceJoin(
    spaceId: "s1",
    room: "sk-space-s1",
    url: "wss://lk.test/ws",
    identity: "chef@dk.skworld",
    role: "host",
    token: "jwt-host",
    title: "SKWorld Town Hall",
  );

  setUp(() {
    svc = MockLiveKitCallService();
    final participants = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld",
          isLocal: true, isSpeaking: true, canPublish: true), // host speaker
      _snap("alice"), // listener (no publish grant)
      _snap("bob"), // listener (no publish grant)
    ];
    when(() => svc.participants)
        .thenAnswer((_) => Stream.value(participants));
    when(() => svc.connectionState)
        .thenAnswer((_) => Stream.value(ConnectionState.connected));
    when(() => svc.currentParticipants).thenReturn(participants);
    // ReactionsButton / ReactionsOverlay (call_shared/reactions.dart) watch
    // this on mount to subscribe to the reaction lane. Unstubbed, mocktail
    // returns null for the getter and building ReactionsButton throws a
    // _TypeError (null is not a Stream); see space_room_screen.dart's control
    // bar.
    when(() => svc.dataChannel).thenAnswer((_) => const Stream.empty());
    // Mic-enabled changes driven internally by LiveKitCallService. Default
    // to an empty stream; tests that exercise a mic-state desync override
    // this with a controller they drive directly.
    when(() => svc.micEnabledChanges).thenAnswer((_) => const Stream.empty());
    // DECOUPLE: whether a content-audio (system audio) share is currently
    // live, read directly by SpaceRoomNotifier.connect's participants
    // listener on every emission to detect the false -> true transition that
    // defaults the mic to muted. Default to not-sharing; the DECOUPLE test
    // group below overrides this per case.
    when(() => svc.isSharingSystemAudio).thenReturn(false);
    // Server-initiated mute signal (M1). Default to an empty stream; the M1
    // group below overrides this with a controller it drives directly.
    when(() => svc.externalMuteEvents)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => svc.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).thenAnswer((_) async {});
    when(() => svc.setMicEnabled(any())).thenAnswer((_) async {});
    when(() => svc.leaveRoom()).thenAnswer((_) async {});
    when(() => svc.setScreenShareEnabled(any(),
        systemAudioDeviceId: any(named: "systemAudioDeviceId"),
        sourceId: any(named: "sourceId"))).thenAnswer((_) async {});
    // Content audio for the control-bar share. Default to "this platform has
    // no system-audio source"; the desktop-audio case below overrides it.
    when(() => svc.defaultSystemAudioSource()).thenAnswer((_) async => null);
    // CAM: camera go-live / flip default stubs. Individual tests override
    // these to simulate a permission-deny / no-camera failure.
    when(() => svc.setCameraEnabled(any(),
        cameraPosition:
            any(named: "cameraPosition"))).thenAnswer((_) async {});
    when(() => svc.switchCameraPosition(any())).thenAnswer((_) async {});

    spaces = MockSpacesService();
    when(() => spaces.mute(
          any(),
          requester: any(named: "requester"),
          identity: any(named: "identity"),
          trackSid: any(named: "trackSid"),
        )).thenAnswer((_) async {});
    when(() => spaces.removeFromStage(
          any(),
          requester: any(named: "requester"),
          identity: any(named: "identity"),
        )).thenAnswer((_) async {});
    when(() => spaces.invite(
          any(),
          requester: any(named: "requester"),
          identity: any(named: "identity"),
        )).thenAnswer((_) async {});
    when(() => spaces.kick(
          any(),
          requester: any(named: "requester"),
          identity: any(named: "identity"),
        )).thenAnswer((_) async {});
    // Default raise-hand stub: on_stage false (a plain raise, not a gate
    // completion). X1 tests override this per-case to return true / false
    // as needed.
    when(() => spaces.raiseHand(any(), identity: any(named: "identity")))
        .thenAnswer((_) async => false);
    // SHARECTL-app: host-controlled per-speaker sharing toggle.
    when(() => spaces.setSharing(
          any(),
          requester: any(named: "requester"),
          identity: any(named: "identity"),
          allow: any(named: "allow"),
        )).thenAnswer((_) async => true);
  });

  Widget wrapFor(SpaceJoin join, {List<Override> extraOverrides = const []}) {
    return ProviderScope(
      overrides: [
        liveKitCallServiceProvider.overrideWithValue(svc),
        spacesServiceProvider.overrideWithValue(spaces),
        laneServiceFactoryProvider.overrideWithValue((args) => _NoopLane()),
        ...extraOverrides,
      ],
      child: MaterialApp(home: SpaceRoomScreen(join: join)),
    );
  }

  Widget wrap() => wrapFor(join);

  testWidgets("connects with the role token and renders host + listeners",
      (tester) async {
    await tester.pumpWidget(wrap());
    // Let post-frame connect + stream emissions settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Connected via the role-scoped token (not joinRoom / mintToken).
    verify(() => svc.connectWithToken(
          wsUrl: "wss://lk.test/ws",
          token: "jwt-host",
        )).called(1);
    // Host published mic.
    verify(() => svc.setMicEnabled(true)).called(1);

    // Title renders.
    expect(find.text("SKWorld Town Hall"), findsOneWidget);
    // Speakers section + the two listeners section labels.
    expect(find.text("SPEAKERS"), findsOneWidget);
    expect(find.text("LISTENERS"), findsOneWidget);
    // Listener count in header ("2 listening").
    expect(find.textContaining("listening"), findsOneWidget);
    // Host controls present (End + Mute available to host).
    expect(find.text("End"), findsOneWidget);
    expect(find.text("Mute"), findsOneWidget);
  });

  testWidgets(
      "a canPublish speaker who self-mutes renders as a SPEAKER, not a listener",
      (tester) async {
    final participants = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", isLocal: true, canPublish: true),
      // Speaker with publish grant but currently muted - must stay a speaker.
      _snap("dana", canPublish: true, isMuted: true),
      _snap("alice"), // listener
    ];
    when(() => svc.participants).thenAnswer((_) => Stream.value(participants));
    when(() => svc.currentParticipants).thenReturn(participants);

    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 2 speakers (host + muted-but-can-publish dana), 1 listener.
    expect(find.text("SPEAKERS"), findsOneWidget);
    expect(find.text("dana"), findsOneWidget); // dana shows on the speaker grid
    // Muted speaker still carries the muted mic indicator (secondary signal).
    expect(find.byIcon(Icons.mic_off_rounded), findsWidgets);
    // Listener section has alice.
    expect(find.text("LISTENERS"), findsOneWidget);
    expect(find.text("alice"), findsOneWidget);
  });

  testWidgets("a handRaised listener appears in the host raised-hands queue",
      (tester) async {
    final participants = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", isLocal: true, canPublish: true),
      _snap("evan", handRaised: true), // listener who raised their hand
      _snap("alice"), // plain listener
    ];
    when(() => svc.participants).thenAnswer((_) => Stream.value(participants));
    when(() => svc.currentParticipants).thenReturn(participants);

    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Raised-hands section visible to the host with the raised-hand listener.
    expect(find.text("RAISED HANDS"), findsOneWidget);
    expect(find.text("evan"), findsWidgets);
    expect(find.text("tap to invite"), findsWidgets);
  });

  testWidgets(
      "late remote join refreshes the roster live (new speaker appears without a rejoin)",
      (tester) async {
    // Reproduces the reported bug at the UI-consumption layer: a device that has
    // ALREADY joined must see a peer who joins LATER. The screen is driven purely
    // by svc.participants, and the service now re-emits the snapshot on the
    // explicit ParticipantConnected RoomEvent, so a later emission must add the
    // tile without the user rejoining. A broadcast StreamController stands in for
    // that live re-emit.
    final controller =
        StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
    addTearDown(controller.close);
    final initial = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", isLocal: true, canPublish: true), // host
      _snap("alice", canPublish: true), // speaker already in the room
    ];
    when(() => svc.participants).thenAnswer((_) => controller.stream);
    when(() => svc.currentParticipants).thenReturn(initial);

    await tester.pumpWidget(wrap());
    await tester.pump(); // post-frame connect
    controller.add(initial);
    await tester.pump(const Duration(milliseconds: 50));

    // Before the late join, alice is on the grid and bob is nowhere.
    expect(find.text("alice"), findsOneWidget);
    expect(find.text("bob"), findsNothing);

    // A third participant joins AFTER we were already in the room.
    controller.add(<LiveKitParticipantSnapshot>[
      ...initial,
      _snap("bob", canPublish: true),
    ]);
    await tester.pump(const Duration(milliseconds: 50));

    // The roster refreshed live: bob is now on the speaker grid, no rejoin.
    expect(find.text("bob"), findsOneWidget);
    expect(find.text("alice"), findsOneWidget);
  });

  testWidgets(
      "a remote leave refreshes the roster live (tile disappears without a rejoin)",
      (tester) async {
    final controller =
        StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
    addTearDown(controller.close);
    final full = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", isLocal: true, canPublish: true),
      _snap("alice", canPublish: true),
      _snap("bob", canPublish: true),
    ];
    when(() => svc.participants).thenAnswer((_) => controller.stream);
    when(() => svc.currentParticipants).thenReturn(full);

    await tester.pumpWidget(wrap());
    await tester.pump();
    controller.add(full);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("bob"), findsOneWidget);

    // bob leaves; ParticipantDisconnected re-emits the shrunk snapshot.
    controller.add(<LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", isLocal: true, canPublish: true),
      _snap("alice", canPublish: true),
    ]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("bob"), findsNothing);
    expect(find.text("alice"), findsOneWidget);
  });

  // ── SP2: promoted-speaker mic controls ────────────────────────────────────
  //
  // X Spaces model: real mic controls follow the actual LiveKit publish
  // grant (canPublish), not SpaceJoin.isHost. A promoted speaker gets a
  // mute/unmute control without rejoining, starts MUTED (never auto-
  // unmuted), and loses the control (reverting to "Raise hand") the moment
  // the grant is revoked.

  const speakerJoin = SpaceJoin(
    spaceId: "s1",
    room: "sk-space-s1",
    url: "wss://lk.test/ws",
    identity: "dana@dk.skworld",
    role: "speaker",
    token: "jwt-speaker",
    title: "SKWorld Town Hall",
  );

  const listenerJoin = SpaceJoin(
    spaceId: "s1",
    room: "sk-space-s1",
    url: "wss://lk.test/ws",
    identity: "alice@dk.skworld",
    role: "listener",
    token: "jwt-listener",
    title: "SKWorld Town Hall",
  );

  testWidgets(
      "a non-host participant with the publish grant sees the mute control, not raise hand",
      (tester) async {
    final participants = <LiveKitParticipantSnapshot>[
      _snap("dana@dk.skworld", isLocal: true, canPublish: true),
      _snap("chef@dk.skworld", canPublish: true),
      _snap("alice"), // listener
    ];
    when(() => svc.participants).thenAnswer((_) => Stream.value(participants));
    when(() => svc.currentParticipants).thenReturn(participants);

    await tester.pumpWidget(wrapFor(speakerJoin));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Speaker section (SP2 is UI-only: the mute/unmute control is gated on
    // canPublish, not on the host flag). Connect-time auto-publish is
    // HOST-ONLY (see connect()'s goLive comment), so a non-host speaker
    // always starts muted: "Unmute" is the deterministic label here, not
    // just "some mic control".
    expect(find.text("Raise hand"), findsNothing);
    expect(find.text("Unmute"), findsOneWidget);
    expect(find.text("Mute"), findsNothing);
  });

  testWidgets(
      "a plain listener (no publish grant) sees raise hand, never a mute control",
      (tester) async {
    final participants = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", canPublish: true),
      _snap("alice@dk.skworld", isLocal: true), // listener, no grant
    ];
    when(() => svc.participants).thenAnswer((_) => Stream.value(participants));
    when(() => svc.currentParticipants).thenReturn(participants);

    await tester.pumpWidget(wrapFor(listenerJoin));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text("Raise hand"), findsOneWidget);
    expect(find.text("Mute"), findsNothing);
    expect(find.text("Unmute"), findsNothing);
    // A plain listener must never be put live.
    verifyNever(() => svc.setMicEnabled(true));
  });

  testWidgets(
      "promotion (grant flips to canPublish) enables mic controls WITHOUT a "
      "rejoin, starting MUTED (never auto-unmuted)", (tester) async {
    final controller =
        StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
    addTearDown(controller.close);
    final asListener = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", canPublish: true),
      _snap("alice@dk.skworld", isLocal: true), // not yet promoted
    ];
    when(() => svc.participants).thenAnswer((_) => controller.stream);
    when(() => svc.currentParticipants).thenReturn(asListener);

    await tester.pumpWidget(wrapFor(listenerJoin));
    await tester.pump();
    controller.add(asListener);
    await tester.pump(const Duration(milliseconds: 50));

    // Still a listener: raise hand only, mic never touched.
    expect(find.text("Raise hand"), findsOneWidget);
    verifyNever(() => svc.setMicEnabled(true));

    // Server flips the grant (mutual consent: hand_raised AND invited). No
    // rejoin, no new connectWithToken call, just a fresh snapshot.
    controller.add(<LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", canPublish: true),
      _snap("alice@dk.skworld", isLocal: true, canPublish: true),
    ]);
    await tester.pump(const Duration(milliseconds: 50));

    // The mic control now exists...
    expect(find.text("Raise hand"), findsNothing);
    // ...but starts muted: "Unmute" is shown, never auto-live.
    expect(find.text("Unmute"), findsOneWidget);
    expect(find.text("Mute"), findsNothing);
    verifyNever(() => svc.setMicEnabled(true));
    verify(() => svc.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).called(1); // one connect only, no rejoin on promotion
  });

  testWidgets(
      "demotion (grant revoked) stops publishing and reverts to raise hand; "
      "connect-time auto-publish is HOST-ONLY (a granted speaker starts muted)",
      (tester) async {
    final controller =
        StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
    addTearDown(controller.close);
    // Non-host speaker joining (or rejoining) with a pre-authorized publish
    // grant already on their snapshot.
    final live = <LiveKitParticipantSnapshot>[
      _snap("dana@dk.skworld", isLocal: true, canPublish: true),
      _snap("chef@dk.skworld", canPublish: true),
    ];
    when(() => svc.participants).thenAnswer((_) => controller.stream);
    when(() => svc.currentParticipants).thenReturn(live);

    await tester.pumpWidget(wrapFor(speakerJoin));
    await tester.pump();
    controller.add(live);
    await tester.pump(const Duration(milliseconds: 50));

    // Auto-publish at connect is HOST-ONLY: this speaker holds the grant so
    // the mic control renders, but they start MUTED (no hot-mic surprise on
    // rejoin) and the service mic was never touched.
    expect(find.text("Raise hand"), findsNothing);
    expect(find.text("Unmute"), findsOneWidget);
    expect(find.text("Mute"), findsNothing);
    verifyNever(() => svc.setMicEnabled(true));

    // The speaker self-unmutes (X Spaces model) and goes live.
    await tester.tap(find.text("Unmute"));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("Mute"), findsOneWidget);
    verify(() => svc.setMicEnabled(true)).called(1);

    // Host revokes the grant (removeFromStage): dana's snapshot loses
    // canPublish.
    controller.add(<LiveKitParticipantSnapshot>[
      _snap("dana@dk.skworld", isLocal: true, canPublish: false),
      _snap("chef@dk.skworld", canPublish: true),
    ]);
    await tester.pump(const Duration(milliseconds: 50));

    // Mic control gone, back to raise hand, and the mic was force-stopped.
    expect(find.text("Raise hand"), findsOneWidget);
    expect(find.text("Mute"), findsNothing);
    expect(find.text("Unmute"), findsNothing);
    verify(() => svc.setMicEnabled(false)).called(1);
  });

  // ── IF1: system-audio mutual exclusion must not desync the mic label ──────
  //
  // startScreenShareSystemAudio() enforces "at most one microphone-source
  // publication" by disabling the real mic at the LiveKit layer directly,
  // bypassing toggleMic(). Without an observability seam, SpaceRoomState.
  // isMicEnabled (and therefore the control-bar label) keeps its stale value
  // until the user taps mute/unmute manually. LiveKitCallService.
  // micEnabledChanges is that seam: every mic-enabled flip, whichever path
  // triggers it, funnels through setMicEnabled() and is broadcast there.

  group("IF1 system-audio / mic-label sync", () {
    testWidgets(
        "system audio silently disabling the mic flips the control-bar "
        "label to Unmute without a manual tap", (tester) async {
      final micCtl = StreamController<bool>.broadcast();
      addTearDown(micCtl.close);
      when(() => svc.micEnabledChanges).thenAnswer((_) => micCtl.stream);

      await tester.pumpWidget(wrap()); // host join: mic starts live.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Mute"), findsOneWidget);
      expect(find.text("Unmute"), findsNothing);

      // DECOUPLE: content audio no longer force-disables the real mic (see
      // LiveKitCallService.setMicEnabled), but the control bar must still
      // catch up to ANY externally-driven mic-state emission (e.g. the
      // DECOUPLE mic-default-on-content-share-start path, or a host force-
      // mute) WITHOUT going through toggleMic() itself. Drive the same
      // stream directly to keep this a pure reactivity test.
      micCtl.add(false);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Unmute"), findsOneWidget);
      expect(find.text("Mute"), findsNothing);
    });

    testWidgets(
        "re-enabling the mic while system audio is live flips the label "
        "back to Mute (symmetric direction)", (tester) async {
      final micCtl = StreamController<bool>.broadcast();
      addTearDown(micCtl.close);
      when(() => svc.micEnabledChanges).thenAnswer((_) => micCtl.stream);

      final participants = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld", isLocal: true, canPublish: true),
        _snap("chef@dk.skworld", canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      // Non-host: starts muted (host-only connect-time auto-publish).
      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Unmute"), findsOneWidget);
      expect(find.text("Mute"), findsNothing);

      // The mic gets re-enabled by some path other than this notifier's own
      // toggleMic() (e.g. a host force-unmute reconciliation, or any other
      // future external re-enable); the label must still catch up.
      micCtl.add(true);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Mute"), findsOneWidget);
      expect(find.text("Unmute"), findsNothing);
    });
  });

  // ── DECOUPLE: content audio + independent mic ─────────────────────────────
  //
  // Content audio (TrackSource.screenShareAudio) and the voice mic
  // (TrackSource.microphone) are independent tracks now (see
  // LiveKitCallService.setMicEnabled / startScreenShareSystemAudio): no
  // mutual exclusion. The ONLY UI-level behavior change lives here: default
  // the mic to muted the moment a content share with system audio starts
  // (echo avoidance), show a one-line note while that holds, and never force
  // the mic control itself.
  group("DECOUPLE content-audio / independent-mic UX", () {
    testWidgets(
        "starting a content share with system audio defaults the mic to "
        "muted and shows the echo note; the mic control stays available",
        (tester) async {
      final partCtl =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(partCtl.close);
      final roster = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isSpeaking: true),
      ];
      when(() => svc.participants).thenAnswer((_) => partCtl.stream);
      when(() => svc.currentParticipants).thenReturn(roster);

      await tester.pumpWidget(wrap()); // host join: mic starts live.
      partCtl.add(roster);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Before any content share: mic live, no echo note.
      expect(find.text("Mute"), findsOneWidget);
      expect(find.textContaining("Mic muted to avoid echo"), findsNothing);

      // Content share with system audio starts (whichever widget triggered
      // LiveKitCallService.startScreenShareSystemAudio; this only observes
      // the service-level isSharingSystemAudio flag flipping, so it covers
      // ScreenSharePanel's direct service call just as much as a control-
      // bar-driven path). Re-emit the same roster so the participants
      // listener re-evaluates svc.isSharingSystemAudio.
      when(() => svc.isSharingSystemAudio).thenReturn(true);
      partCtl.add(roster);
      await tester.pump(const Duration(milliseconds: 50));

      // Mic defaulted to muted exactly once, the control relabels, and the
      // echo note appears.
      verify(() => svc.setMicEnabled(false)).called(1);
      expect(find.text("Unmute"), findsOneWidget);
      expect(find.text("Mute"), findsNothing);
      expect(find.textContaining("Mic muted to avoid echo"), findsOneWidget);

      // The mic control remains fully present and tappable (not hidden, not
      // disabled): the note is informational only.
      expect(find.text("Unmute"), findsOneWidget);
    });

    testWidgets(
        "the mic stays independently unmutable while content audio keeps "
        "playing, and the echo note clears once unmuted", (tester) async {
      final partCtl =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(partCtl.close);
      final roster = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isSpeaking: true),
      ];
      when(() => svc.participants).thenAnswer((_) => partCtl.stream);
      when(() => svc.currentParticipants).thenReturn(roster);
      when(() => svc.isSharingSystemAudio).thenReturn(true);

      await tester.pumpWidget(wrap());
      partCtl.add(roster);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Content audio was already live at connect time: mic defaulted muted
      // (via connect()'s own goLive setMicEnabled(true) immediately followed
      // by the DECOUPLE default-mute setMicEnabled(false); both already
      // happened by now, so clear the mock's recorded calls and only assert
      // on what happens from the Unmute tap onward).
      expect(find.text("Unmute"), findsOneWidget);
      expect(find.textContaining("Mic muted to avoid echo"), findsOneWidget);
      clearInteractions(svc);

      // Tap Unmute: the mic control is fully independent, so this must work
      // even while content audio keeps sharing (isSharingSystemAudio stays
      // true throughout; only the mic state changes).
      await tester.tap(find.text("Unmute"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setMicEnabled(true)).called(1);
      // stopScreenShareSystemAudio must never be called by unmuting: the
      // old mutual exclusion (mic-on stops content audio) is gone.
      verifyNever(() => svc.stopScreenShareSystemAudio());
      expect(find.text("Mute"), findsOneWidget);
      // The note is specifically "muted to avoid echo"; once unmuted it no
      // longer applies.
      expect(find.textContaining("Mic muted to avoid echo"), findsNothing);
    });

    testWidgets(
        "content audio stopping does not auto-unmute the mic (X model: only "
        "the explicit tap unmutes)", (tester) async {
      final partCtl =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(partCtl.close);
      final roster = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isSpeaking: true),
      ];
      when(() => svc.participants).thenAnswer((_) => partCtl.stream);
      when(() => svc.currentParticipants).thenReturn(roster);

      await tester.pumpWidget(wrap());
      partCtl.add(roster);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Content share starts: mic defaults muted.
      when(() => svc.isSharingSystemAudio).thenReturn(true);
      partCtl.add(roster);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text("Unmute"), findsOneWidget);
      // Only assert on what happens from here (the stop transition): clear
      // the calls made so far (connect()'s own goLive setMicEnabled(true)
      // plus the default-mute setMicEnabled(false)).
      clearInteractions(svc);

      // Content share stops.
      when(() => svc.isSharingSystemAudio).thenReturn(false);
      partCtl.add(roster);
      await tester.pump(const Duration(milliseconds: 50));

      // X model: nothing auto-unmutes. The mic is still muted (only the
      // explicit tap would change it), and the echo note is gone now that
      // there is no content audio to echo.
      expect(find.text("Unmute"), findsOneWidget);
      expect(find.textContaining("Mic muted to avoid echo"), findsNothing);
      // The stop transition itself never touches the mic at all.
      verifyNever(() => svc.setMicEnabled(any()));
    });
  });

  // ── SP4: host moderation controls (mute + demote) ─────────────────────────
  //
  // X Spaces model: the host can force-MUTE a live speaker (one-directional,
  // the speaker must self-unmute; force-unmute does not exist) and can DEMOTE
  // a speaker off the stage (removeFromStage revokes the publish grant; the
  // SP2 grant-flip listener then force-stops their mic client-side). The
  // actions live in the per-tile host sheet, are host-only, never appear on
  // the host's own tile, and mute/demote only target on-stage (canPublish)
  // participants.

  group("SP4 host moderation", () {
    testWidgets(
        "host sees Mute mic + Remove from stage on a speaker tile, and no "
        "Invite to speak for someone already on stage", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        _snap("dana", canPublish: true), // live remote speaker
        _snap("alice"), // listener
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The host's OWN tile has no moderation sheet.
      await tester.tap(find.text("You"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Remove from Space"), findsNothing);
      expect(find.text("Mute mic"), findsNothing);

      // Tap the live speaker's tile: moderation sheet with mute + demote.
      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Mute mic"), findsOneWidget);
      expect(find.text("Remove from stage"), findsOneWidget);
      expect(find.text("Remove from Space"), findsOneWidget);
      // Already on stage: no invite action.
      expect(find.text("Invite to speak"), findsNothing);
    });

    testWidgets(
        "a listener tile offers Invite to speak but never mute or demote",
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("alice"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Invite to speak"), findsOneWidget);
      expect(find.text("Mute mic"), findsNothing);
      expect(find.text("Remove from stage"), findsNothing);
      expect(find.text("Remove from Space"), findsOneWidget);
    });

    testWidgets(
        "Mute mic calls SpacesService.mute with the speaker identity and "
        "their live mic track sid", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        _snap("dana", canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      // Live room graph: dana has a published mic track with a known sid.
      final room = MockRoom();
      final dana = MockRemoteParticipant();
      final micPub = MockRemoteTrackPublication();
      when(() => micPub.sid).thenReturn("TR_MIC_DANA");
      when(() => dana.getTrackPublicationBySource(TrackSource.microphone))
          .thenReturn(micPub);
      when(() => dana.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => room.remoteParticipants).thenReturn(
          UnmodifiableMapView<String, RemoteParticipant>({"dana": dana}));
      when(() => room.localParticipant).thenReturn(null);
      when(() => svc.room).thenReturn(room);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text("Mute mic"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      verify(() => spaces.mute(
            "s1",
            requester: "chef@dk.skworld",
            identity: "dana",
            trackSid: "TR_MIC_DANA",
          )).called(1);
    });

    testWidgets(
        "Remove from stage calls the demote endpoint with the right identity",
        (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        _snap("dana", canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text("Remove from stage"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      verify(() => spaces.removeFromStage(
            "s1",
            requester: "chef@dk.skworld",
            identity: "dana",
          )).called(1);
      verifyNever(() => spaces.mute(
            any(),
            requester: any(named: "requester"),
            identity: any(named: "identity"),
            trackSid: any(named: "trackSid"),
          ));
    });

    testWidgets("a non-host never gets moderation actions on any tile",
        (tester) async {
      const speakerJoin = SpaceJoin(
        spaceId: "s1",
        room: "sk-space-s1",
        url: "wss://lk.test/ws",
        identity: "dana@dk.skworld",
        role: "speaker",
        token: "jwt-speaker",
        title: "SKWorld Town Hall",
      );
      final participants = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld", isLocal: true, canPublish: true),
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice"),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Tapping another speaker's tile as a NON-host opens nothing.
      await tester.tap(find.text("chef@dk.skworld"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Mute mic"), findsNothing);
      expect(find.text("Remove from stage"), findsNothing);
      expect(find.text("Remove from Space"), findsNothing);

      // Nor does a listener tile.
      await tester.tap(find.text("alice"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Invite to speak"), findsNothing);
      expect(find.text("Remove from Space"), findsNothing);
    });

    testWidgets(
        "Mute mic on a speaker with no published mic track shows feedback "
        "instead of silently no-op'ing", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        // Promoted speaker who never went live: no mic publication yet.
        _snap("dana", canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      // Live room graph with NO entry for dana, so the mic-track-sid lookup
      // resolves null (never published).
      final room = MockRoom();
      when(() => room.remoteParticipants).thenReturn(
          UnmodifiableMapView<String, RemoteParticipant>({}));
      when(() => room.localParticipant).thenReturn(null);
      when(() => svc.room).thenReturn(room);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text("Mute mic"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text("No live mic to mute"), findsOneWidget);
      verifyNever(() => spaces.mute(
            any(),
            requester: any(named: "requester"),
            identity: any(named: "identity"),
            trackSid: any(named: "trackSid"),
          ));
    });

    testWidgets(
        "mute is one-directional: a self-muted speaker's sheet offers NO "
        "unmute-participant action anywhere", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        // dana self-muted but still on stage.
        _snap("dana", canPublish: true, isMuted: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // The sheet is up (demote is offered) but no unmute action exists.
      // The host's own control bar reads "Mute" here (host mic live), so
      // "Unmute" appearing anywhere would be a moderation leak.
      expect(find.text("Remove from stage"), findsOneWidget);
      expect(find.textContaining("Unmute"), findsNothing);
    });
  });

  // ── M1: server-initiated host mute must be visible to the muted speaker ──
  //
  // Today the label reconciliation (IF1, above) already covers ANY
  // micEnabledChanges emission, including a server-initiated mute. What was
  // missing is the "someone else did this" notice: LiveKitCallService
  // additionally emits on the dedicated externalMuteEvents stream when the
  // mute came from the server (a host force-mute) rather than a local
  // toggle, and the screen surfaces that as a snackbar.

  group("M1 host mute reconciliation", () {
    testWidgets(
        "a server-initiated mute (host force-mute) flips the label to "
        "Unmute and shows a 'Muted by host' notice", (tester) async {
      final micCtl = StreamController<bool>.broadcast();
      final extMuteCtl = StreamController<void>.broadcast();
      addTearDown(micCtl.close);
      addTearDown(extMuteCtl.close);
      when(() => svc.micEnabledChanges).thenAnswer((_) => micCtl.stream);
      when(() => svc.externalMuteEvents).thenAnswer((_) => extMuteCtl.stream);

      await tester.pumpWidget(wrap()); // host join: mic starts live.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Mute"), findsOneWidget);
      expect(find.text("Muted by host"), findsNothing);

      // The service reconciles a server-initiated mute (MuteRoomTrackRequest
      // targeting our OWN mic) by emitting on both streams: the boolean flip
      // on micEnabledChanges, and the "external" signal on externalMuteEvents.
      micCtl.add(false);
      extMuteCtl.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Unmute"), findsOneWidget);
      expect(find.text("Mute"), findsNothing);
      expect(find.text("Muted by host"), findsOneWidget);
    });

    testWidgets(
        "a self-initiated mute (own toggle) never shows the 'Muted by "
        "host' notice", (tester) async {
      final micCtl = StreamController<bool>.broadcast();
      addTearDown(micCtl.close);
      when(() => svc.micEnabledChanges).thenAnswer((_) => micCtl.stream);
      // externalMuteEvents stays the default empty stream (see setUp): a
      // plain toggle never touches it, only the server-mute path does.

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Mute"), findsOneWidget);

      await tester.tap(find.text("Mute"));
      await tester.pump();
      micCtl.add(false); // toggleMic's own setMicEnabled(false) call.
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Unmute"), findsOneWidget);
      expect(find.text("Muted by host"), findsNothing);
    });
  });

  // ── M9: the Spaces "Go live" control must resolve its capture source
  // through screenShareSourceResolverProvider, the same DI seam M2 wired
  // into conf_screen.dart / livekit_call_screen.dart, so a provider override
  // reaches this entry point too and tests never touch the real
  // desktopCapturer platform channel.
  //
  // CAM: "Go live" now opens a source chooser first (Camera front/back,
  // Screen share desktop-only) instead of resolving a screen share
  // directly, so these tests tap "Go live" then the "Screen share" chooser
  // option before asserting the resolver / setScreenShareEnabled behavior.

  group("M9 screen-share resolver DI", () {
    testWidgets(
        "tapping Go live then Screen share resolves the source through the "
        "injected fake resolver and passes the chosen sourceId to "
        "setScreenShareEnabled", (tester) async {
      var resolverCalls = 0;
      Future<({bool proceed, String? sourceId})> fakeResolver(
          BuildContext context) async {
        resolverCalls++;
        return (proceed: true, sourceId: "screen:9");
      }

      await tester.pumpWidget(wrapFor(join, extraOverrides: [
        screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Screen share"));
      await tester.pump(const Duration(milliseconds: 50));

      expect(resolverCalls, 1);
      verify(() => svc.setScreenShareEnabled(true,
          systemAudioDeviceId: null, sourceId: "screen:9")).called(1);
    });

    testWidgets(
        "Go live then Screen share CARRIES DESKTOP AUDIO: the auto-selected "
        "system-audio device is passed, so content audio rides its own track",
        (tester) async {
      // The control bar is the primary way a host goes live in a Space, but it
      // used to publish video only, with no systemAudioDeviceId. Listeners then
      // heard nothing but the host's microphone, which drove hosts to point the
      // MIC input at the loopback device as a workaround. That collapses both
      // into one track: muting the mic then kills the content audio, and the
      // real microphone stops working. Content audio must be its own track.
      Future<({bool proceed, String? sourceId})> fakeResolver(
              BuildContext context) async =>
          (proceed: true, sourceId: "screen:9");

      when(() => svc.defaultSystemAudioSource()).thenAnswer((_) async =>
          MediaDevice("c41d0a9b77e2", "Kodi-Cast-Loopback", "audioinput", null));

      await tester.pumpWidget(wrapFor(join, extraOverrides: [
        screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Screen share"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setScreenShareEnabled(true,
          systemAudioDeviceId: "c41d0a9b77e2",
          sourceId: "screen:9")).called(1);
    });

    testWidgets(
        "a failure resolving the system-audio device still starts the share",
        (tester) async {
      // Content audio is best effort: no desktop audio is worse than no share.
      Future<({bool proceed, String? sourceId})> fakeResolver(
              BuildContext context) async =>
          (proceed: true, sourceId: "screen:9");

      when(() => svc.defaultSystemAudioSource())
          .thenThrow(Exception("enumerateDevices blew up"));

      await tester.pumpWidget(wrapFor(join, extraOverrides: [
        screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Screen share"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setScreenShareEnabled(true,
          systemAudioDeviceId: null, sourceId: "screen:9")).called(1);
      expect(find.textContaining("Screen share failed"), findsNothing);
    });

    testWidgets(
        "cancelling the injected resolver is a silent no-op: no share call, "
        "no error toast", (tester) async {
      Future<({bool proceed, String? sourceId})> cancelResolver(
              BuildContext context) async =>
          (proceed: false, sourceId: null);

      await tester.pumpWidget(wrapFor(join, extraOverrides: [
        screenShareSourceResolverProvider.overrideWithValue(cancelResolver),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Screen share"));
      await tester.pump(const Duration(milliseconds: 50));

      verifyNever(() => svc.setScreenShareEnabled(any(),
          systemAudioDeviceId: any(named: "systemAudioDeviceId"),
          sourceId: any(named: "sourceId")));
      expect(find.textContaining("Screen share failed"), findsNothing);
      expect(find.text("Go live"), findsOneWidget);
    });
  });

  // ── Z1: mobile-web screen-share origination is impossible (no
  // getDisplayMedia on a phone browser). CAM: the "Go live" chooser now
  // hides the Screen share option entirely on mobile web (instead of the
  // old immediate friendly-message short-circuit), showing only the camera
  // options; picking a camera reaches the real go-live path there. Desktop
  // still offers Screen share and resolves it exactly as before.

  group("Z1 mobile-web Go live guard", () {
    testWidgets(
        "on mobile web, the Go live chooser hides Screen share and shows "
        "only the camera options", (tester) async {
      var resolverCalls = 0;
      Future<({bool proceed, String? sourceId})> fakeResolver(
          BuildContext context) async {
        resolverCalls++;
        return (proceed: true, sourceId: null);
      }

      await tester.pumpWidget(wrapFor(join, extraOverrides: [
        isMobileWebProvider.overrideWithValue(true),
        screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();

      expect(find.text("Camera (front)"), findsOneWidget);
      expect(find.text("Camera (back)"), findsOneWidget);
      expect(find.text("Screen share"), findsNothing);

      // Dismiss without picking: never touches the screen-share path.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(resolverCalls, 0);
      verifyNever(() => svc.setScreenShareEnabled(any(),
          systemAudioDeviceId: any(named: "systemAudioDeviceId"),
          sourceId: any(named: "sourceId")));
      // Never the raw LiveKit exception text, and never the old
      // "needs the desktop app" message either (nothing ever tried to
      // originate a share on mobile).
      expect(find.textContaining("Screen share failed"), findsNothing);
      expect(find.textContaining("LiveKit"), findsNothing);
      // The button stays put, not stuck mid-share.
      expect(find.text("Go live"), findsOneWidget);
    });

    testWidgets(
        "on desktop (isMobileWebProvider false), the chooser offers Screen "
        "share and picking it still resolves the source and starts the "
        "share as before", (tester) async {
      var resolverCalls = 0;
      Future<({bool proceed, String? sourceId})> fakeResolver(
          BuildContext context) async {
        resolverCalls++;
        return (proceed: true, sourceId: "screen:1");
      }

      await tester.pumpWidget(wrapFor(join, extraOverrides: [
        isMobileWebProvider.overrideWithValue(false),
        screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();

      expect(find.text("Screen share"), findsOneWidget);

      await tester.tap(find.text("Screen share"));
      await tester.pump(const Duration(milliseconds: 50));

      expect(resolverCalls, 1);
      verify(() => svc.setScreenShareEnabled(true,
          systemAudioDeviceId: null, sourceId: "screen:1")).called(1);
      expect(
        find.textContaining("Screen sharing needs the desktop app"),
        findsNothing,
      );
    });
  });

  // ── CAM: Spaces "Go live" with camera (front/back), plus the source
  // chooser. Mobile browsers cannot screen-share (Z1), but CAN publish a
  // camera (getUserMedia), so "Go live" now offers Camera (front, default) /
  // Camera (back) / Screen (desktop only) everywhere. Camera XOR screen:
  // choosing one stops the other; "Go live" becomes "Stop" while either is
  // live; a Flip control appears only while the camera is the live source.

  group("CAM camera go-live", () {
    testWidgets(
        "picking Camera (front) publishes with front facing (the chooser's "
        "default)", (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Camera (front)"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setCameraEnabled(true,
          cameraPosition: CameraPosition.front)).called(1);
    });

    testWidgets("picking Camera (back) publishes with back facing",
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Camera (back)"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setCameraEnabled(true,
          cameraPosition: CameraPosition.back)).called(1);
    });

    testWidgets(
        "dismissing the chooser without a pick never calls setCameraEnabled "
        "or setScreenShareEnabled", (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      // Tap the scrim outside the sheet content to dismiss without a pick.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      verifyNever(() => svc.setCameraEnabled(any(),
          cameraPosition: any(named: "cameraPosition")));
      verifyNever(() => svc.setScreenShareEnabled(any(),
          systemAudioDeviceId: any(named: "systemAudioDeviceId"),
          sourceId: any(named: "sourceId")));
      expect(find.text("Go live"), findsOneWidget);
    });

    testWidgets(
        "while the camera is live, the control relabels to Stop and a Flip "
        "control appears; Flip switches the live camera's facing",
        (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isCameraEnabled: true),
        _snap("alice"),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Stop"), findsOneWidget);
      expect(find.text("Go live"), findsNothing);
      expect(find.text("Flip"), findsOneWidget);

      await tester.tap(find.text("Flip"));
      await tester.pump(const Duration(milliseconds: 50));

      // Front is the chooser's implicit default facing at connect time (no
      // go-live tap happened in this test), so the first flip targets back.
      verify(() => svc.switchCameraPosition(CameraPosition.back)).called(1);
    });

    testWidgets(
        "Flip is never shown while a screen share (not camera) is the live "
        "source", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isScreenSharing: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Stop"), findsOneWidget);
      expect(find.text("Flip"), findsNothing);
    });

    testWidgets(
        "Stop while the camera is live tears down the camera, not the "
        "screen share", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isCameraEnabled: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Stop"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setCameraEnabled(false)).called(1);
      verifyNever(() => svc.setScreenShareEnabled(any(),
          systemAudioDeviceId: any(named: "systemAudioDeviceId"),
          sourceId: any(named: "sourceId")));
    });

    testWidgets(
        "Stop while the screen share is live tears down the screen, not "
        "the camera", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld",
            isLocal: true, canPublish: true, isScreenSharing: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Stop"));
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setScreenShareEnabled(false)).called(1);
      verifyNever(() => svc.setCameraEnabled(false));
    });

    testWidgets(
        "a getUserMedia permission deny / no-camera error shows a plain "
        "non-blocking message, mirroring the mic error handling",
        (tester) async {
      when(() => svc.setCameraEnabled(any(),
              cameraPosition: any(named: "cameraPosition")))
          .thenThrow(Exception("NotAllowedError"));

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("Go live"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Camera (front)"));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining("Camera unavailable"), findsOneWidget);
      // Non-blocking: the control stays put, not stuck mid-attempt.
      expect(find.text("Go live"), findsOneWidget);
    });
  });

  // ── W1: Share action, invites others to the Space via a skchat chat, the
  // OS native share sheet, or copy-link. The button lives in the header next
  // to the title, visible to every role (host AND listener alike, it is not
  // a moderation action), and opens space_share_sheet.dart's bottom sheet.

  group("W1 Share Space", () {
    testWidgets(
        "the host sees the Share button and it opens the Share Space sheet",
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byTooltip("Share Space"), findsOneWidget);

      await tester.tap(find.byTooltip("Share Space"));
      await tester.pumpAndSettle();

      expect(find.text("Share to skchat chat"), findsOneWidget);
      expect(find.text("Share via..."), findsOneWidget);
      expect(find.text("Copy link"), findsOneWidget);
    });

    testWidgets(
        "a plain listener (no publish grant) also sees the Share button",
        (tester) async {
      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byTooltip("Share Space"), findsOneWidget);

      await tester.tap(find.byTooltip("Share Space"));
      await tester.pumpAndSettle();

      expect(find.text("Share to skchat chat"), findsOneWidget);
      expect(find.text("Share via..."), findsOneWidget);
      expect(find.text("Copy link"), findsOneWidget);
    });
  });

  // ── X1: invited-to-stage "Join stage" prompt ──────────────────────────────
  //
  // Bug (operator report): host taps "Invite to speak" on a listener, the
  // guest sees NOTHING and never becomes a speaker. Server model
  // (moderation.py, recon-verified): metadata carries {"hand_raised",
  // "invited_to_stage"}; canPublish flips only once BOTH are true (the
  // AND-gate). A host invite alone sets invited_to_stage, which previously
  // surfaced nowhere client-side. Accepting is simply calling the existing
  // raise-hand endpoint again (completes the gate).

  group("X1 invited-to-stage prompt", () {
    testWidgets(
        "shows the banner and relabels the control-bar button exactly when "
        "invited, hand not yet raised, and not yet on stage", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true), // host
        _snap("alice@dk.skworld", isLocal: true, invitedToStage: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("The host invited you to speak."), findsOneWidget);
      expect(find.text("Not now"), findsOneWidget);
      // Control-bar button relabelled too (SP2's "Raise hand" is gone).
      expect(find.text("Raise hand"), findsNothing);
      expect(find.text("Join stage"), findsNWidgets(2)); // banner + control bar
    });

    testWidgets(
        "does NOT show once the gate has completed (canPublish true): SP2 "
        "mute controls take over instead", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld",
            isLocal: true, invitedToStage: true, canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("The host invited you to speak."), findsNothing);
      expect(find.text("Join stage"), findsNothing);
      expect(find.text("Unmute"), findsOneWidget);
    });

    testWidgets(
        "does NOT show once the hand is already raised (accept already in "
        "flight / a recording-consent revert kept them a listener)",
        (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld",
            isLocal: true, invitedToStage: true, handRaised: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("The host invited you to speak."), findsNothing);
      // Falls back to the ordinary raise-hand control (the control bar's
      // "Lower"/"Raise hand" label tracks SpaceRoomState.handRaised, the
      // notifier's own request-in-flight bookkeeping, not the server-
      // sourced snapshot flag used for the AND-gate condition above), not a
      // "Join stage" relabel.
      expect(find.text("Join stage"), findsNothing);
    });

    testWidgets("does NOT show for a plain, uninvited listener",
        (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld", isLocal: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("The host invited you to speak."), findsNothing);
      expect(find.text("Raise hand"), findsOneWidget);
    });

    testWidgets(
        "Join stage in the banner calls raiseHand exactly once with the "
        "guest's identity", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld", isLocal: true, invitedToStage: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);
      when(() => spaces.raiseHand(any(), identity: "alice@dk.skworld"))
          .thenAnswer((_) async => true);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.widgetWithText(FilledButton, "Join stage"));
      await tester.pump();

      verify(() =>
              spaces.raiseHand(any(), identity: "alice@dk.skworld"))
          .called(1);
    });

    testWidgets(
        "Not now dismisses the banner locally without calling raiseHand, "
        "and the control-bar button stays the accept path", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld", isLocal: true, invitedToStage: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("The host invited you to speak."), findsOneWidget);

      await tester.tap(find.text("Not now"));
      await tester.pump();

      expect(find.text("The host invited you to speak."), findsNothing);
      verifyNever(
          () => spaces.raiseHand(any(), identity: any(named: "identity")));
      // The banner's FilledButton is gone, but the control bar's own
      // "Join stage" affordance survives the local dismissal.
      expect(find.text("Join stage"), findsOneWidget);
    });

    testWidgets(
        "re-prompts on a FRESH invite (false -> true again) even after an "
        "earlier dismissal", (tester) async {
      final controller =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(controller.close);
      final invited = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld", isLocal: true, invitedToStage: true),
      ];
      final notInvited = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", canPublish: true),
        _snap("alice@dk.skworld", isLocal: true), // invite cleared
      ];
      when(() => svc.participants).thenAnswer((_) => controller.stream);
      when(() => svc.currentParticipants).thenReturn(invited);

      await tester.pumpWidget(wrapFor(listenerJoin));
      await tester.pump();
      controller.add(invited);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text("The host invited you to speak."), findsOneWidget);

      await tester.tap(find.text("Not now"));
      await tester.pump();
      expect(find.text("The host invited you to speak."), findsNothing);

      // The invite clears entirely (e.g. the host rescinds it).
      controller.add(notInvited);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text("The host invited you to speak."), findsNothing);

      // A FRESH invite (false -> true again): must re-arm even though the
      // PREVIOUS invite was dismissed.
      controller.add(invited);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text("The host invited you to speak."), findsOneWidget);
    });
  });

  // ── Y3: lanes menu is a draggable, scrollable, safe-area-aware sheet ──────
  //
  // Operator bug (mobile Safari): the tools menu (Chat / Watch together /
  // Whiteboard / Shared doc / Screen share / Terminal) was a fixed Column in
  // a plain modal sheet, so the lower tiles were cut off behind the browser
  // chrome on a short viewport with no way to scroll or drag to reach them.
  // Fixed by hosting the tiles in a DraggableScrollableSheet with a grab
  // handle, its own ListView scroll controller, and bottom-safe-area padding.
  group("Y3 lanes menu: draggable, scrollable, safe-area-aware sheet", () {
    testWidgets(
        "opens as a DraggableScrollableSheet with a grab handle and all six "
        "lanes reachable, scrolling to reveal Terminal", (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.dashboard_customize_outlined));
      await tester.pumpAndSettle();

      // Draggable up/down by default, with a tactile grab handle.
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.byKey(const Key("lanesGrabHandle")), findsOneWidget);

      // The first lanes are visible without scrolling.
      expect(find.text("Chat"), findsOneWidget);
      expect(find.text("Watch together"), findsOneWidget);

      // Terminal is the last tile; it must be reachable by scrolling the
      // sheet's own list, never cut off with no way to reach it.
      await tester.scrollUntilVisible(
        find.text("Terminal"),
        100.0,
        scrollable: find.descendant(
          of: find.byKey(const Key("lanesList")),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text("Terminal"), findsOneWidget);
      expect(find.text("Whiteboard"), findsOneWidget);
      expect(find.text("Shared doc"), findsOneWidget);
      expect(find.text("Screen share"), findsOneWidget);
    });

    testWidgets(
        "tapping a lane tile pops the sheet and opens that lane's panel",
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.dashboard_customize_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);

      await tester.tap(find.text("Chat"));
      await tester.pumpAndSettle();

      // The lanes sheet is gone (popped)...
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      // ...and the lane's own panel opened in its place (_openLane path,
      // untouched by this change).
      expect(find.byType(SpaceChatPanel), findsOneWidget);
    });
  });

  // ── SHARECTL-app: host-controlled per-speaker video sharing ──────────────
  //
  // The host can revoke a speaker's video sharing (camera + screen-share)
  // while leaving their mic alone, and re-allow it. Two surfaces:
  // - Host sheet (per-speaker, host-only): "Disable sharing" / "Allow
  //   sharing", reflecting the target's current
  //   LiveKitParticipantSnapshot.canPublishVideo and calling
  //   SpacesService.setSharing with the flipped allow value.
  // - The (possibly local) speaker's own "Go live": hidden with a short
  //   note the moment their OWN canPublishVideo goes false; mic mute/
  //   unmute is untouched (a separate LiveKit grant, canPublish).
  group("SHARECTL-app host-controlled sharing", () {
    testWidgets(
        "host sheet offers Disable sharing for a speaker who can currently "
        "share, and it calls setSharing with allow=false", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        _snap("dana", canPublish: true), // canPublishVideo defaults true
        _snap("alice"), // listener
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Disable sharing"), findsOneWidget);
      expect(find.text("Allow sharing"), findsNothing);

      await tester.tap(find.text("Disable sharing"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      verify(() => spaces.setSharing(
            "s1",
            requester: "chef@dk.skworld",
            identity: "dana",
            allow: false,
          )).called(1);
    });

    testWidgets(
        "host sheet offers Allow sharing for a speaker whose sharing is "
        "already disabled, and it calls setSharing with allow=true",
        (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        _snap("dana", canPublish: true, canPublishVideo: false),
        _snap("alice"),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text("dana"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Allow sharing"), findsOneWidget);
      expect(find.text("Disable sharing"), findsNothing);

      await tester.tap(find.text("Allow sharing"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      verify(() => spaces.setSharing(
            "s1",
            requester: "chef@dk.skworld",
            identity: "dana",
            allow: true,
          )).called(1);
    });

    testWidgets(
        "the sharing toggle never appears on the host's own tile or a "
        "listener tile", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true),
        _snap("dana", canPublish: true),
        _snap("alice"), // listener
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Host's own tile: no moderation sheet at all.
      await tester.tap(find.text("You"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Disable sharing"), findsNothing);
      expect(find.text("Allow sharing"), findsNothing);

      // Listener tile: Invite to speak only, no sharing toggle.
      await tester.tap(find.text("alice"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text("Invite to speak"), findsOneWidget);
      expect(find.text("Disable sharing"), findsNothing);
      expect(find.text("Allow sharing"), findsNothing);
    });

    testWidgets(
        "a local speaker whose own sharing is disabled sees Go live hidden "
        "with a note, and keeps mute/unmute", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld",
            isLocal: true, canPublish: true, canPublishVideo: false),
        _snap("chef@dk.skworld", canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Go live"), findsNothing);
      expect(find.text("Stop"), findsNothing);
      expect(find.text("The host turned off your sharing"), findsOneWidget);
      // Mic control (canPublish is untouched) stays available: dana starts
      // MUTED (SP2 default), so the control reads "Unmute".
      expect(find.text("Unmute"), findsOneWidget);
    });

    testWidgets(
        "re-allowing sharing (canPublishVideo true again) restores Go live "
        "and clears the note", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld", isLocal: true, canPublish: true),
        _snap("chef@dk.skworld", canPublish: true),
      ];
      when(() => svc.participants)
          .thenAnswer((_) => Stream.value(participants));
      when(() => svc.currentParticipants).thenReturn(participants);

      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Go live"), findsOneWidget);
      expect(find.text("The host turned off your sharing"), findsNothing);
    });

    // SHARECTL-app follow-up: the host can disable sharing WHILE the
    // speaker is already live. The Stop control is the same _RoundButton
    // as Go live (gated on canPublishVideo), so it disappears the instant
    // the grant flips, leaving no in-app way to stop an already-live
    // share. The notifier's participants listener now auto-stops the live
    // video source the moment the LOCAL canPublishVideo flips true ->
    // false, mirroring the existing demotion auto-mute pattern.
    testWidgets(
        "a live camera share auto-stops the moment the host disables "
        "sharing mid-session, and mic mute/unmute stays available",
        (tester) async {
      final controller =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(controller.close);
      final live = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld",
            isLocal: true, canPublish: true, isCameraEnabled: true),
        _snap("chef@dk.skworld", canPublish: true),
      ];
      when(() => svc.participants).thenAnswer((_) => controller.stream);
      when(() => svc.currentParticipants).thenReturn(live);

      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      controller.add(live);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Stop"), findsOneWidget);

      // Host disables sharing WHILE dana is still live on camera: the
      // server permission update arrives before the local track actually
      // unpublishes (the exact race this fix closes), so the snapshot
      // still reports isCameraEnabled true alongside canPublishVideo:
      // false.
      controller.add(<LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld",
            isLocal: true,
            canPublish: true,
            isCameraEnabled: true,
            canPublishVideo: false),
        _snap("chef@dk.skworld", canPublish: true),
      ]);
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setCameraEnabled(false)).called(1);
      verifyNever(() => svc.setScreenShareEnabled(any(),
          systemAudioDeviceId: any(named: "systemAudioDeviceId"),
          sourceId: any(named: "sourceId")));
      // No stuck/absent control: Stop and Go live are both gone (the
      // canPublishVideo gate), the disabled note shows instead, and mic
      // mute/unmute is untouched.
      expect(find.text("Stop"), findsNothing);
      expect(find.text("Go live"), findsNothing);
      expect(find.text("The host turned off your sharing"), findsOneWidget);
      expect(find.text("Unmute"), findsOneWidget);
    });

    testWidgets(
        "a live screen share auto-stops the moment the host disables "
        "sharing mid-session", (tester) async {
      final controller =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(controller.close);
      final live = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld",
            isLocal: true, canPublish: true, isScreenSharing: true),
        _snap("chef@dk.skworld", canPublish: true),
      ];
      when(() => svc.participants).thenAnswer((_) => controller.stream);
      when(() => svc.currentParticipants).thenReturn(live);

      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      controller.add(live);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("Stop"), findsOneWidget);

      controller.add(<LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld",
            isLocal: true,
            canPublish: true,
            isScreenSharing: true,
            canPublishVideo: false),
        _snap("chef@dk.skworld", canPublish: true),
      ]);
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => svc.setScreenShareEnabled(false)).called(1);
      verifyNever(() => svc.setCameraEnabled(any(),
          cameraPosition: any(named: "cameraPosition")));
      expect(find.text("Stop"), findsNothing);
      expect(find.text("The host turned off your sharing"), findsOneWidget);
      expect(find.text("Unmute"), findsOneWidget);
    });

    testWidgets(
        "sharing disabled while NOT live calls no stop path (nothing to "
        "stop, no spurious call)", (tester) async {
      final controller =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(controller.close);
      final notLive = <LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld", isLocal: true, canPublish: true),
        _snap("chef@dk.skworld", canPublish: true),
      ];
      when(() => svc.participants).thenAnswer((_) => controller.stream);
      when(() => svc.currentParticipants).thenReturn(notLive);

      await tester.pumpWidget(wrapFor(speakerJoin));
      await tester.pump();
      controller.add(notLive);
      await tester.pump(const Duration(milliseconds: 50));

      controller.add(<LiveKitParticipantSnapshot>[
        _snap("dana@dk.skworld",
            isLocal: true, canPublish: true, canPublishVideo: false),
        _snap("chef@dk.skworld", canPublish: true),
      ]);
      await tester.pump(const Duration(milliseconds: 50));

      verifyNever(() => svc.setCameraEnabled(any(),
          cameraPosition: any(named: "cameraPosition")));
      verifyNever(() => svc.setScreenShareEnabled(any(),
          systemAudioDeviceId: any(named: "systemAudioDeviceId"),
          sourceId: any(named: "sourceId")));
    });
  });

  group("Watch Together stage placement", () {
    testWidgets(
        "the watch surface stays mounted (same State, just Offstage) while "
        "live video owns the stage, and comes back visible without a "
        "remount once the live video ends", (tester) async {
      final participants = <LiveKitParticipantSnapshot>[
        _snap("chef@dk.skworld", isLocal: true, canPublish: true), // host
        _snap("dana", canPublish: true), // has the live camera
      ];
      final rosterCtl =
          StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
      addTearDown(rosterCtl.close);
      when(() => svc.participants).thenAnswer((_) => rosterCtl.stream);
      when(() => svc.currentParticipants).thenReturn(participants);

      // Live room graph: dana has a published camera track. No screen
      // share, and no local participant (never needed: chef never publishes
      // video in this test), mirroring the "Mute mic" test's room stubbing.
      final room = MockRoom();
      final dana = MockRemoteParticipant();
      final camPub = MockRemoteTrackPublication();
      final fakeTrack = _FakeVideoTrack();
      // VideoTrackRenderer (livekit_client) calls these synchronously in
      // initState/dispose regardless of whether the platform-channel render
      // path ever succeeds, so mocktail needs real stubs, not just an
      // unstubbed Mock's default null. Both are @internal to livekit_client
      // (meant for VideoTrackRenderer's own use, not a public track API),
      // hence the ignores; stubbing them here is a test-only concession to
      // that package boundary, not a call site pretending they are public.
      // ignore: invalid_use_of_internal_member
      when(() => fakeTrack.addViewKey()).thenReturn(GlobalKey());
      // ignore: invalid_use_of_internal_member
      when(() => fakeTrack.removeViewKey(any())).thenAnswer((_) {});
      when(() => camPub.track).thenReturn(fakeTrack);
      when(() => dana.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(camPub);
      when(() => dana.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => room.remoteParticipants).thenReturn(
          UnmodifiableMapView<String, RemoteParticipant>({"dana": dana}));
      when(() => room.localParticipant).thenReturn(null);
      when(() => svc.room).thenReturn(room);

      await tester.pumpWidget(wrap());
      await tester.pump();
      rosterCtl.add(participants);
      await tester.pump(const Duration(milliseconds: 50));

      // Live video is up, but nobody has loaded a watch video yet: the
      // watch surface is not in the tree at all, matching pre-Task-4
      // behavior for a plain live-video stage.
      expect(find.byType(WatchVideo), findsNothing);

      // Load a video through the SAME shared session _WatchTogetherStage
      // reads (space_room_screen.dart), so the room now has an active watch
      // session underneath the live camera. A YouTube URL keeps this on the
      // controller's embed-only path (watch_video_stub.dart), so no real
      // video_player / platform channel is touched.
      final context = tester.element(find.byType(SpaceRoomScreen));
      final container = ProviderScope.containerOf(context);
      const watchArgs =
          WatchSessionArgs(spaceId: "s1", identity: "chef@dk.skworld");
      container
          .read(watchSessionProvider(watchArgs).notifier)
          .loadUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Both are true now: the live camera owns the stage, and the watch
      // surface stays in the tree, Offstage rather than gone. `find`'s
      // default skipOffstage:true hides an intentionally-offstage subtree
      // (that is the whole point of using Offstage for this), so every
      // finder reaching past the wrapper here passes skipOffstage: false.
      final offstageKey =
          find.byKey(const ValueKey("watch-together-s1"), skipOffstage: false);
      expect(offstageKey, findsOneWidget);
      expect(tester.widget<Offstage>(offstageKey).offstage, isTrue);
      final watchVideoFinder = find.byType(WatchVideo, skipOffstage: false);
      expect(watchVideoFinder, findsOneWidget);
      final mountedOnceState =
          tester.state<State<WatchVideo>>(watchVideoFinder);

      // Live video ends: dana's camera publication drops.
      when(() => dana.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      rosterCtl.add(participants);
      await tester.pump(const Duration(milliseconds: 50));

      // The watch session now owns the stage outright: visible (not
      // offstage, so the default skipOffstage:true finder reaches it now),
      // and crucially the SAME State instance as before, proving no remount
      // happened. Losing the ValueKey on the Offstage wrapper
      // (space_room_screen.dart) is exactly what would make this fail: the
      // watch widget's position in the stage's children list shifts once
      // the live-video block above it disappears, and without the key
      // Flutter would tear down and recreate the element at its new slot
      // instead of reusing it, which for the real web controller would mean
      // a detached, reloaded video surface.
      expect(tester.widget<Offstage>(offstageKey).offstage, isFalse);
      final stillMountedState =
          tester.state<State<WatchVideo>>(find.byType(WatchVideo));
      expect(identical(stillMountedState, mountedOnceState), isTrue);
    });
  });

  group("control bar layout", () {
    testWidgets(
        "the multitool control does not cover the Leave button", (tester) async {
      // Chef: "the multitool menu icon renders on top of the hangup button".
      // It was a Scaffold floatingActionButton, and the default endFloat
      // position is the bottom-right corner, which is exactly where the
      // control bar draws Leave. A FAB floats ABOVE the body, so it covered
      // the one control a user needs most when a call goes wrong.
      await tester.pumpWidget(wrapFor(join));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final leave = find.byIcon(Icons.call_end_rounded);
      final multitool = find.byIcon(Icons.dashboard_customize_outlined);
      expect(leave, findsOneWidget);
      expect(multitool, findsOneWidget);

      final leaveRect = tester.getRect(leave);
      final toolRect = tester.getRect(multitool);
      expect(leaveRect.overlaps(toolRect), isFalse,
          reason: "multitool at $toolRect must not cover Leave at $leaveRect");
    });
  });
}
