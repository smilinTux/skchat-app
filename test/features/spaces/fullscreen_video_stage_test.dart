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

  testWidgets("double-tap while fullscreen exits back to the tile",
      (tester) async {
    await tester.pumpWidget(wrap(
      const FullscreenableVideo(video: Text("VIDEO")),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text("VIDEO"));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text("VIDEO"));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
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
