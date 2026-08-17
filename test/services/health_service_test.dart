// Tests for lib/services/health_service.dart -- the client for
// GET /api/v1/health and the honesty contract every branch of
// HealthService.fetch() upholds (see that file's header):
//   1. Never show green the client did not verify: a network failure, a
//      404 (not-yet-deployed), a 401 (not authorised), and an unparseable
//      body all collapse to HealthUnavailable with every known service
//      unknown.
//   2. `state` is trusted only as the literal strings "up"/"down"; anything
//      else (including the literal string "unknown", a missing value, or a
//      wrong type) parses to ServiceHealthState.unknown, never `up`.
//   3. `/api/v1/health` is capauth-gated server-side; the client MUST
//      attach `buildOperatorAuthInterceptor`, not just a bare
//      X-Operator-Token, or every call 401s against a healthy server (the
//      "client-side trap" documented in skchat's own CLAUDE.md).
import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/health_service.dart";
import "package:skchat/services/operator_session_service.dart";

const _jsonHeaders = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter({this.status = 200, this.body = const {}, this.throwError});
  final int status;
  final Object body;
  final DioException? Function(RequestOptions options)? throwError;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final err = throwError?.call(options);
    if (err != null) throw err;
    return ResponseBody.fromString(jsonEncode(body), status, headers: _jsonHeaders);
  }
}

HealthService _service(HttpClientAdapter adapter, {DateTime Function()? now}) =>
    HealthService(
      dio: Dio()..httpClientAdapter = adapter,
      webuiBaseUrl: "https://h.test",
      now: now,
    );

void main() {
  group("a healthy 200 response", () {
    test("parses services with server-provided labels and states", () async {
      final adapter = _FixedAdapter(body: {
        "generated_at": "2026-08-16T12:00:00Z",
        "services": [
          {
            "id": "stt",
            "label": "Speech to text",
            "state": "up",
            "detail": "200 in 34ms",
            "latency_ms": 34,
            "checked_at": "2026-08-16T12:00:00Z",
          },
          {
            "id": "llm",
            "label": "Language model",
            "state": "down",
            "checked_at": "2026-08-16T11:59:00Z",
          },
        ],
      });

      final result = await _service(adapter).fetch();
      expect(result, isA<HealthAvailable>());
      final report = (result as HealthAvailable).report;
      expect(report.generatedAt, DateTime.parse("2026-08-16T12:00:00Z"));
      expect(report.services, hasLength(2));
      expect(report.services[0].id, "stt");
      expect(report.services[0].label, "Speech to text");
      expect(report.services[0].state, ServiceHealthState.up);
      expect(report.services[0].latencyMs, 34);
      expect(report.services[1].state, ServiceHealthState.down);
    });

    test('a state value that is not exactly "up" or "down" parses to '
        "unknown, never up", () async {
      final adapter = _FixedAdapter(body: {
        "generated_at": "2026-08-16T12:00:00Z",
        "services": [
          {"id": "sfu", "state": "UP", "checked_at": "2026-08-16T12:00:00Z"},
          {"id": "tts", "state": "healthy", "checked_at": "2026-08-16T12:00:00Z"},
          {"id": "webui", "checked_at": "2026-08-16T12:00:00Z"}, // missing state
        ],
      });

      final result = await _service(adapter).fetch();
      final report = (result as HealthAvailable).report;
      for (final s in report.services) {
        expect(s.state, ServiceHealthState.unknown, reason: s.id);
      }
    });

    test("a missing label falls back to the known-id default", () async {
      final adapter = _FixedAdapter(body: {
        "generated_at": "2026-08-16T12:00:00Z",
        "services": [
          {"id": "tts", "state": "up", "checked_at": "2026-08-16T12:00:00Z"},
        ],
      });
      final result = await _service(adapter).fetch();
      final report = (result as HealthAvailable).report;
      expect(report.services.single.label, "Text to speech");
    });
  });

  group("a 404 (endpoint not yet deployed)", () {
    test("is HealthUnavailable(notDeployed), never an error and never up",
        () async {
      final adapter = _FixedAdapter(
        status: 404,
        throwError: (options) => DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
          type: DioExceptionType.badResponse,
        ),
      );

      final result = await _service(adapter).fetch();
      expect(result, isA<HealthUnavailable>());
      expect(
        (result as HealthUnavailable).reason,
        HealthUnavailableReason.notDeployed,
      );
      // Every known id gets an unknown placeholder -- nothing is silently
      // dropped, and nothing renders green.
      expect(result.placeholderServices, hasLength(kKnownServiceIds.length));
      for (final s in result.placeholderServices) {
        expect(s.state, ServiceHealthState.unknown);
      }
    });
  });

  group("a 401 (not authorised)", () {
    test(
      "is HealthUnavailable(notAuthorized), distinct from unreachable and "
      "notDeployed, never up",
      () async {
        final adapter = _FixedAdapter(
          status: 401,
          throwError: (options) => DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 401),
            type: DioExceptionType.badResponse,
          ),
        );

        final result = await _service(adapter).fetch();
        expect(result, isA<HealthUnavailable>());
        expect(
          (result as HealthUnavailable).reason,
          HealthUnavailableReason.notAuthorized,
        );
        expect(result.reason, isNot(HealthUnavailableReason.unreachable));
        expect(result.reason, isNot(HealthUnavailableReason.notDeployed));
        for (final s in result.placeholderServices) {
          expect(s.state, ServiceHealthState.unknown);
        }
      },
    );
  });

  group("the client cannot reach the server at all", () {
    test("a connection timeout is HealthUnavailable(unreachable)", () async {
      final adapter = _FixedAdapter(
        throwError: (options) => DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        ),
      );

      final result = await _service(adapter).fetch();
      expect(result, isA<HealthUnavailable>());
      expect(
        (result as HealthUnavailable).reason,
        HealthUnavailableReason.unreachable,
      );
      for (final s in result.placeholderServices) {
        expect(s.state, ServiceHealthState.unknown);
      }
    });

    test("a bare non-Dio exception is also unreachable, not a crash",
        () async {
      final adapter = _FixedAdapter(
        throwError: (_) => null, // placeholder, overridden below
      );
      // A generic (non-DioException) throw, e.g. a bug in a custom
      // adapter -- fetch() must still return, never propagate.
      final throwingAdapter = _ThrowingAdapter();
      final result = await _service(throwingAdapter).fetch();
      expect(result, isA<HealthUnavailable>());
      expect(
        (result as HealthUnavailable).reason,
        HealthUnavailableReason.unreachable,
      );
      expect(adapter, isNotNull); // silence unused-var lint on the stub
    });
  });

  group("an unparseable 2xx body", () {
    test("a bare array instead of the documented object is unparseable",
        () async {
      final adapter = _FixedAdapter(body: {});
      // Force a top-level array by using a raw-string variant instead.
      final rawArrayAdapter = _RawBodyAdapter("[1,2,3]");
      final result = await _service(rawArrayAdapter).fetch();
      expect(result, isA<HealthUnavailable>());
      expect(
        (result as HealthUnavailable).reason,
        HealthUnavailableReason.unparseable,
      );
      expect(adapter, isNotNull);
    });

    test('a "services" field that is not a list is unparseable', () async {
      final adapter = _FixedAdapter(body: {
        "generated_at": "2026-08-16T12:00:00Z",
        "services": "not a list",
      });
      final result = await _service(adapter).fetch();
      expect(result, isA<HealthUnavailable>());
      expect(
        (result as HealthUnavailable).reason,
        HealthUnavailableReason.unparseable,
      );
    });
  });

  group("capauth data-plane credential", () {
    // The regression this pins (mirrors device_list_service_test.dart's own
    // "the request carries a session Bearer, not only the pasted token"):
    // `/api/v1/health` is capability-mapped server-side (CAP_STATUS), and
    // that gate reads ONLY `Authorization: Bearer <session>` /
    // `X-CapAuth-Token`, never `X-Operator-Token`. A HealthService built
    // without buildOperatorAuthInterceptor attached sends no Authorization
    // header at all, so this drew a 401 on every call against a perfectly
    // healthy server -- the screen looked completely dead. MUTATION TARGET:
    // removing the `buildOperatorAuthInterceptor` line from HealthService's
    // constructor turns this test red (no Authorization header is ever
    // attached).
    test("the request carries a session Bearer, not only a pasted token",
        () async {
      final recorder = _RecordingAdapter();
      final service = HealthService(
        dio: Dio()..httpClientAdapter = recorder,
        webuiBaseUrl: "https://h.test",
        sessionService: _sessionYielding(hs256: "SESSION-JWT"),
      );

      await service.fetch();

      final auth =
          (recorder.requests.last.headers["Authorization"] ?? "").toString();
      expect(
        auth,
        contains("SESSION-JWT"),
        reason: "the data-plane gate reads Authorization / X-CapAuth-Token "
            "only, never X-Operator-Token",
      );
    });
  });
}

