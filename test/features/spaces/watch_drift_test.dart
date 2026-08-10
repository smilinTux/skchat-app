import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_drift.dart";

PlaybackSnapshot snap(double p,
        {bool playing = true, bool buffering = false}) =>
    PlaybackSnapshot(position: p, playing: playing, buffering: buffering);

void main() {
  test("small drift inside the dead band is left alone", () {
    // Correcting constantly is worse than being slightly off: every seek
    // stutters the picture for the viewer.
    expect(
        resolveDrift(local: snap(100.5), hostPosition: 100.0, hostPlaying: true),
        DriftAction.none);
  });

  test("drift past the dead band seeks and matches play state", () {
    expect(
        resolveDrift(local: snap(90.0), hostPosition: 100.0, hostPlaying: true),
        DriftAction.seekAndPlay);
    expect(
        resolveDrift(local: snap(120.0), hostPosition: 100.0, hostPlaying: false),
        DriftAction.seekAndPause);
  });

  test("a buffering local player is NEVER corrected", () {
    // Seeking a player that is still buffering restarts the buffer and can
    // livelock: it never catches up, so it never stops being corrected.
    expect(
        resolveDrift(
            local: snap(10.0, buffering: true),
            hostPosition: 100.0,
            hostPlaying: true),
        DriftAction.none);
  });

  test("in-band position but wrong play state fixes only the play state", () {
    expect(
        resolveDrift(
            local: snap(100.2, playing: false),
            hostPosition: 100.0,
            hostPlaying: true),
        DriftAction.playOnly);
    expect(
        resolveDrift(
            local: snap(100.2, playing: true),
            hostPosition: 100.0,
            hostPlaying: false),
        DriftAction.pauseOnly);
  });

  test("dead band is configurable and boundary is inclusive", () {
    expect(
        resolveDrift(
            local: snap(102.0),
            hostPosition: 100.0,
            hostPlaying: true,
            deadBandSeconds: 2.0),
        DriftAction.none);
    expect(
        resolveDrift(
            local: snap(102.01),
            hostPosition: 100.0,
            hostPlaying: true,
            deadBandSeconds: 2.0),
        DriftAction.seekAndPlay);
  });
}
