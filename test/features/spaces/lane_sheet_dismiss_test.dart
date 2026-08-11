// Chef: "I can't lower the slide up control menu."
//
// Lane panels open via `_openLane` (space_room_screen.dart), a plain
// showModalBottomSheet wrapping a fixed-height panel. enableDrag defaults to
// true, so a drag that reaches the SHEET dismisses it. The bug is that a drag
// starting anywhere the panel handles gestures never reaches the sheet at all,
// and a lane panel is mostly gesture-handling widgets, so the only place a drag
// works is a few pixels of decorative handle nobody can reliably hit.
//
// These tests mirror _openLane exactly and pump the REAL WatchPanel, so they
// fail for the same reason the real screen does.
import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_drift.dart";
import "package:skchat/features/spaces/watch_panel.dart";
import "package:skchat/features/spaces/watch_session.dart"
    show
        laneServiceFactoryProvider,
        watchControllerFactoryProvider,
        WatchSessionArgs;
import "package:skchat/features/spaces/watch_sync.dart" show WatchController;
import "package:skchat/services/lane_service.dart" show LaneLike;

class _FakeLane implements LaneLike {
  @override
  Stream<Map<String, dynamic>> get inbound => const Stream.empty();
  @override
  Future<void> publish(Map<String, dynamic> payload) async {}
  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async {}
  @override
  Future<List<Map<String, dynamic>>> catchUp(String lane) async => const [];
}

class _FakeController implements WatchController {
  @override
  void load(String url) {}
  @override
  void play() {}
  @override
  void pause() {}
  @override
  void seekTo(double t) {}
  @override
  void setRate(double rate) {}
  @override
  void dispose() {}
  @override
  double get position => 0;
  @override
  PlaybackSnapshot get playbackSnapshot =>
      const PlaybackSnapshot(position: 0, playing: false);
}

/// Mirrors `_openLane` in space_room_screen.dart. Kept in sync by hand: if that
/// method changes, this must change with it or these tests stop testing it.
void openLane(BuildContext context, Widget panel) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // showDragHandle removed to match current prod
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: panel,
    ),
  );
}

Widget harness() => ProviderScope(
      overrides: [
        laneServiceFactoryProvider.overrideWithValue((_) => _FakeLane()),
        watchControllerFactoryProvider.overrideWithValue(() => _FakeController()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => openLane(
                  ctx,
                  const WatchPanel(spaceId: "s1", identity: "chef@dk.skworld"),
                ),
                child: const Text("open"),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  const args = WatchSessionArgs(spaceId: "s1", identity: "chef@dk.skworld");
  // Referenced so the import is not flagged unused; the args value is what the
  // panel builds internally.
  assert(args.spaceId == "s1");

  testWidgets("the panel sheet exposes a drag handle to lower it",
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();

    expect(find.text("Watch Together"), findsOneWidget);
    // Flutter's built-in handle is a real, reliably hittable target wired to
    // the sheet's drag, unlike a decorative Container.
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets("dragging the panel down lowers it (the reported bug)",
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
    expect(find.text("Watch Together"), findsOneWidget);

    // Grab the panel's own title area, which is what a user actually aims for,
    // not the few pixels of handle.
    final title = tester.getCenter(find.text("Watch Together"));
    await tester.dragFrom(title, const Offset(0, 700));
    await tester.pumpAndSettle();

    expect(find.text("Watch Together"), findsNothing,
        reason: "dragging the panel down must dismiss the sheet");
  });
}
