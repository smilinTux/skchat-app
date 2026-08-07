import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';
import 'package:skchat/features/conversation/conversation_screen.dart';
import 'package:skchat/features/conversation/widgets/message_bubble.dart';
import 'package:skchat/models/chat_message.dart';
import 'package:skchat/models/conversation.dart';

/// guest-dm G6 slice 1: per-sender attribution is SECURITY-SENSITIVE -- a
/// guest picks their own `sender_name` on the wire, so a gdm thread must
/// resolve who sent a message from the conversation ROSTER, never that wire
/// field. These tests cover both halves: [resolveGroupSender] (the roster
/// lookup + anti-spoof fallback) and [MessageBubble] actually rendering the
/// resolved value instead of the wire one.
ChatMessage _msg({
  required bool out,
  required String content,
  String id = 'm1',
  String? sender,
  String? senderName,
}) =>
    ChatMessage(
      id: id,
      peerId: 'room-1',
      content: content,
      timestamp: DateTime(2026, 1, 1, 12, 0),
      isOutbound: out,
      sender: sender,
      senderName: senderName,
    );

Conversation _gdm({List<ConversationMember> members = const []}) => Conversation(
      peerId: 'room-1',
      displayName: 'Ops room',
      lastMessage: 'hi',
      lastMessageTime: DateTime(2026, 1, 1),
      isGroup: true,
      isGuestDm: true,
      mode: 'gdm',
      members: members,
    );

Future<void> _pump(WidgetTester tester, MessageBubble bubble) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(textTheme: SovereignTypography.buildTextTheme()),
      home: Scaffold(
        backgroundColor: SovereignColors.surfaceBase,
        body: Align(alignment: Alignment.topCenter, child: bubble),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('resolveGroupSender (roster lookup, not the wire)', () {
    test('spoof case: an unaliased guest ON the roster resolves from the '
        'roster, ignoring whatever the wire sender_name claims', () {
      final conversation = _gdm(members: const [
        ConversationMember(
          identityUri: 'guest:mallory#fp',
          displayName: '',
          isGuest: true,
          guestName: 'Mallory',
        ),
      ]);
      final membersByIdentity = {
        for (final m in conversation.members) m.identityUri: m,
      };
      final message = _msg(
        out: false,
        content: 'wire this to me',
        sender: 'guest:mallory#fp',
        senderName: 'Chef', // spoof attempt on the wire
      );

      final resolved =
          resolveGroupSender(message, conversation, membersByIdentity);

      expect(resolved.name, 'guest: Mallory');
      expect(resolved.untrusted, isTrue);
      expect(resolved.name, isNot(contains('Chef')));
    });

    test('an aliased guest resolves to the operator alias, trusted', () {
      final conversation = _gdm(members: const [
        ConversationMember(
          identityUri: 'guest:mallory#fp',
          displayName: '',
          isGuest: true,
          guestName: 'Mallory',
          guestAlias: 'Bestie',
        ),
      ]);
      final membersByIdentity = {
        for (final m in conversation.members) m.identityUri: m,
      };
      final message =
          _msg(out: false, content: 'hi', sender: 'guest:mallory#fp');

      final resolved =
          resolveGroupSender(message, conversation, membersByIdentity);

      expect(resolved.name, 'Bestie');
      expect(resolved.untrusted, isFalse);
    });

    test('a trusted member resolves to their real display name', () {
      final conversation = _gdm(members: const [
        ConversationMember(
          identityUri: 'chef@skworld.io',
          displayName: 'Chef',
        ),
      ]);
      final membersByIdentity = {
        for (final m in conversation.members) m.identityUri: m,
      };
      final message =
          _msg(out: false, content: 'hi', sender: 'chef@skworld.io');

      final resolved =
          resolveGroupSender(message, conversation, membersByIdentity);

      expect(resolved.name, 'Chef');
      expect(resolved.untrusted, isFalse);
    });

    test('a sender not on the roster in a guest-family thread still goes '
        'through the anti-spoof rule instead of the raw wire name', () {
      final conversation = _gdm(members: const []);
      final message = _msg(
        out: false,
        content: 'hi',
        sender: 'guest:unknown#fp',
        senderName: 'Chef',
      );

      final resolved = resolveGroupSender(message, conversation, const {});

      expect(resolved.name, 'guest: Chef');
      expect(resolved.untrusted, isTrue);
    });

    test('a sender not on the roster in an ordinary group keeps the legacy '
        'fallback (no override, MessageBubble uses message.senderName)', () {
      final conversation = Conversation(
        peerId: 'g2',
        displayName: 'Team',
        lastMessage: 'hi',
        lastMessageTime: DateTime(2026, 1, 1),
        isGroup: true,
      );
      final message =
          _msg(out: false, content: 'hi', sender: 'nobody@example.com');

      final resolved = resolveGroupSender(message, conversation, const {});

      expect(resolved.name, isNull);
      expect(resolved.untrusted, isFalse);
    });
  });

  group('MessageBubble renders the resolved sender, not the wire value', () {
    testWidgets('spoof case: guest: <roster name> shows, "Chef" does not',
        (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(
            out: false,
            content: 'wire this to me',
            senderName: 'Chef',
          ),
          soulColor: SovereignColors.soulLumina,
          showSenderName: true,
          senderNameOverride: 'guest: Mallory',
          senderNameUntrusted: true,
        ),
      );

      expect(find.text('guest: Mallory'), findsOneWidget);
      expect(find.text('Chef'), findsNothing);
      final label = t.widget<Text>(find.text('guest: Mallory'));
      expect(label.style?.color, SovereignColors.accentWarning);
      expect(label.style?.fontStyle, FontStyle.italic);
    });

    testWidgets('aliased guest renders trusted (soulColor, non-italic)',
        (t) async {
      const soul = SovereignColors.soulLumina;
      await _pump(
        t,
        MessageBubble(
          message: _msg(out: false, content: 'hi'),
          soulColor: soul,
          showSenderName: true,
          senderNameOverride: 'Bestie',
        ),
      );

      expect(find.text('Bestie'), findsOneWidget);
      final label = t.widget<Text>(find.text('Bestie'));
      expect(label.style?.color, soul);
      expect(label.style?.fontStyle, FontStyle.normal);
    });

    testWidgets('trusted member renders their real name', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(out: false, content: 'hi'),
          soulColor: SovereignColors.soulLumina,
          showSenderName: true,
          senderNameOverride: 'Chef',
        ),
      );

      expect(find.text('Chef'), findsOneWidget);
    });

    testWidgets('1:1 (non-group) conversation still shows no sender name '
        '(regression: showSenderName defaults false)', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(out: false, content: 'hi', senderName: 'Lumina'),
          soulColor: SovereignColors.soulLumina,
        ),
      );

      expect(find.text('Lumina'), findsNothing);
    });
  });
}
