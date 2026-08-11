import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/skcode/skcode_event.dart";
import "package:skchat/services/skcode/skcode_event_merge.dart";

SkcodeEvent _ev({
  required String sid,
  required int seq,
  required double ts,
  String type = "assistant_text",
  String text = "",
}) =>
    SkcodeEvent(sid: sid, seq: seq, ts: ts, type: type, text: text);

void main() {
  group("mergeSkcodeEventWindows: the seq-resets-on-restart trap", () {
    // TRAP 1 (card f2e35195): `seq` is a per-session counter LOCAL TO ONE
    // DAEMON PROCESS. It resets to 1 on every restart while `ts` keeps
    // climbing. A dedup key of `seq` alone, or `(sid, seq)` alone, therefore
    // collapses a pre-restart event and an unrelated post-restart event that
    // happen to share a seq number. The correct key is `(sid, seq, ts)`.
    //
    // This test simulates exactly that: the archive window holds 3 events
    // from BEFORE a daemon restart (seq 1,2,3 at low timestamps); the live
    // window holds 3 events from AFTER the restart on the SAME session
    // (seq 1,2,3 again, at much later timestamps, because the counter reset
    // to 1). A correct merge must keep all 6 rows. A `(sid, seq)`-keyed merge
    // collapses them to 3, silently losing the entire pre-restart archive.
    test("no rows collapse and no rows are lost across a seq reset", () {
      const sid = "s-restart";

      final preRestartArchive = [
        _ev(sid: sid, seq: 1, ts: 1000.0, text: "before-1"),
        _ev(sid: sid, seq: 2, ts: 1001.0, text: "before-2"),
        _ev(sid: sid, seq: 3, ts: 1002.0, text: "before-3"),
      ];
      final postRestartLive = [
        _ev(sid: sid, seq: 1, ts: 5000.0, text: "after-1"),
        _ev(sid: sid, seq: 2, ts: 5001.0, text: "after-2"),
        _ev(sid: sid, seq: 3, ts: 5002.0, text: "after-3"),
      ];

      final merged =
          mergeSkcodeEventWindows(postRestartLive, preRestartArchive);

      expect(
        merged.length,
        6,
        reason: "all 6 events (3 pre-restart + 3 post-restart) must survive; "
            "a naive (sid, seq) key would collapse this to 3 and silently "
            "drop the entire pre-restart archive",
      );

      // Every pre-restart row is still present, unharmed by the same-numbered
      // post-restart rows.
      for (final before in preRestartArchive) {
        expect(
          merged.any((e) => e.seq == before.seq && e.ts == before.ts && e.text == before.text),
          isTrue,
          reason: "pre-restart event seq=${before.seq} ts=${before.ts} was dropped",
        );
      }
      // Every post-restart row is present too.
      for (final after in postRestartLive) {
        expect(
          merged.any((e) => e.seq == after.seq && e.ts == after.ts && e.text == after.text),
          isTrue,
          reason: "post-restart event seq=${after.seq} ts=${after.ts} was dropped",
        );
      }

      // Ascending (ts, seq): the 3 pre-restart rows all sort before the 3
      // post-restart rows.
      final ts = merged.map((e) => e.ts).toList();
      final sortedTs = [...ts]..sort();
      expect(ts, sortedTs);
    });

    test("a TRUE duplicate (identical sid, seq, AND ts) still dedups, live wins", () {
      const sid = "s-dup";
      final archived = [
        _ev(sid: sid, seq: 7, ts: 42.0, text: "archived-copy"),
      ];
      final live = [
        _ev(sid: sid, seq: 7, ts: 42.0, text: "live-copy-with-mutation"),
      ];

      final merged = mergeSkcodeEventWindows(live, archived);

      expect(merged.length, 1,
          reason: "identical (sid, seq, ts) IS a true duplicate and must collapse to one row");
      expect(merged.single.text, "live-copy-with-mutation",
          reason: "the live copy must win: it may carry incremental transcript mutations the archive lacks");
    });

    test("different sessions never collide even with identical seq/ts", () {
      final live = [_ev(sid: "s-A", seq: 1, ts: 100.0)];
      final archived = [_ev(sid: "s-B", seq: 1, ts: 100.0)];

      final merged = mergeSkcodeEventWindows(live, archived);

      expect(merged.length, 2,
          reason: "sid must be part of the dedup key; two different sessions "
              "sharing (seq, ts) are NOT duplicates");
    });
  });

  group("mergeSkcodeEventWindows: general behavior", () {
    test("empty archive returns live events sorted", () {
      final live = [
        _ev(sid: "s1", seq: 2, ts: 20.0),
        _ev(sid: "s1", seq: 1, ts: 10.0),
      ];
      final merged = mergeSkcodeEventWindows(live, const []);
      expect(merged.map((e) => e.seq), [1, 2]);
    });

    test("empty live returns archived events sorted", () {
      final archived = [
        _ev(sid: "s1", seq: 2, ts: 20.0),
        _ev(sid: "s1", seq: 1, ts: 10.0),
      ];
      final merged = mergeSkcodeEventWindows(const [], archived);
      expect(merged.map((e) => e.seq), [1, 2]);
    });

    test("sorts ascending by ts then seq when ts ties", () {
      final live = [
        _ev(sid: "s1", seq: 5, ts: 100.0),
        _ev(sid: "s1", seq: 3, ts: 100.0),
        _ev(sid: "s1", seq: 4, ts: 100.0),
      ];
      final merged = mergeSkcodeEventWindows(live, const []);
      expect(merged.map((e) => e.seq), [3, 4, 5]);
    });
  });

  group("skcodeEventRowId", () {
    test("joins sid:seq:ts as the stable scroll anchor", () {
      final e = _ev(sid: "s-1a2b", seq: 412, ts: 1765430000.123);
      expect(skcodeEventRowId(e), "s-1a2b:412:1765430000.123");
    });
  });

  group("capLiveSkcodeWindow", () {
    test("leaves a window at or under the cap untouched", () {
      final events = List.generate(10, (i) => _ev(sid: "s1", seq: i, ts: i.toDouble()));
      final capped = capLiveSkcodeWindow(events, max: 10);
      expect(capped.length, 10);
    });

    test("trims to the most recent N when over the cap", () {
      final events =
          List.generate(3005, (i) => _ev(sid: "s1", seq: i, ts: i.toDouble()));
      final capped = capLiveSkcodeWindow(events, max: kMaxLiveSkcodeEvents);
      expect(capped.length, kMaxLiveSkcodeEvents);
      // The oldest events (lowest seq) are the ones dropped.
      expect(capped.first.seq, 3005 - kMaxLiveSkcodeEvents);
      expect(capped.last.seq, 3004);
    });

    test("default max is Buzz's MAX_OBSERVER_EVENTS (3000)", () {
      expect(kMaxLiveSkcodeEvents, 3000);
    });
  });

  group("SkcodeEvent.fromJson / toJson", () {
    test("round-trips the full v2 wire shape", () {
      final json = {
        "type": "tool_call",
        "text": "Edit",
        "ts": 1765430000.123,
        "data": {"id": "abc", "name": "Edit", "input": <String, dynamic>{}},
        "seq": 412,
        "sid": "s-1a2b",
        "source": "interactive",
      };
      final event = SkcodeEvent.fromJson(json);
      expect(event.type, "tool_call");
      expect(event.seq, 412);
      expect(event.sid, "s-1a2b");
      expect(event.source, "interactive");
      expect(event.toJson(), json);
    });

    test("tolerates a v1 frame missing seq/sid/source (defaults applied)", () {
      final event = SkcodeEvent.fromJson({
        "type": "status",
        "text": "",
        "ts": 100.0,
        "data": <String, dynamic>{},
      });
      expect(event.seq, 0);
      expect(event.sid, "");
      expect(event.source, "interactive");
    });
  });
}
