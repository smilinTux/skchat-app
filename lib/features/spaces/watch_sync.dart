/// Pure, platform-independent watch-together sync logic.
///
/// The "watch" lane carries JSON events of the shape:
///   `{"lane":"watch","action":"load","url":"...","from":"<id>"}`
///   `{"lane":"watch","action":"play","t":<seconds>,"from":"<id>"}`
///   `{"lane":"watch","action":"pause","t":<seconds>,"from":"<id>"}`
///   `{"lane":"watch","action":"seek","t":<seconds>,"from":"<id>"}`
///
/// Both the web and native watch surfaces drive playback off this same event
/// stream (see [applyWatchEvent]) and emit the same events on local control, so
/// web <-> native participants stay aligned.
///
/// `heartbeat` and `stop` are additive on top of this mapper, handled by
/// `WatchSession.applyRemote` (watch_session.dart) before either ever
/// reaches [applyWatchEvent]: an older client's copy of this file has no
/// `case` for them, so they fall into the `default:` branch below and are
/// silently ignored, which is what "additive" means on this wire.
///
/// This file intentionally has NO Flutter / dart:html / dart:io dependency so
/// the mapping can be unit-tested on the bare Dart VM against a mock target.
library;

import "watch_drift.dart";

/// Minimal control surface a watch event can drive. Both the web
/// (`watch_video_web.dart`) and native (`watch_video_native.dart`)
/// `WatchVideoController`s satisfy this shape.
abstract class WatchPlaybackTarget {
  void load(String url);
  void play();
  void pause();
  void seekTo(double t);
}

/// The full control surface `WatchSession` (watch_session.dart) drives:
/// [WatchPlaybackTarget] plus the read side a drift-correction loop needs.
/// Both platform `WatchVideoController`s implement this directly (see
/// watch_video_stub.dart / watch_video_web.dart), so the concrete real
/// controller flows through to the widget that renders it (`WatchVideo`)
/// unchanged; a test substitutes a fake implementation instead of driving a
/// real `video_player` / DOM element. Lives here, not in watch_session.dart,
/// so the platform controller files can implement it without an import
/// cycle back to the session file.
abstract class WatchController implements WatchPlaybackTarget {
  double get position;
  PlaybackSnapshot get playbackSnapshot;
  void dispose();
}

/// Apply a single inbound watch lane event to [target] WITHOUT re-publishing
/// (callers use this only for REMOTE events, to avoid sync loops).
///
/// Returns the URL when the event is a successful `load` (so the caller can
/// update its own UI state), otherwise null. Unknown / malformed events are
/// ignored.
String? applyWatchEvent(WatchPlaybackTarget target, Map<String, dynamic> e) {
  final action = e["action"];
  switch (action) {
    case "load":
      final url = e["url"] as String?;
      if (url != null && url.isNotEmpty) {
        target.load(url);
        return url;
      }
      return null;
    case "play":
      // Honor an accompanying position so a late play stays aligned.
      final t = (e["t"] as num?)?.toDouble();
      if (t != null) target.seekTo(t);
      target.play();
      return null;
    case "pause":
      final t = (e["t"] as num?)?.toDouble();
      if (t != null) target.seekTo(t);
      target.pause();
      return null;
    case "seek":
      final t = (e["t"] as num?)?.toDouble();
      if (t != null) target.seekTo(t);
      return null;
    default:
      return null;
  }
}
