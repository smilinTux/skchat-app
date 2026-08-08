import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_group_service.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/operator_session_service.dart";

class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);
  final Map<String, Object?> routes;
  RequestOptions? last;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    last = options;
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}


/// dio hands the adapter the raw request body (a Map when posting JSON), so
/// normalise to a Map for assertions whether it arrives as a Map or a String.
Map<String, dynamic> _decode(Object? data) {
  if (data is String) return jsonDecode(data) as Map<String, dynamic>;
  if (data is Map) return data.cast<String, dynamic>();
  return const {};
}

void main() {
  test("createInvite posts to the operator route and fullLink prefixes base",
      () async {
    final adapter = _CannedAdapter({
      "/api/v1/groups/g1/invite": {
        "token": "INV-TOKEN",
        "join_url": "/join/INV-TOKEN",
        "group_id": "g1",
      },
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final svc = GuestInviteService(dio: dio, webuiBaseUrl: "https://h.test");

    final res = await svc.createInvite(groupId: "g1", singleUse: true);
    expect(res["token"], "INV-TOKEN");
    final body = _decode(adapter.last!.data);
    expect(body["single_use"], true);

    // The relative join_url is turned into a full shareable link.
    expect(svc.fullLink(res["join_url"] as String),
        "https://h.test/join/INV-TOKEN");
  });

  group("data-plane credential", () {
    test("the request carries a session Bearer, not only the pasted token", () async {
      // The regression this pins. This route is capability-mapped
      // server-side, so with SKCHAT_DATAPLANE_AUTH=1 the data-plane gate runs
      // FIRST and only accepts `Authorization: Bearer <session>` or
      // `X-CapAuth-Token`. It does NOT recognise `X-Operator-Token`. Sending
      // only the pasted token draws a 401 "capauth authentication required"
      // before the route's own operator check ever runs, so every invite mint
      // fails against a healthy server.
      final adapter = _CannedAdapter({
        "/api/v1/groups/g1/invite": {
          "token": "INV-TOKEN",
          "join_url": "/join/INV-TOKEN",
          "group_id": "g1",
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final svc = GuestInviteService(
        dio: dio,
        webuiBaseUrl: "https://h.test",
        sessionService: _sessionYielding(hs256: "SESSION-JWT"),
      );

      await svc.createInvite(groupId: "g1", singleUse: true);

      final auth = (adapter.last!.headers["Authorization"] ?? "").toString();
      expect(auth, contains("SESSION-JWT"),
          reason: "the data-plane gate reads Authorization / X-CapAuth-Token only");
    });
  });
}

/// A session service whose handshake yields a fixed HS256 credential. The
/// helpers below are lifted from `operator_auth_interceptor_test.dart`, which
/// already proves this shape drives a real handshake.
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
      RequestOptions o, Stream<List<int>>? s, Future<void>? c) async {
    final body =
        o.uri.path.endsWith("/challenge") ? {"nonce": nonce, "exp": 0} : sessionBody;
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
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