/// Records every request and answers with a fixed empty-services 200 body --
/// this group only cares about the OUTGOING Authorization header, not the
/// parsed result.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({"generated_at": "2026-08-16T12:00:00Z", "services": <dynamic>[]}),
      200,
      headers: _jsonHeaders,
    );
  }
}

/// A session service whose handshake yields a fixed HS256 credential, lifted
/// from `device_list_service_test.dart`'s identical helper (which in turn
/// cites `operator_auth_interceptor_test.dart` as proof this shape drives a
/// real handshake).
OperatorSessionService _sessionYielding({required String hs256}) {
  final dio = Dio()
    ..httpClientAdapter = _SessionAdapter(
        {"session_token": hs256, "expires_at": 0, "issuer_policy": "hs256"}, "NONCE");
  return OperatorSessionService(
    dio: dio,
    baseUrl: "http://localhost:9384",
    identity: _FakeIdentity(),
    tokenReader: _MemSlot().read,
    tokenWriter: _MemSlot().write,
  );
}

class _MemSlot {
  static String? _v;
  String? read() => _v;
  void write(String? v) => _v = (v == null || v.isEmpty) ? null : v;
}

class _SessionAdapter implements HttpClientAdapter {
  _SessionAdapter(this.sessionBody, this.nonce);
  final Map<String, Object?> sessionBody;
  final String nonce;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? s,
    Future<void>? c,
  ) async {
    final body =
        o.uri.path.endsWith("/challenge") ? {"nonce": nonce, "exp": 0} : sessionBody;
    return ResponseBody.fromString(jsonEncode(body), 200, headers: _jsonHeaders);
  }
}

class _FakeIdentity implements GuestIdentity {
  bool _cached = false;
  @override
  Future<bool> hasCached() async => _cached;
  @override
  Future<GuestKeypair> ensure() async {
    _cached = true;
    return const GuestKeypair(
      publicKeyB64: "PUB-KEY-B64",
      fingerprint: "deadbeefdeadbeef",
    );
  }

  @override
  Future<String> sign(String data) async => "SIG";
  @override
  Future<void> clear() async => _cached = false;
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw StateError("boom");
  }
}

class _RawBodyAdapter implements HttpClientAdapter {
  _RawBodyAdapter(this.raw);
  final String raw;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(raw, 200, headers: _jsonHeaders);
  }
}
