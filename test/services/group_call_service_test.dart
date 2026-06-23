import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/group_call_service.dart";

/// Canned-response adapter keyed by request path — records the last request.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
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

void main() {
  late _CannedAdapter adapter;
  late Dio dio;
  late GroupCallService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = GroupCallService(dio: dio, baseUrl: "https://test.local");
  });

  test("startCall posts to the group call/start endpoint with ring+topic",
      () async {
    adapter.routes["/api/v1/groups/g1/call/start"] = {
      "ok": true,
      "group_id": "g1",
      "room": "gcall-abcdef0123456789",
      "identity": "chef@skworld.io",
      "token": "jwt-token-here",
      "livekit_url": "wss://sfu.test:8443",
      "members": [
        {"identity_uri": "chef@skworld.io", "display_name": "chef"},
        {"identity_uri": "lumina", "display_name": "lumina"},
      ],
      "rung": ["lumina"],
    };

    final session = await svc.startCall("g1", topic: "standup");

    // Request shape: ring defaults true, topic forwarded.
    expect(adapter.lastRequest!.path, "/api/v1/groups/g1/call/start");
    final sent = adapter.lastRequest!.data as Map;
    expect(sent["ring"], true);
    expect(sent["topic"], "standup");

    // Response parsing.
    expect(session.room, "gcall-abcdef0123456789");
    expect(session.token, "jwt-token-here");
    expect(session.livekitUrl, "wss://sfu.test:8443");
    expect(session.identity, "chef@skworld.io");
    expect(session.members.length, 2);
    expect(session.rung, ["lumina"]);
  });

  test("startCall with ring:false suppresses the ring flag", () async {
    adapter.routes["/api/v1/groups/g1/call/start"] = {
      "room": "gcall-x",
      "token": "t",
      "livekit_url": "wss://x",
    };
    await svc.startCall("g1", ring: false);
    expect((adapter.lastRequest!.data as Map)["ring"], false);
  });

  test("joinCall posts to the call/join endpoint (no ring)", () async {
    adapter.routes["/api/v1/groups/g2/call/join"] = {
      "room": "gcall-y",
      "token": "t2",
      "livekit_url": "wss://y",
      "identity": "chef@skworld.io",
    };
    final session = await svc.joinCall("g2");
    expect(adapter.lastRequest!.path, "/api/v1/groups/g2/call/join");
    expect(session.room, "gcall-y");
    expect(session.token, "t2");
  });

  test("participants parses active count + roster", () async {
    adapter.routes["/api/v1/groups/g3/call/participants"] = {
      "room": "gcall-z",
      "active": 2,
      "participants": [
        {"identity": "chef@skworld.io"},
        {"identity": "lumina"},
      ],
      "members": [
        {"identity_uri": "chef@skworld.io"},
        {"identity_uri": "lumina"},
        {"identity_uri": "jarvis"},
      ],
    };
    final p = await svc.participants("g3");
    expect(p.room, "gcall-z");
    expect(p.active, 2);
    expect(p.participants.length, 2);
    expect(p.members.length, 3);
  });

  test("empty participants response degrades to active:0", () async {
    adapter.routes["/api/v1/groups/g4/call/participants"] = {
      "room": "gcall-w",
      "active": 0,
      "participants": [],
      "members": [],
    };
    final p = await svc.participants("g4");
    expect(p.active, 0);
    expect(p.participants, isEmpty);
  });
}
