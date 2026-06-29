import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/consent_service.dart";

/// Canned-response adapter — resolves each request from [routes] by path,
/// recording the last request for assertions. Mirrors the project's existing
/// service-test mocking style (see recordings_service_test.dart).
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  RequestOptions? lastRequest;
  int statusCode = 200;

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
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  late _CannedAdapter adapter;
  late Dio dio;
  late ConsentService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = ConsentService(dio: dio, baseUrl: "http://localhost:9384");
  });

  test("listRequests parses the consent/requests envelope", () async {
    adapter.routes["/api/v1/consent/requests"] = {
      "agent": "lumina",
      "requests": [
        {
          "sender": "stranger@dk.skworld",
          "envelope_id": "env-1",
          "received_at": "2026-06-24T10:00:00Z",
        },
        {
          "sender": "newpeer@chef.skworld",
          "envelope_id": "env-2",
          "received_at": "2026-06-24T11:00:00Z",
        },
      ],
    };

    final reqs = await svc.listRequests();
    expect(reqs, hasLength(2));
    expect(reqs.first.sender, "stranger@dk.skworld");
    expect(reqs.first.envelopeId, "env-1");
    expect(reqs.first.receivedAt, "2026-06-24T10:00:00Z");
    expect(reqs[1].sender, "newpeer@chef.skworld");
    expect(adapter.lastRequest?.uri.path, "/api/v1/consent/requests");
  });

  test("listRequests tolerates a bare list (no envelope) + empty", () async {
    adapter.routes["/api/v1/consent/requests"] = [
      {"sender": "a@b", "envelope_id": "e", "received_at": "t"},
    ];
    final reqs = await svc.listRequests();
    expect(reqs.single.sender, "a@b");

    adapter.routes["/api/v1/consent/requests"] = {"agent": "x", "requests": []};
    expect(await svc.listRequests(), isEmpty);
  });

  test("accept POSTs the sender and returns the minted token", () async {
    adapter.routes["/api/v1/consent/accept"] = {
      "agent": "lumina",
      "sender": "stranger@dk.skworld",
      "token": "tok-abc123",
    };

    final token = await svc.accept("stranger@dk.skworld");
    expect(token, "tok-abc123");
    expect(adapter.lastRequest?.uri.path, "/api/v1/consent/accept");
    expect(adapter.lastRequest?.method, "POST");
    expect(
      (adapter.lastRequest?.data as Map)["sender"],
      "stranger@dk.skworld",
    );
  });

  test("decline POSTs sender + block flag (default false)", () async {
    adapter.routes["/api/v1/consent/decline"] = {"result": "declined"};

    await svc.decline("stranger@dk.skworld");
    expect(adapter.lastRequest?.uri.path, "/api/v1/consent/decline");
    final body = adapter.lastRequest?.data as Map;
    expect(body["sender"], "stranger@dk.skworld");
    expect(body["block"], false);
  });

  test("decline with block:true forwards the block flag", () async {
    adapter.routes["/api/v1/consent/decline"] = {"result": "declined"};
    await svc.decline("x@y", block: true);
    expect((adapter.lastRequest?.data as Map)["block"], true);
  });

  test("block POSTs the sender to /consent/block", () async {
    adapter.routes["/api/v1/consent/block"] = {"result": "blocked"};
    await svc.block("bad@actor");
    expect(adapter.lastRequest?.uri.path, "/api/v1/consent/block");
    expect((adapter.lastRequest?.data as Map)["sender"], "bad@actor");
  });

  test("unblock POSTs the sender to /consent/unblock", () async {
    adapter.routes["/api/v1/consent/unblock"] = {"result": "unblocked"};
    await svc.unblock("ex@blocked");
    expect(adapter.lastRequest?.uri.path, "/api/v1/consent/unblock");
    expect((adapter.lastRequest?.data as Map)["sender"], "ex@blocked");
  });

  test("listKnown parses the known roster (envelope + bare list)", () async {
    adapter.routes["/api/v1/consent/known"] = {
      "agent": "lumina",
      "known": ["friend@a", "friend@b"],
    };
    expect(await svc.listKnown(), ["friend@a", "friend@b"]);

    adapter.routes["/api/v1/consent/known"] = ["solo@c"];
    expect(await svc.listKnown(), ["solo@c"]);
  });

  test("ContactRequest.fromJson tolerates missing fields", () {
    final r = ContactRequest.fromJson(const {"sender": "only@sender"});
    expect(r.sender, "only@sender");
    expect(r.envelopeId, "");
    expect(r.receivedAt, "");
  });
}
