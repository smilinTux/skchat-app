import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/recordings_service.dart";

/// Canned-response adapter — resolves each request from [routes] by path,
/// recording the last request for assertions.
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
  late RecordingsService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = RecordingsService(dio: dio, webuiBaseUrl: "https://test.local");
  });

  test("list parses the recordings array of objects", () async {
    adapter.routes["/recordings"] = {
      "recordings": [
        {
          "name": "room-a-2026.mp4",
          "size": 1048576,
          "modified": "2026-06-20T10:00:00Z",
          "room": "sk-room-a",
        },
        {"name": "space-b.ogg", "size_bytes": 2048},
      ],
    };

    final recs = await svc.list();
    expect(recs, hasLength(2));
    expect(recs.first.name, "room-a-2026.mp4");
    expect(recs.first.sizeBytes, 1048576);
    expect(recs.first.room, "sk-room-a");
    expect(recs[1].sizeBytes, 2048);
  });

  test("list tolerates a bare top-level array of strings", () async {
    adapter.routes["/recordings"] = ["a.mp4", "b.mp4"];
    final recs = await svc.list();
    expect(recs.map((r) => r.name), ["a.mp4", "b.mp4"]);
  });

  test("fetchUrl builds an encoded /recordings/{name} URL", () {
    expect(
      svc.fetchUrl("room a.mp4"),
      "https://test.local/recordings/room%20a.mp4",
    );
  });

  test("recordStart posts the room to /livekit/record/start", () async {
    adapter.routes["/livekit/record/start"] = {"ok": true};
    await svc.recordStart("sk-room-x");
    expect(adapter.lastRequest?.uri.path, "/livekit/record/start");
    expect((adapter.lastRequest?.data as Map)["room"], "sk-room-x");
  });

  test("recordStop posts the room to /livekit/record/stop", () async {
    adapter.routes["/livekit/record/stop"] = {"ok": true};
    await svc.recordStop("sk-room-x");
    expect(adapter.lastRequest?.uri.path, "/livekit/record/stop");
    expect((adapter.lastRequest?.data as Map)["room"], "sk-room-x");
  });

  test("spaceRecordStart posts requester to /spaces/{id}/record/start",
      () async {
    adapter.routes["/spaces/s1/record/start"] = {"ok": true};
    await svc.spaceRecordStart("s1", requester: "chef@dk.skworld");
    expect(adapter.lastRequest?.uri.path, "/spaces/s1/record/start");
    expect(
      (adapter.lastRequest?.data as Map)["requester"],
      "chef@dk.skworld",
    );
  });
}
