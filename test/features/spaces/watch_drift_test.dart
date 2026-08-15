import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_drift.dart";

PlaybackSnapshot snap(double p,
        {bool playing = true, bool buffering = false, double rate = 1.0}) =>
    PlaybackSnapshot(
        position: p, playing: playing, buffering: buffering, rate: rate);

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

  test(
      "a local rate that disagrees with the session's agreed rate suppresses "
      "correction even at large drift", () {
    // A viewer who bumps the YouTube embed's own speed menu to 1.5x while
    // the room is still agreed on 1x is racing ahead on purpose, not
    // drifting out of sync: seek-yanking them back every heartbeat fights
    // the choice they just made instead of helping, the same reasoning that
    // leaves a buffering player alone. The next "rate" lane event resettles
    // this once it lands.
    expect(
        resolveDrift(
            local: snap(500.0, rate: 1.5),
            hostPosition: 100.0,
            hostPlaying: true,
            sessionRate: 1.0),
        DriftAction.none);
    expect(
        resolveDrift(
            local: snap(500.0, playing: false, rate: 1.5),
            hostPosition: 100.0,
            hostPlaying: true,
            sessionRate: 1.0),
        DriftAction.none);
  });

  test(
      "drift correction keeps running normally when local and session rate "
      "AGREE, even at a non-1x shared speed", () {
    // This is the regression the whole feature turns on: once speed is
    // shared room state, everyone running at the same non-1x rate is the
    // NORMAL case, not a suspicious one, so ordinary drift correction must
    // still apply.
    expect(
        resolveDrift(
            local: snap(90.0, rate: 1.5),
            hostPosition: 100.0,
            hostPlaying: true,
            sessionRate: 1.5),
        DriftAction.seekAndPlay);
    expect(
        resolveDrift(
            local: snap(100.2, playing: false, rate: 1.5),
            hostPosition: 100.0,
            hostPlaying: true,
            sessionRate: 1.5),
        DriftAction.playOnly);
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

  group("the dead band is a WALL-CLOCK tolerance, so it scales with rate", () {
    test("a faster room gets a proportionally wider band in video seconds", () {
      // The band is spent by real-world lag (a seek's rebuffer, the age of the
      // last infoDelivery sample, transport). Those costs are in wall-clock
      // seconds and do not shrink when the room speeds up, but a band fixed in
      // VIDEO seconds does: 2.0s of video is only 1.6s of wall clock at 1.25x.
      // Scaling keeps the real tolerance constant instead of quietly tightening
      // it every time someone bumps the speed.
      expect(effectiveDeadBand(2.0, 1.0), 2.0);
      expect(effectiveDeadBand(2.0, 1.25), closeTo(2.5, 1e-9));
      expect(effectiveDeadBand(2.0, 2.0), 4.0);
    });

    test("slower than 1x never TIGHTENS the band below the baseline", () {
      // Widening at speed is the fix; narrowing at half speed would just be a
      // new way to over-correct. 2.0s is the perceptual floor either way.
      expect(effectiveDeadBand(2.0, 0.5), 2.0);
      expect(effectiveDeadBand(2.0, 0.25), 2.0);
    });

    test("2.4s off at 1.25x is left alone, the same offset at 1x is not", () {
      // The exact case Chef hit: at 1.25x this drift used to be corrected, and
      // the correction's own rebuffer manufactured more than 2.0s of fresh
      // drift, so the next heartbeat corrected again, forever.
      expect(
          resolveDrift(
              local: snap(97.6, rate: 1.25),
              hostPosition: 100.0,
              hostPlaying: true,
              sessionRate: 1.25),
          DriftAction.none);
      expect(
          resolveDrift(
              local: snap(97.6), hostPosition: 100.0, hostPlaying: true),
          DriftAction.seekAndPlay);
    });
  });

  group("DriftCorrector backs off instead of stuttering forever", () {
    // A viewer whose player cannot complete a seek inside the dead band can
    // never be corrected INTO the band: the seek's own stall puts them right
    // back out of it. resolveDrift alone re-issues that seek on every 3s
    // heartbeat, which is what the room saw as "pause for a second or two,
    // then play", on repeat, for the rest of the movie.
    DriftAction tick(DriftCorrector c, double localPos, double hostPos,
            {double rate = 1.0, bool buffering = false}) =>
        c.onHeartbeat(
          local: snap(localPos, rate: rate, buffering: buffering),
          hostPosition: hostPos,
          hostPlaying: true,
          sessionRate: rate,
        );

    test("the first correction fires immediately", () {
      final c = DriftCorrector();
      expect(tick(c, 90.0, 100.0), DriftAction.seekAndPlay);
    });

    test("the tick right after a correction does not grade it", () {
      // The seek has not landed yet: the player is still stalling and its
      // reported position is still the pre-seek one. Correcting off that
      // reading is correcting off a measurement of our own correction.
      final c = DriftCorrector();
      expect(tick(c, 90.0, 100.0), DriftAction.seekAndPlay);
      expect(tick(c, 90.0, 103.0), DriftAction.none);
    });

    test("a client that never settles is corrected less and less often", () {
      final c = DriftCorrector();
      // Every tick is out of band: the correction is not working.
      final fired = <int>[];
      for (var t = 0; t < 40; t++) {
        if (tick(c, 0.0, 100.0 + t * 3.0) != DriftAction.none) fired.add(t);
      }
      // 1, 2, 4, 8 then capped: seeks at ticks 0, 2, 5, 10, 19, 28, 37.
      expect(fired, [0, 2, 5, 10, 19, 28, 37]);
    });

    test("the back-off is bounded, so a real desync always heals", () {
      // Backing off to "never" would strand someone in the wrong scene. The
      // cap is what bounds worst-case recovery.
      final c = DriftCorrector();
      for (var t = 0; t < 200; t++) {
        tick(c, 0.0, 100.0 + t * 3.0);
      }
      expect(c.cooldownTicks, lessThanOrEqualTo(DriftCorrector.maxCooldownTicks));
    });

    test("settling inside the band gives responsiveness straight back", () {
      final c = DriftCorrector();
      tick(c, 0.0, 100.0); // seek, arms the cool-down
      tick(c, 0.0, 103.0); // suppressed
      tick(c, 106.0, 106.0); // settled: in band
      // Next real drift must be corrected at once, not on a stale back-off.
      expect(tick(c, 100.0, 120.0), DriftAction.seekAndPlay);
    });

    test("a buffering tick neither grades nor forgives the back-off", () {
      // A seek puts the player into buffering, and resolveDrift returns none
      // for a buffering player. Treating that none as "settled" would reset
      // the back-off on the very stall the back-off exists to damp, so the
      // cool-down could never grow past its first step.
      final c = DriftCorrector();
      expect(tick(c, 0.0, 100.0), DriftAction.seekAndPlay);
      expect(tick(c, 0.0, 103.0, buffering: true), DriftAction.none);
      expect(tick(c, 0.0, 106.0), DriftAction.none,
          reason: "still inside the first cool-down");
      expect(tick(c, 0.0, 109.0), DriftAction.seekAndPlay);
      expect(tick(c, 0.0, 112.0), DriftAction.none);
      expect(tick(c, 0.0, 115.0), DriftAction.none,
          reason: "second cool-down is longer, so the back-off did grow");
    });

    test("play/pause corrections are never suppressed", () {
      // They cost nothing to apply (no rebuffer) and a viewer left rolling
      // through a pause the host called is the loudest possible desync.
      final c = DriftCorrector();
      expect(tick(c, 0.0, 100.0), DriftAction.seekAndPlay); // arms cool-down
      expect(
          c.onHeartbeat(
            local: snap(100.2, playing: true),
            hostPosition: 100.0,
            hostPlaying: false,
          ),
          DriftAction.pauseOnly);
    });

    test("reset() clears the back-off after an explicit re-sync", () {
      // An explicit load/seek/play/pause lane event re-aligns this client by
      // construction, so whatever the drift loop had learned is stale.
      final c = DriftCorrector();
      tick(c, 0.0, 100.0);
      c.reset();
      expect(tick(c, 0.0, 103.0), DriftAction.seekAndPlay);
    });
  });
}
