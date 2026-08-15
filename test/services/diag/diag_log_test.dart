// Tests for the DiagLog ring buffer and its bounded persisted tail
// (lib/services/diag/diag_log.dart). Card b62da57c (Obs P1.2): every
// acceptance criterion below needs a test that would FAIL without the
// corresponding guard. See the "MUTATION TARGET" comments; each names the
// exact behavior whose removal turns the paired test red.
//
// Hive key/box name for the persisted tail is public (kDiagLogBoxName);
// the storage KEY under that box is private to diag_log.dart, so it is
// mirrored here as a literal, same convention as
// test/services/module_prefs_seed_version_test.dart.
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:skchat/services/diag/diag_event.dart";
import "package:skchat/services/diag/diag_log.dart";

const _kTailKey = "tail";

void main() {
  setUpAll(() {
    Hive.init(
      Directory.systemTemp.createTempSync("skchat_diag_log_test").path,
    );
  });

  setUp(() async {
    // Start each test from a clean, closed box so persistence assertions
    // never see a previous test's data.
    if (Hive.isBoxOpen(kDiagLogBoxName)) {
      await Hive.box(kDiagLogBoxName).close();
    }
    await Hive.deleteBoxFromDisk(kDiagLogBoxName);
  });

  group("ring buffer cap (AC1)", () {
    test("holds at most 1000 events; the 1001st evicts the oldest", () {
      // MUTATION TARGET: the fixed-size ring + write-cursor eviction in
      // DiagLog._pushToRing / the `events` getter. Letting the ring grow
      // past ringCapacity (e.g. a plain growable list with no wraparound)
      // turns `events.length` into 1001 and this test red.
      final log = DiagLog();
      addTearDown(log.dispose);

      for (var i = 0; i < 1001; i++) {
        log.emit(
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: {"buildId": "b$i"},
        );
      }

      final events = log.events;
      expect(events, hasLength(1000));
      // seq 0 (the 1st event) was evicted by the 1001st; order is
      // preserved oldest-to-newest, not just membership.
      expect(events.first.seq, 1);
      expect(events.last.seq, 1000);
      for (var i = 0; i < events.length; i++) {
        expect(events[i].seq, i + 1);
      }
    });

    test("well under the cap, nothing is evicted and order is stable", () {
      final log = DiagLog();
      addTearDown(log.dispose);

      for (var i = 0; i < 10; i++) {
        log.emit(
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: {"buildId": "b$i"},
        );
      }

      final events = log.events;
      expect(events, hasLength(10));
      expect(events.first.seq, 0);
      expect(events.last.seq, 9);
    });
  });

  group("persisted tail respects the event-count cap (AC2)", () {
    test("with small fields, exactly 300 of 301 events survive a flush",
        () async {
      // MUTATION TARGET: the persistedTailMaxEvents trim in
      // DiagLog._boundedTailPayload. Dropping that check (persist
      // everything the ring has) turns `stored.length` into 301.
      final log = DiagLog();
      addTearDown(log.dispose);
      await log.init();
      expect(log.isPersistenceAvailable, isTrue);

      for (var i = 0; i < 301; i++) {
        log.emit(
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: {"buildId": "b$i"},
        );
      }
      await log.flush();

      final box = Hive.box<dynamic>(kDiagLogBoxName);
      final stored = (box.get(_kTailKey) as List).cast<Map>();
      expect(stored, hasLength(300));
      // Oldest survivor is seq 1 (seq 0 aged out of the 300-event window);
      // newest is the last emitted.
      expect(stored.first["seq"], 1);
      expect(stored.last["seq"], 300);
      // Comfortably under the byte cap for tiny fields, i.e. the event
      // cap is what bound here, not the byte cap.
      final bytes = utf8.encode(jsonEncode(stored)).length;
      expect(bytes, lessThan(256 * 1024));
    });
  });

  group("persisted tail respects the byte cap (AC2)", () {
    test("large fields blow the 256 KiB cap before 300 events accumulate",
        () async {
      // MUTATION TARGET: the persistedTailMaxBytes accumulation check in
      // DiagLog._boundedTailPayload. Dropping that check (only trim by
      // event count) lets `stored.length` reach 300 and `bytes` exceed
      // the 256 KiB cap, turning both assertions below red.
      final log = DiagLog();
      addTearDown(log.dispose);
      await log.init();

      final bigHost = List<String>.filled(900, "h").join();
      for (var i = 0; i < 300; i++) {
        log.emit(
          level: DiagLevel.warn,
          category: DiagCategory.net,
          code: "net.request_failed",
          fields: {
            "kind": NetFailureKind.connectTimeout,
            "host": bigHost,
            "port": 443,
            "pathTemplate": "/api/v1/health/deps",
            "method": "GET",
            "durationMs": 5000,
          },
        );
      }
      await log.flush();

      final box = Hive.box<dynamic>(kDiagLogBoxName);
      final stored = (box.get(_kTailKey) as List).cast<Map>();
      // 300 events at ~950+ bytes each would total well over 256 KiB, so
      // the byte cap must bind and trim below the 300-event cap.
      expect(stored.length, lessThan(300));
      expect(stored, isNotEmpty);
      final bytes = utf8.encode(jsonEncode(stored)).length;
      expect(bytes, lessThanOrEqualTo(256 * 1024));
      // Oldest-first trimming: the newest event always survives.
      expect(stored.last["seq"], 299);
    });
  });

  group("no per-event disk writes (AC3)", () {
    test("box has no tail after N emits with no debounce, pause, or capture",
        () async {
      // MUTATION TARGET: any write to the box from inside DiagLog.emit
      // itself (e.g. calling flush()/box.put per emit instead of only
      // scheduling the debounce timer). That would populate `tail` here.
      final log = DiagLog();
      addTearDown(log.dispose);
      await log.init();
      expect(log.isPersistenceAvailable, isTrue);

      for (var i = 0; i < 50; i++) {
        log.emit(
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: {"buildId": "b$i"},
        );
      }
      // Give any accidentally-synchronous-triggered async write a chance
      // to land, nowhere near the real 30 s debounce interval.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final box = Hive.box<dynamic>(kDiagLogBoxName);
      expect(box.isEmpty, isTrue);
      expect(box.get(_kTailKey), isNull);
    });
  });

  group("corrupt/unopenable box falls back to memory-only (AC4)", () {
    test("init() never throws when opening the box fails, app keeps working",
        () async {
      // MUTATION TARGET: the try/catch around `_box = await _openBox()`
      // in DiagLog.init. Removing it lets the simulated failure below
      // propagate out of init() and fail this test with an uncaught
      // StateError instead of the assertions passing.
      final log = DiagLog(
        openBox: () async => throw StateError("simulated unopenable box"),
      );
      addTearDown(log.dispose);

      await log.init(); // must not throw
      expect(log.isPersistenceAvailable, isFalse);

      final event = log.emit(
        level: DiagLevel.error,
        category: DiagCategory.lifecycle,
        code: "lifecycle.error",
        fields: {"buildId": "b0"},
      );
      expect(event, isNotNull);
      expect(log.events, hasLength(1));

      // A flush on a persistence-unavailable log is a safe no-op, not a
      // throw.
      await log.flush();
    });

    test("a healthy box still opens and persists normally (control)",
        () async {
      final log = DiagLog();
      addTearDown(log.dispose);
      await log.init();
      expect(log.isPersistenceAvailable, isTrue);
    });
  });

  group("persisted tail prepended on startup (AC5)", () {
    test("events survive a restart: a fresh DiagLog reads the prior tail",
        () async {
      final first = DiagLog();
      await first.init();
      expect(first.isPersistenceAvailable, isTrue);

      for (var i = 0; i < 5; i++) {
        first.emit(
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: {"buildId": "b$i"},
        );
      }
      await first.flush(); // simulates pause/detach or snapshot capture
      await first.dispose(); // release the box so a "restart" can reopen it

      final second = DiagLog();
      addTearDown(second.dispose);
      await second.init();

      final restored = second.events;
      expect(restored, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(restored[i].code, "lifecycle.start");
        expect(restored[i].fields["buildId"], "b$i");
      }

      // New emits land after the restored tail, with a seq counter that
      // continues rather than colliding with the restored events.
      final next = second.emit(
        level: DiagLevel.info,
        category: DiagCategory.lifecycle,
        code: "lifecycle.resume",
        fields: {"buildId": "resume"},
      );
      expect(second.events, hasLength(6));
      expect(second.events.last, same(next));
      expect(next!.seq, greaterThan(restored.last.seq));
    });

    test("no persisted box yet: startup is just an empty ring, not a throw",
        () async {
      final log = DiagLog();
      addTearDown(log.dispose);
      await log.init();
      expect(log.isPersistenceAvailable, isTrue);
      expect(log.events, isEmpty);
    });
  });

  group("eventStream", () {
    test("emits exactly the accepted events, in order", () async {
      final log = DiagLog();
      addTearDown(log.dispose);
      final seen = <String>[];
      final sub = log.eventStream.listen((e) => seen.add(e.code));

      log.emit(
        level: DiagLevel.info,
        category: DiagCategory.lifecycle,
        code: "lifecycle.start",
        fields: {"buildId": "b0"},
      );
      log.emit(
        level: DiagLevel.info,
        category: DiagCategory.lifecycle,
        code: "lifecycle.resume",
        fields: {"buildId": "b1"},
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, ["lifecycle.start", "lifecycle.resume"]);
    });
  });
}
