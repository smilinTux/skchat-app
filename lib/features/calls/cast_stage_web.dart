import "dart:async";
import "dart:html" as html;
import "dart:js_interop";
import "dart:ui_web" as ui_web;

import "package:flutter/material.dart";

/// Web TV-cast stage: owns the browser `<video>` that plays a room's HLS stream
/// and exposes the three cast paths through the vendored `window.skCast` helper
/// (`web/sk_cast.js`):
///
///  * hls.js plays the m3u8 in Chrome / non-Safari (loaded lazily by the helper);
///  * Safari plays HLS natively, so the element carries the native AirPlay route
///    button, and [showAirplay] can pop the picker on demand;
///  * [requestChromecast] opens the Google Cast device picker and loads the
///    hls_url on the default media receiver.
///
/// This mirrors the platform-view pattern in `watch_video_web.dart`. The Dart
/// side only creates a container `<div>` (an [HtmlElementView]) with a stable id
/// and makes small typed `dart:js_interop` calls into `window.skCast`; all the
/// browser + SDK glue lives in the vendored JS.

/// Typed view of the vendored `window.skCast` helper object.
extension type _SkCast(JSObject _) implements JSObject {
  external void mount(String id, String hlsUrl);
  external bool castAvailable();
  external bool airplayAvailable(String id);
  external void showAirplay(String id);
  external JSPromise<JSBoolean> requestCast(String id);
  external void unmount(String id);
}

@JS("skCast")
external JSObject? get _skCastRaw;

/// Resolve the vendored `window.skCast` helper, or null if it did not load.
_SkCast? get _skCast {
  final raw = _skCastRaw;
  if (raw == null) return null;
  return _SkCast(raw);
}

/// Controller that binds a [CastStage] to its `window.skCast` mount by DOM id.
class CastController {
  CastController(this.hlsUrl)
      : viewId = "sk-cast-${DateTime.now().microsecondsSinceEpoch}";

  /// The room's public HLS URL that the receiver will play.
  final String hlsUrl;

  /// Stable DOM id of the container `<div>` this controller drives.
  final String viewId;

  bool _mounted = false;
  bool _disposed = false;

  /// Poll for the platform view's `<div>` to attach, then mount the player.
  ///
  /// The `<div>` only enters the DOM once the [HtmlElementView] is laid out, so
  /// we retry briefly until `getElementById` resolves it.
  void mountWhenReady() {
    var attempts = 0;
    void tryMount() {
      if (_mounted || _disposed) return;
      if (html.document.getElementById(viewId) != null) {
        _mount();
        return;
      }
      attempts++;
      if (attempts < 40) {
        Future.delayed(const Duration(milliseconds: 50), tryMount);
      }
    }

    tryMount();
  }

  void _mount() {
    final sk = _skCast;
    if (sk == null) return;
    try {
      sk.mount(viewId, hlsUrl);
      _mounted = true;
    } catch (_) {
      // Helper present but mount failed; the open-URL fallback still works.
    }
  }

  /// True once the Google Cast SDK is initialised and a session can be started.
  bool chromecastAvailable() {
    final sk = _skCast;
    if (sk == null) return false;
    try {
      return sk.castAvailable();
    } catch (_) {
      return false;
    }
  }

  /// True when the mounted element can pop a native AirPlay picker (Safari).
  bool airplayAvailable() {
    final sk = _skCast;
    if (sk == null || !_mounted) return false;
    try {
      return sk.airplayAvailable(viewId);
    } catch (_) {
      return false;
    }
  }

  /// Show Safari's AirPlay device picker for the mounted element.
  void showAirplay() {
    final sk = _skCast;
    if (sk == null) return;
    try {
      sk.showAirplay(viewId);
    } catch (_) {
      // Non-Safari or no route; caller falls back to the open-URL affordance.
    }
  }

  /// Open the Chromecast device picker and load the hls_url on the receiver.
  /// Resolves true when a load request was sent to a connected receiver.
  Future<bool> requestChromecast() async {
    final sk = _skCast;
    if (sk == null) return false;
    try {
      final ok = await sk.requestChromecastSafe(viewId);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Tear the player down and unmount from the helper.
  void dispose() {
    _disposed = true;
    final sk = _skCast;
    if (sk != null) {
      try {
        sk.unmount(viewId);
      } catch (_) {
        // Best-effort teardown.
      }
    }
    _mounted = false;
  }
}

extension on _SkCast {
  /// Await the JS `requestCast` Promise and unwrap the JS boolean to a Dart bool.
  Future<bool> requestChromecastSafe(String id) async {
    final result = await requestCast(id).toDart;
    return result.toDart;
  }
}

CastController createCastController(String hlsUrl) => CastController(hlsUrl);

/// The HLS video surface. Registers a platform view whose container `<div>`
/// carries [CastController.viewId], then asks the controller to mount once the
/// element attaches.
class CastStage extends StatefulWidget {
  const CastStage({super.key, required this.controller});

  final CastController controller;

  @override
  State<CastStage> createState() => _CastStageState();
}

class _CastStageState extends State<CastStage> {
  @override
  void initState() {
    super.initState();
    final id = widget.controller.viewId;

    final container = html.DivElement()
      ..id = id
      ..style.position = "relative"
      ..style.width = "100%"
      ..style.height = "100%"
      ..style.backgroundColor = "#000";

    ui_web.platformViewRegistry
        .registerViewFactory(id, (int _) => container);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.mountWhenReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: widget.controller.viewId);
  }
}
