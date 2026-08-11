import "package:flutter/material.dart";
import "package:video_player/video_player.dart";

import "watch_drift.dart";
import "watch_sync.dart";

/// Native (mobile / desktop) watch-together video surface.
///
/// This is the non-web side of the conditional import seam, which lives in
/// `watch_session.dart` and `space_room_screen.dart` (`watch_video_stub.dart
/// if (dart.library.html) watch_video_web.dart`), not in `watch_panel.dart`
/// (moved there after the panel refactor). Despite the historical "stub"
/// filename, this is a REAL player, not a placeholder.
///
/// It mirrors the public API of the web controller (`watch_video_web.dart`) so
/// the conditional import compiles identically on every target, and it is
/// driven by the SAME "watch" lane events the web client consumes (via
/// [applyWatchEvent]), emitting the same events on local control, so
/// web <-> native participants stay in sync.
///
/// Source handling, parity with web:
///  * **Direct file** (`.mp4`/`.webm`/… or any non-YouTube/Rumble URL) →
///    real `video_player` playback with full play/pause/seek control.
///  * **YouTube / Rumble** → in-app embedding of those players natively would
///    require a webview dependency we deliberately avoid here; we surface the
///    URL and track a "shadow" position so the sync lane state (seek/play/pause)
///    still propagates and stays consistent with web participants. This matches
///    the web client's own best-effort posture for non-controllable iframe
///    sources (it cannot cross-origin command a Rumble embed either).
enum _WatchMode { none, file, embedOnly }

