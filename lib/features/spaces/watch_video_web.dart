import "dart:async";
import "dart:convert";
import "dart:html" as html;
import "dart:ui_web" as ui_web;

import "package:flutter/material.dart";

import "watch_drift.dart";
import "watch_sync.dart";
import "watch_yt_info.dart";

/// Web watch-together video surface.
///
/// Supports three source kinds, auto-detected from the URL passed to [load]:
///
///  * **YouTube**, `youtube.com/watch?v=ID`, `youtu.be/ID`,
///    `youtube.com/shorts/ID`. Rendered as an IFrame API embed
///    (`/embed/<ID>?enablejsapi=1&playsinline=1`). play/pause/seek are driven
///    via `iframe.contentWindow.postMessage` using the YouTube IFrame API
///    command protocol, so inbound lane events keep every participant aligned.
///  * **Rumble**, `rumble.com/...`. Rendered as a Rumble embed iframe when an
///    embed id can be derived, otherwise the page URL is embedded best-effort.
///    NOTE: Rumble's embed does not expose a stable, documented cross-origin
///    postMessage control API. `load` works; play/pause/seek are best-effort
///    no-ops (we cannot reliably command the Rumble player from another origin).
///  * **Direct file**, anything else (incl. `.mp4`/`.webm`/`.ogg`). Rendered
///    as a native HTML5 `<video>` element with full play/pause/seek control.
///
/// The controller registers ONE platform view: a container `<div>` that holds
/// both a `<video>` element and an `<iframe>`. [load] swaps which child is
/// visible (and rebuilds the iframe `src`) based on the detected source, so the
/// active surface is always the right player for the current URL.
enum _WatchMode { none, video, youtube, rumble }

class WatchVideoController implements WatchController {
  /// Container div holding both the <video> and <iframe> children.
  html.DivElement? container;
  html.VideoElement? videoEl;
  html.IFrameElement? iframeEl;

  _WatchMode _mode = _WatchMode.none;
  String? _currentUrl;

  /// Stable id for the `{"event":"listening"}` handshake. Set once by
  /// [_WatchVideoState.initState] alongside [iframeEl]; the YouTube IFrame
  /// API doesn't require this id to mean anything, it just needs to be
  /// present.
  String? viewType;

  /// Latest parsed `infoDelivery` frame. Null until the first frame arrives
  /// after the listening handshake (or after a fresh [load] swaps the
  /// player out from under it).
  PlaybackSnapshot? _latest;

  StreamSubscription<html.MessageEvent>? _msgSub;
  StreamSubscription<html.Event>? _loadSub;
  Timer? _handshakeTimer;

  /// Last position we set on a non-controllable (iframe) source. Used as the
  /// [position] fallback for iframe sources before the listening handshake's
  /// first `infoDelivery` frame lands, and for sources (Rumble) that never
  /// deliver real player state at all.
  double _shadowPos = 0;

  /// Last rate we set on a source [playbackSnapshot] cannot read a real rate
  /// back from: Rumble (no documented postMessage state API at all, same gap
  /// [_shadowPos] covers) and any source before its first real reading
  /// lands. YouTube's real rate comes back through the listening handshake
  /// (`_latest`); direct `<video>` reads straight off [videoEl].
  double _shadowRate = 1.0;

  bool get _ready => container != null;

  /// Web plays YouTube and Rumble inline via iframe (see class doc), so
  /// there is never an embed-only picture gap here the way there is on
  /// native; exists so both controllers satisfy the same shape.
  bool get isEmbedOnly => false;

  /// Wire the window-level postMessage listener that receives YouTube IFrame
  /// API `infoDelivery` frames, and the iframe `onLoad` listener that re-sends
  /// the `{"event":"listening"}` handshake on every load. Called once, from
  /// [_WatchVideoState.initState], right after [iframeEl] is assigned.
  void _attach() {
    _msgSub = html.window.onMessage.listen((event) {
      // Other origins post to this window too; only trust the iframe we own.
      if (event.source != iframeEl?.contentWindow) return;
      final data = event.data;
      if (data is! String) return;
      final snap = parseYouTubeInfo(data, previous: _latest);
      if (snap != null) _latest = snap;
    });
    _loadSub = iframeEl?.onLoad.listen((_) => _sendHandshake());
  }

