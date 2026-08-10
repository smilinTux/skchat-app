import "dart:async";

import "package:fake_async/fake_async.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/screen_share_helper.dart";
import "package:skchat/features/spaces/stage_content.dart";
import "package:skchat/features/spaces/watch_drift.dart";
import "package:skchat/features/spaces/watch_session.dart";
import "package:skchat/features/spaces/watch_sync.dart" show WatchController;
import "package:skchat/services/lane_service.dart";

/// Records every publish and lets the test push inbound / catch-up events
/// without touching the network or a real LiveKit room. The two publish
/// lists (persisted vs ephemeral) are the guard against requirement 1
/// regressing: a heartbeat that ever lands in [persisted] means it would be
/// mirrored to the server lane store and replayed to every late joiner.
class FakeLane implements LaneLike {
  final _inboundCtl = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> persisted = [];
  final List<Map<String, dynamic>> ephemeral = [];
  List<Map<String, dynamic>> catchUpEvents = const [];

  @override
  Stream<Map<String, dynamic>> get inbound => _inboundCtl.stream;

  @override
  Future<void> publish(Map<String, dynamic> payload) async {
    persisted.add(payload);
  }

  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async {
    ephemeral.add(payload);
  }

  Completer<List<Map<String, dynamic>>>? _pendingCatchUp;

  @override
  Future<List<Map<String, dynamic>>> catchUp(String lane) {
    final pending = _pendingCatchUp;
    if (pending != null) return pending.future;
    return Future.value(catchUpEvents);
  }

  /// Lets a test control exactly when catchUp's "HTTP round trip" resolves,
  /// to reproduce a dispose-before-response race deterministically instead
  /// of hoping a real timing window lines up.
  Completer<List<Map<String, dynamic>>> holdCatchUp() {
    final c = Completer<List<Map<String, dynamic>>>();
    _pendingCatchUp = c;
    return c;
  }

  /// Simulate a peer's live data-channel send arriving.
  void pushInbound(Map<String, dynamic> e) => _inboundCtl.add(e);

  bool get hasListener => _inboundCtl.hasListener;

  void close() => _inboundCtl.close();
}

/// Small fake standing in for a real `video_player` / DOM element: records
/// every call so tests can assert on control flow without a platform
/// binding, and reports back whatever [PlaybackSnapshot] the test sets up.
class FakeWatchController implements WatchController {
  String? loadedUrl;
  bool playing = false;
  double _position = 0;
  bool buffering = false;
  bool rateIsNormal = true;
  final List<String> calls = [];

  @override
  void load(String url) {
    loadedUrl = url;
    calls.add("load:$url");
  }

  @override
  void play() {
    playing = true;
    calls.add("play");
  }

  @override
  void pause() {
    playing = false;
    calls.add("pause");
  }

  @override
  void seekTo(double t) {
    _position = t;
    calls.add("seekTo:$t");
  }

  @override
  double get position => _position;

  @override
  PlaybackSnapshot get playbackSnapshot => PlaybackSnapshot(
        position: _position,
        playing: playing,
        buffering: buffering,
        rateIsNormal: rateIsNormal,
      );

  @override
  void dispose() => calls.add("dispose");
}

const _args = WatchSessionArgs(spaceId: "s1", identity: "me");

