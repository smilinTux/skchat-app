// Card C-12, spec section 7.1: "Two composers, one hard rule: they must be
// unmistakable." The four-column tier puts the project-chat composer
// (InputBar, the SAME widget the Chats tab renders, unmodified visuals) and
// skcode's inject composer (SkcodeInjectComposer, card C-5) at the bottoms
// of ADJACENT columns. Typing into the wrong one means injecting keystrokes
// into a live agent process when the operator meant to ask a person a
// question, so the card requires this proven with a widget test rather than
// left to "they look different, probably fine."
//
// This test lives in the HOST app (not packages/skcode_client) because the
// chat composer half is InputBar, a host widget the package's import gate
// forbids it from ever seeing. Both real widgets are used here, unmodified,
// placed exactly as the four-column tier places them: side by side.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skcode_client/skcode_client.dart';
import 'package:skchat/features/conversation/widgets/input_bar.dart';

void main() {
  Future<void> pumpBothComposers(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: InputBar(onSend: (_) {}, hintText: 'Message #skworld-app')),
              Expanded(
                child: SkcodeInjectComposer(sid: 's-1', onInject: (_) async {}),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('card C-12 AC6: chat and inject composers share no styling token', () {
    testWidgets('placeholders and button verbs are distinct', (tester) async {
      await pumpBothComposers(tester);

      // Chat: standard skchat placeholder, matching the Chats tab exactly
      // apart from the repo-scoped text (spec 7.1: "placeholder Message
      // #<repo>").
      expect(find.text('Message #skworld-app'), findsOneWidget);

      // The Chats tab's send affordance only swaps in once there is text to
      // send (its icon-only voice/send AnimatedSwitcher, unmodified by this
      // card); type something so the "Send" tooltip this card adds is
      // actually mounted to check.
      await tester.enterText(find.byType(TextField).first, 'hello');
      await tester.pump();

      // Inject: the verb is ALWAYS "Inject", never "Send" -- and the chat
      // composer's own verb (present as a Tooltip on its icon-only send
      // affordance, matching the Chats tab's existing icon-only chrome) is
      // literally "Send". Two different words, never the same button.
      expect(find.text('Inject'), findsOneWidget);
      final sendTooltip = tester.widgetList<Tooltip>(find.byType(Tooltip)).where(
            (t) => t.message == 'Send',
          );
      expect(sendTooltip, hasLength(1));

      // The persistent, non-dismissable target chip only the inject
      // composer carries -- nothing in the chat composer has anything like
      // it.
      expect(find.byKey(const Key('skcodeInjectTargetChip')), findsOneWidget);
      expect(find.textContaining('INJECT -> s-1'), findsOneWidget);
    });

    testWidgets('the inject field is mono; the chat field is not (no shared text style)',
        (tester) async {
      await pumpBothComposers(tester);

      final injectField = tester.widget<TextField>(find.byKey(const Key('skcodeInjectField')));
      final chatField = tester.widget<TextField>(find.byType(TextField).first);

      expect(injectField.style?.fontFamily, 'monospace');
      expect(chatField.style?.fontFamily, isNot('monospace'));
    });
  });

  group('card C-12 AC6: chat and inject composers share no focus traversal', () {
    testWidgets(
        "the inject field's FocusNode is built non-traversable (skipTraversal), "
        "the chat field's is an ordinary traversal stop", (tester) async {
      await pumpBothComposers(tester);

      final injectField = tester.widget<TextField>(find.byKey(const Key('skcodeInjectField')));
      final chatField = tester.widget<TextField>(find.byType(TextField).first);

      expect(injectField.focusNode?.skipTraversal, isTrue);
      expect(chatField.focusNode?.skipTraversal, isNot(true));
    });

    testWidgets(
        'live proof: focusing the chat field and repeatedly asking for the next '
        'traversal stop (what Tab drives) never lands on the inject field',
        (tester) async {
      await pumpBothComposers(tester);

      final injectField = tester.widget<TextField>(find.byKey(const Key('skcodeInjectField')));
      final chatField = tester.widget<TextField>(find.byType(TextField).first);
      final injectFocusNode = injectField.focusNode!;
      final chatFocusNode = chatField.focusNode!;

      chatFocusNode.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(chatFocusNode));

      // Walk the traversal order forward several times (more stops than
      // this small tree has, so the cycle wraps at least once): the inject
      // field must never be the result, at any point.
      for (var i = 0; i < 8; i++) {
        FocusManager.instance.primaryFocus?.nextFocus();
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, isNot(same(injectFocusNode)));
      }
    });
  });
}
