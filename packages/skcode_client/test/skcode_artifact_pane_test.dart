import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

SkcodeEvent _ev({
  String type = "diff",
  String text = "",
  Map<String, dynamic> data = const {},
  int seq = 1,
  double ts = 1000.0,
  String sid = "s-1",
}) =>
    SkcodeEvent(type: type, text: text, data: data, seq: seq, ts: ts, sid: sid);

Widget _wrap(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme,
      home: Scaffold(body: child),
    );

void main() {
  group("tabs", () {
    testWidgets("without a chat slot renders exactly Diff, Logs, Raw",
        (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));

      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Logs"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Raw"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Chat"), findsNothing);
    });

    testWidgets("showChatTab prepends a Chat tab", (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: [], showChatTab: true)),
      );

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      // Chat is first, ahead of Diff/Logs/Raw (spec: "Chat | Diff | Digest |
      // Logs | Raw"; Digest is C-9's, not built here).
      expect(tabBar.tabs.length, 4);
      expect(find.widgetWithText(Tab, "Chat"), findsOneWidget);
    });

    testWidgets("Chat tab renders the inert placeholder with no chatSlot",
        (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: [], showChatTab: true)),
      );

      expect(find.text("Chat"), findsWidgets); // tab label + placeholder body
    });

    testWidgets("Chat tab renders C-12's widget once chatSlot is supplied",
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SkcodeArtifactPane(
            events: const [],
            showChatTab: true,
            chatSlot: const Text("real chat content"),
          ),
        ),
      );

      expect(find.text("real chat content"), findsOneWidget);
    });

    testWidgets("chatUnreadCount renders a Badge on the Chat tab",
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SkcodeArtifactPane(
            events: [],
            showChatTab: true,
            chatUnreadCount: 3,
          ),
        ),
      );

      expect(find.byType(Badge), findsOneWidget);
      expect(find.text("3"), findsOneWidget);
    });

    testWidgets("no badge when chatUnreadCount is 0", (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: [], showChatTab: true)),
      );

      expect(find.byType(Badge), findsNothing);
    });

    testWidgets("Raw tab hosts SkcodeRawRail, not a second rail",
        (tester) async {
      final event = _ev(type: "assistant_text", text: "hello", seq: 1);
      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: [event])));

      await tester.tap(find.widgetWithText(Tab, "Raw"));
      await tester.pumpAndSettle();

      expect(find.byType(SkcodeRawRail), findsOneWidget);
    });

    testWidgets("Logs tab renders a reserved placeholder", (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));

      await tester.tap(find.widgetWithText(Tab, "Logs"));
      await tester.pumpAndSettle();

      expect(find.text("No logs yet"), findsOneWidget);
    });
  });

  group("Diff tab grouping", () {
    testWidgets("empty state with no diff events", (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));
      expect(find.text("No diffs yet"), findsOneWidget);
    });

    testWidgets(
        "groups the latest diff event per file with add/remove counts",
        (tester) async {
      final events = [
        _ev(
          data: {"file": "lib/x.dart", "added": 10, "removed": 2},
          ts: 100,
          seq: 1,
        ),
        // A newer diff event for the SAME file: this is the one that must
        // win (latest per file, not first-seen).
        _ev(
          data: {"file": "lib/x.dart", "added": 61, "removed": 38},
          ts: 200,
          seq: 2,
        ),
        _ev(
          data: {"file": "lib/y.dart", "added": 5, "removed": 0},
          ts: 150,
          seq: 3,
        ),
        // Non-diff noise must be ignored entirely.
        _ev(type: "assistant_text", text: "hi", ts: 300, seq: 4),
      ];

      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: events)));

      expect(find.text("lib/x.dart"), findsOneWidget);
      expect(find.text("lib/y.dart"), findsOneWidget);
      expect(find.text("+61"), findsOneWidget);
      expect(find.text("-38"), findsOneWidget);
      // The stale (ts:100) row for lib/x.dart must NOT also render.
      expect(find.text("+10"), findsNothing);
      expect(find.text("-2"), findsNothing);
      expect(find.text("+5"), findsOneWidget);
      expect(find.text("-0"), findsOneWidget);
    });

    testWidgets("tolerates alternate key names for file/added/removed",
        (tester) async {
      final events = [
        _ev(
          data: {"path": "lib/z.dart", "insertions": 7, "deletions": 1},
          ts: 100,
          seq: 1,
        ),
      ];

      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: events)));

      expect(find.text("lib/z.dart"), findsOneWidget);
      expect(find.text("+7"), findsOneWidget);
      expect(find.text("-1"), findsOneWidget);
    });

    testWidgets("a diff event with no resolvable file name is dropped",
        (tester) async {
      final events = [_ev(data: {"added": 1, "removed": 1}, ts: 100, seq: 1)];

      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: events)));

      expect(find.text("No diffs yet"), findsOneWidget);
    });
  });

  group("panel-left shadow", () {
    List<BoxShadow> shadowFor(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(
        find.byKey(const Key("skcode-artifact-pane-shadow")),
      );
      final decoration = box.decoration as BoxDecoration;
      return decoration.boxShadow!;
    }

    testWidgets("carries two negative-x layers in light mode",
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SkcodeArtifactPane(events: []),
          theme: ThemeData.light(),
        ),
      );

      final shadows = shadowFor(tester);
      expect(shadows.length, 2);

      // Hairline: the boundary layer, zero blur/spread, offset (-1, 0).
      expect(shadows[0].offset, const Offset(-1, 0));
      expect(shadows[0].blurRadius, 0);
      expect(shadows[0].spreadRadius, 0);
      // A visible (non-transparent) color: the hairline is what carries
      // dark mode, so it can never be fully transparent.
      expect(shadows[0].color.a, greaterThan(0));

      // Soft lift: -16px 0 32px -12px black at low alpha.
      expect(shadows[1].offset, const Offset(-16, 0));
      expect(shadows[1].blurRadius, 32);
      expect(shadows[1].spreadRadius, -12);
      expect(shadows[1].color.a, greaterThan(0));
      expect(shadows[1].color.a, lessThan(1));
    });

    testWidgets(
        "still reads as docked in dark mode (hairline color adapts, "
        "geometry is unchanged)", (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SkcodeArtifactPane(events: []),
          theme: ThemeData.dark(),
        ),
      );

      final shadows = shadowFor(tester);
      expect(shadows.length, 2);
      expect(shadows[0].offset, const Offset(-1, 0));
      expect(shadows[1].offset, const Offset(-16, 0));
      // The hairline must still be a visible color against a dark surface,
      // not black-on-black (the whole reason `panel-left` needs a hairline
      // at all: "a black shadow reads as nothing" in dark mode).
      expect(shadows[0].color.a, greaterThan(0));
      final scheme = ThemeData.dark().colorScheme;
      expect(shadows[0].color, scheme.outlineVariant);
    });

    testWidgets("hairline color differs between light and dark (theme-aware)",
        (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: []), theme: ThemeData.light()),
      );
      final lightHairline = shadowFor(tester)[0].color;

      // MaterialApp wraps its Theme in an implicit AnimatedTheme, so a
      // second pumpWidget with a different theme needs pumpAndSettle to
      // let the transition finish before Theme.of reflects the new
      // (dark) ColorScheme rather than an in-flight interpolation.
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: []), theme: ThemeData.dark()),
      );
      await tester.pumpAndSettle();
      final darkHairline = shadowFor(tester)[0].color;

      expect(lightHairline, isNot(darkHairline));
    });

    testWidgets("a left-only Border alone is never used for this pane",
        (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));

      final box = tester.widget<DecoratedBox>(
        find.byKey(const Key("skcode-artifact-pane-shadow")),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.border, isNull);
    });
  });

  group("phone bottom sheet", () {
    testWidgets("showBottomSheet presents the pane in a DraggableScrollableSheet",
        (tester) async {
      final event = _ev(
        data: {"file": "lib/x.dart", "added": 1, "removed": 0},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => SkcodeArtifactPane.showBottomSheet(
                  context,
                  events: [event],
                ),
                child: const Text("open"),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();

      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.byType(SkcodeArtifactPane), findsOneWidget);
      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      expect(find.text("lib/x.dart"), findsOneWidget);
    });
  });
}
