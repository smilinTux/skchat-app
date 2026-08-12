import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";
import "../../services/backend_config.dart" show backendConfigProvider;
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
//
// WatchController itself lives in watch_sync.dart, not here: both platform
// WatchVideoControllers (watch_video_stub.dart, watch_video_web.dart)
// implement it directly, so the REAL controller instance (not a wrapper
// hiding it behind a private field) flows out of [controller] with its
// concrete type intact, renderable by WatchVideo on either platform. A test
// substitutes a fake implementation instead of driving a real video_player /
// DOM element.

/// DI seam around constructing the real [WatchController], mirroring
/// [laneServiceFactoryProvider] (also `screenShareSourceResolverProvider` in
/// call_shared/screen_share_source.dart): production code never overrides
/// this, a test substitutes a fake controller instead of exercising a real
/// `video_player` / DOM element.
typedef WatchControllerFactory = WatchController Function();

final watchControllerFactoryProvider = Provider<WatchControllerFactory>(
  (ref) => () => real.WatchVideoController(),
);

// ── Lane seam ────────────────────────────────────────────────────────────────

/// DI seam around constructing the room's [LaneLike], mirroring
/// [watchControllerFactoryProvider]: production code never overrides this,
/// a test substitutes a fake lane instead of exercising the real LiveKit
/// data channel + HTTP mirror.
typedef LaneServiceFactory = LaneLike Function(WatchSessionArgs args);

final laneServiceFactoryProvider = Provider<LaneServiceFactory>((ref) {
  // RUNTIME base, not the compile-time constant. kDefaultWebuiUrl defaults to
  // "" and the web deploy passes no SKCHAT_WEBUI_URL dart-define, so building
  // the lane with it sent every HTTP call to an empty base, where it failed
  // into LaneService's swallowing catch. Live play/pause/rate still worked
  // because those ride the LiveKit data channel, so the only visible symptom
  // was that catch-up replay gave a late joiner nothing. Mirrors how
  // spacesServiceProvider resolves its base (spaces_service.dart).
  final base = ref.watch(backendConfigProvider.select((c) => c.skchatWebuiUrl));
  return (args) => LaneService(
        livekit: ref.read(liveKitCallServiceProvider),
        baseUrl: base,
        spaceId: args.spaceId,
      );
});

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
    this.rate = 1.0,
  });

  final String? url;
  final bool isPlaying;
  final bool isHostOfVideo;

  /// The room's agreed playback speed: shared state, not a per-viewer
  /// preference (Chef chose "sync the speed to everyone" over letting each
  /// viewer run their own). Set locally by [WatchSession.setRate] and by a
  /// remote "rate" lane event in [WatchSession.applyRemote], and consulted
  /// by [WatchSession._applyHeartbeat] as the `sessionRate` drift correction
  /// compares the local player's actual rate against.
  final double rate;

  /// A video is loaded, so the stage has something to show. Drives
  /// [StageKind.watch]/[resolveStageKind] (stage_content.dart): the stage
  /// only claims space for Watch Together once a URL has actually been
  /// loaded, not the instant the session/provider itself comes into
  /// existence.
  bool get isActive => url != null;

  /// [clearUrl] is an explicit sentinel, not folded into the nullable [url]
  /// parameter: `url ?? this.url` can never express "set it to null", so
  /// ending a session (see [WatchSession.stopWatching]) needs its own way
  /// to say "clear it" that a plain `copyWith(url: null)` call cannot reach.
  WatchSessionState copyWith({
    String? url,
    bool clearUrl = false,
    bool? isPlaying,
    bool? isHostOfVideo,
    double? rate,
  }) =>
      WatchSessionState(
        url: clearUrl ? null : (url ?? this.url),
        isPlaying: isPlaying ?? this.isPlaying,
        isHostOfVideo: isHostOfVideo ?? this.isHostOfVideo,
        rate: rate ?? this.rate,
      );
}

// ── Notifier ─────────────────────────────────────────────────────────────────

