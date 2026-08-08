import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/operator_auth_interceptor.dart";
import "package:skchat/services/operator_session_service.dart";

/// A JWT-shaped string carrying `exp`, enough for the session service's
/// client-side cache-expiry check (it decodes the payload, never verifies the
/// signature). Mirrors the helper in operator_session_service_test.dart.
String _fakeJwt(int expUnixSeconds) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll("=", "");
  return "${seg({"alg": "none"})}.${seg({"exp": expUnixSeconds, "sub": "op"})}.SIG";
}

/// Deterministic identity, matching the session-service test's fake.
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

/// Canned adapter for the SESSION service's OWN dio: answers the
/// challenge/session handshake with whatever session body is supplied.
class _SessionAdapter implements HttpClientAdapter {
  _SessionAdapter(this.sessionBody, this.nonce);
  final Map<String, Object?> sessionBody;
  final String nonce;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<List<int>>? s,
      Future<void>? c) async {
    final body = o.uri.path.endsWith("/challenge")
        ? {"nonce": nonce, "exp": 0}
        : sessionBody;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// App-plane adapter for a gated route. It answers based on the presented
/// Bearer credential so a real 401/403-then-fallback flow can be exercised
/// end to end through the interceptor's retry.
class _GatedAdapter implements HttpClientAdapter {
  _GatedAdapter({
    required this.audienceToken,
    required this.hs256Token,
    this.audienceStatus = 403,
  });

  final String audienceToken;
  final String hs256Token;

  /// The status the AUDIENCE credential draws (200 = accepted, 401/403 =
  /// rejected -> the interceptor should fall back to HS256).
  final int audienceStatus;

  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<List<int>>? s,
      Future<void>? c) async {
    requests.add(o);
    final auth = o.headers["Authorization"];
    final int status;
    if (auth == "Bearer $audienceToken") {
      status = audienceStatus;
    } else if (auth == "Bearer $hs256Token") {
      status = 200;
    } else {
      status = 401; // no/unknown credential
    }
    return ResponseBody.fromString(
      jsonEncode({"ok": status == 200}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Build a session service whose handshake yields the given credential bundle.
OperatorSessionService _sessionYielding({
  required String hs256,
  String? audience,
  required String policy,
}) {
  final body = <String, Object?>{
    "session_token": hs256,
    "expires_at": 0,
    "audience_token": ?audience,
    "issuer_policy": policy,
  };
  final dio = Dio()..httpClientAdapter = _SessionAdapter(body, "NONCE");
  return OperatorSessionService(
    dio: dio,
    baseUrl: "http://localhost:9384",
    identity: _FakeIdentity(),
    // In-memory slot so each test is isolated.
    tokenReader: _MemSlot().read,
    tokenWriter: _MemSlot().write,
  );
}

class _MemSlot {
  static String? _v;
  String? read() => _v;
  void write(String? v) => _v = (v == null || v.isEmpty) ? null : v;
}

Dio _appDioWith(OperatorSessionService session, _GatedAdapter gated) {
  final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
    ..httpClientAdapter = gated;
  dio.interceptors.add(buildOperatorAuthInterceptor(session, () => dio));
  return dio;
}

void main() {
  final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;

  setUp(() => _MemSlot._v = null);

  group("hs256 policy (unchanged, live default)", () {
    test("attaches the HS256 session and never touches the audience path",
        () async {
      final hs = _fakeJwt(future);
      final session = _sessionYielding(hs256: hs, policy: "hs256");
      final gated = _GatedAdapter(audienceToken: "AUD", hs256Token: hs);
      final dio = _appDioWith(session, gated);

      final resp = await dio.get("/api/v1/messages");

      expect(resp.statusCode, 200);
      expect(gated.requests, hasLength(1));
      expect(gated.requests.single.headers["Authorization"], "Bearer $hs");
      expect(session.audienceFallbackCount, 0);
    });
  });

  group("prefer-audience policy", () {
    test("attaches the audience token when the server accepts it (no fallback)",
        () async {
      final hs = _fakeJwt(future);
      final session =
          _sessionYielding(hs256: hs, audience: "AUD", policy: "prefer-audience");
      final gated = _GatedAdapter(
        audienceToken: "AUD",
        hs256Token: hs,
        audienceStatus: 200,
      );
      final dio = _appDioWith(session, gated);

      final resp = await dio.get("/api/v1/messages");

      expect(resp.statusCode, 200);
      expect(gated.requests, hasLength(1));
      expect(gated.requests.single.headers["Authorization"], "Bearer AUD");
      expect(session.audienceFallbackCount, 0);
    });

    test("falls back to HS256 ONCE on a 403 and counts the fallback", () async {
      final hs = _fakeJwt(future);
      final session =
          _sessionYielding(hs256: hs, audience: "AUD", policy: "prefer-audience");
      final gated = _GatedAdapter(
        audienceToken: "AUD",
        hs256Token: hs,
        audienceStatus: 403,
      );
      final dio = _appDioWith(session, gated);

      final resp = await dio.get("/api/v1/messages");

      expect(resp.statusCode, 200);
      // First attempt: audience (403). Retry: HS256 (200).
      expect(gated.requests, hasLength(2));
      expect(gated.requests[0].headers["Authorization"], "Bearer AUD");
      expect(gated.requests[1].headers["Authorization"], "Bearer $hs");
      expect(session.audienceFallbackCount, 1);
    });

    test("also falls back on a 401", () async {
      final hs = _fakeJwt(future);
      final session =
          _sessionYielding(hs256: hs, audience: "AUD", policy: "prefer-audience");
      final gated = _GatedAdapter(
        audienceToken: "AUD",
        hs256Token: hs,
        audienceStatus: 401,
      );
      final dio = _appDioWith(session, gated);

      final resp = await dio.get("/api/v1/messages");

      expect(resp.statusCode, 200);
      expect(gated.requests, hasLength(2));
      expect(session.audienceFallbackCount, 1);
    });

    test(
        "when the server sends prefer-audience but no audience token, attaches "
        "HS256 (nothing to prefer, no fallback)", () async {
      final hs = _fakeJwt(future);
      final session = _sessionYielding(hs256: hs, policy: "prefer-audience");
      final gated = _GatedAdapter(audienceToken: "AUD", hs256Token: hs);
      final dio = _appDioWith(session, gated);

      final resp = await dio.get("/api/v1/messages");

      expect(resp.statusCode, 200);
      expect(gated.requests, hasLength(1));
      expect(gated.requests.single.headers["Authorization"], "Bearer $hs");
      expect(session.audienceFallbackCount, 0);
    });
  });

  group("auth handshake paths are exempt", () {
    test("does not attach a credential to /api/v1/auth/* requests", () async {
      final hs = _fakeJwt(future);
      final session =
          _sessionYielding(hs256: hs, audience: "AUD", policy: "prefer-audience");
      // The gated adapter returns 200 only for a recognized Bearer; for the
      // exempt path we expect NO Authorization header, so force a plain 200.
      final gated = _GatedAdapter(audienceToken: "AUD", hs256Token: hs);
      final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = gated;
      dio.interceptors.add(buildOperatorAuthInterceptor(session, () => dio));

      // A 401 is fine; the assertion is that no credential was attached and no
      // recursion/fallback happened on the handshake path itself.
      await dio.get("/api/v1/auth/challenge").catchError((_) => Response(
            requestOptions: RequestOptions(path: "/api/v1/auth/challenge"),
          ));

      expect(
        gated.requests.every((r) => !r.headers.containsKey("Authorization")),
        isTrue,
      );
      expect(session.audienceFallbackCount, 0);
    });
  });
}
