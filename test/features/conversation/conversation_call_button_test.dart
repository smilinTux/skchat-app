import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/conversation/widgets/conversation_call_button.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';
import 'package:skchat/services/peer_trust_store.dart';

class _MemStore implements PeerTrustStore {
  Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => Map.of(_m);
  @override
  Future<void> save(Map<String, PeerTrustRecord> r) async => _m = Map.of(r);
}

class _FakeApi implements CallApi {
  @override
  Future<CallStartResult> startCall(String p) async => const CallStartResult(
      room: 'r', token: 't', livekitUrl: 'w', peerFqid: 'p', identity: 'i');
  @override
  Future<CallStartResult> answerCall(String p) async => startCall(p);
  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

class _FakeLk extends LiveKitCallService {
  _FakeLk() : super(webuiBaseUrl: 'http://x');
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {}
  @override
  Future<void> leaveRoom() async {}
}

Conversation _peer(String fp) => Conversation(
      peerId: 'steward@skworld.io',
      displayName: 'Steward',
      lastMessage: '',
      lastMessageTime: DateTime(2026),
      soulFingerprint: fp,
    );

void main() {
  testWidgets('tap starts an audio call', (tester) async {
    final store = _MemStore();
    // Verify the peer so the gate allows the call (amber).
    await PeerTrustResolver(store).markVerifyFlow('steward@skworld.io', 'FP1');
    late ProviderContainer container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container = ProviderContainer(overrides: [
          callApiProvider.overrideWithValue(_FakeApi()),
          liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(store)),
        ]),
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [ConversationCallButton(conversation: _peer('FP1'))]),
          ),
        ),
      ),
    );
    addTearDown(container.dispose);
    await tester.tap(find.byKey(const Key('conversation-call-button')));
    await tester.pumpAndSettle();

    final st = container.read(callSessionProvider);
    expect(st, isNotNull);
    expect(st!.isVideo, isFalse);
  });

  testWidgets('long-press starts a video call', (tester) async {
    final store = _MemStore();
    await PeerTrustResolver(store).markVerifyFlow('steward@skworld.io', 'FP1');
    final container = ProviderContainer(overrides: [
      callApiProvider.overrideWithValue(_FakeApi()),
      liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
      peerTrustResolverProvider.overrideWithValue(PeerTrustResolver(store)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [ConversationCallButton(conversation: _peer('FP1'))]),
        ),
      ),
    ));
    await tester.longPress(find.byKey(const Key('conversation-call-button')));
    await tester.pumpAndSettle();

    expect(container.read(callSessionProvider)!.isVideo, isTrue);
  });

  testWidgets('a red (unverified) peer is blocked with a verify prompt', (tester) async {
    final container = ProviderContainer(overrides: [
      callApiProvider.overrideWithValue(_FakeApi()),
      liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
      peerTrustResolverProvider.overrideWithValue(PeerTrustResolver(_MemStore())),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [ConversationCallButton(conversation: _peer('FP1'))]),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('conversation-call-button')));
    await tester.pumpAndSettle();

    expect(container.read(callSessionProvider), isNull); // blocked
    expect(find.text('Verify Steward before calling'), findsOneWidget);
  });
}