  /// Ask the IFrame API to start pushing `infoDelivery` frames.
  ///
  /// Idempotent: YouTube ignores a duplicate handshake, so re-sending is free.
  void _sendHandshake() {
    if (_mode != _WatchMode.youtube) return;
    final win = iframeEl?.contentWindow;
    if (win == null) return;
    win.postMessage(
      jsonEncode({"event": "listening", "id": viewType ?? ""}),
      "https://www.youtube.com",
    );
  }

  /// Re-send the handshake until frames actually arrive, then stop.
  ///
  /// onLoad alone is not enough, verified live: the app's iframe sat with the
  /// correct src and delivered ZERO frames, while posting the same handshake
  /// by hand to that same iframe immediately produced 26. The load event does
  /// not reliably reach us for an element that Flutter's platform-view layer
  /// creates detached and slots into the DOM later, so relying on it left
  /// position pinned at the 0 fallback: every play, seek and heartbeat
  /// published t=0, and a late joiner had nothing to catch up to.
  ///
  /// Bounded on purpose. If frames never come the video still plays, it just
  /// will not drive sync, and a timer that retries forever would be worse
  /// than an honest give-up.
  void _pumpHandshake() {
    _handshakeTimer?.cancel();
    var attempts = 0;
    _sendHandshake();
    _handshakeTimer = Timer.periodic(const Duration(milliseconds: 400), (t) {
      attempts++;
      if (_latest != null || attempts > 25 || _mode != _WatchMode.youtube) {
        t.cancel();
        return;
      }
      _sendHandshake();
    });
  }

  // ---- Source detection -----------------------------------------------------

  /// Extract a YouTube video id from any of the supported URL shapes, or null.
  static String? youtubeId(String url) {
    Uri? uri;
    try {
      uri = Uri.parse(url.trim());
    } catch (_) {
      return null;
    }
    final host = uri.host.toLowerCase().replaceFirst("www.", "");

    // youtu.be/<ID>
    if (host == "youtu.be") {
      final seg = uri.pathSegments;
      if (seg.isNotEmpty && seg.first.isNotEmpty) return _cleanId(seg.first);
      return null;
    }

    if (host == "youtube.com" ||
        host == "m.youtube.com" ||
        host == "music.youtube.com") {
      // youtube.com/watch?v=<ID>
      final v = uri.queryParameters["v"];
      if (v != null && v.isNotEmpty) return _cleanId(v);

      final seg = uri.pathSegments;
      // youtube.com/shorts/<ID>  and  youtube.com/embed/<ID>  and /v/<ID>
      if (seg.length >= 2 &&
          (seg[0] == "shorts" || seg[0] == "embed" || seg[0] == "v")) {
        return _cleanId(seg[1]);
      }
      // youtube.com/live/<ID>
      if (seg.length >= 2 && seg[0] == "live") return _cleanId(seg[1]);
    }
    return null;
  }

