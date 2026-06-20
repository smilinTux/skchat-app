// Unit tests for the platform-independent watch-together sync mapper.
//
// `applyWatchEvent` is the single point that turns inbound "watch" lane events
// into player actions for BOTH the web and native surfaces, so pinning its
// behavior here guarantees web <-> native participants interpret the same lane
// events identically. We drive it against a recording mock target (no real
// player), so this runs on the bare Dart VM.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_sync.dart";

/// Records every call made by the mapper so tests can assert the exact
/// sequence of player actions a lane event produces.
class _RecordingTarget implements WatchPlaybackTarget {
  final List<String> calls = [];

  @override
  void load(String url) => calls.add("load:$url");

  @override
  void play() => calls.add("play");

  @override
  void pause() => calls.add("pause");

  @override
  void seekTo(double t) => calls.add("seek:$t");
}

void main() {
  late _RecordingTarget target;

  setUp(() => target = _RecordingTarget());

  group("applyWatchEvent", () {
    test("load applies and returns the url", () {
      final url = applyWatchEvent(
          target, {"action": "load", "url": "https://x/clip.mp4"});
      expect(url, "https://x/clip.mp4");
      expect(target.calls, ["load:https://x/clip.mp4"]);
    });

    test("load with missing url is a no-op and returns null", () {
      final r = applyWatchEvent(target, {"action": "load"});
      expect(r, isNull);
      expect(target.calls, isEmpty);
    });

    test("load with empty url is a no-op and returns null", () {
      final r = applyWatchEvent(target, {"action": "load", "url": ""});
      expect(r, isNull);
      expect(target.calls, isEmpty);
    });

    test("play seeks to the carried position then plays (stays aligned)", () {
      final r = applyWatchEvent(target, {"action": "play", "t": 12.5});
      expect(r, isNull);
      expect(target.calls, ["seek:12.5", "play"]);
    });

    test("play without a position just plays", () {
      applyWatchEvent(target, {"action": "play"});
      expect(target.calls, ["play"]);
    });

    test("pause seeks to the carried position then pauses", () {
      applyWatchEvent(target, {"action": "pause", "t": 30.0});
      expect(target.calls, ["seek:30.0", "pause"]);
    });

    test("pause without a position just pauses", () {
      applyWatchEvent(target, {"action": "pause"});
      expect(target.calls, ["pause"]);
    });

    test("seek seeks to the carried position", () {
      applyWatchEvent(target, {"action": "seek", "t": 7.0});
      expect(target.calls, ["seek:7.0"]);
    });

    test("seek with no position is a no-op", () {
      applyWatchEvent(target, {"action": "seek"});
      expect(target.calls, isEmpty);
    });

    test("integer positions coerce to double via num", () {
      applyWatchEvent(target, {"action": "seek", "t": 5});
      expect(target.calls, ["seek:5.0"]);
    });

    test("unknown action is ignored", () {
      final r = applyWatchEvent(target, {"action": "frobnicate"});
      expect(r, isNull);
      expect(target.calls, isEmpty);
    });

    test("missing action is ignored", () {
      final r = applyWatchEvent(target, {"url": "x"});
      expect(r, isNull);
      expect(target.calls, isEmpty);
    });

    test("a load->play->seek->pause sequence drives the expected actions", () {
      applyWatchEvent(target, {"action": "load", "url": "u"});
      applyWatchEvent(target, {"action": "play", "t": 0.0});
      applyWatchEvent(target, {"action": "seek", "t": 90.25});
      applyWatchEvent(target, {"action": "pause", "t": 90.25});
      expect(target.calls, [
        "load:u",
        "seek:0.0",
        "play",
        "seek:90.25",
        "seek:90.25",
        "pause",
      ]);
    });
  });
}
