import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/operator_session_service.dart";
import "package:skchat/services/operator_token.dart" as op_token;

/// Canned-response adapter keyed by path; records every request for
/// assertions. Mirrors the project's existing service-test mocking style
/// (see consent_service_test.dart / guest_group_service_test.dart).
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  final List<RequestOptions> requests = [];

  /// Per-path forced HTTP status (Fix 2 tests): a non-2xx here makes Dio
  /// throw a [DioException] for that path, simulating a failed handshake
  /// leg (e.g. the daemon unreachable / rejecting the challenge).
  final Map<String, int> statusOverride = {};

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
    final status =
        statusOverride[path] ?? statusOverride[options.uri.path] ?? 200;
    final body = routes[path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
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

/// Mutable, test-controlled clock injected via [OperatorSessionService]'s
/// `now` constructor param, so the negative-cache window (Fix 2) can be
/// exercised deterministically (advance past 30s) without a real sleep.
class _MutableClock {
  DateTime current = DateTime.now();
  DateTime call() => current;
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

    test(
      "does not rely on Dart's insertion order for a differently-ordered map",
      () {
        final out = canonicalJson({
          "device_pubkey": "pub1",
          "nonce": "windownonce",
        });
        expect(out, '{"device_pubkey":"pub1","nonce":"windownonce"}');
      },
    );

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
    test("runs the challenge-response and returns the minted token", () async {
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
      expect(
        id.lastSigned,
        '{"device_fp":"deadbeefdeadbeef","nonce":"NONCE-1"}',
      );

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

    test(
      "returns the cached token without an HTTP call when unexpired",
      () async {
        final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        final primed = _fakeJwt(future);
        store.value = primed;

        final token = await svc.ensureSession();

        expect(token, primed);
        expect(adapter.requests, isEmpty);
        expect(id.lastSigned, isNull);
      },
    );

    test("ignores an expired cached token and re-runs the handshake", () async {
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
    test(
      "signs the canonical {device_pubkey, nonce} payload and posts it",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll("WINDOW-NONCE-1");

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","nonce":"WINDOW-NONCE-1"}',
        );

        final req = adapter.requests.single;
        expect(req.method, "POST");
        expect(req.uri.path, "/api/v1/auth/enroll");
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["device_pubkey"], "PUB-KEY-B64");
        expect(body["window_nonce"], "WINDOW-NONCE-1");
        expect(body["sig"], isNotEmpty);
      },
    );
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

  group(
    "operator token header on enroll/open (Fix A: funnel-bypass close)",
    () {
      test("defaults the operator-token read seam to the shared "
          "operator_token.dart module (the manually-pasted secret), NOT the "
          "dedicated session-token store above", () {
        final freshSvc = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: id,
        );

        expect(freshSvc.debugOperatorTokenReader, same(op_token.operatorToken));
      });

      test("sends X-Operator-Token when a token is stored", () async {
        adapter.routes["/api/v1/auth/enroll/open"] = {
          "window_nonce": "WIN-TOK",
          "exp": 999,
        };
        final tokenSvc = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: id,
          tokenReader: store.read,
          tokenWriter: store.write,
          operatorTokenReader: () => "SHARED-OPERATOR-SECRET",
        );

        await tokenSvc.openEnrollWindow();

        final req = adapter.requests.single;
        expect(req.uri.path, "/api/v1/auth/enroll/open");
        expect(req.headers["X-Operator-Token"], "SHARED-OPERATOR-SECRET");
      });

      test("omits X-Operator-Token when no token is stored", () async {
        adapter.routes["/api/v1/auth/enroll/open"] = {
          "window_nonce": "WIN-NOTOK",
          "exp": 999,
        };
        final tokenSvc = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: id,
          tokenReader: store.read,
          tokenWriter: store.write,
          operatorTokenReader: () => null,
        );

        await tokenSvc.openEnrollWindow();

        final req = adapter.requests.single;
        expect(req.headers.containsKey("X-Operator-Token"), isFalse);
      });

      test("omits X-Operator-Token when the stored token is empty", () async {
        adapter.routes["/api/v1/auth/enroll/open"] = {
          "window_nonce": "WIN-EMPTY",
          "exp": 999,
        };
        final tokenSvc = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: id,
          tokenReader: store.read,
          tokenWriter: store.write,
          operatorTokenReader: () => "",
        );

        await tokenSvc.openEnrollWindow();

        final req = adapter.requests.single;
        expect(req.headers.containsKey("X-Operator-Token"), isFalse);
      });
    },
  );

  group("storage isolation (Fix 1: dedicated session storage key)", () {
    test("does not default to the shared operator_token seam", () {
      // Constructed WITHOUT tokenReader/tokenWriter, so this exercises the
      // real default wiring. The manual/pasted SKCHAT_GUEST_OPERATOR_TOKEN
      // slot (operator_token.dart) is a DIFFERENT credential; the service
      // must not be wired to it by default (that was the Fix 1 bug: a
      // successful handshake would overwrite the pasted token, and
      // clearSession() would wipe it on a 401).
      final freshSvc = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: id,
      );

      expect(freshSvc.debugTokenReader, isNot(same(op_token.operatorToken)));
      expect(freshSvc.debugTokenWriter, isNot(same(op_token.setOperatorToken)));
    });

    test("a successful handshake does not clobber a primed operator_token "
        "value, and clearSession() leaves it untouched", () async {
      // Prime the UNRELATED manual-token slot with a non-JWT raw secret, the
      // shape of a pasted SKCHAT_GUEST_OPERATOR_TOKEN, NOT a minted session
      // JWT. (Under `flutter test`'s VM target operator_token.dart's real
      // storage is a no-op stub, so this value never actually persists here;
      // the meaningful, environment-independent regression guard is the
      // "does not default to the shared seam" test above. This test still
      // documents + locks in the intended behavior end-to-end.)
      op_token.setOperatorToken("RAW-PASTED-OPERATOR-SECRET");
      final before = op_token.operatorToken();

      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final mintedJwt = _fakeJwt(future);
      adapter.routes["/api/v1/auth/challenge"] = {
        "nonce": "NONCE-ISO",
        "exp": future,
      };
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": mintedJwt,
        "expires_at": future,
      };

      final token = await svc.ensureSession();

      expect(token, mintedJwt);
      // The service's OWN dedicated slot (the injected fake) got the minted
      // token.
      expect(store.value, mintedJwt);
      // The unrelated operator_token slot is untouched.
      expect(op_token.operatorToken(), before);

      svc.clearSession();

      expect(store.value, isNull);
      // clearSession() must not touch the unrelated slot either.
      expect(op_token.operatorToken(), before);
    });
  });

  group("negative caching (Fix 2)", () {
    test("two rapid failing calls trigger only ONE challenge round-trip "
        "within the negative-cache window", () async {
      final clock = _MutableClock();
      final failSvc = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: id,
        tokenReader: store.read,
        tokenWriter: store.write,
        now: clock.call,
      );
      adapter.statusOverride["/api/v1/auth/challenge"] = 500;

      await expectLater(failSvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(1));

      // A second call still within the window must NOT re-hit the wire.
      await expectLater(failSvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(1));

      // Advance the clock past the negative-cache window: the next call
      // retries the handshake.
      clock.current = clock.current.add(const Duration(seconds: 31));
      await expectLater(failSvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(2));
    });

    test("a successful call resets the negative cache", () async {
      final clock = _MutableClock();
      final flakySvc = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: id,
        tokenReader: store.read,
        tokenWriter: store.write,
        now: clock.call,
      );
      adapter.statusOverride["/api/v1/auth/challenge"] = 500;

      await expectLater(flakySvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(1));

      // Still within the window: no retry yet.
      await expectLater(flakySvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(1));

      // Fix the daemon and advance past the window: succeeds and clears the
      // negative cache.
      adapter.statusOverride.remove("/api/v1/auth/challenge");
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      adapter.routes["/api/v1/auth/challenge"] = {
        "nonce": "NONCE-RESET",
        "exp": future,
      };
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": _fakeJwt(future),
        "expires_at": future,
      };
      clock.current = clock.current.add(const Duration(seconds: 31));

      final token = await flakySvc.ensureSession();
      expect(token, _fakeJwt(future));
      expect(adapter.requests, hasLength(3));

      // A subsequent failure right away must hit the wire again (negative
      // cache was reset by the success above, not still armed).
      store.value = null;
      adapter.statusOverride["/api/v1/auth/challenge"] = 500;
      await expectLater(flakySvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(4));
    });

    test("clearSession() resets the negative cache", () async {
      final clock = _MutableClock();
      final failSvc = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: id,
        tokenReader: store.read,
        tokenWriter: store.write,
        now: clock.call,
      );
      adapter.statusOverride["/api/v1/auth/challenge"] = 500;

      await expectLater(failSvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(1));

      failSvc.clearSession();

      // Immediately retries (no window wait needed) because clearSession()
      // dropped the negative cache.
      await expectLater(failSvc.ensureSession(), throwsA(anything));
      expect(adapter.requests, hasLength(2));
    });
  });

  group("in-flight coalescing (Fix 2)", () {
    test("two concurrent calls share one in-flight handshake (one round-trip, "
        "both get the result)", () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final mintedJwt = _fakeJwt(future);
      adapter.routes["/api/v1/auth/challenge"] = {
        "nonce": "NONCE-CONC",
        "exp": future,
      };
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": mintedJwt,
        "expires_at": future,
      };

      final f1 = svc.ensureSession();
      final f2 = svc.ensureSession();
      final results = await Future.wait([f1, f2]);

      expect(results[0], mintedJwt);
      expect(results[1], mintedJwt);
      // Exactly ONE challenge + ONE session request reached the wire, not
      // two of each.
      expect(adapter.requests, hasLength(2));
    });
  });

  group("missing required field handling (Fix 4)", () {
    test("throws when the challenge response is missing 'nonce'", () async {
      adapter.routes["/api/v1/auth/challenge"] = {"exp": 12345};

      await expectLater(svc.ensureSession(), throwsA(isA<StateError>()));
      expect(store.value, isNull);
    });

    test(
      "throws when the session response is missing 'session_token'",
      () async {
        adapter.routes["/api/v1/auth/challenge"] = {"nonce": "N1"};
        adapter.routes["/api/v1/auth/session"] = {"expires_at": 12345};

        await expectLater(svc.ensureSession(), throwsA(isA<StateError>()));
        expect(store.value, isNull);
      },
    );
  });
}
