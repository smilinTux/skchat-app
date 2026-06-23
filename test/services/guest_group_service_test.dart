import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_group_service.dart";
import "package:skchat/services/guest_identity.dart";

/// Canned-response adapter keyed by path; records every request for assertions.
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

/// Deterministic in-test identity: a fixed public key + recorded signing.
class _FakeIdentity implements GuestIdentity {
  _FakeIdentity({this.cached = false});
  bool cached;
  String? lastSigned;

  @override
  Future<bool> hasCached() async => cached;

  @override
  Future<GuestKeypair> ensure() async {
    cached = true;
    return const GuestKeypair(publicKeyB64: "PUB-KEY-B64", fingerprint: "deadbeefdeadbeef");
  }

  @override
  Future<String> sign(String data) async {
    lastSigned = data;
    return "SIG-$data".hashCode.toString();
  }

  @override
  Future<void> clear() async {
    cached = false;
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
  late _CannedAdapter adapter;
  late Dio dio;
  late _FakeIdentity id;
  late GuestGroupService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    id = _FakeIdentity();
    svc = GuestGroupService(
        dio: dio, webuiBaseUrl: "https://test.local", identity: id);
  });

  test("join generates+sends the browser public key and parses tokens",
      () async {
    adapter.routes["/api/v1/guest/join"] = {
      "ok": true,
      "session_token": "SESSION-JWT",
      "guest_id": "guest:alice#deadbeefdeadbeef",
      "display_name": "Alice",
      "trust": "untrusted",
      "group": {"id": "g1", "name": "Town Hall"},
      "call": {
        "available": true,
        "room": "gcall-abc",
        "token": "LK-JWT",
        "lk_url": "wss://sfu.test",
      },
      "messages": [
        {"id": "m1", "body": "hi", "sender": "lumina"}
      ],
    };

    final res = await svc.join(inviteToken: "INV", displayName: "Alice");

    // The request carried the WebCrypto public key (server fingerprints it).
    final sent = _decode(adapter.requests.single.data);
    expect(sent["guest_pubkey"], "PUB-KEY-B64");
    expect(sent["invite_token"], "INV");
    expect(sent["display_name"], "Alice");

    // The result is parsed into the typed bootstrap.
    expect(res.sessionToken, "SESSION-JWT");
    expect(res.groupId, "g1");
    expect(res.groupName, "Town Hall");
    expect(res.trust, "untrusted");
    expect(res.callAvailable, true);
    expect(res.callToken, "LK-JWT");
    expect(res.messages.length, 1);
  });

  test("send signs the canonical {body,group_id,ts} payload and bears the token",
      () async {
    adapter.routes["/api/v1/guest/send"] = {
      "ok": true,
      "message": {"id": "m9", "body": "hello"},
    };

    await svc.send(
        sessionToken: "SESSION-JWT", groupId: "g1", body: "hello");

    // The signed canonical payload uses alphabetical keys + stringified ts —
    // it MUST match the server's guest_groups.canonical_sign_payload.
    expect(id.lastSigned, isNotNull);
    final signed = jsonDecode(id.lastSigned!);
    expect(signed.keys.toList(), ["body", "group_id", "ts"]);
    expect(signed["body"], "hello");
    expect(signed["group_id"], "g1");
    expect(signed["ts"], isA<String>());

    // The request bears the guest session token + carries the signature.
    final req = adapter.requests.single;
    expect(req.headers["Authorization"], "Bearer SESSION-JWT");
    final body = _decode(req.data);
    expect(body["signature"], isNotEmpty);
    expect(body["body"], "hello");
  });

  test("react posts the op + message id with the bearer token", () async {
    adapter.routes["/api/v1/guest/react"] = {"ok": true};
    await svc.react(
        sessionToken: "S", messageId: "m1", emoji: "👍", add: true);
    final req = adapter.requests.single;
    expect(req.headers["Authorization"], "Bearer S");
    final body = _decode(req.data);
    expect(body["message_id"], "m1");
    expect(body["op"], "add");
  });

  test("conversation reads the bound group's messages (token-scoped)", () async {
    adapter.routes["/api/v1/guest/conversation"] = {
      "group_id": "g1",
      "messages": [
        {"id": "a", "body": "1"},
        {"id": "b", "body": "2"},
      ],
    };
    final msgs = await svc.conversation("S");
    expect(msgs.length, 2);
    expect(adapter.requests.single.headers["Authorization"], "Bearer S");
    // No group id is ever sent — the server derives it from the token.
    expect(adapter.requests.single.uri.path, "/api/v1/guest/conversation");
  });

  test("fileUrl builds the group-scoped download URL", () {
    expect(svc.fileUrl("t123"), "https://test.local/api/v1/guest/file/t123");
  });

  test("returning guest is recognised via cached identity (auto-join path)",
      () async {
    final cachedId = _FakeIdentity(cached: true);
    final dio2 = Dio()..httpClientAdapter = adapter;
    final svc2 = GuestGroupService(
        dio: dio2, webuiBaseUrl: "https://test.local", identity: cachedId);
    // hasCached() true -> the landing screen would auto-join without prompting.
    expect(await svc2.identity.hasCached(), isTrue);
  });
}
