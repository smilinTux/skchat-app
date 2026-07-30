import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat_ui/skchat_ui.dart';

/// Trust badges + group composite avatar in the conversation tiles (the last
/// deferred ChatsScreen-parity piece, reconciled spec 3.2). Proves the tile
/// renders a badge from injected trust, none when absent, that the seam defaults
/// safely, and that a group row uses the composite avatar.

Conversation _direct({String peerId = 'lumina'}) => Conversation(
      peerId: peerId,
      displayName: 'Lumina',
      lastMessage: 'The fleet is green.',
      lastMessageTime: DateTime.now(),
      soulFingerprint: 'lumina-real-key',
    );

Conversation _group() => Conversation(
      peerId: 'skworld-ops',
      displayName: 'SKWorld Ops',
      lastMessage: 'Deploy window at 22:00.',
      lastMessageTime: DateTime.now(),
      soulFingerprint: 'skworld-ops-group',
      isGroup: true,
      memberCount: 3,
      members: const [
        ConversationMember(
          identityUri: 'agent:lumina@skworld.io',
          displayName: 'Lumina',
          soulFingerprint: 'lumina-fp',
        ),
        ConversationMember(
          identityUri: 'agent:jarvis@skworld.io',
          displayName: 'Jarvis',
          soulFingerprint: 'jarvis-fp',
        ),
      ],
    );

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('TrustBadge (pure)', () {
    testWidgets('renders a colored dot and announces the tier', (tester) async {
      await tester.pumpWidget(
        _host(const TrustBadge(level: PeerTrustLevel.amber)),
      );
      expect(find.byType(TrustBadge), findsOneWidget);
      // Compact mode announces the tier for screen readers.
      expect(
        find.bySemanticsLabel('Provisional'),
        findsOneWidget,
      );
    });

    testWidgets('non-compact shows the tier text', (tester) async {
      await tester.pumpWidget(
        _host(const TrustBadge(level: PeerTrustLevel.red, compact: false)),
      );
      expect(find.text('Untrusted'), findsOneWidget);
    });
  });

  group('ConversationListTile trust badge', () {
    testWidgets('renders a badge when trust is injected', (tester) async {
      await tester.pumpWidget(
        _host(
          ConversationListTile(
            conversation: _direct(),
            trust: const PeerTrust(level: PeerTrustLevel.amber),
          ),
        ),
      );
      expect(find.byType(TrustBadge), findsOneWidget);
    });

    testWidgets('renders no badge when trust is absent', (tester) async {
      await tester.pumpWidget(
        _host(ConversationListTile(conversation: _direct())),
      );
      expect(find.byType(TrustBadge), findsNothing);
    });
  });

  group('group composite avatar', () {
    testWidgets('a group row renders the composite avatar, not a SoulAvatar',
        (tester) async {
      await tester.pumpWidget(
        _host(ConversationListTile(conversation: _group())),
      );
      expect(find.byType(GroupCompositeAvatar), findsOneWidget);
      expect(find.byType(SoulAvatar), findsNothing);
    });

    testWidgets('a 1:1 row keeps the SoulAvatar, no composite', (tester) async {
      await tester.pumpWidget(
        _host(ConversationListTile(conversation: _direct())),
      );
      expect(find.byType(SoulAvatar), findsOneWidget);
      expect(find.byType(GroupCompositeAvatar), findsNothing);
    });

    testWidgets('composite falls back to a group icon with no members',
        (tester) async {
      final emptyGroup = Conversation(
        peerId: 'empty-group',
        displayName: 'Empty Group',
        lastMessage: 'hi',
        lastMessageTime: DateTime.now(),
        isGroup: true,
      );
      await tester.pumpWidget(
        _host(ConversationListTile(conversation: emptyGroup)),
      );
      expect(find.byType(GroupCompositeAvatar), findsOneWidget);
      expect(find.byIcon(Icons.group_rounded), findsOneWidget);
    });
  });

  group('injected-trust seam on ChatsSurface', () {
    List<Conversation> convs() => [_direct(peerId: 'lumina'), _group()];

    testWidgets('resolver supplies a badge only for the matching row',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatsSurface(
            conversations: convs(),
            trustResolver: (c) => c.peerId == 'lumina'
                ? const PeerTrust(level: PeerTrustLevel.amber)
                : null,
          ),
        ),
      );
      // Exactly one row (Lumina) got trust; the group row resolved to null.
      expect(find.byType(TrustBadge), findsOneWidget);
      // The group row still renders its composite avatar.
      expect(find.byType(GroupCompositeAvatar), findsOneWidget);
    });

    testWidgets('defaults safely to no badges when no resolver is given',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: convs())),
      );
      expect(find.byType(TrustBadge), findsNothing);
      // The surface still renders its rows cleanly.
      expect(find.byType(ConversationListTile), findsNWidgets(2));
    });
  });
}
