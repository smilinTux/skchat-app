import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// A local stand-in for "the project chat composer" (card C-12, not yet
/// built in this repo): standard skchat visuals per spec 7.1 - rounded
/// field, chat/primary accent, placeholder text, button verb "Send". This
/// is what a widget test in THIS package can build to prove the inject
/// composer shares no styling token and no focus traversal path with it,
/// since the real chat composer widget does not exist here yet.
class _FakeChatComposer extends StatelessWidget {
  const _FakeChatComposer({required this.focusNode});

  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key("fakeChatField"),
            focusNode: focusNode,
            decoration: const InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
              hintText: "Message #repo",
            ),
          ),
        ),
        FilledButton(onPressed: () {}, child: const Text("Send")),
      ],
    );
  }
}

void main() {
  testWidgets("renders mono/flat chrome with an amber left border", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeInjectComposer(sid: "s-42", onInject: (_) async {}),
        ),
      ),
    );

    final fieldContainer =
        tester.widget<Container>(find.byKey(const Key("skcodeInjectFieldFrame")));
    final decoration = fieldContainer.decoration! as BoxDecoration;
    // Write-tone amber, spec 7.1: literal `Colors.amber`, the SAME constant
    // `skcode_tone_style.dart` pins the transcript's write rows to (never a
    // theme-derived color, which is the whole point of it being the ONE
    // pinned tone).
    expect((decoration.border! as Border).left.color, Colors.amber);
    // FLAT field: no rounded corners anywhere on the field's own
    // decoration (the chip may round; the field container must not).
    expect(decoration.borderRadius, isNull);

    final field = tester.widget<TextField>(find.byKey(const Key("skcodeInjectField")));
    expect(field.style?.fontFamily, "monospace");
    expect(field.decoration?.border, InputBorder.none);
  });

  testWidgets("shows a persistent, non-dismissable INJECT -> <sid> target chip", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeInjectComposer(sid: "s-target-9", onInject: (_) async {}),
        ),
      ),
    );

    expect(find.text("INJECT -> s-target-9"), findsOneWidget);
    // Non-dismissable: no close/clear affordance anywhere on the chip.
    final chip = find.byKey(const Key("skcodeInjectTargetChip"));
    expect(find.descendant(of: chip, matching: find.byIcon(Icons.close)), findsNothing);
    expect(find.descendant(of: chip, matching: find.byType(IconButton)), findsNothing);
  });

  testWidgets('the button verb is "Inject", never "Send"', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeInjectComposer(sid: "s-1", onInject: (_) async {}),
        ),
      ),
    );

    expect(find.widgetWithText(FilledButton, "Inject"), findsOneWidget);
    expect(find.text("Send"), findsNothing);
  });

  testWidgets("tapping Inject calls onInject with the typed text and clears the field",
      (tester) async {
    final injected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeInjectComposer(
            sid: "s-1",
            onInject: (text) async => injected.add(text),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key("skcodeInjectField")), "ls -la");
    await tester.tap(find.byKey(const Key("skcodeInjectButton")));
    await tester.pumpAndSettle();

    expect(injected, ["ls -la"]);
    final field = tester.widget<TextField>(find.byKey(const Key("skcodeInjectField")));
    expect(field.controller!.text, isEmpty);
  });

  group("shares no styling token and no focus traversal path with a chat composer", () {
    testWidgets("different border shape/color and font family", (tester) async {
      final chatFocus = FocusNode();
      addTearDown(chatFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                _FakeChatComposer(focusNode: chatFocus),
                SkcodeInjectComposer(sid: "s-1", onInject: (_) async {}),
              ],
            ),
          ),
        ),
      );

      final chatField = tester.widget<TextField>(find.byKey(const Key("fakeChatField")));
      final injectField = tester.widget<TextField>(find.byKey(const Key("skcodeInjectField")));

      // Different shape: the chat field is a rounded OutlineInputBorder, the
      // inject field is borderless (its amber cue lives on the surrounding
      // flat Container, not the TextField's own InputDecoration).
      expect(chatField.decoration?.border, isA<OutlineInputBorder>());
      expect(injectField.decoration?.border, InputBorder.none);
      // Different font: chat uses the ambient theme font, inject is pinned
      // to monospace.
      expect(injectField.style?.fontFamily, "monospace");
      expect(chatField.style?.fontFamily, isNot("monospace"));
      // Different button verb: "Send" vs "Inject" (never a shared label).
      expect(find.widgetWithText(FilledButton, "Send"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, "Inject"), findsOneWidget);
    });

    testWidgets("Tab from the chat field never moves focus into the inject field",
        (tester) async {
      final chatFocus = FocusNode();
      addTearDown(chatFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                _FakeChatComposer(focusNode: chatFocus),
                SkcodeInjectComposer(sid: "s-1", onInject: (_) async {}),
              ],
            ),
          ),
        ),
      );

      final injectField = tester.widget<TextField>(find.byKey(const Key("skcodeInjectField")));
      // The composer's own FocusNode is built with `skipTraversal: true`
      // (`SkcodeInjectComposer`'s doc comment): the mechanism behind "Tab
      // does not move between them", asserted directly here.
      expect(injectField.focusNode!.skipTraversal, isTrue);

      chatFocus.requestFocus();
      await tester.pump();
      expect(chatFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      // Tab moved focus AWAY from chat (skipTraversal excludes the inject
      // field as a candidate, so focus lands on the next real stop, e.g.
      // the Send button) but never landed ON the inject field.
      expect(injectField.focusNode!.hasFocus, isFalse);
    });
  });
}
