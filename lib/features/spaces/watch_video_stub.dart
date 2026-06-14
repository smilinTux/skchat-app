import "package:flutter/material.dart";

/// Non-web fallback for the watch-together video surface. Playback state still
/// syncs across the room via the lane substrate; embedded rendering is web-only.
class WatchVideoController {
  String? url;
  double _pos = 0;

  void load(String u) => url = u;
  void play() {}
  void pause() {}
  void seekTo(double t) => _pos = t;
  double get position => _pos;
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
