import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/fullscreen_video_stage.dart";

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets("renders the video inline, no fullscreen page by default",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(
        video: Text("VIDEO"),
        semanticsLabel: "screen share",
      ),
    ));
    await tester.pump();

    expect(find.text("VIDEO"), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
  });

  testWidgets("tapping the fullscreen button pushes the fullscreen page",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(video: Text("VIDEO")),
    ));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();

    // Fullscreen page is up: exit control present, video still rendered.
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(find.text("VIDEO"), findsOneWidget);
  });

  testWidgets("double-tap on the video toggles fullscreen on",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(video: Text("VIDEO")),
    ));
    await tester.pump();

    await tester.tap(find.text("VIDEO"));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text("VIDEO"));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
  });

  testWidgets("the exit control leaves fullscreen and returns to the tile",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(video: Text("VIDEO")),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.fullscreen_exit_rounded));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
  });

  testWidgets(
      "pinch-zoom works on the inline tile (before ever going fullscreen)",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(
        video: SizedBox(width: 200, height: 200, child: Text("VIDEO")),
      ),
    ));
    await tester.pump();

    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.minScale, 1.0);
    expect(viewer.maxScale, 5.0);
    final controller = viewer.transformationController!;
    expect(controller.value, Matrix4.identity());

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final gesture1 = await tester.createGesture();
    final gesture2 = await tester.createGesture();
    await gesture1.down(center - const Offset(20, 0));
    await gesture2.down(center + const Offset(20, 0));
    await tester.pump();
    await gesture1.moveTo(center - const Offset(60, 0));
    await gesture2.moveTo(center + const Offset(60, 0));
    await tester.pump();
    await gesture1.up();
    await gesture2.up();
    await tester.pumpAndSettle();

    expect(controller.value, isNot(Matrix4.identity()));
    // Zooming inline never entered fullscreen: pinch/pan is a scale
    // gesture, not a tap, so it never contends with the double-tap-to-enter
    // gesture living on the same tile.
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
  });

  testWidgets(
      "double-tap while fullscreen resets the zoom instead of exiting "
      "(M7's exit-on-double-tap is superseded by zoom-reset once zoomable)",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(
        video: SizedBox(width: 200, height: 200, child: Text("VIDEO")),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    // Pinch-zoom in while fullscreen.
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final controller = viewer.transformationController!;
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final gesture1 = await tester.createGesture();
    final gesture2 = await tester.createGesture();
    await gesture1.down(center - const Offset(20, 0));
    await gesture2.down(center + const Offset(20, 0));
    await tester.pump();
    await gesture1.moveTo(center - const Offset(60, 0));
    await gesture2.moveTo(center + const Offset(60, 0));
    await tester.pump();
    await gesture1.up();
    await gesture2.up();
    await tester.pumpAndSettle();
    expect(controller.value, isNot(Matrix4.identity()));

    // Double-tap: resets the zoom, does NOT leave fullscreen.
    await tester.tap(find.text("VIDEO"));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text("VIDEO"));
    await tester.pumpAndSettle();

    expect(controller.value, Matrix4.identity());
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    // Explicit exit control still works after a zoom-reset double-tap.
    await tester.tap(find.byIcon(Icons.fullscreen_exit_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
  });

  testWidgets("Esc key leaves fullscreen on desktop", (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(video: Text("VIDEO")),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
  });

  testWidgets(
      "share ending while fullscreen (widget removed from the tree) "
      "auto-exits fullscreen", (tester) async {
    final showTile = ValueNotifier<bool>(true);
    addTearDown(showTile.dispose);

    await tester.pumpWidget(wrap(
      ValueListenableBuilder<bool>(
        valueListenable: showTile,
        builder: (context, show, _) {
          return show
              ? const FullscreenableVideo(video: Text("VIDEO"))
              : const Center(child: Text("No one is sharing anymore."));
        },
      ),
    ));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    // Share ends: the caller stops building the tile entirely.
    showTile.value = false;
    await tester.pumpAndSettle();

    // Auto-exited: fullscreen page gone, back to the room content, no
    // dangling black screen.
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    expect(find.text("No one is sharing anymore."), findsOneWidget);
  });

  testWidgets("track re-publish while fullscreen updates the video live",
      (tester) async {
    final trackKey = ValueNotifier<int>(1);
    addTearDown(trackKey.dispose);

    Widget build() => wrap(
          ValueListenableBuilder<int>(
            valueListenable: trackKey,
            builder: (context, key, _) => FullscreenableVideo(
              video: Text("VIDEO-$key"),
            ),
          ),
        );

    await tester.pumpWidget(build());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.text("VIDEO-1"), findsOneWidget);

    // Simulate the underlying LiveKit track being re-published: the same
    // tile rebuilds with a new video widget while fullscreen stays open.
    trackKey.value = 2;
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(find.text("VIDEO-2"), findsOneWidget);
    expect(find.text("VIDEO-1"), findsNothing);
  });

  testWidgets(
      "two rapid exit invocations (Esc key-repeat) pop ONLY the fullscreen "
      "route, never the screen below", (tester) async {
    // The tile lives on a PUSHED room route (as in the app, where the Space
    // room screen sits above other routes), so an unguarded second pop()
    // would pop the room screen itself, not just the fullscreen route.
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: FullscreenableVideo(video: Text("VIDEO")),
                  ),
                ),
              ),
              child: const Text("OPEN ROOM"),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text("OPEN ROOM"));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    // Holding Esc on a Linux desktop auto-repeats the key, so the exit
    // handler can be invoked a second time DURING the 150ms exit
    // transition, while the fullscreen subtree (with its Focus
    // onKeyEvent) is still mounted. Real key events are not
    // deterministic here (the harness moves focus at pop time), so
    // invoke the page's exit handler directly, twice, back to back.
    final page = tester.widget<FullscreenVideoPage>(
      find.byType(FullscreenVideoPage),
    );
    page.onExit();
    page.onExit();
    await tester.pumpAndSettle();

    // Exactly one pop: fullscreen gone, the room route with the tile is
    // still on top (NOT popped back to the launcher screen).
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(find.text("VIDEO"), findsOneWidget);
    expect(find.text("OPEN ROOM"), findsNothing);
  });

  testWidgets(
      "Esc racing a simultaneous share-end: no crash, single pop, room "
      "screen intact", (tester) async {
    final showTile = ValueNotifier<bool>(true);
    addTearDown(showTile.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: ValueListenableBuilder<bool>(
                      valueListenable: showTile,
                      builder: (context, show, _) => show
                          ? const FullscreenableVideo(video: Text("VIDEO"))
                          : const Center(
                              child: Text("No one is sharing anymore."),
                            ),
                    ),
                  ),
                ),
              ),
              child: const Text("OPEN ROOM"),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text("OPEN ROOM"));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

    // The viewer hits Esc in the same window the share ends: the Esc pop
    // and the dispose()-driven auto-exit race each other.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    showTile.value = false;
    await tester.pumpAndSettle();

    // One pop total: fullscreen gone, the room route (now showing the
    // share-ended state) is still on top, launcher never resurfaced.
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    expect(find.text("No one is sharing anymore."), findsOneWidget);
    expect(find.text("OPEN ROOM"), findsNothing);
  });

  testWidgets("overlay content renders in both inline and fullscreen modes",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(
        video: Text("VIDEO"),
        overlay: Text("Streaming: chef"),
      ),
    ));
    await tester.pump();
    expect(find.text("Streaming: chef"), findsOneWidget);

    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.text("Streaming: chef"), findsOneWidget);
  });
}
