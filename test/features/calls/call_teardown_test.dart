// Leaving a 1:1 call has to take the LiveKit room with it.
//
// From a real call on 2026-08-13: Chef hung up, walked to the DM screen, and
// 42 minutes later still HEARD the agent narrate a 3203-character story
// through his speakers. The server had logged his participant leaving at
// 08:05 and was streaming audio at 08:47, so the teardown on the client was
// partial: a room stayed connected and subscribed with nothing in the UI
// pointing at it, burning audio and bandwidth in the background.
//
// Two client defects produced that, and these tests pin both:
//
//  1. liveKitCallServiceProvider was `Provider.autoDispose`, and every
//     consumer reaches it with `ref.read`, which does NOT keep an autoDispose
//     provider alive. Riverpod disposed the element at the end of the same
//     frame, so each read handed back a DIFFERENT LiveKitCallService. The
//     teardown on leave therefore ran against a fresh instance whose room was
//     null (a silent no-op) while the instance that actually held the Room was
//     orphaned, still connected, still playing.
//  2. Only the hang-up button tore anything down. A route pop (system back,
//     browser back, swipe, pushReplacement, host rebuild) left the room live,
//     and the entry points with no CallSession (group call, agent room, guest
//     room, join link) had no pill or banner left to end it with either.
//
// The one exit that must NOT tear down is the collapse chevron, which hands a
// live call to CallSession so the PiP pill and the in-thread CallBanner can
// bring it back. That feature is real, so it gets a test of its own here.
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart' show CameraPosition;
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/livekit_call_screen.dart';
import 'package:skchat/services/backend_config.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

/// Fake LiveKit service: counts teardowns, never touches a real Room. The
/// super ctor only builds an (unused) Dio, so nothing hits the network as long
/// as every method the screen calls is overridden here.
class _FakeLk extends LiveKitCallService {
  _FakeLk({this.throwOnLeave = false}) : super(webuiBaseUrl: 'http://unused.test');

  final bool throwOnLeave;
  int joins = 0;
  int leaves = 0;

  @override
  Future<void> joinRoom({
    required String roomName,
    required String identity,
    bool withVideo = false,
    String? metadata,
  }) async {
    joins++;
  }

  @override
  Future<void> connectWithToken({
    required String wsUrl,
    required String token,
  }) async {
    joins++;
  }

  @override
  Future<void> leaveRoom() async {
    leaves++;
    if (throwOnLeave) throw StateError('room already gone');
  }

  @override
  Future<void> setMicEnabled(bool enabled) async {}

  @override
  Future<void> setCameraEnabled(
    bool enabled, {
    CameraPosition cameraPosition = CameraPosition.front,
    String? deviceId,
  }) async {}

  @override
  List<LiveKitParticipantSnapshot> get currentParticipants => const [];
}

class _FakeApi implements CallApi {
  @override
  Future<CallStartResult> startCall(String peer) async => const CallStartResult(
        room: 'call-abc',
        token: 'tok',
        livekitUrl: 'wss://sfu',
        peerFqid: 'lumina@skworld.io',
        identity: 'chef@skworld.io',
      );

  @override
  Future<CallStartResult> answerCall(String peer) async => startCall(peer);

  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

/// Builds the config directly: the real notifier's build() reads Hive, which
/// these tests neither need nor have.
class _FixedConfig extends BackendConfigNotifier {
  @override
  BackendConfig build() => BackendConfig.defaults;
}

const _kCallArgs = LiveKitCallArgs(
  roomName: 'call-abc',
  identity: 'chef@skworld.io',
  displayName: 'Lumina',
);

/// Mounts a two-route app (a stand-in DM screen at `/`, the call screen at
/// `/call`) so a pop lands somewhere real, exactly like leaving a call for the
/// conversation the user came from.
Future<GoRouter> _pumpCallScreen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('dm screen')),
      ),
      GoRoute(
        path: '/call',
        builder: (_, _) => const LiveKitCallScreen(args: _kCallArgs),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  router.push('/call');
  await tester.pumpAndSettle();
  return router;
}

