import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/spaces_service.dart";

/// Canned-response adapter — resolves each request from [routes] by path,
/// recording the last request body for assertions.
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
  late SpacesService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = SpacesService(dio: dio, webuiBaseUrl: "https://test.local");
  });

  test("listLive parses the spaces array", () async {
    adapter.routes["/spaces"] = {
      "spaces": [
        {
          "space_id": "s1",
          "title": "Town Hall",
          "host_fqid": "chef@dk.skworld",
          "status": "live",
          "speakers": ["chef@dk.skworld"],
          "recording": true,
        },
        {
          "space_id": "s2",
          "title": "Standup",
          "host_fqid": "lumina@dk.skworld",
          "status": "live",
          "speakers": <String>[],
          "recording": false,
        },
      ],
    };

    final spaces = await svc.listLive();
    expect(spaces, hasLength(2));
    expect(spaces.first.title, "Town Hall");
    expect(spaces.first.recording, isTrue);
    expect(spaces.first.speakers, ["chef@dk.skworld"]);
    expect(spaces[1].recording, isFalse);
  });

  test("joinListener parses a role-scoped join", () async {
    adapter.routes["/spaces/s1/join"] = {
      "space_id": "s1",
      "room": "sk-space-s1",
      "url": "wss://lk.test/ws",
      "identity": "guest-1",
      "role": "listener",
      "token": "jwt-abc",
      "title": "Town Hall",
    };

    final join = await svc.joinListener("s1", identity: "guest-1");
    expect(join.role, "listener");
    expect(join.isHost, isFalse);
    expect(join.url, "wss://lk.test/ws");
    expect(join.token, "jwt-abc");
  });

  test("joinHost posts the requester and yields a host join", () async {
    adapter.routes["/spaces/s1/join-host"] = {
      "space_id": "s1",
      "room": "sk-space-s1",
      "url": "wss://lk.test/ws",
      "identity": "chef@dk.skworld",
      "role": "host",
      "token": "jwt-host",
      "title": "Town Hall",
    };

    final join = await svc.joinHost("s1", requester: "chef@dk.skworld");
    expect(join.isHost, isTrue);
    expect(adapter.lastRequest?.uri.path, "/spaces/s1/join-host");
    expect(
      (adapter.lastRequest?.data as Map)["requester"],
      "chef@dk.skworld",
    );
  });

  test("raiseHand returns the on_stage flag", () async {
    adapter.routes["/spaces/s1/raise-hand"] = {"ok": true, "on_stage": true};
    final onStage = await svc.raiseHand("s1", identity: "guest-1");
    expect(onStage, isTrue);
  });
}
