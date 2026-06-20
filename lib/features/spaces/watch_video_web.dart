import "dart:convert";
import "dart:html" as html;
import "dart:ui_web" as ui_web;

import "package:flutter/material.dart";

import "watch_sync.dart";

/// Web watch-together video surface.
///
/// Supports three source kinds, auto-detected from the URL passed to [load]:
///
///  * **YouTube** — `youtube.com/watch?v=ID`, `youtu.be/ID`,
///    `youtube.com/shorts/ID`. Rendered as an IFrame API embed
///    (`/embed/<ID>?enablejsapi=1&playsinline=1`). play/pause/seek are driven
///    via `iframe.contentWindow.postMessage` using the YouTube IFrame API
///    command protocol, so inbound lane events keep every participant aligned.
///  * **Rumble** — `rumble.com/...`. Rendered as a Rumble embed iframe when an
///    embed id can be derived, otherwise the page URL is embedded best-effort.
///    NOTE: Rumble's embed does not expose a stable, documented cross-origin
///    postMessage control API. `load` works; play/pause/seek are best-effort
///    no-ops (we cannot reliably command the Rumble player from another origin).
///  * **Direct file** — anything else (incl. `.mp4`/`.webm`/`.ogg`). Rendered
///    as a native HTML5 `<video>` element with full play/pause/seek control.
///
/// The controller registers ONE platform view: a container `<div>` that holds
/// both a `<video>` element and an `<iframe>`. [load] swaps which child is
/// visible (and rebuilds the iframe `src`) based on the detected source, so the
/// active surface is always the right player for the current URL.
enum _WatchMode { none, video, youtube, rumble }

class WatchVideoController implements WatchPlaybackTarget {
  /// Container div holding both the <video> and <iframe> children.
  html.DivElement? container;
  html.VideoElement? videoEl;
  html.IFrameElement? iframeEl;

  _WatchMode _mode = _WatchMode.none;
  String? _currentUrl;

  /// Last position we set on a non-controllable (iframe) source, so [position]
  /// returns something sensible for the sync lane even when we can't read the
  /// real player time cross-origin.
  double _shadowPos = 0;

  bool get _ready => container != null;

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
    if (!_ready) return;

    final ytId = youtubeId(url);
    if (ytId != null) {
      _mode = _WatchMode.youtube;
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

  double get position {
    if (_mode == _WatchMode.video) {
      final v = videoEl;
      if (v != null) return v.currentTime.toDouble();
    }
    // iframe sources: we can't read player time cross-origin → shadow value.
    return _shadowPos;
  }

  /// API parity with the native controller (which owns a disposable player).
  /// The web surface is torn down by the browser with the platform view, so
  /// this is a no-op.
  void dispose() {}

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
  const WatchVideo({super.key, required this.controller});

  final WatchVideoController controller;

  @override
  State<WatchVideo> createState() => _WatchVideoState();
}

class _WatchVideoState extends State<WatchVideo> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = "watch-video-${identityHashCode(widget.controller)}";

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
      ..iframeEl = iframe;

    // If a URL was loaded before the surface mounted, apply it now.
    final pending = widget.controller._currentUrl;
    if (pending != null) widget.controller.load(pending);

    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int _) => container);
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
