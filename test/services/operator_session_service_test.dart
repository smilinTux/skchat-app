import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/operator_session_service.dart";

/// Canned-response adapter keyed by path; records every request for
/// assertions. Mirrors the project's existing service-test mocking style
/// (see consent_service_test.dart / guest_group_service_test.dart).
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
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
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Deterministic in-test identity: a fixed public key/fingerprint + recorded
/// signing, matching the `_FakeIdentity` pattern used by
/// guest_group_service_test.dart.
class _FakeIdentity implements GuestIdentity {
  bool _cached = false;
  String? lastSigned;

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
  Future<String> sign(String data) async {
    lastSigned = data;
    return "SIG-${base64Encode(utf8.encode(data))}";
  }

  @override
  Future<void> clear() async {
    _cached = false;
  }
}

/// In-memory stand-in for the `operator_token` seam, injected via the
/// service's token-store constructor params so tests can prime/observe it
/// without depending on the real localStorage/secure-storage platform
/// implementation (which is a web-only no-op stub under `flutter test`'s VM
/// target).
class _FakeTokenStore {
  String? value;
  String? read() => value;
  void write(String? v) => value = v;
}

/// Builds a JWT-shaped string (`header.payload.sig`) whose payload carries
/// `exp`, matching what a real session JWT looks like closely enough for
/// [OperatorSessionService]'s cache-expiry check (it decodes the JWT payload,
/// it does not verify the signature client-side).
String _fakeJwt(int expUnixSeconds) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll("=", "");
  final header = seg({"alg": "none", "typ": "JWT"});
  final payload = seg({"exp": expUnixSeconds, "sub": "operator"});
  return "$header.$payload.SIGNATURE";
}

void main() {
  late _CannedAdapter adapter;
  late Dio dio;
  late _FakeIdentity id;
  late _FakeTokenStore store;
  late OperatorSessionService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    id = _FakeIdentity();
    store = _FakeTokenStore();
    svc = OperatorSessionService(
      dio: dio,
      baseUrl: "http://localhost:9384",
      identity: id,
      tokenReader: store.read,
      tokenWriter: store.write,
    );
  });

  group("canonicalJson", () {
    test("sorts keys and compacts with no whitespace", () {
      final out = canonicalJson({"nonce": "n1", "device_fp": "fp1"});
      expect(out, '{"device_fp":"fp1","nonce":"n1"}');
    });

    test("does not rely on Dart's insertion order for a differently-ordered map",
        () {
      final out =
          canonicalJson({"device_pubkey": "pub1", "nonce": "windownonce"});
      expect(out, '{"device_pubkey":"pub1","nonce":"windownonce"}');
    });

    test("recursively sorts nested maps and preserves list order", () {
      final out = canonicalJson({
        "z": 1,
        "a": {"y": 2, "b": 3},
        "list": [3, 1, 2],
      });
      expect(out, '{"a":{"b":3,"y":2},"list":[3,1,2],"z":1}');
    });
  });

  group("ensureSession", () {
    test("runs the challenge-response and returns the minted token",
        () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final mintedJwt = _fakeJwt(future);
      adapter.routes["/api/v1/auth/challenge"] = {
        "nonce": "NONCE-1",
        "exp": future,
      };
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": mintedJwt,
        "expires_at": future,
      };

      final token = await svc.ensureSession();

      expect(token, mintedJwt);

      // Two calls: GET challenge, then POST session.
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].method, "GET");
      expect(adapter.requests[0].uri.path, "/api/v1/auth/challenge");
      expect(adapter.requests[1].method, "POST");
      expect(adapter.requests[1].uri.path, "/api/v1/auth/session");

      // The signed payload is the CANONICAL {device_fp, nonce}, sorted keys,
      // matching the server's json.dumps(sort_keys=True, separators=(",",":")).
      expect(id.lastSigned, '{"device_fp":"deadbeefdeadbeef","nonce":"NONCE-1"}');

      // The POST body carries device_fp, nonce, sig.
      final sentBody = adapter.requests[1].data;
      final decoded = sentBody is String
          ? jsonDecode(sentBody) as Map
          : (sentBody as Map);
      expect(decoded["device_fp"], "deadbeefdeadbeef");
      expect(decoded["nonce"], "NONCE-1");
      expect(decoded["sig"], isNotEmpty);

      // Cached in the token-store seam so it survives reloads.
      expect(store.value, token);
    });

    test("returns the cached token without an HTTP call when unexpired",
        () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final primed = _fakeJwt(future);
      store.value = primed;

      final token = await svc.ensureSession();

      expect(token, primed);
      expect(adapter.requests, isEmpty);
      expect(id.lastSigned, isNull);
    });

    test("ignores an expired cached token and re-runs the handshake",
        () async {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
      store.value = _fakeJwt(past);

      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      adapter.routes["/api/v1/auth/challenge"] = {
        "nonce": "NONCE-2",
        "exp": future,
      };
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": _fakeJwt(future),
        "expires_at": future,
      };

      final token = await svc.ensureSession();
      expect(token, _fakeJwt(future));
      expect(adapter.requests, hasLength(2));
    });
  });

  group("enroll", () {
    test("signs the canonical {device_pubkey, nonce} payload and posts it",
        () async {
      adapter.routes["/api/v1/auth/enroll"] = {
        "device_fp": "deadbeefdeadbeef",
      };

      await svc.enroll("WINDOW-NONCE-1");

      expect(id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","nonce":"WINDOW-NONCE-1"}');

      final req = adapter.requests.single;
      expect(req.method, "POST");
      expect(req.uri.path, "/api/v1/auth/enroll");
      final body = req.data is String
          ? jsonDecode(req.data as String) as Map
          : (req.data as Map);
      expect(body["device_pubkey"], "PUB-KEY-B64");
      expect(body["window_nonce"], "WINDOW-NONCE-1");
      expect(body["sig"], isNotEmpty);
    });
  });

  group("openEnrollWindow", () {
    test("posts (no body) and returns the window_nonce + exp", () async {
      adapter.routes["/api/v1/auth/enroll/open"] = {
        "window_nonce": "WINDOW-9",
        "exp": 123456,
      };

      final res = await svc.openEnrollWindow();

      expect(res["window_nonce"], "WINDOW-9");
      expect(res["exp"], 123456);
      final req = adapter.requests.single;
      expect(req.method, "POST");
      expect(req.uri.path, "/api/v1/auth/enroll/open");
    });
  });
}