  static String _cleanId(String raw) {
    // Strip any stray query/fragment that survived path parsing.
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

  /// Best-effort Rumble embed URL. Rumble embeds use an opaque embed id
  /// (e.g. `https://rumble.com/embed/<embedId>/?pub=4`) that is NOT derivable
  /// from a public watch URL without an API call. If the URL already points at
  /// an embed, we reuse it; otherwise we embed the page URL directly as a
  /// best-effort fallback (Rumble serves a player for many page URLs in-frame).
  static String _rumbleEmbedUrl(String url) {
    final u = url.trim();
    try {
      final uri = Uri.parse(u);
      final seg = uri.pathSegments;
      // Already an embed URL: rumble.com/embed/<id>/...
      if (seg.length >= 2 && seg[0] == "embed") {
        return "https://rumble.com/embed/${seg[1]}/?pub=4";
      }
    } catch (_) {}
    // Best-effort: embed the page URL itself.
    return u;
  }

  // ---- Public control surface ----------------------------------------------

  @override
  void load(String url) {
    _currentUrl = url;
    _shadowPos = 0;
    // Drop the previous video's snapshot: without this, position/playing
    // would keep reporting the OLD video's state until the new player's
    // first infoDelivery frame lands.
    _latest = null;
    if (!_ready) return;

    final ytId = youtubeId(url);
    if (ytId != null) {
      _mode = _WatchMode.youtube;
      _pumpHandshake();
      _showIframe(
          "https://www.youtube.com/embed/$ytId?enablejsapi=1&playsinline=1");
      return;
    }

    if (_isRumble(url)) {
      _mode = _WatchMode.rumble;
      _showIframe(_rumbleEmbedUrl(url));
      return;
    }

    // Direct file / unknown → native <video>.
    _mode = _WatchMode.video;
    _showVideo();
    final v = videoEl;
    if (v != null) {
      v.src = url;
      v.load();
    }
  }

  @override
  void play() {
    switch (_mode) {
      case _WatchMode.video:
        videoEl?.play();
        break;
      case _WatchMode.youtube:
        _ytCommand("playVideo", const []);
        break;
      case _WatchMode.rumble:
        // Best-effort: Rumble's embed has no reliable cross-origin play cmd.
        break;
      case _WatchMode.none:
        break;
    }
  }

  @override
  void pause() {
    switch (_mode) {
      case _WatchMode.video:
        videoEl?.pause();
        break;
      case _WatchMode.youtube:
        _ytCommand("pauseVideo", const []);
        break;
      case _WatchMode.rumble:
        // Best-effort no-op (see class doc).
        break;
      case _WatchMode.none:
        break;
    }
  }

  @override
  void seekTo(double t) {
    _shadowPos = t;
    switch (_mode) {
      case _WatchMode.video:
        videoEl?.currentTime = t;
        break;
      case _WatchMode.youtube:
        _ytCommand("seekTo", [t, true]);
        break;
      case _WatchMode.rumble:
        // Best-effort no-op (see class doc).
        break;
      case _WatchMode.none:
        break;
    }
  }

  @override
  void setRate(double rate) {
    _shadowRate = rate;
    switch (_mode) {
      case _WatchMode.video:
        videoEl?.playbackRate = rate;
        break;
      case _WatchMode.youtube:
        _ytCommand("setPlaybackRate", [rate]);
        break;
      case _WatchMode.rumble:
        // Best-effort no-op (see class doc): no documented cross-origin
        // rate command, same gap play/pause/seekTo hit above.
        break;
      case _WatchMode.none:
        break;
    }
  }

  @override
  double get position {
    if (_mode == _WatchMode.video) {
      final v = videoEl;
      if (v != null) return v.currentTime.toDouble();
    }
    if (_mode == _WatchMode.youtube) {
      // Real player time once the listening handshake's first frame lands;
      // shadow value (last thing WE set) before that, or for Rumble, which
      // has no documented postMessage state API at all.
      return _latest?.position ?? _shadowPos;
    }
    return _shadowPos;
  }

  /// Full playback state for the drift resolver, not just position: play
  /// state and buffering matter as much as the timestamp for deciding
  /// whether to correct a viewer. YouTube's real rate rides in on [_latest]
  /// (parsed from the listening handshake) same as position; a direct
  /// `<video>` element can report its own actual rate too (the browser's
  /// native controls expose a speed menu independent of our [setRate]
  /// calls), so that reads [videoEl] rather than falling back to the shadow
  /// value the way Rumble (no state API at all) has to.
  @override
  PlaybackSnapshot get playbackSnapshot {
    final latest = _latest;
    if (latest != null) return latest;
    if (_mode == _WatchMode.video) {
      return PlaybackSnapshot(
        position: position,
        playing: false,
        rate: videoEl?.playbackRate.toDouble() ?? _shadowRate,
      );
    }
    return PlaybackSnapshot(position: position, playing: false, rate: _shadowRate);
  }

  /// Tears the controller down for `ref.onDispose` (watch_session.dart):
  /// cancels both subscriptions so neither leaks for the life of the page,
  /// pauses the video element, and blanks the iframe src. Without the pause
  /// + blank, leaving a Space mid-mp4 (or mid-YouTube-video) leaves a
  /// detached video element still decoding audio nobody can hear it stop.
  @override
  void dispose() {
    _msgSub?.cancel();
    _msgSub = null;
    _loadSub?.cancel();
    _loadSub = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    videoEl?.pause();
    iframeEl?.src = "about:blank";
  }

  // ---- Internals ------------------------------------------------------------

  /// Send a YouTube IFrame API command via postMessage.
  /// Example: {"event":"command","func":"playVideo","args":[]}
  void _ytCommand(String func, List<Object?> args) {
    final win = iframeEl?.contentWindow;
    if (win == null) return;
    final msg = jsonEncode({
      "event": "command",
      "func": func,
      "args": args,
    });
    win.postMessage(msg, "https://www.youtube.com");
  }

  void _showVideo() {
    iframeEl?.style.display = "none";
    iframeEl?.src = "about:blank";
    videoEl?.style.display = "block";
  }

  void _showIframe(String src) {
    videoEl?.pause();
    videoEl?.style.display = "none";
    final f = iframeEl;
    if (f != null) {
      f.src = src;
      f.style.display = "block";
    }
  }
}

class WatchVideo extends StatefulWidget {
  const WatchVideo({
    super.key,
    required this.controller,
    this.interactive = true,
  });

