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
}) =>
    SkcodeEvent(type: type, text: text, data: data, seq: seq, ts: ts, sid: sid);

void main() {
  testWidgets("renders one row per non-suppressed activity", (tester) async {
    final events = [
      _ev(type: "assistant_text", seq: 1, text: "hello there"),
      _ev(type: "tool_call", seq: 2, text: "Bash", data: {"id": "c1", "name": "Bash"}),
    ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SkcodeTranscriptList(events: events))),
    );

    expect(find.text("hello there"), findsOneWidget);
    expect(find.text("Bash"), findsOneWidget);
  });

  testWidgets("suppressed events are hidden from the transcript", (tester) async {
    final events = [
      _ev(type: "assistant_text", seq: 1, text: "kept"),
      _ev(type: "status", seq: 2, data: {"subtype": "heartbeat"}),
    ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SkcodeTranscriptList(events: events))),
    );

    expect(find.text("kept"), findsOneWidget);
    // Only one ListTile: the heartbeat produced no row at all.
    expect(find.byType(ListTile), findsOneWidget);
  });

  testWidgets("an empty event list renders the empty state", (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SkcodeTranscriptList(events: []))),
    );
    expect(find.text("No activity yet"), findsOneWidget);
  });

  testWidgets("a failed tool_call renders with error tone styling", (tester) async {
    final events = [
      _ev(type: "tool_call", seq: 1, data: {"id": "c1", "name": "Edit"}),
      _ev(type: "tool_result", seq: 2, data: {"tool_use_id": "c1", "is_error": true}),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: SkcodeTranscriptList(events: events)),
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets(
    "read/write/admin rows render distinguishable tone colors (blast-radius scan)",
    (tester) async {
      final events = [
        _ev(type: "tool_call", seq: 1, data: {"id": "c1", "name": "Read"}),
        _ev(type: "tool_call", seq: 2, data: {"id": "c2", "name": "Edit"}),
        _ev(type: "needs_input", seq: 3),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(body: SkcodeTranscriptList(events: events)),
        ),
      );

      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration)
          .map((c) => (c.decoration as BoxDecoration).border as Border?)
          .whereType<Border>()
          .map((b) => b.left.color)
          .toSet();

      // Read, write (amber), and admin must each render a distinct color;
      // three rows, three colors.
      expect(containers, hasLength(3));
      expect(containers, contains(Colors.amber));
    },
  );

  testWidgets("transcript rows key on skcodeEventRowId, shared with the raw rail",
      (tester) async {
    final call = _ev(type: "tool_call", seq: 9, ts: 500.0, data: {"id": "c1", "name": "Bash"});

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SkcodeTranscriptList(events: [call]))),
    );

    expect(find.byKey(ValueKey(skcodeEventRowId(call))), findsOneWidget);
  });

  group("card C-12 (spec 7.2): the transcript follow-tails independently", () {
    List<SkcodeEvent> manyEvents(int n) => [
          for (var i = 1; i <= n; i++)
            _ev(seq: i, ts: i.toDouble(), text: "message $i"),
        ];

    testWidgets("no jump-to-latest pill while nothing has scrolled away from the bottom",
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: SkcodeTranscriptList(events: manyEvents(40)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeTranscriptJumpToLatest")), findsNothing);
    });

    testWidgets(
        "scrolling away from the bottom shows the jump-to-latest pill; a NEW event "
        "while scrolled away does NOT force-scroll (follow-tail stays disengaged)",
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: SkcodeTranscriptList(events: manyEvents(40)),
            ),
          ),
        ),
      );
      await tester.pump();

      // Scroll up, away from the tail.
      await tester.drag(find.byType(SkcodeTranscriptList), const Offset(0, 300));
      await tester.pump();

      expect(find.byKey(const Key("skcodeTranscriptJumpToLatest")), findsOneWidget);

      // A fresh event arrives while scrolled away: the list must not yank
      // the operator back down to it (spec 7.2: "disengages on user
      // scroll-up").
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: SkcodeTranscriptList(events: manyEvents(41)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeTranscriptJumpToLatest")), findsOneWidget);
      // The newest row is not the one on screen (still scrolled away).
      expect(find.text("message 41"), findsNothing);
    });

    testWidgets("tapping the jump-to-latest pill scrolls to the newest row and "
        "re-engages follow-tail (the pill then disappears)", (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: SkcodeTranscriptList(events: manyEvents(40)),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.drag(find.byType(SkcodeTranscriptList), const Offset(0, 300));
      await tester.pump();
      expect(find.byKey(const Key("skcodeTranscriptJumpToLatest")), findsOneWidget);

      await tester.tap(find.byKey(const Key("skcodeTranscriptJumpToLatest")));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key("skcodeTranscriptJumpToLatest")), findsNothing);
      expect(find.text("message 40"), findsOneWidget);
    });
  });
}
