import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart'
    show CameraPosition, ConnectionState;
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _FakeApi implements CallApi {
  int startCalls = 0, answerCalls = 0;
  CallStartResult result = const CallStartResult(
      room: 'call-abc', token: 'tok', livekitUrl: 'wss://sfu',
      peerFqid: 'steward@skworld.io', identity: 'chef@skworld.io');
  bool throwOnStart = false;
  @override
  Future<CallStartResult> startCall(String peer) async {
    startCalls++;
    if (throwOnStart) throw StateError('start failed');
    return result;
  }
  @override
  Future<CallStartResult> answerCall(String peer) async {
    answerCalls++;
    return result;
  }
  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

/// Fake LiveKit service: records calls, never touches a real Room. The super
/// ctor only builds an (unused) Dio, so no network happens as long as we
/// override every method CallSession calls.
class _FakeLk extends LiveKitCallService {
  _FakeLk() : super(webuiBaseUrl: 'http://unused.test');
  int connects = 0, leaves = 0;
  bool? micSet, camSet;
  String? lastWsUrl, lastToken;
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {
    connects++;
    lastWsUrl = wsUrl;
    lastToken = token;
  }
  @override
  Future<void> leaveRoom() async {
    leaves++;
  }
  @override
  Future<void> setMicEnabled(bool enabled) async {
    micSet = enabled;
  }
  @override
  Future<void> setCameraEnabled(bool enabled,
      {CameraPosition cameraPosition = CameraPosition.front, String? deviceId}) async {
    camSet = enabled;
  }
}

ProviderContainer _container(_FakeApi api, _FakeLk lk) => ProviderContainer(
      overrides: [
        callApiProvider.overrideWithValue(api),
        liveKitCallServiceProvider.overrideWithValue(lk),
      ],
    );

void main() {
  test('startOutgoing rings via startCall then connects, becomes active', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);

    await s.startOutgoing(peer: 'steward@skworld.io', peerName: 'Steward', video: false);

    expect(api.startCalls, 1);
    expect(lk.connects, 1);
    expect(lk.lastToken, 'tok');
    expect(lk.lastWsUrl, 'wss://sfu');
    final st = c.read(callSessionProvider)!;
    expect(st.status, CallSessionStatus.active);
    expect(st.room, 'call-abc');
    expect(st.isIncoming, isFalse);
  });

  test('a failed start does NOT connect and lands in failed', () async {
    final api = _FakeApi()..throwOnStart = true;
    final lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);

    await s.startOutgoing(peer: 'x@y', peerName: 'X', video: false);

    expect(lk.connects, 0);
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.failed);
  });

  test('acceptIncoming answers then connects', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);

    s.receiveIncoming(
      const CallInvite(fromFqid: 'steward@skworld.io', room: 'call-abc',
          livekitUrl: 'wss://sfu', topic: '', ts: 1, nonce: 'n1'),
      peerName: 'Steward',
    );
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.ringing);
    expect(c.read(callSessionProvider)!.isIncoming, isTrue);

    await s.acceptIncoming();
    expect(api.answerCalls, 1);
    expect(lk.connects, 1);
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
  });

  test('minimize/restore only flips the flag, does not leave the room', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);
    await s.startOutgoing(peer: 'a@b', peerName: 'A', video: false);

    s.minimize();
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.minimized);
    expect(c.read(callSessionProvider)!.isMinimized, isTrue);
    expect(lk.leaves, 0);

    s.restore();
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
    expect(c.read(callSessionProvider)!.isMinimized, isFalse);
  });

  test('hangUp always tears down the room and ends', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);
    await s.startOutgoing(peer: 'a@b', peerName: 'A', video: false);

    await s.hangUp();
    expect(lk.leaves, 1);
    expect(c.read(callSessionProvider), isNull);
  });

  test('declineIncoming ends without connecting', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);
    s.receiveIncoming(
      const CallInvite(fromFqid: 'a@b', room: 'r', livekitUrl: 'w', topic: '', ts: 1, nonce: 'n'),
    );
    await s.declineIncoming();
    expect(lk.connects, 0);
    expect(c.read(callSessionProvider), isNull);
  });
}
