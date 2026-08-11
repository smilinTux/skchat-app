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
        watchSessionProvider,
        WatchSessionArgs;
import "package:skchat/features/spaces/watch_sync.dart" show WatchController;
import "package:skchat/features/spaces/watch_video_stub.dart"
    if (dart.library.html) "package:skchat/features/spaces/watch_video_web.dart"
    show WatchVideo;
import "package:skchat/services/lane_service.dart" show LaneLike;

/// Records every publish instead of hitting the real LiveKit data channel /
/// HTTP mirror. Mirrors `FakeLane` in watch_session_test.dart, trimmed to
/// what this file's assertions need.
class FakeLane implements LaneLike {
  final List<Map<String, dynamic>> persisted = [];

  @override
  Stream<Map<String, dynamic>> get inbound => const Stream.empty();

  @override
  Future<void> publish(Map<String, dynamic> payload) async {
    persisted.add(payload);
  }

  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async {}

  @override
  Future<List<Map<String, dynamic>>> catchUp(String lane) async => const [];
}

/// Stands in for the real `video_player` / DOM element so `loadUrl` never
/// touches a platform channel. Mirrors `FakeWatchController` in
/// watch_session_test.dart, trimmed to what this file's assertions need.
class FakeWatchController implements WatchController {
  String? loadedUrl;
  double _position = 0;
  double rate = 1.0;

  @override
  void load(String url) => loadedUrl = url;

  @override
  void play() {}

  @override
  void pause() {}

  @override
  void seekTo(double t) => _position = t;

  @override
  void setRate(double r) => rate = r;

  @override
  double get position => _position;

  @override
  PlaybackSnapshot get playbackSnapshot =>
      PlaybackSnapshot(position: _position, playing: false, rate: rate);

  @override
  void dispose() {}
}

const _args = WatchSessionArgs(spaceId: "s1", identity: "chef@dk.skworld");

void main() {
  late FakeLane lane;
  late FakeWatchController ctl;

  setUp(() {
    lane = FakeLane();
    ctl = FakeWatchController();
  });

  Widget wrap() {
    return ProviderScope(
      overrides: [
        laneServiceFactoryProvider.overrideWithValue((args) => lane),
        watchControllerFactoryProvider.overrideWithValue(() => ctl),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: WatchPanel(spaceId: "s1", identity: "chef@dk.skworld"),
        ),
      ),
    );
  }

  testWidgets(
      "the panel mounts no video surface: the stage is the only "
      "HtmlElementView owner for the shared controller", (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    // BUG A / the shared-viewType constraint: if the panel EVER builds a
    // second WatchVideo for the same controller, web keys the platform view
    // on controller identity (watch_video_web.dart) and the second mount
    // steals the DOM element out from under the stage's.
    expect(find.byType(WatchVideo), findsNothing);
  });

  testWidgets(
      "Stop watching is hidden with no active session and appears once one "
      "is loaded", (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.text("Stop watching"), findsNothing);

    await tester.enterText(
        find.byType(TextField), "https://example.com/movie.mp4");
    await tester.tap(find.text("Load"));
    await tester.pump();

    expect(find.text("Stop watching"), findsOneWidget);
  });

  testWidgets(
      "the transport controls are hidden with no active session, so Play "
      "cannot resume a stopped video with no stage mounted", (tester) async {
    // Stop makes isActive false while the controller still holds the loaded
    // media, and the stage surface is gated on isActive too. An ungated Play
    // would therefore resume the old source with no player anywhere on
    // screen, which on web means an mp4 decoding audio out of nowhere.
    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.byTooltip("Play (synced)"), findsNothing);
    expect(find.byTooltip("Pause (synced)"), findsNothing);
    expect(find.byTooltip("Sync everyone to my position"), findsNothing);

    await tester.enterText(
        find.byType(TextField), "https://example.com/movie.mp4");
    await tester.tap(find.text("Load"));
    await tester.pump();

    expect(find.byTooltip("Play (synced)"), findsOneWidget);

    await tester.tap(find.text("Stop watching"));
    await tester.pump();

    expect(find.byTooltip("Play (synced)"), findsNothing,
        reason: "Play must not survive a stop, the stage is gone");
  });

  testWidgets("tapping Stop watching ends the session for everyone",
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.enterText(
        find.byType(TextField), "https://example.com/movie.mp4");
    await tester.tap(find.text("Load"));
    await tester.pump();
    lane.persisted.clear(); // isolate from load's own persisted publish

    await tester.tap(find.text("Stop watching"));
    await tester.pump();

    expect(lane.persisted.single, {
      "action": "stop",
      "lane": "watch",
      "from": "chef@dk.skworld",
    });
    final element = tester.element(find.byType(WatchPanel));
    final container = ProviderScope.containerOf(element);
    expect(container.read(watchSessionProvider(_args)).isActive, isFalse);
    expect(find.text("Stop watching"), findsNothing);
  });

  testWidgets("tapping Load publishes the typed URL to the watch lane",
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(
        find.byType(TextField), "https://example.com/movie.mp4");
    await tester.tap(find.text("Load"));
    await tester.pump();

    expect(lane.persisted.single, {
      "action": "load",
      "url": "https://example.com/movie.mp4",
      "lane": "watch",
      "from": "chef@dk.skworld",
    });
  });

  testWidgets(
      "loading through the panel drives the SHARED session, so the "
      "loader's own stage populates (BUG B)", (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(
        find.byType(TextField), "https://example.com/movie.mp4");
    await tester.tap(find.text("Load"));
    await tester.pump();

    // The stage reads watchSessionProvider(WatchSessionArgs(spaceId,
    // identity)) built from the same SpaceJoin fields the panel is
    // constructed with (space_room_screen.dart). Resolving the identical
    // args here and finding the url already set proves the panel drove that
    // SAME session, not a private controller of its own: the person who
    // just loaded the video would see it on their own stage.
    final element = tester.element(find.byType(WatchPanel));
    final container = ProviderScope.containerOf(element);
    final state = container.read(watchSessionProvider(_args));

    expect(state.url, "https://example.com/movie.mp4");
    expect(ctl.loadedUrl, "https://example.com/movie.mp4");
  });
}
