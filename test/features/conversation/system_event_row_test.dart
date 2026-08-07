import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';
import 'package:skchat/features/conversation/conversation_screen.dart';
import 'package:skchat/features/conversation/widgets/message_bubble.dart';

/// guest-dm G6 slice 2: a `content_type: system` message (e.g. the
/// dm-promoted-to-gdm notice) must render as a centered, full-width event
/// row -- no bubble, no avatar gutter, no sender name -- so it can never be
/// mistaken for something a participant (trusted or guest) said.
void main() {
  Future<void> pump(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(textTheme: SovereignTypography.buildTextTheme()),
        home: Scaffold(
          backgroundColor: SovereignColors.surfaceBase,
          body: SystemEventRow(text: text),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the notice text', (t) async {
    await pump(t, 'Ops room is now a group conversation.');
    expect(find.text('Ops room is now a group conversation.'), findsOneWidget);
  });

  testWidgets('is centered, not left-aligned like a bubble body', (t) async {
    await pump(t, 'Ops room is now a group conversation.');
    // A Center ancestor of the text is the centering mechanism itself.
    expect(
      find.ancestor(of: find.byType(Text), matching: find.byType(Center)),
      findsOneWidget,
    );
    final text = t.widget<Text>(find.byType(Text));
    expect(text.textAlign, TextAlign.center);
  });

  testWidgets('bypasses bubble chrome entirely (no MessageBubble in the tree)',
      (t) async {
    await pump(t, 'Ops room is now a group conversation.');
    expect(find.byType(MessageBubble), findsNothing);
  });
}
