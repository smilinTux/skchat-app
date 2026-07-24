import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/widgets/conversation_tile.dart';
import 'package:skchat/features/chats/widgets/group_composite_avatar.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/peer_trust_store.dart';

/// In-memory trust store (Hive-free) so the tier resolver settles under widget
/// test fake async instead of sticking on AsyncLoading.
class _MemStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _m;
  _MemStore([Map<String, PeerTrustRecord>? seed]) : _m = seed ?? {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => _m;
  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    _m
      ..clear()
      ..addAll(records);
  }
}

Conversation _group(List<ConversationMember> members) => Conversation(
      peerId: 'g-1',
      displayName: 'Penguins',
      lastMessage: 'hi team',
      lastMessageTime: DateTime(2026, 7, 24, 12),
      isGroup: true,
      memberCount: members.length,
      members: members,
    );

ConversationMember _m(String name, {String? fp}) =>
    ConversationMember(identityUri: '$name@skworld.io', displayName: name, soulFingerprint: fp);

Widget _host(Conversation c, {PeerTrustStore? store}) => ProviderScope(
      overrides: [
        peerTrustResolverProvider
            .overrideWithValue(PeerTrustResolver(store ?? _MemStore())),
      ],
      child: MaterialApp(
        home: Scaffold(body: ConversationTile(conversation: c, onTap: () {})),
      ),
    );

void main() {
  testWidgets('group tile renders a composite avatar', (tester) async {
    await tester.pumpWidget(_host(_group([
      _m('Lumina', fp: 'AAAA1111'),
      _m('Steward', fp: 'BBBB2222'),
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(GroupCompositeAvatar), findsOneWidget);
  });

  testWidgets('any keyed-but-unverified member shows the aggregate badge (red)',
      (tester) async {
    await tester.pumpWidget(_host(_group([
      _m('Lumina', fp: 'AAAA1111'), // keyed, never verified -> red
      _m('Chef'), // keyless
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(TrustBadge), findsOneWidget);
  });

  testWidgets('all-keyless group shows NO badge', (tester) async {
    await tester.pumpWidget(_host(_group([
      _m('Chef'),
      _m('Guest'),
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(TrustBadge), findsNothing);
  });

  testWidgets('all-verified group shows the aggregate badge (amber)',
      (tester) async {
    final store = _MemStore();
    // Pre-verify both keyed members so their tier resolves to amber.
    final r = PeerTrustResolver(store);
    await r.markVerifyFlow('Lumina@skworld.io', 'AAAA1111');
    await r.markVerifyFlow('Steward@skworld.io', 'BBBB2222');

    await tester.pumpWidget(_host(
      _group([_m('Lumina', fp: 'AAAA1111'), _m('Steward', fp: 'BBBB2222')]),
      store: store,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TrustBadge), findsOneWidget);
  });
}
