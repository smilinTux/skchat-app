import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/guest_ring.dart';
import 'package:skchat/features/calls/livekit_call_screen.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/services/group_call_service.dart';
import 'package:skchat_ui/skchat_ui.dart';

import 'guest_ring_test.dart' show FakeChatsNotifier;

/// Records every `joinCall` and returns a fixed session, so Answer's routing
/// can be asserted without a real daemon. `GroupCallService` is a plain class
/// (no `final`/`sealed`), so overriding the one method under test is enough.
class _RecordingGroupCallService extends GroupCallService {
  final List<String> joinedGroupIds = [];

  @override
  Future<GroupCallSession> joinCall(String groupId) async {
    joinedGroupIds.add(groupId);
    return GroupCallSession(
      groupId: groupId,
      room: 'room-for-$groupId',
      identity: 'operator@skworld.io',
      token: 'tok',
      livekitUrl: 'wss://test.local',
    );
  }
}

/// A fixed, never-connecting LiveKitCallNotifier so pushing LiveKitCallScreen
/// after Answer never touches the real service (Hive-backed config is
/// unavailable under `flutter test`), mirroring group_call_screen_test.dart.
class _NoopCallNotifier extends LiveKitCallNotifier {
  @override
  LiveKitCallState? build() => null;

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

Conversation _c({
  required String peerId,
  String? mode,
  List<GuestRinger> ringers = const [],
}) =>
    Conversation(
      peerId: peerId,
      displayName: 'raw-group-name',
      lastMessage: '',
      lastMessageTime: DateTime(2026, 8, 7),
      isGroup: true,
      isGuestDm: true,
      guestName: 'Mallory',
      guestAlias: 'Alex',
      ringing: true,
      ringTs: 1000,
      mode: mode,
      ringers: ringers,
    );

Future<void> _answerAndSettle(WidgetTester tester, Conversation seed) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatsProvider.overrideWith(() => FakeChatsNotifier([seed])),
        groupCallServiceProvider.overrideWithValue(_svc),
        liveKitCallProvider.overrideWith(_NoopCallNotifier.new),
      ],
      child: const MaterialApp(home: Scaffold(body: GuestRingBanner())),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('guest-ring-answer')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

late _RecordingGroupCallService _svc;

void main() {
  setUp(() {
    _svc = _RecordingGroupCallService();
  });

  testWidgets(
      'answering a 1:1 guest ring joins via GroupCallService.joinCall(peerId) '
      '(regression: unchanged from C5)', (tester) async {
    await _answerAndSettle(tester, _c(peerId: 'g-dm'));
    expect(_svc.joinedGroupIds, ['g-dm']);
  });

  testWidgets(
      'answering a gdm ring joins via the SAME group-call join path '
      '(peerId is the group id either way, no separate 1:1 leg)',
      (tester) async {
    await _answerAndSettle(tester, _c(peerId: 'g-gdm', mode: 'gdm'));
    expect(_svc.joinedGroupIds, ['g-gdm']);
  });

  testWidgets('answering dismisses the ring either way', (tester) async {
    await _answerAndSettle(tester, _c(peerId: 'g-gdm', mode: 'gdm'));
    // The banner is gone: the ring was dismissed once Answer fired.
    expect(find.byType(GuestRingBanner), findsOneWidget);
    expect(find.byKey(const Key('guest-ring-answer')), findsNothing);
  });
}
