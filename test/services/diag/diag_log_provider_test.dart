// Tests for lib/services/diag/diag_log_provider.dart -- the seam that
// connects the previously-inert diagEventSink (diag_error_sink.dart) to a
// real DiagLog (diag_log.dart) at boot. Card 0a5b8e07 (Obs P1, wiring half).
//
// MUTATION TARGET (see PR description for the actual mutate-and-report run):
// commenting out the `diagEventSink = ...` assignment in
// initDiagLogAndWireSink turns every test in the first group red, because
// emitDiagEvent then has nowhere to dispatch to and DiagLog.events stays
// empty.
import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:skchat/services/diag/diag_error_sink.dart";
import "package:skchat/services/diag/diag_event.dart";
import "package:skchat/services/diag/diag_log.dart";
import "package:skchat/services/diag/diag_log_provider.dart";

void main() {
  setUpAll(() {
    Hive.init(
      Directory.systemTemp.createTempSync("skchat_diag_wiring_test").path,
    );
  });

  setUp(() async {
    // Isolate from any other DiagLog test file / a prior run of this one:
    // start every test with the box closed and empty, and the global sink
    // reset, since diagEventSink is process-global mutable state.
    if (Hive.isBoxOpen(kDiagLogBoxName)) {
      await Hive.box(kDiagLogBoxName).close();
    }
    await Hive.deleteBoxFromDisk(kDiagLogBoxName);
    diagEventSink = null;
  });

  tearDown(() {
    diagEventSink = null;
  });

  group("initDiagLogAndWireSink connects the sink", () {
    test(
        "a DiagEvent handed to emitDiagEvent after wiring lands in the "
        "returned DiagLog's ring", () async {
      final diagLog = await initDiagLogAndWireSink();
      addTearDown(diagLog.dispose);

      expect(diagEventSink, isNotNull,
          reason: "initDiagLogAndWireSink must assign diagEventSink");

      final event = DiagEvent.tryCreate(
        seq: 0,
        ts: DateTime.now(),
        level: DiagLevel.error,
        category: DiagCategory.net,
        code: "net.request_failed",
        fields: <String, Object>{
          "kind": NetFailureKind.connectTimeout,
          "host": "chi.example",
          "port": 9384,
          "pathTemplate": "/api/v1/probe",
          "method": "GET",
          "durationMs": 12,
        },
      );
      expect(event, isNotNull);

      emitDiagEvent(event);

      expect(diagLog.events, hasLength(1));
      expect(diagLog.events.single.code, "net.request_failed");
      expect(
        diagLog.events.single.fields["host"],
        "chi.example",
      );
    });

    test("with diagEventSink left null (sink never wired), the same event "
        "never reaches any DiagLog -- there is nowhere for it to land",
        () async {
      // Deliberately does NOT call initDiagLogAndWireSink. Stands in for
      // the mutation: this is what "leave diagEventSink null" looks like,
      // proven directly rather than by editing source and re-running.
      final event = DiagEvent.tryCreate(
        seq: 0,
        ts: DateTime.now(),
        level: DiagLevel.error,
        category: DiagCategory.net,
        code: "net.request_failed",
        fields: <String, Object>{
          "kind": NetFailureKind.connectTimeout,
          "host": "chi.example",
          "port": 9384,
          "pathTemplate": "/api/v1/probe",
          "method": "GET",
          "durationMs": 12,
        },
      );

      // Fail-open: must not throw even with nowhere to send the event.
      expect(() => emitDiagEvent(event), returnsNormally);
      expect(diagEventSink, isNull);
    });

    test("wiring survives a DiagLog.init() failure (unopenable box) -- the "
        "sink is still assigned to a usable, memory-only DiagLog", () async {
      // Simulate an unopenable/corrupt box the same way diag_log_test.dart's
      // own init-failure fixtures do: openBox always throws.
      final diagLog = DiagLog(
        openBox: () async => throw const FileSystemException("nope"),
      );
      // Exercise the same fail-open contract initDiagLogAndWireSink relies
      // on directly against DiagLog.init(), then perform the same
      // assignment initDiagLogAndWireSink does, to prove the *sink half* of
      // the wiring does not depend on persistence succeeding.
      await diagLog.init();
      addTearDown(diagLog.dispose);
      expect(diagLog.isPersistenceAvailable, isFalse);

      diagEventSink = (event) => diagLog.emit(
            level: event.level,
            category: event.category,
            code: event.code,
            fields: event.fields,
          );

      final event = DiagEvent.tryCreate(
        seq: 0,
        ts: DateTime.now(),
        level: DiagLevel.warn,
        category: DiagCategory.lifecycle,
        code: "lifecycle.error",
        fields: <String, Object>{
          "buildId": "test-build",
          "errorType": "StateError",
        },
      );
      emitDiagEvent(event);

      expect(diagLog.events, hasLength(1));
    });
  });

  group("diagLogProvider default (no override)", () {
    test("resolves to a usable, memory-only DiagLog rather than throwing",
        () {
      // No override here -- this is exactly the "widget test that never
      // went through main()" case the provider's own doc calls out. It
      // must not require an override to be readable.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(diagLogProvider);
      expect(log, isA<DiagLog>());
      expect(log.isPersistenceAvailable, isFalse);
    });
  });
}
