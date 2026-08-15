// Tests for the dio diagnostic interceptor (lib/services/diag/diag_interceptor.dart).
//
// Card 270ea324 (Obs P1.5). Every acceptance criterion below needs a test
// that would FAIL without the corresponding behavior in
// `buildDiagInterceptor`/`classifyNetFailure`/`pathTemplate`. See the
// "mutation" comments; each names the exact behavior whose removal turns the
// paired test red.
import "dart:io";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/diag/diag_event.dart";
import "package:skchat/services/diag/diag_interceptor.dart";

/// Adapter whose `fetch` is scripted per call: throws or returns whatever
/// the queued script entry says. Lets a single test drive a multi-attempt
/// flow (e.g. an auth-style retry) deterministically.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._script);
  final List<Future<ResponseBody> Function(RequestOptions)> _script;
  int calls = 0;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? s,
    Future<void>? c,
  ) {
    requests.add(o);
    final step = _script[calls.clamp(0, _script.length - 1)];
    calls++;
    return step(o);
  }
}

Future<ResponseBody> _ok() async => ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Future<ResponseBody> _status(int code) async => ResponseBody.fromString(
      '{"ok":false}',
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Future<ResponseBody> _throwing(Object error) async => throw error;

Dio _dioWith(
  _ScriptedAdapter adapter,
  List<DiagEvent> sink, {
  bool withRetryingInterceptor = false,
}) {
  final dio = Dio(BaseOptions(baseUrl: "http://api.skworld.test:9384"))
    ..httpClientAdapter = adapter;
  if (withRetryingInterceptor) {
    // A minimal stand-in for buildOperatorAuthInterceptor's retry shape
    // (operator_auth_interceptor.dart onError, prefer-audience/hs256
    // branches): on the FIRST error for a request, replay it exactly once
    // via `options.copyWith(extra: {...options.extra, retried: true})` and
    // `dio().fetch(retryOptions)`, forwarding whatever that produces. This
    // is the exact "spread the extras map into a copy, re-fetch through
    // the full interceptor pipeline" pattern the diag interceptor's
    // dedupe guard has to survive; it is deliberately independent of the
    // real auth interceptor so this test does not depend on
    // OperatorSessionService plumbing.
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          final options = err.requestOptions;
          if (options.extra["retried"] == true) {
            return handler.next(err);
          }
          try {
            final retryOptions = options.copyWith(
              extra: {...options.extra, "retried": true},
            );
            final response = await dio.fetch(retryOptions);
            return handler.resolve(response);
          } catch (_) {
            return handler.next(err);
          }
        },
      ),
    );
  }
  dio.interceptors.add(buildDiagInterceptor(sink.add));
  return dio;
}