/// Flushes every pending microtask (a chained `Future.then`, a broadcast
/// StreamController's async event dispatch) without a real-time wait: the
/// event loop drains the microtask queue before running any timer callback,
/// even a zero-duration one.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeLane lane;
  late FakeWatchController ctl;
  late ProviderContainer container;

  setUp(() {
    lane = FakeLane();
    ctl = FakeWatchController();
    container = ProviderContainer(overrides: [
      laneServiceFactoryProvider.overrideWithValue((args) => lane),
      watchControllerFactoryProvider.overrideWithValue(() => ctl),
    ]);
    addTearDown(container.dispose);
    addTearDown(lane.close);
  });

  // Builds the notifier (running WatchSession.build, which kicks off the
  // catchUp replay). Callers that need to control what catchUp returns MUST
  // set `lane.catchUpEvents` before calling this, not after: build() reads
  // it synchronously when constructing the replay future.
  //
  // Also keeps the autoDispose family notifier alive across the whole test
  // (mirrors confProvider's own tests, conf_identity_test.dart:161): a bare
  // container.read with nothing watching it is not guaranteed to survive
  // past a microtask boundary, and several tests below await one (the
  // catchUp replay, a pushed inbound event).
  WatchSession notifier() {
    final sub = container.listen(watchSessionProvider(_args), (_, _) {});
    addTearDown(sub.close);
    return container.read(watchSessionProvider(_args).notifier);
  }

  WatchSessionState state() => container.read(watchSessionProvider(_args));

  test("loadUrl publishes load and marks this client the video host", () {
    notifier().loadUrl("https://example.com/movie.mp4");

    expect(ctl.loadedUrl, "https://example.com/movie.mp4");
    expect(lane.persisted.single, {
      "action": "load",
      "url": "https://example.com/movie.mp4",
      "lane": "watch",
      "from": "me",
    });
    expect(lane.ephemeral, isEmpty);
    expect(state().isHostOfVideo, isTrue);
    expect(state().url, "https://example.com/movie.mp4");
  });

  test("applyRemote on a load updates state and publishes nothing (no loop)",
      () {
    notifier().applyRemote({
      "lane": "watch",
      "action": "load",
      "url": "https://x.test/y.mp4",
      "from": "someone-else",
    });

    expect(ctl.loadedUrl, "https://x.test/y.mp4");
    expect(state().url, "https://x.test/y.mp4");
    expect(lane.persisted, isEmpty);
    expect(lane.ephemeral, isEmpty);
  });

  test(
      "onHeartbeatTick publishes only when this client is the video host",
      () {
    final n = notifier();

    // Not the host yet: a tick must be a no-op.
    n.onHeartbeatTick();
    expect(lane.ephemeral, isEmpty);

    n.loadUrl("https://example.com/movie.mp4"); // becomes host
    lane.persisted.clear(); // isolate from load's own persisted publish
    ctl.seekTo(42.0);
    ctl.play();

    n.onHeartbeatTick();

    expect(lane.ephemeral.single, {
      "action": "heartbeat",
      "t": 42.0,
      "playing": true,
      "lane": "watch",
      "from": "me",
    });
    expect(lane.persisted, isEmpty);
  });

  test("a non-host receiving a heartbeat 10s ahead seeks (drift > dead band)",
      () {
    final n = notifier(); // never loaded => not host
    ctl.seekTo(0.0);
    // Starts NOT playing: seekAndPlay's own play() call is what should flip
    // this to true. Starting it true already would make that assertion
    // trivially pass even if play() were never actually invoked.
    ctl.playing = false;

    n.applyRemote(
        {"lane": "watch", "action": "heartbeat", "t": 10.0, "playing": true});

    expect(ctl.calls, contains("seekTo:10.0"));
    expect(ctl.calls, contains("play"));
    expect(ctl.playing, isTrue);
  });

  test("a non-host receiving a heartbeat 0.5s off does NOT seek", () {
    final n = notifier();
    ctl.seekTo(10.0);
    ctl.playing = true;
    final callsBefore = List<String>.from(ctl.calls);

    n.applyRemote(
        {"lane": "watch", "action": "heartbeat", "t": 10.5, "playing": true});

    // Inside the 2s dead band and play state already matches: no correction.
    expect(ctl.calls, callsBefore);
  });

  test(
      "catchUp lands a late joiner on the current url, and the FIRST live "
      "heartbeat (not a replayed one) puts them at the right position",
      () async {
    // Heartbeats structurally cannot appear in catchUp's persisted list
    // (they only ever go through publishEphemeral), so the replay here is
    // exactly what a real store would hand back: load, no heartbeats.
    lane.catchUpEvents = [
      {
        "lane": "watch",
        "action": "load",
        "url": "https://example.com/movie.mp4",
        "from": "host1",
      },
    ];

    notifier(); // triggers build(), which kicks off the catchUp replay
    await _flush();

    expect(ctl.loadedUrl, "https://example.com/movie.mp4");
    expect(state().url, "https://example.com/movie.mp4");
    // Not the loader (from == "host1", not "me"): replay must not make us
    // the authority.
    expect(state().isHostOfVideo, isFalse);

    final callsAfterReplay = List<String>.from(ctl.calls);
    expect(callsAfterReplay.any((c) => c.startsWith("seekTo")), isFalse);

    // First LIVE heartbeat: this is what actually positions the late
    // joiner, not anything replayed.
    lane.pushInbound(
        {"lane": "watch", "action": "heartbeat", "t": 87.0, "playing": true});
    await _flush();

    expect(ctl.calls, contains("seekTo:87.0"));
  });

  test(
      "catchUp resolving after dispose must not touch the disposed "
      "controller", () async {
    // A container of its own, disposed mid-test: the shared `container`
    // from setUp already has a disposal registered via addTearDown.
    final lane3 = FakeLane();
    final ctl3 = FakeWatchController();
    final c3 = ProviderContainer(overrides: [
      laneServiceFactoryProvider.overrideWithValue((args) => lane3),
      watchControllerFactoryProvider.overrideWithValue(() => ctl3),
    ]);
    var c3Disposed = false;
    addTearDown(() {
      if (!c3Disposed) c3.dispose();
    });
    addTearDown(lane3.close);

    // build() calls catchUp("watch") synchronously; holding it open means
    // that call is still in flight (exactly the join-round-trip await a
    // user backing out of the Space mid-join races against).
    final pending = lane3.holdCatchUp();
    c3.read(watchSessionProvider(_args).notifier);

    // Dispose while catchUp is still pending: ref.onDispose has now already
    // run controller.dispose() on ctl3.
    c3.dispose();
    c3Disposed = true;

    // The in-flight catchUp "arrives late" with a load event. Without the
    // disposal guard this would call controller.load() (and, on native,
    // notifyListeners()) on an already-disposed controller.
    pending.complete([
      {
        "lane": "watch",
        "action": "load",
        "url": "https://example.com/movie.mp4",
        "from": "host1",
      },
    ]);
    await _flush();

    expect(ctl3.calls, isNot(contains("load:https://example.com/movie.mp4")));
  });

  test(
      "onHeartbeatTick uses publishEphemeral, never publish, no matter how "
      "many ticks fire", () {
    final n = notifier();
    n.loadUrl("https://example.com/movie.mp4"); // becomes host

    for (var i = 0; i < 50; i++) {
      ctl.seekTo(i.toDouble());
      n.onHeartbeatTick();
    }

    expect(lane.persisted.where((p) => p["action"] == "heartbeat"), isEmpty);
    expect(
        lane.ephemeral.where((p) => p["action"] == "heartbeat").length, 50);
  });

  test("a remote load from someone else CLEARS isHostOfVideo", () {
    final n = notifier();
    n.loadUrl("https://mine.test/a.mp4");
    expect(state().isHostOfVideo, isTrue);

    n.applyRemote({
      "lane": "watch",
      "action": "load",
      "url": "https://theirs.test/b.mp4",
      "from": "someone-else",
    });

    expect(state().isHostOfVideo, isFalse);
  });

  test("a catch-up load whose from == our identity RESTORES isHostOfVideo",
      () async {
    lane.catchUpEvents = [
      {
        "lane": "watch",
        "action": "load",
        "url": "https://mine.test/a.mp4",
        "from": "me", // matches _args.identity
      },
    ];

    notifier();
    await _flush();

    expect(state().isHostOfVideo, isTrue);
    expect(state().url, "https://mine.test/a.mp4");
  });

  test("the host never applies drift correction to itself (rule 4)", () {
    final n = notifier();
    n.loadUrl("https://example.com/movie.mp4"); // isHostOfVideo = true
    ctl.seekTo(0.0);
    final callsBefore = List<String>.from(ctl.calls);

    // A wildly different position: if the host ever corrected toward an
    // inbound heartbeat, two authorities would fight (each corrects toward
    // the other, and the room oscillates instead of converging).
    n.applyRemote(
        {"lane": "watch", "action": "heartbeat", "t": 500.0, "playing": true});

    expect(ctl.calls, callsBefore);
  });

  test(
      "ref.onDispose tears down the controller and the lane subscription",
      () {
    // A container of its own: the shared `container` from setUp already has
    // a disposal registered via addTearDown, and ProviderContainer.dispose
    // is not safe to call twice.
    final lane2 = FakeLane();
    final ctl2 = FakeWatchController();
    final c2 = ProviderContainer(overrides: [
      laneServiceFactoryProvider.overrideWithValue((args) => lane2),
      watchControllerFactoryProvider.overrideWithValue(() => ctl2),
    ]);
    addTearDown(lane2.close);
    // Safety net, not the primary assertion path: if an expect below throws
    // before the explicit c2.dispose() call is reached, this still cleans
    // c2 up instead of leaking it into later tests. Guarded so the explicit
    // dispose call further down doesn't double-dispose.
    var c2Disposed = false;
    addTearDown(() {
      if (!c2Disposed) c2.dispose();
    });

    final n = c2.read(watchSessionProvider(_args).notifier);
    n.loadUrl("https://example.com/movie.mp4");
    expect(lane2.hasListener, isTrue);

    c2.dispose();
    c2Disposed = true;

    expect(ctl2.calls, contains("dispose"));
    expect(lane2.hasListener, isFalse);
  });

  test(
      "the heartbeat Timer actually fires while alive, and stops firing "
      "once disposed", () {
    fakeAsync((async) {
      final lane2 = FakeLane();
      final ctl2 = FakeWatchController();
      final c2 = ProviderContainer(overrides: [
        laneServiceFactoryProvider.overrideWithValue((args) => lane2),
        watchControllerFactoryProvider.overrideWithValue(() => ctl2),
      ]);
      var c2Disposed = false;
      addTearDown(() {
        if (!c2Disposed) c2.dispose();
      });
      addTearDown(lane2.close);

      // Keep the autoDispose notifier alive for the span of this fake-async
      // zone the same way `notifier()` does for the other tests above.
      final sub = c2.listen(watchSessionProvider(_args), (_, _) {});
      final n = c2.read(watchSessionProvider(_args).notifier);
      n.loadUrl("https://example.com/movie.mp4"); // becomes host

      // Nobody calls onHeartbeatTick() directly here: only simulated
      // wall-clock time elapsing drives it, which is what actually exercises
      // the Timer.periodic wiring in build() (every other test in this file
      // calls onHeartbeatTick() directly and would stay green even if that
      // wiring were deleted).
      async.elapse(const Duration(seconds: 3));
      expect(
          lane2.ephemeral.where((p) => p["action"] == "heartbeat").length,
          1);

      sub.close();
      c2.dispose();
      c2Disposed = true;

      // The exact failure mode a leaked Timer produces: heartbeats keep
      // firing into a room this client already left. 10 more ticks' worth
      // of elapsed time must produce zero further heartbeats.
      async.elapse(const Duration(seconds: 30));
      expect(
          lane2.ephemeral.where((p) => p["action"] == "heartbeat").length,
          1);
    });
  });

  test(
      "stopWatching publishes stop on the PERSISTED path and clears the "
      "session", () {
    final n = notifier();
    n.loadUrl("https://example.com/movie.mp4"); // becomes host, isActive
    lane.persisted.clear(); // isolate from load's own persisted publish
    expect(state().isActive, isTrue);

    n.stopWatching();

    // Persisted, not ephemeral: a late joiner's catchUp must replay this
    // stop, or they would be handed a stale load for a session that already
    // ended (see the ephemeral-heartbeat reasoning above for the mirror
    // image of this same catchUp-replay concern).
    expect(lane.persisted.single, {
      "action": "stop",
      "lane": "watch",
      "from": "me",
    });
    expect(state().isActive, isFalse);
    expect(state().isHostOfVideo, isFalse);
    expect(resolveStageKind(videos: const <StageVideo>[], watchActive: state().isActive),
        StageKind.none);
  });

  test("a REMOTE stop clears the session locally without republishing", () {
    final n = notifier();
    // Someone else is the host; we are just a viewer with a session loaded
    // via the existing catch-up/live-load path.
    n.applyRemote({
      "lane": "watch",
      "action": "load",
      "url": "https://theirs.test/movie.mp4",
      "from": "someone-else",
    });
    expect(state().isActive, isTrue);
    lane.persisted.clear();
    lane.ephemeral.clear();

    n.applyRemote({
      "lane": "watch",
      "action": "stop",
      "from": "someone-else",
    });

    expect(state().isActive, isFalse);
    expect(state().isHostOfVideo, isFalse);
    // No republish: applying a REMOTE stop must not re-broadcast it, or
    // every client that ever received one would echo it right back.
    expect(lane.persisted, isEmpty);
    expect(lane.ephemeral, isEmpty);
    expect(resolveStageKind(videos: const <StageVideo>[], watchActive: state().isActive),
        StageKind.none);
  });
}
