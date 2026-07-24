import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/livekit_call_screen.dart';
import 'package:skchat/features/calls/widgets/call_banner.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/daemon_service.dart';
import 'package:skchat/services/livekit_call_service.dart';

const _peer = 'steward@skworld.io';

class _Api implements CallApi {
  @override
  Future<CallStartResult> startCall(String p) async =>
      throw UnimplementedError();
  @override
  Future<CallStartResult> answerCall(String p) async =>
      throw UnimplementedError();
  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

class _Lk extends LiveKitCallService {
  _Lk() : super(webuiBaseUrl: 'http://unused.test');
  int leaves = 0;
  @override
  Future<void> connectWithToken(
          {required String wsUrl, required String token}) async =>
      {};
  @override
  Future<void> leaveRoom() async {
    leaves++;
  }
}

class _ActiveForPeer extends CallSession {
  @override
  CallSessionState? build() => const CallSessionState(
        peer: _peer,
        peerName: 'Steward',
        status: CallSessionStatus.active,
        room: 'call-1',
        token: 'tok',
        livekitUrl: 'wss://sfu',
      );
}

class _MinimizedForPeer extends CallSession {
  @override
  CallSessionState? build() => const CallSessionState(
        peer: _peer,
        peerName: 'Steward',
        status: CallSessionStatus.minimized,
        isMinimized: true,
        room: 'call-1',
        token: 'tok',
        livekitUrl: 'wss://sfu',
      );
}

class _OtherPeerSession extends CallSession {
  @override
  CallSessionState? build() => const CallSessionState(
        peer: 'someone-else@skworld.io',
        peerName: 'Someone',
        status: CallSessionStatus.active,
      );
}

class _IdleSession extends CallSession {
  @override
  CallSessionState? build() => null;
}

class _FailedForPeer extends CallSession {
  @override
  CallSessionState? build() => const CallSessionState(
        peer: _peer,
        peerName: 'Steward',
        status: CallSessionStatus.failed,
        error: 'connection lost',
      );
}

ProviderContainer _container(CallSession session) => ProviderContainer(
      overrides: [
        callSessionProvider.overrideWith(() => session),
        callApiProvider.overrideWithValue(_Api()),
        liveKitCallServiceProvider.overrideWithValue(_Lk()),
        daemonServiceProvider
            .overrideWithValue(DaemonService(identity: 'chef@skworld.io')),
      ],
    );

Widget _host(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/chats/$_peer',
    routes: [
      GoRoute(
        path: '/chats/$_peer',
        builder: (_, __) => const Scaffold(body: CallBanner(peerId: _peer)),
      ),
      GoRoute(
        path: AppRoutes.livekitCall,
        builder: (_, state) {
          final args = state.extra as LiveKitCallArgs;
          return Scaffold(body: Text('LIVEKIT ${args.roomName}'));
        },
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('active session for this peer shows the banner', (tester) async {
    final c = _container(_ActiveForPeer());
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call-banner')), findsOneWidget);
    expect(find.textContaining('Steward'), findsOneWidget);
  });

  testWidgets(
      'minimized session for this peer: tap restores and opens the call screen',
      (tester) async {
    final c = _container(_MinimizedForPeer());
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-banner')), findsOneWidget);

    await tester.tap(find.byKey(const Key('call-banner')));
    await tester.pumpAndSettle();

    expect(c.read(callSessionProvider)!.isMinimized, isFalse);
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
    expect(find.text('LIVEKIT call-1'), findsOneWidget);
  });

  testWidgets('a session for a different peer shows nothing', (tester) async {
    final c = _container(_OtherPeerSession());
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call-banner')), findsNothing);
    expect(find.byKey(const Key('call-banner-failed')), findsNothing);
  });

  testWidgets('no session shows nothing', (tester) async {
    final c = _container(_IdleSession());
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call-banner')), findsNothing);
    expect(find.byKey(const Key('call-banner-failed')), findsNothing);
  });

  testWidgets(
      'a failed session for this peer shows a dismiss affordance that clears the session',
      (tester) async {
    final c = _container(_FailedForPeer());
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call-banner-failed')), findsOneWidget);
    expect(find.byKey(const Key('call-banner')), findsNothing);

    await tester.tap(find.byKey(const Key('call-banner-dismiss')));
    await tester.pumpAndSettle();

    expect(c.read(callSessionProvider), isNull);
    expect(find.byKey(const Key('call-banner-failed')), findsNothing);
  });
}
