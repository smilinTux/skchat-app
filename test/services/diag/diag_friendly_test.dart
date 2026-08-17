// Tests for lib/services/diag/diag_friendly.dart -- the plain-language
// rendering the Me > Logs screen shows for each DiagEvent. The catalog
// (diag_codes.dart) carries no free-form message field by design; this file
// is the only place that gets turned into words a non-engineer can read.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/diag/diag_codes.dart";
import "package:skchat/services/diag/diag_event.dart";
import "package:skchat/services/diag/diag_friendly.dart";

DiagEvent _event({
  required String code,
  required Map<String, Object> fields,
  DiagLevel level = DiagLevel.error,
}) {
  final e = DiagEvent.tryCreate(
    seq: 0,
    ts: DateTime.utc(2026, 8, 16, 12),
    level: level,
    category: DiagCategory.net,
    code: code,
    fields: fields,
  );
  if (e == null) {
    fail("test built an invalid DiagEvent for $code: $fields");
  }
  return e;
}

/// A minimal correctly-typed value for [spec], for building a valid
/// all-required-fields payload without caring what it says.
Object _minimalValue(DiagFieldSpec spec) {
  switch (spec.typeName) {
    case "String":
      return "x";
    case "int":
      return 1;
    case "bool":
      return true;
    case "NetFailureKind":
      return NetFailureKind.unknown;
    case "CredentialKind":
      return CredentialKind.session;
    default:
      throw StateError("unhandled field type ${spec.typeName}");
  }
}

void main() {
  group("net.request_failed", () {
    test("reads as a place, host:port, and a plain-language failure reason",
        () {
      final event = _event(code: "net.request_failed", fields: {
        "kind": NetFailureKind.connectTimeout,
        "host": "skworld-100",
        "port": 18794,
        "pathTemplate": "/stt/transcribe",
        "method": "POST",
        "durationMs": 1200,
      });
      final friendly = friendlyDiagEvent(event);
      expect(friendly.headline, contains("Speech to text"));
      expect(friendly.headline, contains("skworld-100:18794"));
      expect(friendly.headline, contains("timed out"));
      // Never a raw enum dump.
      expect(friendly.headline, isNot(contains("NetFailureKind")));
      expect(friendly.headline, isNot(contains("connectTimeout")));
    });

    test("falls back to host:port with no service guess when nothing "
        "matches a known service", () {
      final event = _event(code: "net.request_failed", fields: {
        "kind": NetFailureKind.refused,
        "host": "192.168.1.50",
        "port": 9384,
        "pathTemplate": "/api/v1/whatever",
        "method": "GET",
        "durationMs": 5,
      });
      final friendly = friendlyDiagEvent(event);
      expect(friendly.headline, contains("192.168.1.50:9384"));
      expect(friendly.headline, contains("refused"));
    });

    test("every field is present in the technical detail, enums by name",
        () {
      final event = _event(code: "net.request_failed", fields: {
        "kind": NetFailureKind.http5xx,
        "host": "skworld-100",
        "port": 8082,
        "pathTemplate": "/llm/chat",
        "method": "POST",
        "status": 503,
        "durationMs": 40,
      });
      final detail = friendlyDiagEvent(event).detail;
      expect(detail, contains("code: net.request_failed"));
      expect(detail, contains("kind: http5xx"));
      expect(detail, contains("host: skworld-100"));
      expect(detail, contains("port: 8082"));
      expect(detail, contains("status: 503"));
      expect(detail, contains("durationMs: 40"));
    });
  });

  group("other catalog codes render without crashing", () {
    test("auth.session_expired names the credential kind in words", () {
      final event = _event(code: "auth.session_expired", fields: {
        "credential": CredentialKind.operator,
      });
      final friendly = friendlyDiagEvent(event);
      expect(friendly.headline, contains("operator session"));
    });

    test("call.media_silent reports seconds, not raw milliseconds prose",
        () {
      final event = _event(code: "call.media_silent", fields: {
        "directionEnum": "inbound",
        "silentForMs": 20000,
        "trackActive": true,
      });
      final friendly = friendlyDiagEvent(event);
      expect(friendly.headline, contains("20 seconds"));
    });

    test("lifecycle.error with no errorType still renders a headline", () {
      final event = _event(code: "lifecycle.error", fields: {
        "buildId": "b123",
      });
      final friendly = friendlyDiagEvent(event);
      expect(friendly.headline, "App error");
    });
  });

  test("every code in the catalog renders a non-empty headline without "
      "throwing", () {
    // Walks every registered code with a minimal all-required-fields
    // payload, so a future catalog addition that this file's switch has
    // not been taught yet is caught here (falling through to
    // _genericHeadline) rather than crashing the screen.
    for (final spec in DiagCodes.catalog.values) {
      final fields = <String, Object>{
        for (final f in spec.fields)
          if (!f.optional) f.key: _minimalValue(f),
      };
      final event = _event(code: spec.code, fields: fields);
      final friendly = friendlyDiagEvent(event);
      expect(friendly.headline, isNotEmpty, reason: spec.code);
      expect(friendly.detail, contains(spec.code), reason: spec.code);
    }
  });
}
