import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

void main() {
  testWidgets("renders the event text with Approve and Deny actions", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeNeedsInputBanner(
            text: "ratify failed for s-1 (score=0.4)",
            onApprove: () {},
            onDeny: () {},
          ),
        ),
      ),
    );

    expect(find.text("ratify failed for s-1 (score=0.4)"), findsOneWidget);
    expect(find.widgetWithText(FilledButton, "Approve"), findsOneWidget);
    expect(find.widgetWithText(TextButton, "Deny"), findsOneWidget);
  });

  testWidgets("Approve and Deny call their own callback exactly once", (tester) async {
    var approves = 0;
    var denies = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeNeedsInputBanner(
            text: "needs input",
            onApprove: () => approves++,
            onDeny: () => denies++,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key("skcodeNeedsInputApprove")));
    await tester.pump();
    expect(approves, 1);
    expect(denies, 0);

    await tester.tap(find.byKey(const Key("skcodeNeedsInputDeny")));
    await tester.pump();
    expect(approves, 1);
    expect(denies, 1);
  });

  testWidgets("busy disables both actions so a slow call cannot be double-fired",
      (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeNeedsInputBanner(
            text: "needs input",
            busy: true,
            onApprove: () => taps++,
            onDeny: () => taps++,
          ),
        ),
      ),
    );

    final approveButton =
        tester.widget<FilledButton>(find.byKey(const Key("skcodeNeedsInputApprove")));
    final denyButton = tester.widget<TextButton>(find.byKey(const Key("skcodeNeedsInputDeny")));
    expect(approveButton.onPressed, isNull);
    expect(denyButton.onPressed, isNull);
  });
}
