import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_drift.dart";
import "package:skchat/features/spaces/watch_yt_info.dart";

void main() {
  test("parses currentTime and playerState from a real infoDelivery frame", () {
    // Shape captured live over CDP from Brave 150 against the IFrame API.
    const raw =
        '{"event":"infoDelivery","info":{"playerState":1,"currentTime":42.5,'
        '"duration":212.0,"playbackRate":1}}';
    final s = parseYouTubeInfo(raw)!;
    expect(s.position, 42.5);
    expect(s.playing, isTrue);
    expect(s.buffering, isFalse);
  });

  test("playerState 3 is buffering, and buffering is NOT playing", () {
    const raw =
        '{"event":"infoDelivery","info":{"playerState":3,"currentTime":10.0}}';
    final s = parseYouTubeInfo(raw)!;
    expect(s.buffering, isTrue);
    expect(s.playing, isFalse);
  });

  test("paused, cued and unstarted are not playing", () {
    for (final st in [2, 5, -1]) {
      final s = parseYouTubeInfo(
          '{"event":"infoDelivery","info":{"playerState":$st,"currentTime":1.0}}')!;
      expect(s.playing, isFalse, reason: "playerState $st must not be playing");
    }
  });

  test("the actual playback rate is reported for drift's rate-mismatch check",
      () {
    const raw =
        '{"event":"infoDelivery","info":{"playerState":1,"currentTime":5.0,'
        '"playbackRate":1.5}}';
    expect(parseYouTubeInfo(raw)!.rate, 1.5);
  });

  test("a missing playbackRate defaults to 1.0", () {
    const raw =
        '{"event":"infoDelivery","info":{"playerState":1,"currentTime":5.0}}';
    expect(parseYouTubeInfo(raw)!.rate, 1.0);
  });

  test("unrelated or malformed frames return null instead of throwing", () {
    expect(parseYouTubeInfo('{"event":"initialDelivery"}'), isNull);
    expect(parseYouTubeInfo("not json"), isNull);
    expect(parseYouTubeInfo('{"event":"infoDelivery","info":{}}'), isNull);
  });

  group("real infoDelivery frames, captured live over CDP", () {
    test("a frame carrying currentTime but NO playerState is still used", () {
      // Measured against the live app: of 26 frames the API pushed, the great
      // majority carried currentTime with playerState undefined. Requiring
      // both threw those away, so position stayed at the 0 fallback and every
      // play/seek/heartbeat published t=0. Incremental frames are the normal
      // case, not an edge case.
      const raw = '{"event":"infoDelivery","info":{"currentTime":8.4}}';
      final prev = const PlaybackSnapshot(
          position: 1.0, playing: true, buffering: false);
      final s = parseYouTubeInfo(raw, previous: prev)!;
      expect(s.position, 8.4);
      expect(s.playing, isTrue,
          reason: "carry the last known play state forward, do not invent one");
    });

    test("with no previous state, a currentTime-only frame is not playing", () {
      const raw = '{"event":"infoDelivery","info":{"currentTime":3.0}}';
      final s = parseYouTubeInfo(raw)!;
      expect(s.position, 3.0);
      expect(s.playing, isFalse);
      expect(s.buffering, isFalse);
    });

    test("a playerState update still wins over the carried-forward value", () {
      const raw =
          '{"event":"infoDelivery","info":{"playerState":2,"currentTime":9.0}}';
      final prev = const PlaybackSnapshot(
          position: 8.0, playing: true, buffering: false);
      final s = parseYouTubeInfo(raw, previous: prev)!;
      expect(s.playing, isFalse, reason: "explicit paused must override");
    });

    test("a frame with neither field is still ignored", () {
      expect(parseYouTubeInfo('{"event":"infoDelivery","info":{"foo":1}}'),
          isNull);
    });
  });
}
