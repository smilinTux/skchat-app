// Tests for lib/services/health_service.dart -- the client for
// GET /api/v1/health and the honesty contract every branch of
// HealthService.fetch() upholds (see that file's header):
//   1. Never show green the client did not verify: a network failure, a
//      404 (not-yet-deployed), and an unparseable body all collapse to
//      HealthUnavailable with every known service unknown.
//   2. `state` is trusted only as the literal strings "up"/"down"; anything
//      else (including the literal string "unknown", a missing value, or a
//      wrong type) parses to ServiceHealthState.unknown, never `up`.
import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/health_service.dart";

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
