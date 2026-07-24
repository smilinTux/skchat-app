import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/widgets/pip_overlay.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/daemon_service.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _Fixed extends CallSession {
  _Fixed(this._seed);
  final CallSessionState? _seed;
  @override
  CallSessionState? build() => _seed;
}

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

List<Override> _overrides(CallSessionState? seed) => [
      callSessionProvider.overrideWith(() => _Fixed(seed)),
      callApiProvider.overrideWithValue(_Api()),
      liveKitCallServiceProvider.overrideWithValue(_Lk()),
      daemonServiceProvider
          .overrideWithValue(DaemonService(identity: 'chef@skworld.io')),
    ];

Widget _host(CallSessionState? seed) => ProviderScope(
      overrides: _overrides(seed),
      child: const MaterialApp(home: PiPOverlay(child: Scaffold(body: SizedBox()))),
    );

/// Host with a stub [GoRouter] so pill-tap navigation can be exercised, mirroring
/// the pattern in call_banner_test.dart.
Widget _routedHost(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, __) =>
            const PiPOverlay(child: Scaffold(body: SizedBox())),
      ),
      GoRoute(
        path: AppRoutes.conversation,
        builder: (_, state) => Scaffold(
          body: Text('CONVERSATION ${state.pathParameters['peerId']}'),
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('minimized session shows the pill', (tester) async {
    await tester.pumpWidget(_host(const CallSessionState(
        peer: 'a', peerName: 'A', status: CallSessionStatus.minimized, isMinimized: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsOneWidget);
  });

  testWidgets('no session shows no pill', (tester) async {
    await tester.pumpWidget(_host(null));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });

  testWidgets('active non-minimized session shows no pill', (tester) async {
    await tester.pumpWidget(_host(const CallSessionState(
        peer: 'a', peerName: 'A', status: CallSessionStatus.active)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });

  testWidgets(
      'tapping the pill body restores and navigates to the peer conversation',
      (tester) async {
    final container = ProviderContainer(
      overrides: _overrides(const CallSessionState(
          peer: 'a',
          peerName: 'A',
          status: CallSessionStatus.minimized,
          isMinimized: true)),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_routedHost(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsOneWidget);

    await tester.tap(find.byKey(const Key('call-pip-window')));
    await tester.pumpAndSettle();

    final state = container.read(callSessionProvider);
    expect(state!.status, CallSessionStatus.active);
    expect(state.isMinimized, isFalse);
    // Restoring cleared the pip, and navigation landed on the peer's
    // conversation thread (where the in-thread CallBanner takes over).
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
    expect(find.text('CONVERSATION a'), findsOneWidget);
  });

  testWidgets('tapping the hang-up button clears the session to null',
      (tester) async {
    final container = ProviderContainer(
      overrides: _overrides(const CallSessionState(
          peer: 'a',
          peerName: 'A',
          status: CallSessionStatus.minimized,
          isMinimized: true)),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PiPOverlay(child: Scaffold(body: SizedBox())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsOneWidget);

    await tester.tap(find.byKey(const Key('call-pip-hangup')));
    await tester.pumpAndSettle();

    expect(container.read(callSessionProvider), isNull);
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });
}
