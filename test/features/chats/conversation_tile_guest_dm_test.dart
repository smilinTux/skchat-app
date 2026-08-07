import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/widgets/conversation_tile.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/peer_trust_store.dart';

/// guest-dm C3: the NATIVE ChatsScreen tile (the default surface) must render
/// guest DMs with the anti-spoofing title + Guest badge + revoked dimming,
/// exactly like the extracted package tile.
class _MemStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => _m;
  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    _m
      ..clear()
      ..addAll(records);
  }
}

Conversation _guestDm({
  String? alias,
  String guestName = 'Mallory',
  String? status,
}) =>
    Conversation(
      peerId: 'g-dm',
      displayName: 'dm-raw-group-name',
      lastMessage: 'hi',
      lastMessageTime: DateTime(2026, 8, 6, 12),
      isGroup: true,
      isGuestDm: true,
      guestName: guestName,
      guestAlias: alias,
      guestStatus: status,
    );

Widget _host(Conversation c) => ProviderScope(
      overrides: [
        peerTrustResolverProvider.overrideWithValue(PeerTrustResolver(_MemStore())),
      ],
      child: MaterialApp(
        home: Scaffold(body: ConversationTile(conversation: c, onTap: () {})),
      ),
    );

void main() {
  testWidgets('operator alias wins the title; raw self-name + group name hidden',
      (tester) async {
    await tester.pumpWidget(_host(_guestDm(alias: 'Alex from expo')));
    await tester.pumpAndSettle();

    expect(find.text('Alex from expo'), findsOneWidget);
    expect(find.text('guest: Mallory'), findsNothing);
    expect(find.text('dm-raw-group-name'), findsNothing);
    expect(find.text('Guest'), findsOneWidget); // still marked a guest
  });

  testWidgets('no alias -> untrusted guest: prefix (spoof-proof)', (tester) async {
    await tester.pumpWidget(_host(_guestDm(guestName: 'Chef')));
    await tester.pumpAndSettle();

    expect(find.text('guest: Chef'), findsOneWidget);
    expect(find.text('Chef'), findsNothing);
    expect(find.text('Guest'), findsOneWidget);
  });

  testWidgets('revoked guest DM shows a Revoked label, dimmed', (tester) async {
    await tester.pumpWidget(_host(_guestDm(status: 'revoked')));
    await tester.pumpAndSettle();

    expect(find.text('Revoked'), findsOneWidget);
    final dimmed = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity < 1.0);
    expect(dimmed, isNotEmpty);
  });
}
