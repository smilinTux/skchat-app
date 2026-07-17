// M2: reuse the Spaces native-desktop screen-share source picker on the 1:1
// call screen's control bar. livekit_call_screen.dart's "Share" toggle used
// to call setScreenShareEnabled(next) with no sourceId, which fails on
// native desktop ("source not found"). It now resolves a capture source
// through the SAME picker Spaces uses (resolveScreenShareSource), injected
// via screenShareSourceResolverProvider so these tests never touch the real
// desktopCapturer platform channel (unavailable under `flutter test`).
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/features/call_shared/screen_share_source.dart';
import 'package:skchat/features/calls/livekit_call_screen.dart';
import 'package:skchat/services/livekit_call_service.dart';

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

/// A notifier that exposes a fixed [LiveKitCallState] without touching a live
/// LiveKit Room, mirroring group_call_screen_test.dart's harness. `join` /
/// `joinWithToken` are no-ops so mounting never pulls the Hive-backed
/// backendConfig provider; `toggleScreenShare` is left un-overridden so the
/// REAL implementation runs and drives the injected mock service, which is
/// exactly the plumbing this test exercises.
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

LiveKitCallState _state({bool screenSharing = false}) {
  return LiveKitCallState(
    roomName: 'call-test',
    identity: 'chef@skworld.io',
    participants: [
      LiveKitParticipantSnapshot(
        identity: 'chef@skworld.io',
        isLocal: true,
        isMuted: false,
        isCameraEnabled: false,
        isSpeaking: false,
      ),
    ],
    isMicEnabled: true,
    isCameraEnabled: false,
    isConnected: true,
    isScreenSharing: screenSharing,
  );
}

void main() {
  late MockLiveKitCallService svc;

  setUp(() {
    svc = MockLiveKitCallService();
    when(() => svc.setScreenShareEnabled(any(),
        sourceId: any(named: 'sourceId'))).thenAnswer((_) async {});
  });

  Widget wrap(LiveKitCallState state, {List<Override> extraOverrides = const []}) {
    return ProviderScope(
      overrides: [
        liveKitCallProvider.overrideWith(() => _FixedCallNotifier(state)),
        liveKitCallServiceProvider.overrideWithValue(svc),
        ...extraOverrides,
      ],
      child: const MaterialApp(
        home: LiveKitCallScreen(
          args: LiveKitCallArgs(
            roomName: 'call-test',
            identity: 'chef@skworld.io',
            displayName: 'Chef',
          ),
        ),
      ),
    );
  }

  testWidgets(
      'tapping Share resolves the source picker and passes the chosen '
      'sourceId through to setScreenShareEnabled', (tester) async {
    var resolverCalls = 0;
    Future<({bool proceed, String? sourceId})> fakeResolver(
        BuildContext context) async {
      resolverCalls++;
      return (proceed: true, sourceId: 'screen:7');
    }

    await tester.pumpWidget(wrap(_state(), extraOverrides: [
      screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
    ]));
    await tester.pump();

    await tester.tap(find.text('Share'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(resolverCalls, 1);
    verify(() => svc.setScreenShareEnabled(true, sourceId: 'screen:7'))
        .called(1);
  });

  testWidgets(
      'cancelling the picker is a silent no-op: no share call, no error '
      'toast', (tester) async {
    Future<({bool proceed, String? sourceId})> cancelResolver(
            BuildContext context) async =>
        (proceed: false, sourceId: null);

    await tester.pumpWidget(wrap(_state(), extraOverrides: [
      screenShareSourceResolverProvider.overrideWithValue(cancelResolver),
    ]));
    await tester.pump();

    await tester.tap(find.text('Share'));
    await tester.pump(const Duration(milliseconds: 50));

    verifyNever(() =>
        svc.setScreenShareEnabled(any(), sourceId: any(named: 'sourceId')));
    expect(find.textContaining('Screen share failed'), findsNothing);
    // Cancel leaves the toggle showing "not sharing".
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Stop share'), findsNothing);
  });

  testWidgets(
      'stopping an active share never re-invokes the picker (it only '
      'resolves a source when turning ON)', (tester) async {
    var resolverCalls = 0;
    Future<({bool proceed, String? sourceId})> fakeResolver(
        BuildContext context) async {
      resolverCalls++;
      return (proceed: true, sourceId: 'screen:1');
    }

    await tester.pumpWidget(wrap(_state(screenSharing: true), extraOverrides: [
      screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
    ]));
    await tester.pump();

    expect(find.text('Stop share'), findsOneWidget);

    await tester.tap(find.text('Stop share'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(resolverCalls, 0); // never consulted on the way OFF
    verify(() => svc.setScreenShareEnabled(false, sourceId: null)).called(1);
  });
}