void main() {
  group("classifyNetFailure: parametrised per failure class", () {
    // AC1: "Each failure class maps to the correct kind enum, proven by a
    // parametrised test per class." Mutation: collapsing any two of these
    // cases onto the same NetFailureKind turns the matching case red.
    final cases = <String, NetFailureKind>{
      "dns": NetFailureKind.dns,
      "refused": NetFailureKind.refused,
      "connectTimeout": NetFailureKind.connectTimeout,
      "readTimeout": NetFailureKind.readTimeout,
      "tls": NetFailureKind.tls,
      "http4xx": NetFailureKind.http4xx,
      "http5xx": NetFailureKind.http5xx,
      "aborted (bonus, not in the required 7 but free)": NetFailureKind.aborted,
    };

    DioException build(String label, RequestOptions ro) {
      switch (label) {
        case "dns":
          return DioException(
            requestOptions: ro,
            error: const SocketException("Failed host lookup: 'dead.example'"),
          );
        case "refused":
          return DioException(
            requestOptions: ro,
            error: SocketException(
              "Connection refused",
              osError: const OSError("Connection refused", 111),
            ),
          );
        case "connectTimeout":
          return DioException(
            requestOptions: ro,
            type: DioExceptionType.connectionTimeout,
          );
        case "readTimeout":
          return DioException(
            requestOptions: ro,
            type: DioExceptionType.receiveTimeout,
          );
        case "tls":
          return DioException(
            requestOptions: ro,
            error: const HandshakeException(
              "Handshake error (OS Error: CERTIFICATE_VERIFY_FAILED)",
            ),
          );
        case "http4xx":
          return DioException(
            requestOptions: ro,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: ro, statusCode: 404),
          );
        case "http5xx":
          return DioException(
            requestOptions: ro,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: ro, statusCode: 503),
          );
        case "aborted (bonus, not in the required 7 but free)":
          return DioException(requestOptions: ro, type: DioExceptionType.cancel);
        default:
          throw StateError("no fixture for $label");
      }
    }

    for (final entry in cases.entries) {
      test("${entry.key} classifies as ${entry.value}", () {
        final ro = RequestOptions(path: "/api/v1/probe");
        final err = build(entry.key, ro);
        expect(classifyNetFailure(err), entry.value);
      });
    }

    test("sendTimeout classifies as connectTimeout (documented grouping, no "
        "distinct write-timeout bucket in the fixed enum)", () {
      final ro = RequestOptions(path: "/api/v1/probe");
      final err = DioException(requestOptions: ro, type: DioExceptionType.sendTimeout);
      expect(classifyNetFailure(err), NetFailureKind.connectTimeout);
    });

    test("an unrecognized connectionError payload classifies as unknown, "
        "never throws", () {
      final ro = RequestOptions(path: "/api/v1/probe");
      final err = DioException(
        requestOptions: ro,
        type: DioExceptionType.connectionError,
        error: Exception("some other transport error"),
      );
      expect(classifyNetFailure(err), NetFailureKind.unknown);
    });
  });

  group("pathTemplate: identifiers reduced, keywords kept", () {
    // AC3: "A concrete path with an id is reduced to its template so
    // identifiers do not leak, proven by test." Mutation: returning
    // uri.path unchanged (no reduction) turns every case here red.
    final cases = <String, String>{
      "/api/v1/messages/12345/read": "/api/v1/messages/:id/read",
      "/api/v1/devices/d4f3281efa92": "/api/v1/devices/:id",
      "/api/v1/groups/550e8400-e29b-41d4-a716-446655440000":
          "/api/v1/groups/:id",
      "/api/v1/health/deps": "/api/v1/health/deps",
      "/api/v1/auth/challenge": "/api/v1/auth/challenge",
    };

    for (final entry in cases.entries) {
      test("${entry.key} -> ${entry.value}", () {
        final uri = Uri.parse("http://api.skworld.test:9384${entry.key}");
        expect(pathTemplate(uri), entry.value);
      });
    }

    test("a query string never survives into the template", () {
      final uri = Uri.parse(
        "http://api.skworld.test:9384/api/v1/messages?token=SECRET&since=99",
      );
      final template = pathTemplate(uri);
      expect(template, "/api/v1/messages");
      expect(template.contains("SECRET"), isFalse);
      expect(template.contains("token"), isFalse);
    });
  });

  group("buildDiagInterceptor: emits net.request_failed", () {
    test("a failed request emits exactly one classified event", () async {
      final events = <DiagEvent>[];
      final adapter = _ScriptedAdapter([
        (o) => _throwing(
              DioException(
                requestOptions: o,
                type: DioExceptionType.connectionTimeout,
              ),
            ),
      ]);
      final dio = _dioWith(adapter, events);

      await expectLater(
        dio.get("/api/v1/messages/12345"),
        throwsA(isA<DioException>()),
      );

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.code, "net.request_failed");
      expect(event.fields["kind"], NetFailureKind.connectTimeout);
      expect(event.fields["host"], "api.skworld.test");
      expect(event.fields["port"], 9384);
      expect(event.fields["pathTemplate"], "/api/v1/messages/:id");
      expect(event.fields["method"], "GET");
      expect(event.fields["durationMs"], isA<int>());
      expect(event.fields.containsKey("status"), isFalse);
    });

    test("http4xx carries the status code", () async {
      final events = <DiagEvent>[];
      final adapter = _ScriptedAdapter([(o) => _status(404)]);
      final dio = _dioWith(adapter, events);

      await expectLater(
        dio.get("/api/v1/messages/1"),
        throwsA(isA<DioException>()),
      );

      expect(events.single.fields["kind"], NetFailureKind.http4xx);
      expect(events.single.fields["status"], 404);
    });

    test("a successful request emits nothing", () async {
      final events = <DiagEvent>[];
      final adapter = _ScriptedAdapter([(o) => _ok()]);
      final dio = _dioWith(adapter, events);

      final resp = await dio.get("/api/v1/messages");

      expect(resp.statusCode, 200);
      expect(events, isEmpty);
    });

    // AC2: "The event carries host, port, pathTemplate and method, and
    // NEVER query string, headers or body, proven by test." Mutation:
    // adding a 'query'/'headers'/'body' field (or recording the full path
    // instead of the template) to _recordFailure's fields map would either
    // fail catalog validation (event becomes null, this test goes red on
    // the null check) or, for the path case, turns the pathTemplate
    // assertion above red.
    test("never carries query string, headers or body even when the "
        "request had all three", () async {
      final events = <DiagEvent>[];
      final adapter = _ScriptedAdapter([
        (o) => _throwing(
              DioException(requestOptions: o, type: DioExceptionType.connectionTimeout),
            ),
      ]);
      final dio = _dioWith(adapter, events);

      // Canaries. Each is asserted ABSENT from the emitted event below, so they
      // are deliberately credential-shaped: a fixture that looks nothing like a
      // real header would not prove the interceptor drops a real one.
      const canaryAuth = "Bearer TOP-SECRET-HEADER"; // gitleaks:allow

      await expectLater(
        dio.post(
          "/api/v1/messages/12345",
          data: {"secret": "TOP-SECRET-BODY"},
          queryParameters: {"token": "TOP-SECRET-QUERY"},
          options: Options(headers: {"Authorization": canaryAuth}),
        ),
        throwsA(isA<DioException>()),
      );

      expect(events, hasLength(1));
      final fields = events.single.fields;
      expect(fields.keys, containsAll(["kind", "host", "port", "pathTemplate", "method", "durationMs"]));
      expect(fields.keys, isNot(contains("query")));
      expect(fields.keys, isNot(contains("headers")));
      expect(fields.keys, isNot(contains("body")));
      expect(fields.values.whereType<String>().any((v) => v.contains("SECRET")), isFalse);
      expect(fields["pathTemplate"], "/api/v1/messages/:id");
    });

    // AC4: "An exception inside the interceptor never fails the request it
    // is observing, proven by test." A throwing emit callback simulates a
    // diagnostics-layer bug; the underlying DioException must still surface
    // to the caller unchanged (not swallowed, not replaced).
    test("a throwing emit callback never blocks the original error from "
        "reaching the caller", () async {
      final adapter = _ScriptedAdapter([
        (o) => _throwing(
              DioException(requestOptions: o, type: DioExceptionType.connectionTimeout),
            ),
      ]);
      final dio = Dio(BaseOptions(baseUrl: "http://api.skworld.test:9384"))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        buildDiagInterceptor((_) => throw StateError("diagnostics bug")),
      );

      Object? caught;
      try {
        await dio.get("/api/v1/probe");
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioException>());
      expect((caught as DioException).type, DioExceptionType.connectionTimeout);
    });

    // AC5: "Exactly one event per failed request, no duplicates on retry
    // paths, proven by test." Mutation: dropping the `state.emitted` guard
    // (or the shared-reference extras plumbing it relies on) turns this
    // red with 2 events instead of 1.
    test("exactly one event when a request is retried once and both "
        "attempts fail", () async {
      final events = <DiagEvent>[];
      final adapter = _ScriptedAdapter([
        (o) => _throwing(
              DioException(requestOptions: o, type: DioExceptionType.connectionTimeout),
            ),
        (o) => _throwing(
              DioException(requestOptions: o, type: DioExceptionType.connectionTimeout),
            ),
      ]);
      final dio = _dioWith(adapter, events, withRetryingInterceptor: true);

      await expectLater(
        dio.get("/api/v1/messages/1"),
        throwsA(isA<DioException>()),
      );

      expect(adapter.calls, 2, reason: "original attempt + one retry");
      expect(events, hasLength(1));
    });

    test("no event at all when a request is retried once and the retry "
        "succeeds", () async {
      final events = <DiagEvent>[];
      final adapter = _ScriptedAdapter([
        (o) => _throwing(
              DioException(requestOptions: o, type: DioExceptionType.connectionTimeout),
            ),
        (o) => _ok(),
      ]);
      final dio = _dioWith(adapter, events, withRetryingInterceptor: true);

      final resp = await dio.get("/api/v1/messages/1");

      expect(resp.statusCode, 200);
      expect(adapter.calls, 2);
      expect(events, isEmpty);
    });
  });
}
