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
