import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";
import "../../services/spaces_service.dart" show kDefaultWebuiUrl;
import "watch_drift.dart";
import "watch_sync.dart";
import "watch_video_stub.dart" if (dart.library.html) "watch_video_web.dart"
    as real;

/// Room-scoped Watch Together session: owns the video controller AND the
/// "watch" lane subscription together, so they share one lifecycle. Both
/// used to live in `_WatchPanelState`, which is the bug this task fixes:
/// closing the bottom-sheet panel destroyed the lane subscription along with
/// playback, silently dropping the viewer out of sync with the room even
/// though the video kept "playing" underneath. A later task points the
/// panel and the fullscreen stage at THIS provider instead so both share the
/// same session and neither owns teardown alone.
// ── Controller seam ─────────────────────────────────────────────────────────

/// The control surface [WatchSession] drives. Matches the public API both
/// platform `WatchVideoController`s (native `watch_video_stub.dart`, web
/// `watch_video_web.dart`) already expose; factored out here, rather than
/// depending on either concrete class directly, so a test can supply a fake
/// controller instead of driving a real `video_player` / DOM element (heavy,
/// and the native controller needs platform-channel bindings a plain
/// `flutter test` doesn't have).
abstract class WatchController implements WatchPlaybackTarget {
  double get position;
  PlaybackSnapshot get playbackSnapshot;
  void dispose();
}

/// Adapts the real platform controller (picked by the conditional import
/// above) to [WatchController]. Thin pass-through: no behavior of its own,
/// just satisfies the interface without editing either platform controller
/// file (out of scope for this task).
class _RealWatchController implements WatchController {
  _RealWatchController() : _c = real.WatchVideoController();

  final real.WatchVideoController _c;

  @override
  void load(String url) => _c.load(url);

  @override
  void play() => _c.play();

  @override
  void pause() => _c.pause();

  @override
  void seekTo(double t) => _c.seekTo(t);

  @override
  double get position => _c.position;

  @override
  PlaybackSnapshot get playbackSnapshot => _c.playbackSnapshot;

  @override
  void dispose() => _c.dispose();
}

/// DI seam around constructing the real [WatchController], mirroring the
/// [laneServiceFactoryProvider] pattern (also
/// `screenShareSourceResolverProvider` in call_shared/screen_share_source.dart):
/// production code never overrides this, a test substitutes a fake
/// controller instead of exercising a real `video_player` / DOM element.
typedef WatchControllerFactory = WatchController Function();

final watchControllerFactoryProvider = Provider<WatchControllerFactory>(
  (ref) => () => _RealWatchController(),
);

// ── Lane seam ────────────────────────────────────────────────────────────────

/// DI seam around constructing the room's [LaneLike], mirroring
/// [watchControllerFactoryProvider]: production code never overrides this,
/// a test substitutes a fake lane instead of exercising the real LiveKit
/// data channel + HTTP mirror.
typedef LaneServiceFactory = LaneLike Function(WatchSessionArgs args);

final laneServiceFactoryProvider = Provider<LaneServiceFactory>(
  (ref) => (args) => LaneService(
        livekit: ref.read(liveKitCallServiceProvider),
        baseUrl: kDefaultWebuiUrl,
        spaceId: args.spaceId,
      ),
);

// ── Family key ───────────────────────────────────────────────────────────────

