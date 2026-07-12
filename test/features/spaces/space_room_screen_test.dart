import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/spaces/space_models.dart";
import "package:skchat/features/spaces/space_room_screen.dart";
import "package:skchat/services/livekit_call_service.dart";

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

LiveKitParticipantSnapshot _snap(
  String identity, {
  bool isLocal = false,
  bool isMuted = false,
  bool isSpeaking = false,
  bool canPublish = false,
  bool handRaised = false,
}) {
  return LiveKitParticipantSnapshot(
    identity: identity,
    isLocal: isLocal,
    isMuted: isMuted,
    isCameraEnabled: false,
    isSpeaking: isSpeaking,
    canPublish: canPublish,
    handRaised: handRaised,
  );
}

void main() {
  late MockLiveKitCallService svc;

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
    when(() => svc.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).thenAnswer((_) async {});
    when(() => svc.setMicEnabled(any())).thenAnswer((_) async {});
    when(() => svc.leaveRoom()).thenAnswer((_) async {});
  });

  Widget wrap() {
    return ProviderScope(
      overrides: [
        liveKitCallServiceProvider.overrideWithValue(svc),
      ],
      child: MaterialApp(home: SpaceRoomScreen(join: join)),
    );
  }

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
}
