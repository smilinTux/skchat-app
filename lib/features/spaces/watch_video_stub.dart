import "package:flutter/material.dart";

/// Non-web fallback for the watch-together video surface. Playback state still
/// syncs across the room via the lane substrate; embedded rendering is web-only.
///
/// The public API mirrors the web controller (`watch_video_web.dart`) so the
/// conditional import compiles identically on non-web targets.
class WatchVideoController {
  String? url;
  double _pos = 0;

  void load(String u) => url = u;
  void play() {}
  void pause() {}
  void seekTo(double t) => _pos = t;
  double get position => _pos;

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
}

class WatchVideo extends StatelessWidget {
  const WatchVideo({super.key, required this.controller});

  final WatchVideoController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Text(
        controller.url == null
            ? "Load a video URL to watch together."
            : "▶ Now playing (synced across the room):\n${controller.url}\n\nEmbedded playback is on the web client.",
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}
