import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/core/widgets/tap_feedback.dart";

void main() {
  /// Records platform haptic calls, which are a method-channel side effect and
  /// otherwise invisible to a widget test.
  List<String> hapticLog(WidgetTester tester) {
    final log = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == "HapticFeedback.vibrate") {
          log.add("${call.arguments}");
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return log;
  }

  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  double scaleOf(WidgetTester tester) => tester
      .widget<AnimatedScale>(find.descendant(
        of: find.byType(TapFeedback),
        matching: find.byType(AnimatedScale),
      ))
      .scale;

  testWidgets("the press is acknowledged on tap DOWN, before any release",
      (tester) async {
    // The whole point: a control that reaches across the network cannot say
    // "it worked" for seconds, but it can always say "I heard you" at once.
    // Acknowledging on release would still leave a held finger wondering.
    await tester.pumpWidget(host(TapFeedback(onTap: () {}, child: const SizedBox(width: 56, height: 56))));

    expect(scaleOf(tester), 1.0);

    final gesture = await tester.press(find.byType(TapFeedback));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(scaleOf(tester), lessThan(1.0),
        reason: "the control must visibly react while the finger is still down");

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(scaleOf(tester), 1.0);
  });

  testWidgets("a haptic fires on press", (tester) async {
    final log = hapticLog(tester);
    await tester.pumpWidget(host(TapFeedback(onTap: () {}, child: const SizedBox(width: 56, height: 56))));

    final gesture = await tester.press(find.byType(TapFeedback));
    await tester.pump();

    expect(log, isNotEmpty, reason: "press must be felt, not only seen");
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets("haptic: false stays silent, for controls that fire their own",
      (tester) async {
    final log = hapticLog(tester);
    await tester.pumpWidget(host(TapFeedback(
        onTap: () {},
        haptic: false,
        child: const SizedBox(width: 56, height: 56))));

    final gesture = await tester.press(find.byType(TapFeedback));
    await tester.pump();

    expect(log, isEmpty);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets("a cancelled drag-off still counted as heard, and settles back",
      (tester) async {
    // Sliding a finger off is how a user CANCELS, so onTap must not fire, but
    // the press did land and pretending otherwise would be a lie.
    var taps = 0;
    await tester.pumpWidget(host(TapFeedback(
        onTap: () => taps++,
        child: const SizedBox(width: 56, height: 56))));

    final gesture = await tester.press(find.byType(TapFeedback));
    await tester.pump();
    expect(scaleOf(tester), lessThan(1.0));

    await gesture.moveTo(const Offset(5, 5));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));

    expect(taps, 0, reason: "dragging off cancels the action");
    expect(scaleOf(tester), 1.0, reason: "and the control must not stay stuck");
  });

  testWidgets("a null onTap neither animates, buzzes, nor fires",
      (tester) async {
    // A disabled control must not claim to have heard a tap it will not act
    // on. Half-acknowledging is worse than not acknowledging.
    final log = hapticLog(tester);
    await tester.pumpWidget(
        host(const TapFeedback(onTap: null, child: SizedBox(width: 56, height: 56))));

    final gesture = await tester.press(find.byType(TapFeedback));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(scaleOf(tester), 1.0);
    expect(log, isEmpty);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets("onTap still fires exactly once on a normal tap", (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(TapFeedback(
        onTap: () => taps++,
        child: const SizedBox(width: 56, height: 56))));

    await tester.tap(find.byType(TapFeedback));
    await tester.pump(const Duration(milliseconds: 200));

    expect(taps, 1);
  });
}
