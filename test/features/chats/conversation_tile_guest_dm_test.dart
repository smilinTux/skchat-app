import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';
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

// guest-dm G6: a gdm is a promoted guest DM - group-shaped (several guests,
// a member count), but still guest-flavored (the Guests filter must still
// catch it). Unlike a 1:1 guest DM its title is the operator-set group name,
// not a guest self-name, so it must NOT render with the untrusted styling.
Conversation _gdm({int memberCount = 3, String name = 'Fishing Trip Crew'}) =>
    Conversation(
      peerId: 'g-gdm',
      displayName: name,
      lastMessage: 'see you at the dock',
      lastMessageTime: DateTime(2026, 8, 6, 12),
      isGroup: true,
      isGuestDm: true,
      mode: 'gdm',
      memberCount: memberCount,
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

  // ── guest-dm G6: gdm (promoted guest DM, group-shaped) ─────────────────────

  testWidgets('gdm shows the group name, a Guest chip, and the member count',
      (tester) async {
    await tester.pumpWidget(_host(_gdm(name: 'Fishing Trip Crew')));
    await tester.pumpAndSettle();

    expect(find.text('Fishing Trip Crew'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget); // still under Guests filter
    expect(find.text('Guest group, 3 members'), findsOneWidget);
    // Never the per-member anti-spoof rendering - there is no single guest.
    expect(find.textContaining('guest:'), findsNothing);
  });

  testWidgets('gdm title renders trusted, NOT the guest-DM untrusted styling',
      (tester) async {
    await tester.pumpWidget(_host(_gdm()));
    await tester.pumpAndSettle();

    final titleText = tester.widget<Text>(find.text('Fishing Trip Crew'));
    expect(titleText.style?.fontStyle, isNot(FontStyle.italic));
    expect(titleText.style?.color, isNot(SovereignColors.accentWarning));
  });

  testWidgets('gdm is never dimmed by the 1:1 revoked/expired path',
      (tester) async {
    await tester.pumpWidget(_host(_gdm()));
    await tester.pumpAndSettle();

    // guestStatus is null for a gdm (no single guest to hold that status),
    // so isGuestInactive is already false - confirm the row renders at full
    // opacity rather than the revoked/expired dimmed state.
    final dimmed = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity < 1.0);
    expect(dimmed, isEmpty);
  });
}
