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

    // CRITICAL 1 regression: Dart's jsonEncode emits non-ASCII as literal
    // UTF-8 text, but the server canonicalizes with Python's
    // json.dumps(ensure_ascii=True), which escapes every non-ASCII character
    // to \uXXXX. Before the fix these two disagreed for any non-ASCII value,
    // so a device label with an accent, CJK, or emoji made enrollment fail
    // with an unrecoverable 401. Expected bytes verified against the real
    // server's _canon() (operator_auth_routes.py), see
    // app-fix-report.md for the full byte-comparison table.
    test(
      "escapes a BMP accent as lowercase \\uXXXX, matching Python's "
      "json.dumps(ensure_ascii=True)",
      () {
        final out = canonicalJson({"label": "Café (chef-laptop)"});
        expect(out, '{"label":"Caf\\u00e9 (chef-laptop)"}');
      },
    );

    test(
      "escapes CJK characters as lowercase \\uXXXX, matching Python's "
      "json.dumps(ensure_ascii=True)",
      () {
        final out = canonicalJson({"label": "Linux (中文主机)"});
        expect(out, '{"label":"Linux (\\u4e2d\\u6587\\u4e3b\\u673a)"}');
      },
    );

    test(
      "escapes an astral character (emoji) as a UTF-16 surrogate PAIR of "
      "\\uXXXX escapes, matching Python's json.dumps(ensure_ascii=True) "
      "(which also encodes through UTF-16, not UTF-32)",
      () {
        final out = canonicalJson({"label": "Linux 😀 box"});
        expect(out, '{"label":"Linux \\ud83d\\ude00 box"}');
      },
    );
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
        // No label passed: the body carries no "label" key at all, matching
        // the server's documented backwards-compatible path for a
        // label-less client.
        expect(body.containsKey("label"), isFalse);
      },
    );

    test(
      "with a label, signs the canonical {device_pubkey, label, nonce} "
      "payload, sorted keys and no whitespace, matching the server's "
      "json.dumps(sort_keys=True, separators=(\",\", \":\"))",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll("WINDOW-NONCE-2", label: "Chef's Laptop");

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","label":"Chef\'s Laptop",'
          '"nonce":"WINDOW-NONCE-2"}',
        );

        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["device_pubkey"], "PUB-KEY-B64");
        expect(body["window_nonce"], "WINDOW-NONCE-2");
        expect(body["label"], "Chef's Laptop");
        expect(body["sig"], isNotEmpty);
      },
    );

    test(
      "a label over 64 chars is trimmed+truncated before signing, matching "
      "the server's label.strip()[:64]",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };
        final longLabel = "  ${"x" * 80}  "; // 80 x's, padded with whitespace
        final truncated = "x" * 64;

        await svc.enroll("WINDOW-NONCE-3", label: longLabel);

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","label":"$truncated",'
          '"nonce":"WINDOW-NONCE-3"}',
        );
        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["label"], truncated);
        expect((body["label"] as String).length, 64);
      },
    );

    test(
      "a whitespace-only label is treated as absent, same as omitting it",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll("WINDOW-NONCE-4", label: "   ");

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","nonce":"WINDOW-NONCE-4"}',
        );
        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body.containsKey("label"), isFalse);
      },
    );

    // CRITICAL 1 regression: every OTHER enroll test in this group uses pure
    // ASCII, exactly the input set where the buggy (pre-fix) and correct
    // implementations agree. These pin the exact canonical bytes for
    // non-ASCII labels so a regression here is caught before it reaches a
    // live device (a real user hits this with an accented name, e.g. "José's
    // iPhone"). Expected bytes verified against the real server's _canon()
    // (operator_auth_routes.py), see app-fix-report.md for the full
    // byte-comparison table.
    test(
      "a label with a BMP accent is escaped as \\uXXXX before signing, "
      "matching the server's json.dumps(sort_keys=True, ensure_ascii=True)",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll("WINDOW-NONCE-ACCENT", label: "Café (chef-laptop)");

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","label":"Caf\\u00e9 (chef-laptop)",'
          '"nonce":"WINDOW-NONCE-ACCENT"}',
        );
        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["label"], "Café (chef-laptop)");
      },
    );

    test(
      "a label with an emoji is escaped as a UTF-16 surrogate pair before "
      "signing, matching the server's "
      "json.dumps(sort_keys=True, ensure_ascii=True)",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll("WINDOW-NONCE-EMOJI", label: "Linux 😀 box");

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","label":"Linux \\ud83d\\ude00 box",'
          '"nonce":"WINDOW-NONCE-EMOJI"}',
        );
        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["label"], "Linux 😀 box");
      },
    );

    // MINOR 4 regression: a plain substring(0, 64) slices UTF-16 code units,
    // not characters. An astral character (emoji) is two code units, so a
    // label whose 64th code unit lands mid-pair must back the cut off by one
    // rather than leave a lone high surrogate (which the server's device-list
    // JSONResponse cannot re-encode, 500ing the whole list).
    test(
      "a label whose 64-code-unit truncation boundary lands mid-surrogate-"
      "pair backs off by one instead of splitting the pair",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };
        // 63 ASCII 'x' + one emoji (2 UTF-16 code units) = 65 code units
        // total. A naive substring(0, 64) would keep only the emoji's high
        // surrogate.
        final label = "${"x" * 63}😀";
        expect(label.length, 65);
        final expectedTruncated = "x" * 63; // whole emoji dropped, not split

        await svc.enroll("WINDOW-NONCE-SURROGATE", label: label);

        expect(
          id.lastSigned,
          '{"device_pubkey":"PUB-KEY-B64","label":"$expectedTruncated",'
          '"nonce":"WINDOW-NONCE-SURROGATE"}',
        );
        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["label"], expectedTruncated);
        // No lone surrogate anywhere in the value actually sent.
        for (final unit in (body["label"] as String).codeUnits) {
          expect(unit < 0xD800 || unit > 0xDFFF, isTrue);
        }
      },
    );
  });

  // inc-c72a9120 part 3: the client signs whatever `capauth_challenge` the
  // server hands back (never re-derives it), and sends the signature as
  // `capauth_proof`. kFixtureChallengeText is the REAL example capauth
  // itself produced (see the incident card): pinned by value, not merely by
  // construction, so a refactor that silently changes the bytes (e.g.
  // signing the base64 text, or double-decoding) is caught.
  // kFixtureChallengeB64 is DERIVED from that pinned text (base64(utf8)),
  // rather than a separately hand-transcribed literal, so there is exactly
  // one source of truth for the fixture and no risk of the two silently
  // drifting apart (also avoids a raw high-entropy base64 blob in source,
  // which secret scanners like GitGuardian flag as "Generic High Entropy
  // Secret" -- it is test fixture data, not a credential, but there is no
  // reason to bait that heuristic when a derived value works identically).
  const kFixtureChallengeText =
      "capauth-pairing-enrollment-verified-v1:"
      "91DD32D8B3037750899BA284917FD5ED33829026:device:91dd32d8b3037750";
  final kFixtureChallengeB64 = base64Encode(utf8.encode(kFixtureChallengeText));

  group("enroll: capauth_proof (inc-c72a9120 part 3)", () {
    test(
      "signs the DECODED capauth_challenge bytes (not the base64 text) and "
      "sends the signature as capauth_proof",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll(
          "WINDOW-PROOF-1",
          capauthChallengeB64: kFixtureChallengeB64,
        );

        // MUTATION GUARD 2: signing the base64 STRING instead of the decoded
        // bytes would leave lastSigned equal to kFixtureChallengeB64, not
        // the decoded text below. Pinning the decoded literal by value (not
        // just "some non-null signature") catches that.
        expect(id.lastSigned, kFixtureChallengeText);

        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        // MUTATION GUARD 1: dropping capauth_proof from the request body
        // entirely reddens this (isNotEmpty on a missing key throws/fails).
        expect(body["capauth_proof"], isNotEmpty);
        expect(
          body["capauth_proof"],
          "SIG-${base64Encode(utf8.encode(kFixtureChallengeText))}",
        );
        // The unrelated `sig` (the pre-existing window-nonce signature) is
        // still present and untouched by any of this.
        expect(body["sig"], isNotEmpty);
      },
    );

    test(
      "a response with NO capauth_challenge still enrolls successfully, "
      "with no capauth_proof field sent",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        // No capauthChallengeB64 argument at all (mirrors openEnrollWindow's
        // response omitting the field on an older/degraded daemon).
        await svc.enroll("WINDOW-PROOF-2");

        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body.containsKey("capauth_proof"), isFalse);
        expect(body["window_nonce"], "WINDOW-PROOF-2");
        expect(body["sig"], isNotEmpty);
      },
    );

    test(
      "an empty-string capauth_challenge is treated the same as absent",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll("WINDOW-PROOF-3", capauthChallengeB64: "");

        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body.containsKey("capauth_proof"), isFalse);
      },
    );

    test(
      "a capauth_challenge that is not valid base64 does not block "
      "enrollment: enroll() completes with no capauth_proof sent",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        await svc.enroll(
          "WINDOW-PROOF-4",
          capauthChallengeB64: "not-valid-base64!!!",
        );

        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body.containsKey("capauth_proof"), isFalse);
        // The rest of the enrollment still went through normally.
        expect(body["window_nonce"], "WINDOW-PROOF-4");
      },
    );

    test(
      "valid base64 that decodes to non-UTF-8 bytes does not block "
      "enrollment: enroll() completes with no capauth_proof sent",
      () async {
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };
        // 0xFF 0xFE is not valid UTF-8.
        final badBytes = base64Encode([0xFF, 0xFE]);

        await svc.enroll("WINDOW-PROOF-5", capauthChallengeB64: badBytes);

        final req = adapter.requests.single;
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body.containsKey("capauth_proof"), isFalse);
      },
    );

    test(
      "full flow: openEnrollWindow's capauth_challenge flows unmodified "
      "into enroll()'s capauth_proof, and both requests carry the SAME "
      "device_pubkey byte-for-byte",
      () async {
        adapter.routes["/api/v1/auth/enroll/open"] = {
          "window_nonce": "WINDOW-PROOF-FULL",
          "exp": 999,
          "capauth_challenge": kFixtureChallengeB64,
        };
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };

        final window = await svc.openEnrollWindow();
        await svc.enroll(
          window["window_nonce"] as String,
          capauthChallengeB64: window["capauth_challenge"] as String?,
        );

        expect(adapter.requests, hasLength(2));
        final openReq = adapter.requests[0];
        final enrollReq = adapter.requests[1];
        final openBody = openReq.data is String
            ? jsonDecode(openReq.data as String) as Map
            : (openReq.data as Map);
        final enrollBody = enrollReq.data is String
            ? jsonDecode(enrollReq.data as String) as Map
            : (enrollReq.data as Map);

        // MUTATION GUARD 3: a re-encoded/trimmed/independently-re-derived
        // pubkey in either call would break this equality.
        expect(openBody["device_pubkey"], enrollBody["device_pubkey"]);
        expect(enrollBody["capauth_proof"], isNotEmpty);
        expect(id.lastSigned, kFixtureChallengeText);
      },
    );
  });

  group("openEnrollWindow", () {
    test(
      "posts this device's device_pubkey and returns the window_nonce + exp",
      () async {
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
        final body = req.data is String
            ? jsonDecode(req.data as String) as Map
            : (req.data as Map);
        expect(body["device_pubkey"], "PUB-KEY-B64");
      },
    );

    test(
      "passes capauth_challenge through in the response untouched when the "
      "server sends one",
      () async {
        // Derived, not a hand-transcribed base64 literal, for the same
        // reason as kFixtureChallengeB64 above (one source of truth, and no
        // raw base64 blob in source for a secret scanner to flag).
        final passthroughB64 = base64Encode(utf8.encode("not-a-secret-challenge-placeholder"));
        adapter.routes["/api/v1/auth/enroll/open"] = {
          "window_nonce": "WINDOW-10",
          "exp": 123456,
          "capauth_challenge": passthroughB64,
        };

        final res = await svc.openEnrollWindow();

        expect(res["capauth_challenge"], passthroughB64);
      },
    );

    test(
      "a server that omits capauth_challenge (older daemon) still returns "
      "the original two-key response with no error",
      () async {
        adapter.routes["/api/v1/auth/enroll/open"] = {
          "window_nonce": "WINDOW-11",
          "exp": 123456,
        };

        final res = await svc.openEnrollWindow();

        expect(res["window_nonce"], "WINDOW-11");
        expect(res.containsKey("capauth_challenge"), isFalse);
      },
    );
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

  group("enroll resets the negative cache (amber-fix)", () {
    test(
      "pre-enrollment handshake failures arm the negative cache, then a "
      "successful enroll() lets the very next ensureSession() retry instead "
      "of rethrowing the stale failure",
      () async {
        final clock = _MutableClock();
        final flow = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: id,
          tokenReader: store.read,
          tokenWriter: store.write,
          now: clock.call,
        );

        // Before enrollment: every gated request's ensureSession() call
        // fails (device not enrolled yet, the daemon 401s the handshake),
        // arming the negative cache.
        adapter.statusOverride["/api/v1/auth/challenge"] = 401;

        await expectLater(flow.ensureSession(), throwsA(anything));
        expect(adapter.requests, hasLength(1));

        // A second call still within the window short-circuits: the
        // negative cache is armed, proven by no NEW request reaching the
        // wire.
        await expectLater(flow.ensureSession(), throwsA(anything));
        expect(adapter.requests, hasLength(1));

        // The user pastes the operator token and taps "Link this device":
        // enroll() now succeeds (the device is enrolled server-side).
        adapter.statusOverride.remove("/api/v1/auth/challenge");
        adapter.routes["/api/v1/auth/enroll"] = {
          "device_fp": "deadbeefdeadbeef",
        };
        final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        adapter.routes["/api/v1/auth/challenge"] = {
          "nonce": "NONCE-AMBER",
          "exp": future,
        };
        final mintedJwt = _fakeJwt(future);
        adapter.routes["/api/v1/auth/session"] = {
          "session_token": mintedJwt,
          "expires_at": future,
        };

        await flow.enroll("WINDOW-NONCE-AMBER");

        // Still well within the original negative-cache window (no clock
        // advance), so without the fix this would rethrow the stale
        // pre-enrollment failure instead of running a fresh handshake.
        final token = await flow.ensureSession();
        expect(token, mintedJwt);
      },
    );
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

  // ── CR-3.4 PR4: operator-audience credential + issuer policy ──────────────
  group("ensureCredentials (CR-3.4 PR4)", () {
    test("carries the audience token + issuer_policy the server sends", () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final hs = _fakeJwt(future);
      adapter.routes["/api/v1/auth/challenge"] = {"nonce": "N", "exp": future};
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": hs,
        "expires_at": future,
        "audience_token": "AUD-WIRE-TOKEN",
        "audience_expires_at": "2026-08-08T00:00:00+00:00",
        "issuer_policy": "prefer-audience",
      };

      final creds = await svc.ensureCredentials();

      expect(creds.sessionToken, hs);
      expect(creds.audienceToken, "AUD-WIRE-TOKEN");
      expect(creds.issuerPolicy, "prefer-audience");
      // The legacy ensureSession() contract is unchanged: still the HS256 token.
      expect(await svc.ensureSession(), hs);
    });

    test(
      "defaults issuer_policy to hs256 and audienceToken null, and keeps the "
      "stored value a BARE JWT, when the server omits the new fields "
      "(byte-identical to the live hs256 path)",
      () async {
        final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        final hs = _fakeJwt(future);
        adapter.routes["/api/v1/auth/challenge"] = {"nonce": "N", "exp": future};
        adapter.routes["/api/v1/auth/session"] = {
          "session_token": hs,
          "expires_at": future,
        };

        final creds = await svc.ensureCredentials();

        expect(creds.sessionToken, hs);
        expect(creds.audienceToken, isNull);
        expect(creds.issuerPolicy, "hs256");
        // No envelope: the slot holds the raw JWT exactly as before this change.
        expect(store.value, hs);
      },
    );

    test(
      "persists the audience envelope so a reload restores the full bundle "
      "with no handshake",
      () async {
        final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        final hs = _fakeJwt(future);
        adapter.routes["/api/v1/auth/challenge"] = {"nonce": "N", "exp": future};
        adapter.routes["/api/v1/auth/session"] = {
          "session_token": hs,
          "expires_at": future,
          "audience_token": "AUD-WIRE",
          "audience_expires_at": "2026-08-08T00:00:00+00:00",
          "issuer_policy": "prefer-audience",
        };

        await svc.ensureCredentials();

        // A fresh service instance reading the SAME persisted slot (a page
        // reload / app relaunch) restores everything without a network call.
        final adapter2 = _CannedAdapter({});
        final dio2 = Dio()..httpClientAdapter = adapter2;
        final reloaded = OperatorSessionService(
          dio: dio2,
          baseUrl: "http://localhost:9384",
          identity: _FakeIdentity(),
          tokenReader: store.read,
          tokenWriter: store.write,
        );

        final creds = await reloaded.ensureCredentials();

        expect(creds.sessionToken, hs);
        expect(creds.audienceToken, "AUD-WIRE");
        expect(creds.issuerPolicy, "prefer-audience");
        expect(adapter2.requests, isEmpty);
      },
    );

    test("reads a legacy bare-JWT stored value as hs256 with no audience", () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      store.value = _fakeJwt(future); // pre-PR4 stored shape

      final creds = await svc.ensureCredentials();

      expect(creds.sessionToken, _fakeJwt(future));
      expect(creds.issuerPolicy, "hs256");
      expect(creds.audienceToken, isNull);
      expect(adapter.requests, isEmpty);
    });

    test("an unknown issuer_policy value is treated as hs256", () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final hs = _fakeJwt(future);
      adapter.routes["/api/v1/auth/challenge"] = {"nonce": "N", "exp": future};
      adapter.routes["/api/v1/auth/session"] = {
        "session_token": hs,
        "expires_at": future,
        "issuer_policy": "banana",
      };

      final creds = await svc.ensureCredentials();

      expect(creds.issuerPolicy, "hs256");
    });
  });

  group("audience fallback counter (CR-3.4 PR4)", () {
    test("starts at zero and increments on recordAudienceFallback", () {
      expect(svc.audienceFallbackCount, 0);
      svc.recordAudienceFallback();
      svc.recordAudienceFallback();
      expect(svc.audienceFallbackCount, 2);
    });
  });
}
