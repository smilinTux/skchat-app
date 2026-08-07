import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat_ui/skchat_ui.dart';

/// guest-dm C3: operator Chats rendering of guest DMs - alias-wins anti-spoofing,
/// the Guest badge, the Guests filter, and revoked/expired dimming.
List<Conversation> _mixed() {
  final now = DateTime.now();
  return [
    Conversation(
      peerId: 'lumina',
      displayName: 'Lumina',
      lastMessage: 'fleet is green',
      lastMessageTime: now,
      isAgent: true,
    ),
    // Guest DM WITH an operator alias -> alias wins the title.
    Conversation(
      peerId: 'g-alias',
      displayName: 'dm-raw-group-name-1',
      lastMessage: 'hi there',
      lastMessageTime: now,
      isGroup: true,
      isGuestDm: true,
      guestName: 'Mallory',
      guestAlias: 'Alex from the expo',
    ),
    // Guest DM with NO alias, self-name "Chef" (impersonation attempt).
    Conversation(
      peerId: 'g-spoof',
      displayName: 'dm-raw-group-name-2',
      lastMessage: 'hello',
      lastMessageTime: now,
      isGroup: true,
      isGuestDm: true,
      guestName: 'Chef',
    ),
    // Revoked guest DM.
    Conversation(
      peerId: 'g-revoked',
      displayName: 'dm-raw-group-name-3',
      lastMessage: 'bye',
      lastMessageTime: now,
      isGroup: true,
      isGuestDm: true,
      guestName: 'Bob',
      guestStatus: 'revoked',
    ),
  ];
}

Widget _surface() => ChatsSurface(conversations: _mixed());

void main() {
  testWidgets("operator alias wins the title; the raw self-name is not shown",
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: _surface()));
    await tester.pump();

    // Alias renders as the title...
    expect(find.text('Alex from the expo'), findsOneWidget);
    // ...and the guest's own name never wins when an alias is set (anti-spoof).
    expect(find.text('guest: Mallory'), findsNothing);
    // The raw group name is never shown.
    expect(find.text('dm-raw-group-name-1'), findsNothing);
  });

  testWidgets("a guest self-name with no alias shows the untrusted guest: prefix",
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: _surface()));
    await tester.pump();

    // "Chef" cannot impersonate a real contact: always prefixed + marked guest.
    expect(find.text('guest: Chef'), findsOneWidget);
    expect(find.text('Chef'), findsNothing);
  });

  testWidgets("every guest DM row carries a Guest badge", (tester) async {
    await tester.pumpWidget(MaterialApp(home: _surface()));
    await tester.pump();

    // 3 guest DMs -> 3 'Guest' chips (the filter chip label is 'Guests').
    expect(find.text('Guest'), findsNWidgets(3));
  });

  testWidgets("a revoked guest DM renders a Revoked label, dimmed",
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: _surface()));
    await tester.pump();

    expect(find.text('Revoked'), findsOneWidget);
    // The revoked row is wrapped in an Opacity < 1.
    final dimmed = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity < 1.0);
    expect(dimmed, isNotEmpty);
  });

  testWidgets("the Guests filter shows only guest DMs", (tester) async {
    await tester.pumpWidget(MaterialApp(home: _surface()));
    await tester.pump();

    // Before filtering, the agent row is visible.
    expect(find.text('Lumina'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Guests'));
    await tester.pump();

    // Agent row gone; the guest rows remain.
    expect(find.text('Lumina'), findsNothing);
    expect(find.text('Alex from the expo'), findsOneWidget);
    expect(find.text('guest: Chef'), findsOneWidget);
  });
}
