// Tests for the diagnostic event code catalog (lib/services/diag/diag_codes.dart).
//
// Card cebbee31 (Obs P1.1): every acceptance criterion below needs a test
// that would FAIL without the corresponding check in DiagCodes. See the
// "mutation" comments; each one names the exact line whose removal turns
// the paired test red.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/diag/diag_codes.dart";
import "package:skchat/services/diag/diag_event.dart";

void main() {
  // Spec 4.1, section-by-section: code -> (required field keys, optional
  // field keys). This table is the acceptance criterion "every code in
  // spec 4.1 exists in the catalog with its declared field keys" made
  // explicit and checkable, independent of DiagCodes' own source.
  const expectedRequired = {
    "net.request_failed": [
      "kind",
      "host",
      "port",
      "pathTemplate",
      "method",
      "durationMs",
    ],
    "net.request_slow": ["host", "port", "pathTemplate", "durationMs"],
    "auth.retry": ["credential"],
    "auth.session_expired": ["credential"],
    "auth.mint_failed": ["credential"],
    "call.state": ["state", "room", "peerCount"],
    "call.quality": ["quality", "participant"],
    "call.media_silent": ["directionEnum", "silentForMs", "trackActive"],
    "voice.turn": ["stage"],
    "health.change": ["dep", "from", "to", "probe"],
    "beat.missed": ["loop", "expectedMs", "silentForMs"],
    "store.box_corrupt": ["box"],
    "store.flush_failed": ["box"],
    "lifecycle.start": ["buildId"],
    "lifecycle.resume": ["buildId"],
    "lifecycle.error": ["buildId"],
  };

  const expectedOptional = {
    "net.request_failed": ["status"],
    "net.request_slow": <String>[],
    "auth.retry": ["status"],
    "auth.session_expired": ["status"],
    "auth.mint_failed": ["status"],
    "call.state": <String>[],
    "call.quality": <String>[],
    "call.media_silent": <String>[],
    "voice.turn": ["durationMs"],
    "health.change": <String>[],
    "beat.missed": <String>[],
    "store.box_corrupt": ["bytes"],
    "store.flush_failed": ["bytes"],
    "lifecycle.start": ["errorType"],
    "lifecycle.resume": ["errorType"],
    "lifecycle.error": ["errorType"],
  };

  // A syntactically valid value for each field key used anywhere in the
  // catalog. Used to build a "known-good" fields map per code so the
  // per-field wrong-type test only ever varies ONE field at a time.
  final validValueFor = <String, Object>{
    "kind": NetFailureKind.connectTimeout,
    "host": "skworld-100.tailnet",
    "port": 8443,
    "pathTemplate": "/api/v1/health/deps",
    "method": "GET",
    "status": 503,
    "durationMs": 1200,
    "credential": CredentialKind.session,
    "state": "connected",
    "room": "8f3a9c2e",
    "peerCount": 2,
    "quality": "good",
    "participant": "local",
    "directionEnum": "outbound",
    "silentForMs": 4000,
    "trackActive": true,
    "stage": "transcribing",
    "dep": "skchat",
    "from": "ok",
    "to": "unknown",
    "probe": "client",
    "loop": "voice_engine.poll",
    "expectedMs": 5000,
    "box": "diag_log",
    "bytes": 2048,
    "buildId": "0.9.0+42",
    "errorType": "SocketException",
  };

  // A value guaranteed to be the WRONG type for every key above.
  final wrongValueFor = <String, Object>{
    "kind": "connectTimeout", // must be NetFailureKind, not String
    "host": 1,
    "port": "8443",
    "pathTemplate": 1,
    "method": 1,
    "status": "503",
    "durationMs": "1200",
    "credential": "session", // must be CredentialKind, not String
    "state": 1,
    "room": 1,
    "peerCount": "2",
    "quality": 1,
    "participant": 1,
    "directionEnum": 1,
    "silentForMs": "4000",
    "trackActive": "true",
    "stage": 1,
    "dep": 1,
    "from": 1,
    "to": 1,
    "probe": 1,
    "loop": 1,
    "expectedMs": "5000",
    "box": 1,
    "bytes": "2048",
    "buildId": 1,
    "errorType": 1,
  };

  Map<String, Object> validFieldsFor(String code) => {
    for (final k in [...expectedRequired[code]!, ...expectedOptional[code]!])
      k: validValueFor[k]!,
  };

  group("catalog completeness (AC1: every spec 4.1 code, exact fields)", () {
    test("catalog has exactly the codes spec 4.1 declares, no more, no less", () {
      expect(DiagCodes.catalog.keys.toSet(), expectedRequired.keys.toSet());
    });

    for (final code in expectedRequired.keys) {
      test("$code: declared required + optional fields match spec 4.1", () {
        final spec = DiagCodes.catalog[code];
        expect(spec, isNotNull, reason: "code $code must be registered");
        final required = spec!.fields
            .where((f) => !f.optional)
            .map((f) => f.key)
            .toSet();
        final optional = spec.fields
            .where((f) => f.optional)
            .map((f) => f.key)
            .toSet();
        expect(required, expectedRequired[code]!.toSet());
        expect(optional, expectedOptional[code]!.toSet());
      });

      test("$code: a fully valid fields map is accepted", () {
        expect(DiagCodes.firstViolation(code, validFieldsFor(code)), isNull);
      });

      for (final key in expectedRequired[code]!) {
        test(
          "$code: field '$key' with the wrong type is rejected (AC4)",
          () {
            final fields = Map<String, Object>.of(validFieldsFor(code));
            fields[key] = wrongValueFor[key]!;
            // MUTATION TARGET: DiagCodes.firstViolation's
            // `if (!field.isValidValue(value))` branch. Deleting that check
            // (always treating values as valid) turns this test red because
            // firstViolation would then return null.
            expect(DiagCodes.firstViolation(code, fields), isNotNull);
          },
        );
      }
    }
  });

  group("unregistered code rejection (AC2)", () {
    test("a code absent from the catalog is a violation", () {
      // MUTATION TARGET: DiagCodes.firstViolation's
      // `if (spec == null) { return '...not registered...'; }` branch.
      // Deleting that early return (falling through as if spec were found)
      // makes this null-check crash instead of returning a violation
      // string, or (if instead short-circuited to "return null") turns
      // this assertion red directly.
      expect(
        DiagCodes.firstViolation("nope.does_not_exist", const {}),
        isNotNull,
      );
    });

    test("isRegistered is false for an unknown code", () {
      expect(DiagCodes.isRegistered("nope.does_not_exist"), isFalse);
    });

    test("isRegistered is true for a real catalog code", () {
      expect(DiagCodes.isRegistered("net.request_failed"), isTrue);
    });
  });

  group("undeclared field key rejection (AC3)", () {
    test("a declared code with an extra, undeclared field key is a violation", () {
      final fields = Map<String, Object>.of(validFieldsFor("lifecycle.start"));
      fields["stackTrace"] = "some free-form text"; // never declared, anywhere
      // MUTATION TARGET: firstViolation's loop
      // `for (final key in fields.keys) { if (spec.fieldSpec(key) == null) ... }`.
      // Deleting this loop (only checking declared keys' types, never
      // scanning for extras) turns this test red.
      expect(DiagCodes.firstViolation("lifecycle.start", fields), isNotNull);
    });

    test("an exception MESSAGE key can never be declared for any code", () {
      // The privacy gate itself: no catalog entry may expose a raw
      // exception/message string, only classified kinds and runtime type
      // names. If a future edit ever adds a `message` field to any code,
      // this fails loudly at review time.
      for (final spec in DiagCodes.catalog.values) {
        final keys = spec.fields.map((f) => f.key).toSet();
        expect(
          keys.contains("message"),
          isFalse,
          reason: "${spec.code} must not declare a free-form message field",
        );
      }
    });
  });

  group("required field presence", () {
    test("a code missing a required field is a violation", () {
      final fields = Map<String, Object>.of(validFieldsFor("call.state"));
      fields.remove("room");
      expect(DiagCodes.firstViolation("call.state", fields), isNotNull);
    });

    test("a code missing only an OPTIONAL field is fine", () {
      final fields = Map<String, Object>.of(validFieldsFor("voice.turn"));
      fields.remove("durationMs");
      expect(DiagCodes.firstViolation("voice.turn", fields), isNull);
    });
  });
}
