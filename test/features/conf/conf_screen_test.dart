// Widget tests for the conference waiting-room UI (guest lobby + host
// admit/deny). The server already supports the flow (POST/GET
// /conf/{room}/waiting, POST /conf/{room}/admit|deny); these pin the Flutter
// surface: a guest sees a "pending host approval" lobby and only joins media
// once admitted, a denied guest sees the denial, and the host sees pending
// guests with working Admit / Deny buttons.
import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/conf/conf_screen.dart";
import "package:skchat/services/conf_service.dart";
import "package:skchat/services/livekit_call_service.dart";

class MockConfService extends Mock implements ConfService {}

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

LiveKitParticipantSnapshot _snap(String identity, {bool isLocal = false}) {
  return LiveKitParticipantSnapshot(
    identity: identity,
    isLocal: isLocal,
    isMuted: false,
    isCameraEnabled: false,
    isSpeaking: false,
    canPublish: true,
    handRaised: false,
  );
}

void main() {
  late MockConfService conf;
  late MockLiveKitCallService lk;

  setUp(() {
    conf = MockConfService();
    lk = MockLiveKitCallService();

    // LiveKit media mock (only exercised once a guest/host actually joins).
    final parts = <LiveKitParticipantSnapshot>[
      _snap("chef@dk.skworld", isLocal: false),
      _snap("g1", isLocal: true),
    ];
    when(() => lk.participants).thenAnswer((_) => Stream.value(parts));
    when(() => lk.connectionState)
        .thenAnswer((_) => Stream.value(ConnectionState.connected));
    when(() => lk.currentParticipants).thenReturn(parts);
    // ReactionsButton / ReactionsOverlay (call_shared/reactions.dart) watch
    // this on mount to subscribe to the reaction lane. Unstubbed, mocktail
    // returns null for the getter and building ReactionsButton throws a
    // _TypeError (null is not a Stream); see conf_screen.dart's control bar.
    when(() => lk.dataChannel).thenAnswer((_) => const Stream.empty());
    when(() => lk.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).thenAnswer((_) async {});
    when(() => lk.setMicEnabled(any())).thenAnswer((_) async {});
    when(() => lk.setCameraEnabled(any())).thenAnswer((_) async {});
    when(() => lk.setScreenShareEnabled(any())).thenAnswer((_) async {});
    when(() => lk.leaveRoom()).thenAnswer((_) async {});
  });

  Widget wrap(ConfArgs args) {
    return ProviderScope(
      overrides: [
        confServiceProvider.overrideWithValue(conf),
        liveKitCallServiceProvider.overrideWithValue(lk),
      ],
      child: MaterialApp(home: ConfScreen(args: args)),
    );
  }

  const guestArgs = ConfArgs(
    identity: "g1",
    room: "conf-1",
    name: "Guest One",
    role: "guest",
  );

  ConfToken hostToken() => const ConfToken(
        room: "conf-1",
        url: "wss://lk.test/ws",
        token: "jwt-host",
        identity: "chef@dk.skworld",
        role: "host",
        title: "Town Hall",
      );

  ConfToken guestToken() => const ConfToken(
        room: "conf-1",
        url: "wss://lk.test/ws",
        token: "jwt-guest",
        identity: "g1",
        role: "guest",
        title: "Town Hall",
      );

  testWidgets("guest sees the pending lobby and does NOT join media",
      (tester) async {
    when(() => conf.enterWaiting("conf-1",
            identity: any(named: "identity"), display: any(named: "display")))
        .thenAnswer((_) async => const WaitingStatus(
              admitted: false,
              position: 1,
              message: "Waiting for host to admit you",
            ));

    await tester.pumpWidget(wrap(guestArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text("Waiting to be admitted"), findsOneWidget);
    expect(find.text("Waiting for host to admit you"), findsOneWidget);
    // A pending guest can back out.
    expect(find.text("Cancel"), findsOneWidget);
    // Media is NOT joined while pending.
    verifyNever(() => conf.token(any(),
        identity: any(named: "identity"),
        name: any(named: "name"),
        role: any(named: "role")));
    verifyNever(() => lk.connectWithToken(
        wsUrl: any(named: "wsUrl"), token: any(named: "token")));
    // NB: no pumpAndSettle, the lobby spinner animates forever. The admission
    // poll timer is torn down via the provider's onDispose at test teardown.
  });

  testWidgets("guest auto-admitted (tailnet) joins media straight away",
      (tester) async {
    when(() => conf.enterWaiting("conf-1",
            identity: any(named: "identity"), display: any(named: "display")))
        .thenAnswer((_) async =>
            const WaitingStatus(admitted: true, autoAdmitted: true));
    when(() => conf.token("conf-1",
            identity: any(named: "identity"),
            name: any(named: "name"),
            role: any(named: "role")))
        .thenAnswer((_) async => guestToken());

    await tester.pumpWidget(wrap(guestArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // No lobby, went straight to the media join.
    expect(find.text("Waiting to be admitted"), findsNothing);
    verify(() => lk.connectWithToken(
          wsUrl: "wss://lk.test/ws",
          token: "jwt-guest",
        )).called(1);
  });

  testWidgets("pending guest transitions to the call when the host admits",
      (tester) async {
    var calls = 0;
    when(() => conf.enterWaiting("conf-1",
            identity: any(named: "identity"), display: any(named: "display")))
        .thenAnswer((_) async {
      calls += 1;
      // First knock: still pending. Subsequent poll: admitted.
      return calls == 1
          ? const WaitingStatus(
              admitted: false, message: "Waiting for host to admit you")
          : const WaitingStatus(admitted: true);
    });
    when(() => conf.token("conf-1",
            identity: any(named: "identity"),
            name: any(named: "name"),
            role: any(named: "role")))
        .thenAnswer((_) async => guestToken());

    await tester.pumpWidget(wrap(guestArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("Waiting to be admitted"), findsOneWidget);

    // Advance past the admission poll interval (3s) so the guest re-knocks.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("Waiting to be admitted"), findsNothing);
    verify(() => lk.connectWithToken(
          wsUrl: "wss://lk.test/ws",
          token: "jwt-guest",
        )).called(1);

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets("denied guest sees the denial and never joins media",
      (tester) async {
    when(() => conf.enterWaiting("conf-1",
            identity: any(named: "identity"), display: any(named: "display")))
        .thenAnswer((_) async => const WaitingStatus(
              admitted: false,
              denied: true,
              message: WaitingStatus.denyMessage,
            ));

    await tester.pumpWidget(wrap(guestArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text("Couldn't join conference"), findsOneWidget);
    expect(find.text(WaitingStatus.denyMessage), findsOneWidget);
    verifyNever(() => lk.connectWithToken(
        wsUrl: any(named: "wsUrl"), token: any(named: "token")));
  });

  testWidgets("host sees pending guests and Admit calls the route",
      (tester) async {
    when(() => conf.token("conf-1",
            identity: any(named: "identity"),
            name: any(named: "name"),
            role: any(named: "role")))
        .thenAnswer((_) async => hostToken());
    when(() => conf.waitingList("conf-1")).thenAnswer(
        (_) async => const [WaitingGuest(identity: "g1", name: "Guest One")]);
    when(() => conf.admit("conf-1",
            identity: any(named: "identity"),
            requester: any(named: "requester")))
        .thenAnswer((_) async {});
    when(() => conf.deny("conf-1",
            identity: any(named: "identity"),
            requester: any(named: "requester")))
        .thenAnswer((_) async {});

    const hostArgs = ConfArgs(
      identity: "chef@dk.skworld",
      room: "conf-1",
      name: "Chef",
      role: "host",
    );

    await tester.pumpWidget(wrap(hostArgs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Host is in the call, not the lobby, and the pending guest is listed.
    expect(find.text("Waiting to be admitted"), findsNothing);
    expect(find.text("Guest One"), findsOneWidget);
    expect(find.byTooltip("Admit"), findsOneWidget);
    expect(find.byTooltip("Deny"), findsOneWidget);

    await tester.tap(find.byTooltip("Admit"));
    await tester.pump(const Duration(milliseconds: 50));
    verify(() => conf.admit("conf-1",
        identity: "g1", requester: "chef@dk.skworld")).called(1);

    await tester.tap(find.byTooltip("Deny"));
    await tester.pump(const Duration(milliseconds: 50));
    verify(() => conf.deny("conf-1",
        identity: "g1", requester: "chef@dk.skworld")).called(1);

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });
}
