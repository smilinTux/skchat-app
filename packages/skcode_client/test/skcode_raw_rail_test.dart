import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

SkcodeEvent _ev({
  String type = "assistant_text",
  String text = "",
  Map<String, dynamic> data = const {},
  int seq = 1,
  double ts = 1000.0,
  String sid = "s-1",
  String source = "interactive",
}) =>
    SkcodeEvent(
      type: type,
      text: text,
      data: data,
      seq: seq,
      ts: ts,
      sid: sid,
      source: source,
    );

void main() {
  testWidgets("renders one expandable row per event, including suppressed ones",
      (tester) async {
    final events = [
      _ev(type: "assistant_text", seq: 1, text: "hello"),
      _ev(type: "status", seq: 2, data: {"subtype": "heartbeat"}),
    ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SkcodeRawRail(events: events))),
    );

    // Both rows exist: the raw rail is the noise valve, not a filter.
    expect(find.byType(ExpansionTile), findsNWidgets(2));
    expect(find.textContaining("#1"), findsOneWidget);
    expect(find.textContaining("#2"), findsOneWidget);
  });

  testWidgets("suppressed events still appear in the raw rail (the explicit noise valve)",
      (tester) async {
    final heartbeat = _ev(type: "status", seq: 5, data: {"subtype": "heartbeat"});

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SkcodeRawRail(events: [heartbeat]))),
    );

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.byKey(ValueKey(skcodeEventRowId(heartbeat))), findsOneWidget);
  });

  testWidgets("expanding a row shows the pretty-printed JSON payload in mono",
      (tester) async {
    final event = _ev(
      type: "tool_call",
      seq: 3,
      text: "Bash",
      data: {"id": "c1", "name": "Bash"},
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SkcodeRawRail(events: [event]))),
    );

    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    final selectable = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(selectable.data, contains('"type": "tool_call"'));
    expect(selectable.data, contains('"name": "Bash"'));
    expect(selectable.style?.fontFamily, "monospace");
  });

  testWidgets("an empty event list renders the empty state", (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SkcodeRawRail(events: []))),
    );
    expect(find.text("No events yet"), findsOneWidget);
  });

  testWidgets(
    "card C-17: an attach-mode TUI chrome line and a terminal redraw are "
    "hidden from the transcript, but the SAME frames still appear in the "
    "raw rail (the suppressed contract: filtering, not discarding)",
    (tester) async {
      final events = [
        _ev(type: "assistant_text", seq: 1, text: "❯ do the thing", source: "attach"),
        _ev(type: "assistant_text", seq: 2, text: "─" * 40, source: "attach"), // chrome
        _ev(type: "assistant_text", seq: 3, text: "● done", source: "attach"),
        _ev(type: "assistant_text", seq: 4, text: "● done", source: "attach"), // redraw
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(height: 200, child: SkcodeTranscriptList(events: events)),
                SizedBox(height: 400, child: SkcodeRawRail(events: events)),
              ],
            ),
          ),
        ),
      );

      // Half 1: the transcript only shows the two real lines. Row 2 (the
      // chrome separator) and row 4 (the redraw of row 3) never became rows.
      expect(find.text("❯ do the thing"), findsOneWidget);
      expect(find.text("● done"), findsOneWidget); // one row, not two
      expect(find.text("─" * 40), findsNothing);

      // Half 2: the raw rail still renders all four original events. A test
      // that only checked half 1 would also pass on an implementation that
      // discarded the frames outright instead of filtering them -- this
      // assertion is the one that would catch that regression. Scoped to
      // the raw rail subtree: rows 1 and 3 also key-match inside the
      // transcript above (they are NOT suppressed there), so an unscoped
      // lookup would over-count them.
      final rawRail = find.byType(SkcodeRawRail);
      expect(
        find.descendant(of: rawRail, matching: find.byType(ExpansionTile)),
        findsNWidgets(4),
      );
      for (final event in events) {
        expect(
          find.descendant(
            of: rawRail,
            matching: find.byKey(ValueKey(skcodeEventRowId(event))),
          ),
          findsOneWidget,
          reason: "event seq ${event.seq} must still be in the raw rail",
        );
      }
    },
  );

  testWidgets("raw rail rows share the sid:seq:ts anchor id with transcript rows",
      (tester) async {
    final call = _ev(
      type: "tool_call",
      seq: 11,
      ts: 77.0,
      text: "Read",
      data: {"id": "c1", "name": "Read"},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: 200, child: SkcodeTranscriptList(events: [call])),
              SizedBox(height: 200, child: SkcodeRawRail(events: [call])),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(ValueKey(skcodeEventRowId(call))), findsNWidgets(2));
  });
}
