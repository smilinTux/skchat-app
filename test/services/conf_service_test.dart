import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/conf_service.dart";

/// Canned-response adapter — resolves each request from [routes] by path,
/// recording the last request for body/method assertions.
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
  late ConfService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = ConfService(dio: dio, webuiBaseUrl: "https://test.local");
  });

  test("create posts host/title and parses the room", () async {
    adapter.routes["/conf/create"] = {
      "room": "conf-xyz",
      "title": "Town Hall",
      "host_fqid": "chef@dk.skworld",
    };

    final room = await svc.create(
      hostFqid: "chef@dk.skworld",
      title: "Town Hall",
    );
    expect(room.room, "conf-xyz");
    expect(room.title, "Town Hall");
    expect(adapter.lastRequest?.method, "POST");
    expect(adapter.lastRequest?.uri.path, "/conf/create");
    expect(
        (adapter.lastRequest?.data as Map)["host_fqid"], "chef@dk.skworld");
  });

  test("token mints a role-scoped join", () async {
    adapter.routes["/conf/conf-xyz/token"] = {
      "room": "conf-xyz",
      "url": "wss://lk.test/ws",
      "token": "jwt-host",
      "identity": "chef@dk.skworld",
      "role": "host",
      "title": "Town Hall",
    };

    final tok = await svc.token(
      "conf-xyz",
      identity: "chef@dk.skworld",
      name: "Chef",
      role: "host",
    );
    expect(tok.isHost, isTrue);
    expect(tok.url, "wss://lk.test/ws");
    expect(tok.token, "jwt-host");
    final sent = adapter.lastRequest?.data as Map;
    expect(sent["identity"], "chef@dk.skworld");
    expect(sent["name"], "Chef");
    expect(sent["role"], "host");
  });

  test("token defaults name to identity and role to guest", () async {
    adapter.routes["/conf/r1/token"] = {
      "room": "r1",
      "url": "wss://lk.test/ws",
      "token": "jwt-guest",
      "identity": "guest-1",
      "role": "guest",
    };

    final tok = await svc.token("r1", identity: "guest-1");
    expect(tok.isHost, isFalse);
    final sent = adapter.lastRequest?.data as Map;
    expect(sent["name"], "guest-1");
    expect(sent["role"], "guest");
  });

  test("participants parses the list", () async {
    adapter.routes["/conf/r1/participants"] = {
      "participants": [
        {"identity": "chef@dk.skworld", "role": "host"},
        {"identity": "lumina", "role": "agent", "is_agent": true},
      ],
    };

    final list = await svc.participants("r1");
    expect(list, hasLength(2));
    expect(list.first.identity, "chef@dk.skworld");
    expect(list[1].isAgent, isTrue);
    expect(adapter.lastRequest?.method, "GET");
  });

  test("waitingList parses guests from either key", () async {
    adapter.routes["/conf/r1/waiting"] = {
      "waiting": [
        {"identity": "g1", "name": "Guest One"},
        {"identity": "g2"},
      ],
    };

    final list = await svc.waitingList("r1");
    expect(list, hasLength(2));
    expect(list.first.name, "Guest One");
    expect(list[1].name, "");
    expect(adapter.lastRequest?.method, "GET");
  });

  test("admit posts identity + requester", () async {
    adapter.routes["/conf/r1/admit"] = {"ok": true};
    await svc.admit("r1", identity: "g1", requester: "chef@dk.skworld");
    expect(adapter.lastRequest?.uri.path, "/conf/r1/admit");
    final sent = adapter.lastRequest?.data as Map;
    expect(sent["identity"], "g1");
    expect(sent["requester"], "chef@dk.skworld");
  });

  test("deny posts identity", () async {
    adapter.routes["/conf/r1/deny"] = {"ok": true};
    await svc.deny("r1", identity: "g2");
    expect(adapter.lastRequest?.uri.path, "/conf/r1/deny");
    expect((adapter.lastRequest?.data as Map)["identity"], "g2");
  });

  test("inviteAgent posts the agent name", () async {
    adapter.routes["/conf/r1/invite-agent"] = {"ok": true};
    await svc.inviteAgent("r1", agent: "lumina", requester: "chef");
    expect(adapter.lastRequest?.uri.path, "/conf/r1/invite-agent");
    expect((adapter.lastRequest?.data as Map)["agent"], "lumina");
  });

  test("removeAgent posts the agent name", () async {
    adapter.routes["/conf/r1/remove-agent"] = {"ok": true};
    await svc.removeAgent("r1", agent: "lumina");
    expect(adapter.lastRequest?.uri.path, "/conf/r1/remove-agent");
    expect((adapter.lastRequest?.data as Map)["agent"], "lumina");
  });

  test("enterWaiting posts the guest identity", () async {
    adapter.routes["/conf/r1/waiting"] = {"ok": true};
    await svc.enterWaiting("r1", identity: "g1", name: "Guest One");
    expect(adapter.lastRequest?.method, "POST");
    final sent = adapter.lastRequest?.data as Map;
    expect(sent["identity"], "g1");
    expect(sent["name"], "Guest One");
  });

  test("end posts to the conf end route", () async {
    adapter.routes["/conf/r1/end"] = {"ok": true};
    await svc.end("r1", requester: "chef");
    expect(adapter.lastRequest?.uri.path, "/conf/r1/end");
    expect((adapter.lastRequest?.data as Map)["requester"], "chef");
  });
}
