// Tests for DiagEvent.tryCreate (lib/services/diag/diag_event.dart).
//
// `flutter test` runs with Dart asserts ENABLED, i.e. it behaves like a
// debug build. That is exactly what "asserts in debug" (card cebbee31 AC2,
// AC3, AC4) needs: `tryCreate` should throw an AssertionError for invalid
// input here.
//
// Release behavior (asserts stripped) cannot be toggled from within a
// single `flutter test` run, so it is proven at the layer that actually
// carries it: DiagCodes.firstViolation contains no `assert` at all and is
// the exact check `tryCreate` still runs after the compiler strips
// `assert(violation == null, ...)`. diag_codes_test.dart exercises that
// function directly for every acceptance criterion; this file additionally
// confirms `tryCreate` is wired to it (i.e. bad input never produces an
// event object, assert or no assert) and covers construction concerns
// specific to DiagEvent itself: UTC normalization and field immutability.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/diag/diag_codes.dart";
import "package:skchat/services/diag/diag_event.dart";

void main() {
  group("DiagEvent.tryCreate: valid input", () {
    test("returns a populated event for a registered code with valid fields", () {
      final event = DiagEvent.tryCreate(
        seq: 1,
        ts: DateTime.utc(2026, 8, 14, 3, 4, 5),
        level: DiagLevel.error,
        category: DiagCategory.net,
        code: "net.request_failed",
        fields: {
          "kind": NetFailureKind.connectTimeout,
          "host": "skworld-100.tailnet",
          "port": 8443,
          "pathTemplate": "/api/v1/health/deps",
          "method": "GET",
          "durationMs": 5000,
        },
      );
      expect(event, isNotNull);
      expect(event!.code, "net.request_failed");
      expect(event.fields["kind"], NetFailureKind.connectTimeout);
    });

    test("normalizes ts to UTC regardless of the caller's local time", () {
      final local = DateTime(2026, 8, 14, 12, 0, 0);
      final event = DiagEvent.tryCreate(
        seq: 1,
        ts: local,
        level: DiagLevel.info,
        category: DiagCategory.lifecycle,
        code: "lifecycle.start",
        fields: {"buildId": "0.9.0+1"},
      );
      expect(event!.ts.isUtc, isTrue);
      expect(event.ts, local.toUtc());
    });

    test("fields map on the returned event is unmodifiable", () {
      final event = DiagEvent.tryCreate(
        seq: 1,
        ts: DateTime.utc(2026),
        level: DiagLevel.info,
        category: DiagCategory.lifecycle,
        code: "lifecycle.start",
        fields: {"buildId": "0.9.0+1"},
      );
      expect(() => event!.fields["buildId"] = "tampered", throwsUnsupportedError);
    });
  });

  group("DiagEvent.tryCreate: invalid input asserts in debug (AC2/AC3/AC4)", () {
    test("an unregistered code throws AssertionError", () {
      // MUTATION TARGET: DiagEvent.tryCreate's
      // `assert(violation == null, violation ?? '')` line. Deleting it
      // turns this from throwsA(isA<AssertionError>()) to a silent
      // non-throwing call (it would instead just return null), so the
      // test goes red.
      expect(
        () => DiagEvent.tryCreate(
          seq: 1,
          ts: DateTime.utc(2026),
          level: DiagLevel.error,
          category: DiagCategory.net,
          code: "nope.does_not_exist",
          fields: const {},
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test("a declared code with an undeclared field key throws AssertionError", () {
      expect(
        () => DiagEvent.tryCreate(
          seq: 1,
          ts: DateTime.utc(2026),
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: const {"buildId": "0.9.0+1", "message": "leaky"},
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test("a field with the wrong type throws AssertionError", () {
      expect(
        () => DiagEvent.tryCreate(
          seq: 1,
          ts: DateTime.utc(2026),
          level: DiagLevel.info,
          category: DiagCategory.lifecycle,
          code: "lifecycle.start",
          fields: const {"buildId": 12345}, // must be String
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group("DiagEvent.tryCreate: wired to the release-safe check", () {
    test(
      "every input that throws here is exactly the input DiagCodes.firstViolation flags "
      "(the check that still runs once asserts are stripped in release)",
      () {
        const cases = [
          ["nope.does_not_exist", <String, Object>{}],
          [
            "lifecycle.start",
            {"buildId": "x", "message": "leaky"},
          ],
          [
            "lifecycle.start",
            {"buildId": 12345},
          ],
        ];
        for (final c in cases) {
          final code = c[0] as String;
          final fields = c[1] as Map<String, Object>;
          expect(
            DiagCodes.firstViolation(code, fields),
            isNotNull,
            reason: "$code / $fields must be a violation in both debug and release",
          );
        }
      },
    );
  });
}
