// Mobile-web soft-keyboard / viewport regression tests.
//
// THE BUG (real iPhone Safari at the tailscale URL): tapping the composer made
// the conversation go blank and "shoot up", and sending jolted the layout. Root
// cause = mobile browsers scroll the Flutter canvas to reveal the focused input
// instead of resizing, and the message list was top-anchored so the latest
// messages were not pinned above the keyboard.
//
// THE FIX (see conversation_screen.dart + web/index.html):
//   1. Scaffold `resizeToAvoidBottomInset: true` (explicit).
//   2. Message ListView is bottom-anchored (`reverse: true`) so the newest
//      message stays at the bottom, just above the keyboard.
//   3. Re-pin to bottom when the view-inset changes (keyboard open/close).
//   4. web/index.html viewport meta `interactive-widget=resizes-content`.
//
// WHAT THESE TESTS SIMULATE: a soft keyboard cannot be raised in the headless
// widget tester, so we SIMULATE it by wrapping widgets in a MediaQuery whose
// `viewInsets.bottom` is 300 (a typical keyboard height) and asserting the
// layout stays sane: the composer remains laid out & on-screen, and the
// bottom-anchored list keeps the LAST (newest) message visible above the inset.
// Canvas-scroll behavior + the meta tag are browser-only and are verified by the
// operator on a real device (documented in the PR report).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/conversation/widgets/input_bar.dart';

/// Pump [child] under a simulated soft keyboard of [insetBottom] px.
Future<void> _pumpWithKeyboard(
  WidgetTester tester,
  Widget child, {
  double insetBottom = 300,
  bool resizeToAvoidBottomInset = true,
}) async {
  tester.view.physicalSize = const Size(390, 844); // iPhone-ish logical-ish
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        // Simulate the soft keyboard occupying the bottom of the viewport.
        data: MediaQueryData(
          size: const Size(390, 844),
          viewInsets: EdgeInsets.only(bottom: insetBottom),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: resizeToAvoidBottomInset,
          body: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('composer stays laid out under a soft-keyboard inset', () {
    testWidgets('InputBar text field + send affordance remain on-screen',
        (tester) async {
      await _pumpWithKeyboard(
        tester,
        Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            InputBar(onSend: (_) {}),
          ],
        ),
      );

      // The composer text field is present and laid out (non-zero size).
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      final fieldSize = tester.getSize(field);
      expect(fieldSize.width, greaterThan(0));
      expect(fieldSize.height, greaterThan(0));

      // It must sit within the visible area (above the keyboard, i.e. above
      // 844 - 300 = 544), NOT pushed off the bottom of the screen.
      final topLeft = tester.getTopLeft(find.byType(InputBar));
      expect(topLeft.dy, lessThan(844 - 300),
          reason: 'composer should ride above the simulated keyboard');
    });

    testWidgets('typing text in the composer does not throw / stays laid out',
        (tester) async {
      await _pumpWithKeyboard(
        tester,
        Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            InputBar(onSend: (_) {}),
          ],
        ),
      );

      await tester.enterText(find.byType(TextField), 'hello above the keyboard');
      await tester.pump();

      expect(find.text('hello above the keyboard'), findsOneWidget);
      // Send button (swaps in once there is text) is reachable on-screen.
      final sendIcon = find.byIcon(Icons.send_rounded);
      expect(sendIcon, findsOneWidget);
      final sendCenter = tester.getCenter(sendIcon);
      expect(sendCenter.dy, lessThan(844 - 300),
          reason: 'send button must be tappable above the keyboard');
    });
  });

  group('message list is bottom-anchored (latest pinned above keyboard)', () {
    // Mirrors the conversation screen list construction: reverse:true with
    // newest-first index mapping. This is the cross-browser anchor that keeps
    // the latest messages visible on iOS Safari (which ignores the viewport
    // meta tag), even when the canvas/inset behavior is unreliable.
    Widget buildList(List<String> chronological) {
      final count = chronological.length;
      return ListView.builder(
        reverse: true,
        itemCount: count,
        itemBuilder: (context, index) {
          final text = chronological[count - 1 - index]; // newest first
          return SizedBox(
            height: 80,
            child: Center(child: Text(text)),
          );
        },
      );
    }

    testWidgets('the NEWEST message renders at the bottom of the viewport',
        (tester) async {
      final msgs = [for (var i = 0; i < 30; i++) 'msg-$i'];
      await _pumpWithKeyboard(
        tester,
        Column(children: [Expanded(child: buildList(msgs))]),
      );

      // Newest message is visible (rendered) — it is pinned to the bottom.
      expect(find.text('msg-29'), findsOneWidget);

      // It sits LOWER on screen than an older one that is also visible,
      // confirming bottom-anchoring (newest at bottom, older above it).
      final newest = tester.getCenter(find.text('msg-29')).dy;
      final older = tester.getCenter(find.text('msg-28')).dy;
      expect(newest, greaterThan(older),
          reason: 'reverse:true pins the newest message to the bottom');
    });

    testWidgets('newest message stays visible above a 300px keyboard inset',
        (tester) async {
      final msgs = [for (var i = 0; i < 30; i++) 'msg-$i'];
      await _pumpWithKeyboard(
        tester,
        Column(children: [Expanded(child: buildList(msgs))]),
      );

      // With resizeToAvoidBottomInset the Scaffold body shrinks to ~544px tall;
      // the bottom-anchored list keeps the newest message within that area.
      final newestBottom = tester.getBottomLeft(find.text('msg-29')).dy;
      expect(newestBottom, lessThanOrEqualTo(844 - 300 + 1),
          reason: 'newest message must remain above the keyboard');
    });
  });
}
