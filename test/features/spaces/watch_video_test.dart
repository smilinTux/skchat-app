// Unit tests for the watch-together video controller's pure URL parsing.
//
// We import the STUB controller (no dart:html) so this runs on the Dart VM.
// The web controller (`watch_video_web.dart`) carries a byte-identical copy of
// `youtubeId`/`_cleanId` for API parity, so these cases pin both.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_video_stub.dart";

void main() {
  group("WatchVideoController.youtubeId", () {
    test("parses youtube.com/watch?v=ID", () {
      expect(
        WatchVideoController.youtubeId(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        "dQw4w9WgXcQ",
      );
    });

    test("parses youtu.be/ID short link", () {
      expect(
        WatchVideoController.youtubeId("https://youtu.be/dQw4w9WgXcQ"),
        "dQw4w9WgXcQ",
      );
    });

    test("parses youtube.com/shorts/ID", () {
      expect(
        WatchVideoController.youtubeId(
            "https://youtube.com/shorts/abc123XYZ_-"),
        "abc123XYZ_-",
      );
    });

    test("parses youtube.com/embed/ID", () {
      expect(
        WatchVideoController.youtubeId("https://www.youtube.com/embed/vID00001"),
        "vID00001",
      );
    });

    test("parses youtube.com/live/ID", () {
      expect(
        WatchVideoController.youtubeId("https://www.youtube.com/live/liveID99"),
        "liveID99",
      );
    });

    test("parses m.youtube.com and music.youtube.com hosts", () {
      expect(
        WatchVideoController.youtubeId(
            "https://m.youtube.com/watch?v=mobileID1"),
        "mobileID1",
      );
      expect(
        WatchVideoController.youtubeId(
            "https://music.youtube.com/watch?v=musicID2"),
        "musicID2",
      );
    });

    test("strips trailing &-params from watch?v=ID&t=", () {
      // The query parser hands back the v= value directly; _cleanId trims a
      // stray '&'/'?' that survives in path-derived ids.
      expect(
        WatchVideoController.youtubeId(
            "https://www.youtube.com/watch?v=cleanID7&t=30s&list=PL"),
        "cleanID7",
      );
    });

    test("strips stray query from youtu.be/ID?si=...", () {
      expect(
        WatchVideoController.youtubeId(
            "https://youtu.be/shareID8?si=trackingtoken"),
        "shareID8",
      );
    });

    test("handles www. prefix removal on host match", () {
      expect(
        WatchVideoController.youtubeId(
            "https://www.youtube.com/watch?v=wwwID999"),
        "wwwID999",
      );
    });

    test("returns null for a Rumble URL", () {
      expect(
        WatchVideoController.youtubeId("https://rumble.com/v123-some-video.html"),
        isNull,
      );
    });

    test("returns null for a direct mp4 URL", () {
      expect(
        WatchVideoController.youtubeId("https://cdn.example.com/clip.mp4"),
        isNull,
      );
    });

    test("returns null for youtube.com with no video id", () {
      expect(
        WatchVideoController.youtubeId("https://www.youtube.com/feed/subscriptions"),
        isNull,
      );
    });

    test("returns null for empty youtu.be path", () {
      expect(WatchVideoController.youtubeId("https://youtu.be/"), isNull);
    });

    test("returns null for garbage / non-URL input", () {
      expect(WatchVideoController.youtubeId("not a url at all"), isNull);
      expect(WatchVideoController.youtubeId(""), isNull);
    });

    test("trims surrounding whitespace before parsing", () {
      expect(
        WatchVideoController.youtubeId(
            "  https://www.youtube.com/watch?v=trimID42  "),
        "trimID42",
      );
    });
  });

  group("WatchVideoController stub control surface", () {
    test("load records the url; play/pause are inert; seek tracks position", () {
      final c = WatchVideoController();
      expect(c.url, isNull);
      expect(c.position, 0);

      c.load("https://youtu.be/abc");
      expect(c.url, "https://youtu.be/abc");

      // Non-web stub: play/pause are no-ops and must not throw.
      c.play();
      c.pause();

      c.seekTo(42.5);
      expect(c.position, 42.5);
    });

    test("native YouTube reports embed-only so the UI can say so", () {
      final c = WatchVideoController();
      c.load("https://youtu.be/abc");
      expect(c.isEmbedOnly, isTrue);
      c.load("https://example.com/clip.mp4");
      expect(c.isEmbedOnly, isFalse);
    });

    test("native Rumble also reports embed-only (same branch as YouTube)", () {
      final c = WatchVideoController();
      c.load("https://rumble.com/v123-some-video.html");
      expect(c.isEmbedOnly, isTrue);
    });
  });
}