class WatchSession extends AutoDisposeFamilyNotifier<WatchSessionState,
    WatchSessionArgs> {
  late final WatchController controller;
  late final LaneLike _lane;
  Timer? _heartbeatTimer;

  /// Set (only) inside [ref.onDispose]. Guards every continuation that can
  /// resume after disposal: [_lane.catchUp]'s HTTP round trip is exactly the
  /// kind of await a user backing out of the Space mid-join races against,
  /// and once ref.onDispose has run, [controller] is already disposed
  /// (native: a disposed ChangeNotifier throws on notifyListeners; web:
  /// mutates a detached DOM element either way). Mirrors the `_disposed`
  /// flag `SpaceRoomNotifier` (space_room_screen.dart) already uses for the
  /// identical class of race on its own post-await state writes.
  bool _disposed = false;

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
      if (_disposed) return;
      for (final e in events) {
        if (_disposed) return;
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
      _disposed = true;
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
    // Speed is per-video, not a sticky room preference: carrying 2x into an
    // unrelated video is a surprise, and the viewer who set it may not be the
    // one loading next. The reset rides the load event rather than a separate
    // rate publish, so there is no extra message and no race between the reset
    // and the loader's next rate change.
    controller.setRate(1.0);
    state = state.copyWith(url: url, isHostOfVideo: true, rate: 1.0);
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

  /// Local speed change: sets the controller's rate, updates state, and
  /// publishes PERSISTED (not ephemeral), same as [loadUrl]/[play]/[pause]/
  /// [syncPosition]. Persisted on purpose: a late joiner's [catchUp] must
  /// replay it, or they would arrive at the room's current speed only by
  /// coincidence instead of by design, landing at 1x until the next live
  /// "rate" event happened to fire.
  void setRate(double rate) {
    controller.setRate(rate);
    state = state.copyWith(rate: rate);
    _publish({"action": "rate", "rate": rate});
  }

  /// "Sync everyone to my position": re-broadcasts this client's current
  /// position as an authoritative seek, same as the panel's existing sync
  /// button.
  void syncPosition() {
    final t = controller.position;
    controller.seekTo(t);
    _publish({"action": "seek", "t": t});
  }

  /// End the watch session for everyone: without this, nothing ever clears
  /// `url` (see [WatchSessionState.isActive]), so once anyone loads a video
  /// it owns the main stage for the life of the room with no way to reclaim
  /// it. Publishes PERSISTED (not ephemeral), same as [loadUrl]/[play]/
  /// [pause]/[syncPosition]: a late joiner's catchUp must replay this stop,
  /// or [loadUrl]'s own persisted `load` event would re-establish the ended
  /// session for them.
  void stopWatching() {
    controller.pause();
    state = state.copyWith(
        clearUrl: true, isHostOfVideo: false, isPlaying: false);
    _publish({"action": "stop"});
  }

  /// Only the client that loaded the video publishes heartbeats. Two
  /// authorities would fight: each would correct toward the other and the
  /// room would oscillate.
  ///
  /// EPHEMERAL on purpose. A persisted heartbeat every 3s would put ~2400
  /// events in the lane store for a two hour movie, and catchUp replays the
  /// whole list to every late joiner, which is a seek storm ending on a
  /// stale position. Live heartbeats arrive within 3s anyway.
  ///
  /// Publishes at ANY rate, including a non-1x one. This used to bail out
  /// whenever the snapshot's rate wasn't 1.0, on the theory that an unsynced
  /// rate was unknowable and therefore not worth reporting; that theory made
  /// this host stop heartbeating the instant it ran at 1.5x, and the whole
  /// room silently drifted apart with no heartbeats to catch it. Now that
  /// rate is shared state (see [setRate]), the host's own rate is exactly as
  /// knowable and exactly as worth reporting as its position always was.
  void onHeartbeatTick() {
    if (!state.isHostOfVideo) return;
    final s = controller.playbackSnapshot;
    _publishEphemeral(
        {"action": "heartbeat", "t": s.position, "playing": s.playing});
  }

  void _applyHeartbeat(double hostPosition, bool hostPlaying) {
    if (state.isHostOfVideo) return; // never correct the authority
    final local = controller.playbackSnapshot;
    final action = resolveDrift(
      local: local,
      hostPosition: hostPosition,
      hostPlaying: hostPlaying,
      sessionRate: state.rate,
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
    if (_disposed) return;
    final action = e["action"];
    if (action == "heartbeat") {
      final t = (e["t"] as num?)?.toDouble();
      final playing = e["playing"] as bool? ?? false;
      if (t != null) _applyHeartbeat(t, playing);
      return;
    }
    if (action == "rate") {
      // Mirror of setRate() for a REMOTE rate change: apply it locally
      // WITHOUT republishing, same no-loop discipline as heartbeat/stop
      // above, or every client that ever received one would echo it right
      // back onto the lane. ADDITIVE on the wire: an older client's
      // applyWatchEvent has no "rate" case, so it falls into that switch's
      // existing `default:` branch and simply ignores it.
      final r = (e["rate"] as num?)?.toDouble();
      if (r != null) {
        controller.setRate(r);
        state = state.copyWith(rate: r);
      }
      return;
    }
    if (action == "stop") {
      // Mirror of stopWatching() for a REMOTE stop: clear local state and
      // pause playback without publishing again, or every client that
      // received a stop would immediately echo it back out. ADDITIVE on the
      // wire: an older client's applyWatchEvent has no "stop" case, so it
      // falls into that switch's existing `default:` branch and simply
      // ignores it, same as any other action it predates.
      controller.pause();
      state = state.copyWith(
          clearUrl: true, isHostOfVideo: false, isPlaying: false);
      return;
    }
    // Everything else (load/play/pause/seek) is the wire-compatible mapper
    // an older client also understands; heartbeat and stop are additive on
    // top of it.
    applyWatchEvent(controller, e);
    switch (action) {
      case "load":
        // Mirror of loadUrl's reset: every client drops to 1x on a load, which
        // is what lets the reset ride the load event instead of needing its
        // own publish.
        controller.setRate(1.0);
        state = state.copyWith(
          url: e["url"] as String?,
          isHostOfVideo: e["from"] == arg.identity,
          rate: 1.0,
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