/// Family key for [watchSessionProvider]. MUST have value equality: the
/// panel and the fullscreen stage each build their own [WatchSessionArgs]
/// instance for the same room. Riverpod family lookup keys on `==`/
/// `hashCode`, so without them the panel and the stage would resolve to TWO
/// different [WatchSession] notifiers, each with its own lane subscription
/// and its own (possibly conflicting) `isHostOfVideo` flag. `SpaceJoin`
/// (space_room_screen.dart) and `ConfArgs` (conf_screen.dart) skip this only
/// because a single widget-owned instance flows to every `ref.watch`/`read`
/// call site; Watch Together has no such single instance to share.
class WatchSessionArgs {
  const WatchSessionArgs({required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  bool operator ==(Object other) =>
      other is WatchSessionArgs &&
      other.spaceId == spaceId &&
      other.identity == identity;

  @override
  int get hashCode => Object.hash(spaceId, identity);
}

// ── State ────────────────────────────────────────────────────────────────────

class WatchSessionState {
  const WatchSessionState({
    this.url,
    this.isPlaying = false,
    this.isHostOfVideo = false,
  });

  final String? url;
  final bool isPlaying;
  final bool isHostOfVideo;

  WatchSessionState copyWith({
    String? url,
    bool? isPlaying,
    bool? isHostOfVideo,
  }) =>
      WatchSessionState(
        url: url ?? this.url,
        isPlaying: isPlaying ?? this.isPlaying,
        isHostOfVideo: isHostOfVideo ?? this.isHostOfVideo,
      );
}

// ── Notifier ─────────────────────────────────────────────────────────────────

class WatchSession extends AutoDisposeFamilyNotifier<WatchSessionState,
    WatchSessionArgs> {
  late final WatchController controller;
  late final LaneLike _lane;
  Timer? _heartbeatTimer;

  @override
  WatchSessionState build(WatchSessionArgs arg) {
    controller = ref.read(watchControllerFactoryProvider)();
    _lane = ref.read(laneServiceFactoryProvider)(arg);

    // Replay persisted state for a late joiner: load/play/pause/seek, in
    // order. Heartbeats are never in this list (they publish through
    // publishEphemeral, which never mirrors to the store), so the first
    // position fix a late joiner sees comes from the first LIVE heartbeat,
    // not a stale replayed one.
    _lane.catchUp("watch").then((events) {
      for (final e in events) {
        applyRemote(e);
      }
    });

    final sub =
        _lane.inbound.where((j) => j["lane"] == "watch").listen(applyRemote);

    // Only the client that loaded the video publishes heartbeats (see
    // onHeartbeatTick). Every OTHER client corrects toward what it hears.
    // Live, not persisted: see LaneService.publishEphemeral for why a
    // persisted heartbeat every 3s would flood the lane store.
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => onHeartbeatTick());

    // autoDispose is load-bearing here, not incidental: a keepAlive family
    // member never runs this, so leaving the Space would leave this Timer
    // heartbeating into a disconnected room forever, and the lane
    // subscription and controller (a real video_player on native) would
    // leak with it.
    ref.onDispose(() {
      sub.cancel();
      _heartbeatTimer?.cancel();
      controller.dispose();
    });

    return const WatchSessionState();
  }

  Future<void> _publish(Map<String, dynamic> payload) {
    payload["lane"] = "watch";
    payload["from"] = arg.identity;
    return _lane.publish(payload);
  }

  Future<void> _publishEphemeral(Map<String, dynamic> payload) {
    payload["lane"] = "watch";
    payload["from"] = arg.identity;
    return _lane.publishEphemeral(payload);
  }

  /// Local load: this client becomes the video's authority. See
  /// [applyRemote] for the mirror image (a REMOTE load clears the flag).
  void loadUrl(String url) {
    controller.load(url);
    state = state.copyWith(url: url, isHostOfVideo: true);
    _publish({"action": "load", "url": url});
  }

  void play() {
    controller.play();
    state = state.copyWith(isPlaying: true);
    _publish({"action": "play", "t": controller.position});
  }

  void pause() {
    controller.pause();
    state = state.copyWith(isPlaying: false);
    _publish({"action": "pause", "t": controller.position});
  }

  /// "Sync everyone to my position": re-broadcasts this client's current
  /// position as an authoritative seek, same as the panel's existing sync
  /// button.
  void syncPosition() {
    final t = controller.position;
    controller.seekTo(t);
    _publish({"action": "seek", "t": t});
  }

  /// Only the client that loaded the video publishes heartbeats. Two
  /// authorities would fight: each would correct toward the other and the
  /// room would oscillate.
  ///
  /// EPHEMERAL on purpose. A persisted heartbeat every 3s would put ~2400
  /// events in the lane store for a two hour movie, and catchUp replays the
  /// whole list to every late joiner, which is a seek storm ending on a
  /// stale position. Live heartbeats arrive within 3s anyway.
  void onHeartbeatTick() {
    if (!state.isHostOfVideo) return;
    final s = controller.playbackSnapshot;
    if (!s.rateIsNormal) return; // do not guess at a non-1.0 rate
    _publishEphemeral(
        {"action": "heartbeat", "t": s.position, "playing": s.playing});
  }

  void _applyHeartbeat(double hostPosition, bool hostPlaying) {
    if (state.isHostOfVideo) return; // never correct the authority
    final action = resolveDrift(
      local: controller.playbackSnapshot,
      hostPosition: hostPosition,
      hostPlaying: hostPlaying,
    );
    switch (action) {
      case DriftAction.none:
        break;
      case DriftAction.seekAndPlay:
        controller
          ..seekTo(hostPosition)
          ..play();
        break;
      case DriftAction.seekAndPause:
        controller
          ..seekTo(hostPosition)
          ..pause();
        break;
      case DriftAction.playOnly:
        controller.play();
        break;
      case DriftAction.pauseOnly:
        controller.pause();
        break;
    }
  }

  /// Apply a single inbound (or catch-up replayed) "watch" lane event.
  /// Called from both the live [_lane.inbound] subscription and the
  /// [_lane.catchUp] replay in [build], never for a locally-originated
  /// action (those go through [loadUrl]/[play]/[pause]/[syncPosition],
  /// which publish instead of applying).
  ///
  /// Host-authority bookkeeping rides on the SAME "from == our identity"
  /// check for both paths, which is what makes rules 2 and 3 below fall out
  /// of one line instead of needing a separate catch-up-vs-live branch:
  /// LiveKit never loops a live data-channel send back to its own sender,
  /// so a LIVE "load" event's `from` can never equal [arg.identity] (always
  /// clears). `catchUp` DOES replay our own past events, so a REPLAYED
  /// "load" whose `from` equals [arg.identity] restores the flag (we were,
  /// and still are, the loader).
  void applyRemote(Map<String, dynamic> e) {
    final action = e["action"];
    if (action == "heartbeat") {
      final t = (e["t"] as num?)?.toDouble();
      final playing = e["playing"] as bool? ?? false;
      if (t != null) _applyHeartbeat(t, playing);
      return;
    }
    // Everything else (load/play/pause/seek) is the wire-compatible mapper
    // an older client also understands; heartbeat is additive on top of it.
    applyWatchEvent(controller, e);
    switch (action) {
      case "load":
        state = state.copyWith(
          url: e["url"] as String?,
          isHostOfVideo: e["from"] == arg.identity,
        );
        break;
      case "play":
        state = state.copyWith(isPlaying: true);
        break;
      case "pause":
        state = state.copyWith(isPlaying: false);
        break;
    }
  }
}

final watchSessionProvider = AutoDisposeNotifierProviderFamily<WatchSession,
    WatchSessionState, WatchSessionArgs>(WatchSession.new);