ProviderContainer _container(_FakeLk lk) {
  final c = ProviderContainer(overrides: [
    liveKitCallServiceProvider.overrideWithValue(lk),
    callApiProvider.overrideWithValue(_FakeApi()),
    backendConfigProvider.overrideWith(_FixedConfig.new),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('LiveKitCallService teardown', () {
    test(
        'leaveRoom is idempotent, never throws with no room, and leaves the '
        'service usable for the next call', () async {
      final svc = LiveKitCallService(webuiBaseUrl: 'http://unused.test');

      // Idempotent: three teardowns in a row on a service that never joined.
      await svc.leaveRoom();
      await svc.leaveRoom();
      await svc.leaveRoom();

      // Still usable. leaveRoom used to be an alias for dispose(), which
      // closed all five broadcast controllers, so a service reused after one
      // call went permanently silent: every emit is dropped by an isClosed
      // guard and nothing fails loudly.
      final micEvents = <bool>[];
      final participantEvents = <List<LiveKitParticipantSnapshot>>[];
      final micSub = svc.micEnabledChanges.listen(micEvents.add);
      final partSub = svc.participants.listen(participantEvents.add);
      addTearDown(micSub.cancel);
      addTearDown(partSub.cancel);

      await svc.setMicEnabled(true);
      await Future<void>.delayed(Duration.zero);

      expect(micEvents, [true],
          reason: 'leaveRoom must not close the streams the next call needs');
      expect(participantEvents, hasLength(1));

      // dispose() is the terminal one, and a teardown after it is still safe.
      await svc.dispose();
      await svc.leaveRoom();
    });

    test(
        'the service provider hands every caller the SAME instance, so a '
        'teardown lands on the object that owns the room', () async {
      final c = ProviderContainer(overrides: [
        backendConfigProvider.overrideWith(_FixedConfig.new),
      ]);
      addTearDown(c.dispose);

      final first = c.read(liveKitCallServiceProvider);
      // A frame later, with nobody listening: this is exactly the gap between
      // joining a room and hanging up.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = c.read(liveKitCallServiceProvider);

      expect(identical(first, second), isTrue,
          reason: 'an autoDispose provider read (never watched) is rebuilt per '
              'read, so hangUp ran against a fresh service with no room while '
              'the instance holding the live Room kept playing audio');
    });
  });

  group('leaving the call surface', () {
    testWidgets('popping the route tears the room down', (tester) async {
      final lk = _FakeLk();
      final container = _container(lk);
      final router = await _pumpCallScreen(tester, container);
      expect(lk.joins, 1);
      expect(lk.leaves, 0);

      // The system back button / browser back / swipe-back, none of which go
      // through the hang-up button.
      router.pop();
      await tester.pumpAndSettle();

      expect(find.text('dm screen'), findsOneWidget);
      expect(lk.leaves, greaterThanOrEqualTo(1),
          reason: 'a call the user has navigated away from must not keep a '
              'live subscription');
    });

    testWidgets('the hang-up button still tears the room down', (tester) async {
      final lk = _FakeLk();
      final container = _container(lk);
      await _pumpCallScreen(tester, container);

      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      expect(lk.leaves, greaterThanOrEqualTo(1));
      expect(container.read(callSessionProvider), isNull);
      expect(find.text('dm screen'), findsOneWidget);
    });

    testWidgets(
        'collapsing a call that HAS a session keeps the room live (the PiP '
        'pill and the in-thread banner bring it back)', (tester) async {
      final lk = _FakeLk();
      final container = _container(lk);
      await container.read(callSessionProvider.notifier).startOutgoing(
            peer: 'lumina@skworld.io',
            peerName: 'Lumina',
            video: false,
          );
      await _pumpCallScreen(tester, container);
      final leavesBefore = lk.leaves;

      await tester.tap(find.byKey(const Key('call-collapse')));
      await tester.pumpAndSettle();

      expect(find.text('dm screen'), findsOneWidget);
      expect(lk.leaves, leavesBefore,
          reason: 'deliberately backgrounding a call must not end it');
      final session = container.read(callSessionProvider);
      expect(session, isNotNull);
      expect(session!.status, CallSessionStatus.minimized);
    });

    testWidgets(
        'collapsing a call with NO session tears down instead of orphaning a '
        'room nothing can reach', (tester) async {
      final lk = _FakeLk();
      final container = _container(lk);
      // A group call, an agent room, a guest room or a join link never creates
      // a CallSession, so there is no pill and no banner to restore from.
      expect(container.read(callSessionProvider), isNull);
      await _pumpCallScreen(tester, container);

      await tester.tap(find.byKey(const Key('call-collapse')));
      await tester.pumpAndSettle();

      expect(lk.leaves, greaterThanOrEqualTo(1));
      expect(container.read(callSessionProvider), isNull);
    });

    testWidgets('a teardown that throws does not escape the dispose path',
        (tester) async {
      final lk = _FakeLk(throwOnLeave: true);
      final container = _container(lk);
      final router = await _pumpCallScreen(tester, container);

      router.pop();
      await tester.pumpAndSettle();

      expect(lk.leaves, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull,
          reason: 'a room the SFU already dropped must tear down quietly');
    });
  });
}
