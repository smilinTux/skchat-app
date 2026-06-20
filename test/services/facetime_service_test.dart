import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/facetime_service.dart";

/// Canned-response adapter — resolves each request from [routes] by path,
/// recording the last request for method/URL assertions.
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
    final body = routes[options.uri.path] ?? routes[options.path] ?? {};
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
  late FaceTimeService svc;

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = FaceTimeService(dio: dio, webuiBaseUrl: "https://test.local");
  });

  test("agents parses the roster", () async {
    adapter.routes["/api/facetime/agents"] = {
      "agents": [
        {
          "name": "lumina",
          "has_portrait": true,
          "portrait_url": "/api/facetime/portrait/lumina",
        },
        {"name": "jarvis", "has_portrait": false, "portrait_url": null},
      ],
    };

    final list = await svc.agents();
    expect(list, hasLength(2));
    expect(list.first.name, "lumina");
    expect(list.first.hasPortrait, isTrue);
    expect(list.first.portraitPath, "/api/facetime/portrait/lumina");
    expect(list[1].hasPortrait, isFalse);
    expect(list[1].portraitPath, isNull);
    expect(adapter.lastRequest?.method, "GET");
    expect(adapter.lastRequest?.uri.path, "/api/facetime/agents");
  });

  test("agents tolerates an empty/missing list", () async {
    adapter.routes["/api/facetime/agents"] = {};
    final list = await svc.agents();
    expect(list, isEmpty);
  });

  test("portraitUrl uses the server-provided path when present", () {
    final url = svc.portraitUrl(
      "lumina",
      portraitPath: "/api/facetime/portrait/lumina",
    );
    expect(url, "https://test.local/api/facetime/portrait/lumina");
  });

  test("portraitUrl falls back to the canonical path", () {
    final url = svc.portraitUrl("opus");
    expect(url, "https://test.local/api/facetime/portrait/opus");
  });

  test("portraitUrl passes through absolute URLs unchanged", () {
    final url = svc.portraitUrl(
      "x",
      portraitPath: "https://cdn.example/x.png",
    );
    expect(url, "https://cdn.example/x.png");
  });

  test("base URL trailing slash is stripped", () async {
    final svc2 = FaceTimeService(dio: dio, webuiBaseUrl: "https://h.local///");
    expect(svc2.portraitUrl("a"), "https://h.local/api/facetime/portrait/a");
  });

  test("FaceTimeAgent.fromJson defaults missing fields", () {
    final a = FaceTimeAgent.fromJson(const {});
    expect(a.name, "");
    expect(a.hasPortrait, isFalse);
    expect(a.portraitPath, isNull);
  });
}
