import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/operator_session_service.dart";
import "package:skchat/services/pq_prekey_service.dart";

/// Regression guard for the multi-device fanout blocker: the prekey Dio sent
/// EVERY call (publish, sign, peer-fetch, NACK) unauthenticated, so the daemon
/// dataplane gate 401'd the publish and NO device ever registered a pqdm2 slot.
/// The service must now attach the operator-session Bearer, exactly like the
/// SKComms data client. `fetchPeer` is the simplest wire call to assert on.
class _CannedAdapter implements HttpClientAdapter {
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
      jsonEncode({"prekeys": []}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class _FakeSessionService extends OperatorSessionService {
  _FakeSessionService() : super();

  final List<Object> script = ["TOKEN-1"];
  int ensureSessionCalls = 0;

  @override
  Future<String> ensureSession() async {
    ensureSessionCalls++;
    final next = script.length > 1 ? script.removeAt(0) : script.first;
    if (next is Exception) throw next;
    return next as String;
  }

  /// The interceptor now consumes the full credential bundle (hs256 path here).
  @override
  Future<OperatorCredentials> ensureCredentials() async =>
      OperatorCredentials(sessionToken: await ensureSession());

  @override
  void clearSession() {}
}

void main() {
  test("a prekey wire call carries Authorization: Bearer <session-token>",
      () async {
    final adapter = _CannedAdapter();
    final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
      ..httpClientAdapter = adapter;
    final session = _FakeSessionService();
    final svc = PqPrekeyService(
      storage: const FlutterSecureStorage(),
      baseUrl: "http://localhost:9384",
      deviceId: "dev-test",
      dio: dio,
      sessionService: session,
    );

    await svc.fetchPeer("chef");

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.path, "/api/v1/prekey/chef");
    expect(adapter.requests.single.headers["Authorization"], "Bearer TOKEN-1");
    expect(session.ensureSessionCalls, 1);
  });

  test("a null session service leaves the prekey call unauthenticated (ship dark)",
      () async {
    final adapter = _CannedAdapter();
    final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
      ..httpClientAdapter = adapter;
    final svc = PqPrekeyService(
      storage: const FlutterSecureStorage(),
      baseUrl: "http://localhost:9384",
      deviceId: "dev-test",
      dio: dio,
      // no sessionService: the interceptor is a no-op passthrough.
    );

    await svc.fetchPeer("chef");

    expect(adapter.requests, hasLength(1));
    expect(
      adapter.requests.single.headers.containsKey("Authorization"),
      isFalse,
    );
  });
}
