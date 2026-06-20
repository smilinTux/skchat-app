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
/// This file intentionally has NO Flutter / dart:html / dart:io dependency so
/// the mapping can be unit-tested on the bare Dart VM against a mock target.
library;

/// Minimal control surface a watch event can drive. Both the web
/// (`watch_video_web.dart`) and native (`watch_video_native.dart`)
/// `WatchVideoController`s satisfy this shape.
abstract class WatchPlaybackTarget {
  void load(String url);
  void play();
  void pause();
  void seekTo(double t);
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
