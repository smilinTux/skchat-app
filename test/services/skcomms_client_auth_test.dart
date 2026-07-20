import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/operator_session_service.dart";
import "package:skchat/services/skcomms_client.dart";

/// Canned-response adapter keyed by path; records every request for
/// assertions and supports a per-path scripted 401. Mirrors the project's
/// existing service-test mocking style (see operator_session_service_test.dart
/// / consent_service_test.dart).
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  final List<RequestOptions> requests = [];

  /// Paths that should return 401 on their NEXT hit (a set so a path can be
  /// scripted to fail once then succeed on the retry, mimicking a real
  /// expired-session response followed by a fresh one after re-auth).
  final Set<String> failOnceWith401 = {};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.path;
    if (failOnceWith401.remove(path)) {
      return ResponseBody.fromString(
        jsonEncode({"error": "unauthorized"}),
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final body = routes[path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Test double standing in for [OperatorSessionService]: overrides the two
/// methods the SKCommsClient interceptor calls so tests can control success,
/// failure, and observe call counts without driving the real
/// challenge-response handshake over HTTP.
class _FakeSessionService extends OperatorSessionService {
  _FakeSessionService() : super();

  /// Queue of results: each call to [ensureSession] pops the next entry.
  /// A `String` resolves with that token; an `Exception` throws it. When the
  /// queue is empty, the LAST scripted behavior repeats.
  final List<Object> script = ["TOKEN-1"];
  int ensureSessionCalls = 0;
  int clearSessionCalls = 0;

  @override
  Future<String> ensureSession() async {
    ensureSessionCalls++;
    final next = script.length > 1 ? script.removeAt(0) : script.first;
    if (next is Exception) throw next;
    return next as String;
  }

  @override
  void clearSession() {
    clearSessionCalls++;
  }
}

void main() {
  late _CannedAdapter adapter;
  late Dio dio;
  late _FakeSessionService session;
  late SKCommsClient client;

  setUp(() {
    adapter = _CannedAdapter({
      "/api/v1/status": {"ok": true},
      "/api/v1/auth/challenge": {"nonce": "N"},
    });
    dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
      ..httpClientAdapter = adapter;
    session = _FakeSessionService();
    client = SKCommsClient(dio: dio, sessionService: session);
  });

  group("request interceptor: attaches session", () {
    test("a normal /api/v1 request carries Authorization: Bearer <token>",
        () async {
      await client.getStatus();

      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers["Authorization"],
        "Bearer TOKEN-1",
      );
      expect(session.ensureSessionCalls, 1);
    });

    test("ensureSession failure does not block the request (ship dark)",
        () async {
      session.script
        ..clear()
        ..add(Exception("not enrolled yet"));

      // Must not throw, and must still hit the daemon.
      final result = await client.getStatus();

      expect(result, {"ok": true});
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers.containsKey("Authorization"),
        isFalse,
      );
    });

    test(
        "an auth-handshake path does not get a Bearer attached and does not "
        "call ensureSession",
        () async {
      final resp = await dio.get("/api/v1/auth/challenge");

      expect(resp.statusCode, 200);
      expect(
        adapter.requests.single.headers.containsKey("Authorization"),
        isFalse,
      );
      expect(session.ensureSessionCalls, 0);
    });

    test(
        "a path merely CONTAINING the /api/v1/auth/ marker (not as a "
        "prefix) IS treated as a normal gated request, not a handshake path",
        () async {
      // Anchored check (Fix 3): `_isAuthHandshakePath` must use `startsWith`,
      // not `contains`, so a path where the marker appears mid-string (e.g.
      // proxied/nested) is NOT mistaken for the handshake itself, which would
      // wrongly skip attaching the Bearer header.
      adapter.routes["/proxy/api/v1/auth/inner"] = {"ok": true};

      final resp = await dio.get("/proxy/api/v1/auth/inner");

      expect(resp.statusCode, 200);
      expect(
        adapter.requests.single.headers["Authorization"],
        "Bearer TOKEN-1",
      );
      expect(session.ensureSessionCalls, 1);
    });
  });

  group("error interceptor: 401 triggers one re-auth + retry", () {
    test("a single 401 clears the session, re-auths once, and retries once",
        () async {
      session.script
        ..clear()
        ..addAll(["STALE-TOKEN", "FRESH-TOKEN"]);
      adapter.failOnceWith401.add("/api/v1/status");

      final result = await client.getStatus();

      expect(result, {"ok": true});
      // 1st attempt (401) + 1 retry = 2 requests hit the wire.
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].headers["Authorization"], "Bearer STALE-TOKEN");
      expect(adapter.requests[1].headers["Authorization"], "Bearer FRESH-TOKEN");
      expect(session.clearSessionCalls, 1);
      // 1 for the original request + 1 for the re-auth (the retry's own
      // onRequest attach reuses whatever ensureSession returns at that point).
      expect(session.ensureSessionCalls, greaterThanOrEqualTo(2));
    });

    test("does not loop: a 401 on the retry itself is passed through once",
        () async {
      // Both the original AND the retried request come back 401, so the
      // retry-guard (not a second re-auth loop) must be what stops it.
      final alwaysFailAdapter = _AlwaysUnauthorizedAdapter();
      final loopDio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = alwaysFailAdapter;
      final loopSession = _FakeSessionService()
        ..script.clear()
        ..script.addAll(["STALE-TOKEN", "FRESH-TOKEN"]);
      final loopClient =
          SKCommsClient(dio: loopDio, sessionService: loopSession);

      await expectLater(
        loopClient.getStatus(),
        throwsA(isA<DioException>()),
      );

      // Exactly 2 requests reach the wire: the original + exactly ONE retry.
      // A third would mean the retry-guard failed and it started looping.
      expect(alwaysFailAdapter.hitCount, 2);
      expect(loopSession.clearSessionCalls, 1);
    });
  });
}

class _AlwaysUnauthorizedAdapter implements HttpClientAdapter {
  int hitCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hitCount++;
    return ResponseBody.fromString(
      jsonEncode({"error": "unauthorized"}),
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}
