import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/incoming_call_watcher.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _Api implements CallApi {
  List<CallInvite> incoming = const [];
  bool throwOnce = false;
  @override
  Future<CallStartResult> startCall(String p) async => const CallStartResult(
      room: 'r', token: 't', livekitUrl: 'w', peerFqid: 'x', identity: 'y');
  @override
  Future<CallStartResult> answerCall(String p) async => throw UnimplementedError();
  @override
  Future<List<CallInvite>> pollIncoming() async {
    if (throwOnce) {
      throwOnce = false;
      throw StateError('poll failed');
    }
    return incoming;
  }
}

class _Lk extends LiveKitCallService {
  _Lk() : super(webuiBaseUrl: 'http://x');
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {}
  @override
  Future<void> leaveRoom() async {}
}

ProviderContainer _c(_Api api) => ProviderContainer(overrides: [
      callApiProvider.overrideWithValue(api),
      liveKitCallServiceProvider.overrideWithValue(_Lk()),
    ]);

CallInvite _inv(String nonce) => CallInvite(
    fromFqid: 'steward@skworld.io', room: 'r', livekitUrl: 'w', topic: '', ts: 1, nonce: nonce);

void main() {
  test('pollOnce with an invite drives CallSession into ringing', () async {
    final api = _Api()..incoming = [_inv('n1')];
    final c = _c(api);
    addTearDown(c.dispose);
    await c.read(incomingCallWatcherProvider).pollOnce();
    final st = c.read(callSessionProvider);
    expect(st?.status, CallSessionStatus.ringing);
    expect(st?.isIncoming, isTrue);
  });

  test('the same nonce does not re-ring an already-handled invite', () async {
    final api = _Api()..incoming = [_inv('n1')];
    final c = _c(api);
    addTearDown(c.dispose);
    final w = c.read(incomingCallWatcherProvider);
    await w.pollOnce();
    // User hangs up / it ends; session cleared via the public API (Notifier.state
    // is @protected, so this must go through hangUp(), not a direct set).
    await c.read(callSessionProvider.notifier).hangUp();
    await w.pollOnce(); // same nonce still returned by the server
    expect(c.read(callSessionProvider), isNull); // not re-rung
  });

  test('a poll failure is swallowed (no throw, no ring)', () async {
    final api = _Api()..throwOnce = true;
    final c = _c(api);
    addTearDown(c.dispose);
    await c.read(incomingCallWatcherProvider).pollOnce(); // must not throw
    expect(c.read(callSessionProvider), isNull);
  });

  test('does not override an already-active call', () async {
    final api = _Api()..incoming = [_inv('n2')];
    final c = _c(api);
    addTearDown(c.dispose);
    // Simulate an active outgoing call via the public API (fakes make this
    // succeed and land in CallSessionStatus.active).
    await c
        .read(callSessionProvider.notifier)
        .startOutgoing(peer: 'x', peerName: 'X', video: false);
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
    await c.read(incomingCallWatcherProvider).pollOnce();
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
  });
}
