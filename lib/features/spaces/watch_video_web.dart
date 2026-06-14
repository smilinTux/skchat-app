import "dart:html" as html;
import "dart:ui_web" as ui_web;

import "package:flutter/material.dart";

/// Web watch-together video surface: a real HTML5 <video> element embedded via
/// HtmlElementView. The controller drives load/play/pause/seek so inbound lane
/// events keep every participant's player in sync.
class WatchVideoController {
  html.VideoElement? element;

  void load(String url) {
    final el = element;
    if (el == null) return;
    el.src = url;
    el.load();
  }

  void play() => element?.play();
  void pause() => element?.pause();
  void seekTo(double t) {
    final el = element;
    if (el != null) el.currentTime = t;
  }

  double get position => element?.currentTime.toDouble() ?? 0;
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
    final el = html.VideoElement()
      ..controls = true
      ..autoplay = false
      ..style.width = "100%"
      ..style.height = "100%"
      ..style.backgroundColor = "#000";
    widget.controller.element = el;
    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int _) => el);
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
