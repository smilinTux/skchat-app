import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/zoomable_video.dart";

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  InteractiveViewer viewerOf(WidgetTester tester) =>
      tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));

  /// Pinches out (zooms in) on the [ZoomableVideo] under test using two
  /// synthetic pointers, mirroring the pattern Flutter's own
  /// InteractiveViewer tests use to drive its ScaleGestureRecognizer.
  Future<void> pinchZoomIn(WidgetTester tester) async {
    final center = tester.getCenter(find.byType(ZoomableVideo));
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
  }

  testWidgets("wraps the child in an InteractiveViewer with the expected "
      "min/max scale and bounded panning", (tester) async {
    await tester.pumpWidget(wrap(
      const ZoomableVideo(child: Text("VIDEO")),
    ));

    expect(find.text("VIDEO"), findsOneWidget);
    final viewer = viewerOf(tester);
    expect(viewer.minScale, 1.0);
    expect(viewer.maxScale, 5.0);
    expect(viewer.panEnabled, isTrue);
    expect(viewer.scaleEnabled, isTrue);
    // Zero boundary margin (InteractiveViewer's own default) keeps the
    // child from ever being panned fully off-screen.
    expect(viewer.boundaryMargin, EdgeInsets.zero);
  });

  testWidgets("a pinch/scale gesture changes the transform", (tester) async {
    final controller = ZoomableVideoController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(
      ZoomableVideo(
        controller: controller,
        child: const SizedBox(width: 200, height: 200, child: Text("VIDEO")),
      ),
    ));

    expect(controller.transformationController.value, Matrix4.identity());

    await pinchZoomIn(tester);

    expect(controller.transformationController.value, isNot(Matrix4.identity()));
  });

  testWidgets("double-tap resets the transform back to identity by default",
      (tester) async {
    final controller = ZoomableVideoController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(
      ZoomableVideo(
        controller: controller,
        child: const SizedBox(width: 200, height: 200, child: Text("VIDEO")),
      ),
    ));

    await pinchZoomIn(tester);
    expect(controller.transformationController.value, isNot(Matrix4.identity()));

    final center = tester.getCenter(find.byType(ZoomableVideo));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    expect(controller.transformationController.value, Matrix4.identity());
  });

  testWidgets(
      "enableInternalDoubleTapReset: false installs no double-tap gesture "
      "of its own, so an ancestor's double-tap is free to fire unambiguously",
      (tester) async {
    var ancestorDoubleTapCount = 0;
    final controller = ZoomableVideoController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(
      GestureDetector(
        onDoubleTap: () => ancestorDoubleTapCount++,
        child: ZoomableVideo(
          controller: controller,
          enableInternalDoubleTapReset: false,
          child: const SizedBox(width: 200, height: 200, child: Text("VIDEO")),
        ),
      ),
    ));

    await pinchZoomIn(tester);
    expect(controller.transformationController.value, isNot(Matrix4.identity()));

    final center = tester.getCenter(find.byType(ZoomableVideo));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    // The ancestor's double-tap fired exactly once (no competing internal
    // recognizer), and the zoom was NOT reset by it.
    expect(ancestorDoubleTapCount, 1);
    expect(controller.transformationController.value, isNot(Matrix4.identity()));
  });

  testWidgets(
      "an external ZoomableVideoController.reset() works even when the "
      "internal double-tap gesture is disabled (the fullscreen-page wiring)",
      (tester) async {
    final controller = ZoomableVideoController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(
      ZoomableVideo(
        controller: controller,
        enableInternalDoubleTapReset: false,
        child: const SizedBox(width: 200, height: 200, child: Text("VIDEO")),
      ),
    ));

    await pinchZoomIn(tester);
    expect(controller.transformationController.value, isNot(Matrix4.identity()));

    controller.reset();
    await tester.pumpAndSettle();

    expect(controller.transformationController.value, Matrix4.identity());
  });

  testWidgets("controller.reset() is a safe no-op before/after the widget "
      "is mounted", (tester) async {
    final controller = ZoomableVideoController();
    addTearDown(controller.dispose);

    // Not mounted yet: reset() must not throw.
    expect(controller.reset, returnsNormally);

    final show = ValueNotifier<bool>(true);
    addTearDown(show.dispose);
    await tester.pumpWidget(wrap(
      ValueListenableBuilder<bool>(
        valueListenable: show,
        builder: (context, visible, _) => visible
            ? ZoomableVideo(controller: controller, child: const Text("VIDEO"))
            : const Text("GONE"),
      ),
    ));

    show.value = false;
    await tester.pumpAndSettle();

    // Unmounted now: reset() must still not throw.
    expect(controller.reset, returnsNormally);
  });
}