  final WatchVideoController controller;

  /// Whether the video surface should accept pointer events at all.
  ///
  /// This exists because ``IgnorePointer`` cannot do the job on web. This
  /// surface is a REAL DOM element (a platform view), and the browser
  /// dispatches a click over it to that element natively, before Flutter's
  /// hit-testing is ever consulted. ``IgnorePointer`` only removes the widget
  /// from FLUTTER's hit test, so with a lane panel open every tap landing over
  /// the video still went to the iframe: the panel's own buttons were dead
  /// wherever they overlapped the video, and shrinking the window until the
  /// video was small was the only way to reach them.
  ///
  /// Setting ``pointer-events: none`` on the element is the only thing the
  /// browser honors, so pass false whenever something is drawn over the video.
  final bool interactive;

  @override
  State<WatchVideo> createState() => _WatchVideoState();
}

class _WatchVideoState extends State<WatchVideo> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = "watch-video-${identityHashCode(widget.controller)}";

    // A remount reuses the SAME controller instance (the Space stage keeps
    // this surface's controller alive underneath an Offstage while live
    // video takes the stage on top of it; see _WatchTogetherStage in
    // space_room_screen.dart). The registered view factory below closed over
    // the container built on the FIRST mount; rebuilding fresh DOM elements
    // here and reassigning them to widget.controller would leave that
    // factory returning an orphaned node forever (an empty box) instead of
    // the live iframe/video, and for a YouTube iframe specifically, tearing
    // it down and rebuilding a fresh one on every remount would stop and
    // reload the movie. Reuse what is already there instead.
    if (widget.controller.container != null) return;

    final container = html.DivElement()
      ..style.position = "relative"
      ..style.width = "100%"
      ..style.height = "100%"
      ..style.backgroundColor = "#000";

    final video = html.VideoElement()
      ..controls = true
      ..autoplay = false
      ..style.position = "absolute"
      ..style.top = "0"
      ..style.left = "0"
      ..style.width = "100%"
      ..style.height = "100%"
      ..style.display = "block"
      ..style.backgroundColor = "#000";

    final iframe = html.IFrameElement()
      ..allowFullscreen = true
      ..allow = "autoplay; encrypted-media; picture-in-picture; fullscreen"
      ..style.position = "absolute"
      ..style.top = "0"
      ..style.left = "0"
      ..style.width = "100%"
      ..style.height = "100%"
      ..style.border = "0"
      ..style.display = "none";
    // allowfullscreen attribute (some embeds check the attribute, not the prop).
    iframe.setAttribute("allowfullscreen", "true");

    container.children.addAll([video, iframe]);

    widget.controller
      ..container = container
      ..videoEl = video
      ..iframeEl = iframe
      ..viewType = _viewType
      .._attach();

    // If a URL was loaded before the surface mounted, apply it now.
    final pending = widget.controller._currentUrl;
    if (pending != null) widget.controller.load(pending);

    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int _) => container);
  }

  @override
  void didUpdateWidget(covariant WatchVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interactive != widget.interactive) _applyInteractive();
  }

  /// Push [WatchVideo.interactive] down onto the real DOM node.
  ///
  /// Applied to the container rather than the iframe: the container is what the
  /// platform view registers, and `pointer-events` inherits, so one property
  /// covers both the `<video>` and `<iframe>` children whichever is visible.
  void _applyInteractive() {
    widget.controller.container?.style.pointerEvents =
        widget.interactive ? "auto" : "none";
  }

  @override
  Widget build(BuildContext context) {
    // Re-applied on every build, not only on change: the container is created
    // asynchronously by the view factory, so the first _applyInteractive can
    // land before there is anything to style.
    _applyInteractive();
    return HtmlElementView(viewType: _viewType);
  }
}
