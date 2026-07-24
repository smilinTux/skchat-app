import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/widgets/incoming_call_banner.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _Api implements CallApi {
  int answerCalls = 0;
  @override
  Future<CallStartResult> startCall(String p) async => throw UnimplementedError();
  @override
  Future<CallStartResult> answerCall(String p) async {
    answerCalls++;
    return const CallStartResult(
        room: 'r', token: 't', livekitUrl: 'w', peerFqid: 'x', identity: 'y');
  }
  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

class _Lk extends LiveKitCallService {
  _Lk() : super(webuiBaseUrl: 'http://x');
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {}
  @override
  Future<void> leaveRoom() async {}
}

/// Fake CallSession whose build() pins a ringing-incoming state. Only build()
/// is overridden; acceptIncoming/declineIncoming stay the REAL implementation
/// (from CallSession) so a tap exercises the real public API against the
/// fake CallApi/LiveKitCallService overrides below (pattern mirrors
/// _FixedCallNotifier in group_call_screen_test.dart).
class _RingingSession extends CallSession {
  @override
  CallSessionState? build() => const CallSessionState(
      peer: 'steward@skworld.io',
      peerName: 'Steward',
      status: CallSessionStatus.ringing,
      isIncoming: true);
}

class _IdleSession extends CallSession {
  @override
  CallSessionState? build() => null;
}

Widget _app(CallSession session, _Api api) => ProviderScope(
      overrides: [
        callSessionProvider.overrideWith(() => session),
        callApiProvider.overrideWithValue(api),
        liveKitCallServiceProvider.overrideWithValue(_Lk()),
      ],
      child: const MaterialApp(home: Scaffold(body: IncomingCallBanner())),
    );

void main() {
  testWidgets('ringing incoming shows Accept/Decline with the peer name',
      (tester) async {
    await tester.pumpWidget(_app(_RingingSession(), _Api()));
    expect(find.byKey(const Key('incoming-accept')), findsOneWidget);
    expect(find.byKey(const Key('incoming-decline')), findsOneWidget);
    expect(find.text('Incoming call from Steward'), findsOneWidget);
  });

  testWidgets('a non-ringing state renders SizedBox.shrink (no banner)',
      (tester) async {
    await tester.pumpWidget(_app(_IdleSession(), _Api()));
    expect(find.byKey(const Key('incoming-accept')), findsNothing);
    expect(find.byKey(const Key('incoming-decline')), findsNothing);
  });

  testWidgets('tapping incoming-accept invokes acceptIncoming', (tester) async {
    final api = _Api();
    await tester.pumpWidget(_app(_RingingSession(), api));
    await tester.tap(find.byKey(const Key('incoming-accept')));
    await tester.pump();
    expect(api.answerCalls, 1);
  });
}