class WatchVideoController extends ChangeNotifier
    implements WatchController {
  VideoPlayerController? _vp;
  _WatchMode _mode = _WatchMode.none;
  String? url;

  /// Position used for non-`video_player` sources so [position] stays sensible
  /// for the sync lane even when we are not actually decoding the media.
  double _shadowPos = 0;

  /// Rate used for non-`video_player` sources (embed-only YouTube/Rumble):
  /// there is no native player to command, so [setRate] just records it here
  /// so [playbackSnapshot] stays truthful, the same posture as [_shadowPos]
  /// above and as [play]/[pause]'s existing no-op for this mode.
  double _shadowRate = 1.0;

  /// True when the loaded source is YouTube/Rumble: no inline picture on this
  /// platform, only sync propagation. Lets the UI say so plainly instead of
  /// leaving a blank stage the viewer has to puzzle out.
  bool get isEmbedOnly => _mode == _WatchMode.embedOnly;

  /// Whether the controllable player is initialized and ready for commands.
  bool get isFilePlayerReady =>
      _mode == _WatchMode.file &&
      _vp != null &&
      (_vp?.value.isInitialized ?? false);

  /// The live `video_player` controller, or null when no file is loaded.
  VideoPlayerController? get fileController =>
      _mode == _WatchMode.file ? _vp : null;

  /// Mirror of the web controller's YouTube id parser (kept for API parity).
  static String? youtubeId(String url) {
    Uri? uri;
    try {
      uri = Uri.parse(url.trim());
    } catch (_) {
      return null;
    }
    final host = uri.host.toLowerCase().replaceFirst("www.", "");
    if (host == "youtu.be") {
      final seg = uri.pathSegments;
      if (seg.isNotEmpty && seg.first.isNotEmpty) return _cleanId(seg.first);
      return null;
    }
    if (host == "youtube.com" ||
        host == "m.youtube.com" ||
        host == "music.youtube.com") {
      final v = uri.queryParameters["v"];
      if (v != null && v.isNotEmpty) return _cleanId(v);
      final seg = uri.pathSegments;
      if (seg.length >= 2 &&
          (seg[0] == "shorts" || seg[0] == "embed" || seg[0] == "v")) {
        return _cleanId(seg[1]);
      }
      if (seg.length >= 2 && seg[0] == "live") return _cleanId(seg[1]);
    }
    return null;
  }

  static String _cleanId(String raw) {
    var id = raw;
    final amp = id.indexOf("&");
    if (amp >= 0) id = id.substring(0, amp);
    final q = id.indexOf("?");
    if (q >= 0) id = id.substring(0, q);
    return id;
  }

  static bool _isRumble(String url) {
    try {
      final host = Uri.parse(url.trim()).host.toLowerCase();
      return host == "rumble.com" || host.endsWith(".rumble.com");
    } catch (_) {
      return false;
    }
  }

  // ---- Public control surface ----------------------------------------------

  @override
  void load(String url) {
    this.url = url;
    _shadowPos = 0;
    _disposePlayer();

    // YouTube / Rumble → embed-only surface (no controllable native player).
    if (youtubeId(url) != null || _isRumble(url)) {
      _mode = _WatchMode.embedOnly;
      notifyListeners();
      return;
    }

    // Direct file / unknown → real video_player playback.
    _mode = _WatchMode.file;
    final vp = VideoPlayerController.networkUrl(Uri.parse(url));
    _vp = vp;
    notifyListeners();
    vp.initialize().then((_) {
      // Surface may have been replaced (another load) before init finished.
      if (_vp != vp) return;
      notifyListeners();
    }).catchError((_) {
      // Leave the surface in file mode; the UI shows a not-ready placeholder.
    });
  }

  @override
  void play() {
    if (isFilePlayerReady) {
      _vp?.play();
    }
    // embed-only: best-effort no-op (see class doc).
  }

  @override
  void pause() {
    if (isFilePlayerReady) {
      _vp?.pause();
    }
  }

  @override
  void seekTo(double t) {
    _shadowPos = t;
    if (isFilePlayerReady) {
      _vp?.seekTo(Duration(milliseconds: (t * 1000).round()));
    }
  }

  @override
  void setRate(double rate) {
    _shadowRate = rate;
    if (isFilePlayerReady) {
      _vp?.setPlaybackSpeed(rate);
    }
  }

  @override
  double get position {
    if (isFilePlayerReady) {
      return (_vp?.value.position.inMilliseconds ?? 0) / 1000.0;
    }
    return _shadowPos;
  }

  /// Real state for `video_player` sources; for YouTube/Rumble embed-only
  /// mode there is no native player to read, so this mirrors [position]'s
  /// shadow-value fallback and reports not-playing (parity with the web
  /// controller's pre-handshake fallback).
  @override
  PlaybackSnapshot get playbackSnapshot => PlaybackSnapshot(
        position: position,
        playing: _vp?.value.isPlaying ?? false,
        buffering: _vp?.value.isBuffering ?? false,
        rate: _vp?.value.playbackSpeed ?? _shadowRate,
      );

  void _disposePlayer() {
    final old = _vp;
    _vp = null;
    _mode = _WatchMode.none;
    old?.dispose();
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }
}

class WatchVideo extends StatefulWidget {
  const WatchVideo({
    super.key,
    required this.controller,
    this.interactive = true,
  });

  final WatchVideoController controller;

  /// Accepted for API parity with the web implementation and ignored here.
  /// Native renders through Flutter, so ``IgnorePointer`` alone already works;
  /// only web has a DOM element that wins pointer events on its own.
  final bool interactive;

  @override
  State<WatchVideo> createState() => _WatchVideoState();
}

class _WatchVideoState extends State<WatchVideo> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(WatchVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    if (c.isFilePlayerReady) {
      final vp = c.fileController!;
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: AspectRatio(
          aspectRatio:
              vp.value.aspectRatio == 0 ? 16 / 9 : vp.value.aspectRatio,
          child: VideoPlayer(vp),
        ),
      );
    }

    final url = c.url;
    // Explicit, not inferred from fileController being non-null: isEmbedOnly
    // is the getter that exists to say this outright (see class doc), so the
    // UI should actually ask it instead of the two conditions happening to
    // agree by construction of load().
    final embedOnly = c.isEmbedOnly;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Text(
        url == null
            ? "Load a video URL to watch together."
            : embedOnly
                ? "$url\n\n"
                    "This device keeps play, pause and seek in sync with the "
                    "room, but does not show the picture: inline YouTube/"
                    "Rumble playback is on the web client. Open this Space "
                    "in a browser to see it."
                : "Loading…\n$url",
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}
