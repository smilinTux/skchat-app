import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// Canned-response adapter that RECORDS every request so tests can assert on
/// headers and URLs, mirroring the project's existing service-test mocking
/// style (`facetime_service_test.dart`, `audience_token_service_test.dart`).
class _RecordingAdapter implements HttpClientAdapter {
  int status = 200;
  Object? body;
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
    return ResponseBody.fromString(
      jsonEncode(body ?? const {}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  late _RecordingAdapter adapter;
  late Dio dio;
  late SkcodeApiClient client;

  setUp(() {
    adapter = _RecordingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    client = SkcodeApiClient(dio: dio, baseUrl: "https://daemon.local");
  });

  group("Grade A rule: Bearer header, never a token in the URL", () {
    test("listSessions sends Authorization: Bearer <token> and no token in the URL",
        () async {
      adapter.body = {"sessions": <Map<String, dynamic>>[]};

      await client.listSessions(token: "WIRE-TOKEN-1");

      final req = adapter.requests.single;
      expect(req.headers["Authorization"], "Bearer WIRE-TOKEN-1");
      expect(req.uri.toString(), isNot(contains("WIRE-TOKEN-1")));
      expect(req.uri.path, "/skcode/api/v1/sessions");
      expect(req.uri.queryParameters, isEmpty,
          reason: "no query string at all on the sessions list call");
    });

    test("fetchEventsPage sends Authorization: Bearer <token> and no token in the URL",
        () async {
      adapter.body = {"sid": "s1", "events": <Map<String, dynamic>>[]};

      await client.fetchEventsPage("s1", token: "WIRE-TOKEN-2", beforeSeq: 50, limit: 25);

      final req = adapter.requests.single;
      expect(req.headers["Authorization"], "Bearer WIRE-TOKEN-2");
      expect(req.uri.toString(), isNot(contains("WIRE-TOKEN-2")));
      expect(req.uri.path, "/skcode/api/v1/sessions/s1/events");
      expect(req.uri.queryParameters["before_seq"], "50");
      expect(req.uri.queryParameters["limit"], "25");
    });

    test("fetchEventsPage omits before_seq when not paging backward", () async {
      adapter.body = {"sid": "s1", "events": <Map<String, dynamic>>[]};
      await client.fetchEventsPage("s1", token: "T");
      final req = adapter.requests.single;
      expect(req.uri.queryParameters.containsKey("before_seq"), isFalse);
      expect(req.uri.queryParameters["limit"], "100");
    });

    test("injectText posts {text} to /sessions/{sid}/inject with the bearer header",
        () async {
      await client.injectText("s1", "echo hi", token: "WIRE-TOKEN-3");

      final req = adapter.requests.single;
      expect(req.method, "POST");
      expect(req.headers["Authorization"], "Bearer WIRE-TOKEN-3");
      expect(req.uri.toString(), isNot(contains("WIRE-TOKEN-3")));
      expect(req.uri.path, "/skcode/api/v1/sessions/s1/inject");
      // The card's core safety property: the text travels in the POST body,
      // never in the URL/query string, so it can never end up in a proxy or
      // access log line the way a query param would.
      expect(req.uri.toString(), isNot(contains("echo hi")));
      expect(req.data, {"text": "echo hi"});
    });

    test("ratifySession posts with no body to /sessions/{sid}/ratify", () async {
      await client.ratifySession("s1", token: "WIRE-TOKEN-4");

      final req = adapter.requests.single;
      expect(req.method, "POST");
      expect(req.headers["Authorization"], "Bearer WIRE-TOKEN-4");
      expect(req.uri.path, "/skcode/api/v1/sessions/s1/ratify");
      expect(req.data, isNull);
    });
  });

  group("parsing", () {
    test("listSessions parses the sessions array", () async {
      adapter.body = {
        "sessions": [
          {
            "sid": "s-1",
            "host": ".158",
            "harness": "claude-code",
            "repo": "skworld-app",
            "branch": "main",
            "model": "sonnet",
            "state": "running",
            "last_activity": 1765430000.0,
            "last_message": "hi",
            "quality": "sandbox",
            "permission_mode": "manual",
            "mode": "interactive",
            "source": "interactive",
          },
        ],
      };

      final list = await client.listSessions(token: "T");
      expect(list, hasLength(1));
      expect(list.single.sid, "s-1");
      expect(list.single.source, "interactive");
      expect(list.single.state, "running");
    });

    test("listSessions tolerates a missing/empty sessions array", () async {
      adapter.body = <String, dynamic>{};
      final list = await client.listSessions(token: "T");
      expect(list, isEmpty);
    });

    test("fetchEventsPage parses the events array into SkcodeEvent", () async {
      adapter.body = {
        "sid": "s1",
        "events": [
          {
            "type": "tool_call",
            "text": "Edit",
            "ts": 100.5,
            "data": {"name": "Edit"},
            "seq": 3,
            "sid": "s1",
            "source": "interactive",
          },
        ],
      };
      final events = await client.fetchEventsPage("s1", token: "T");
      expect(events, hasLength(1));
      expect(events.single.seq, 3);
      expect(events.single.type, "tool_call");
    });
  });

  group("error handling", () {
    test("a 401 response throws SkcodeUnauthorizedException", () async {
      adapter
        ..status = 401
        ..body = {"error": "unauthorized"};

      expect(
        () => client.listSessions(token: "STALE"),
        throwsA(isA<SkcodeUnauthorizedException>()),
      );
    });

    test("a 500 response throws SkcodeApiException (not Unauthorized)", () async {
      adapter
        ..status = 500
        ..body = {"error": "boom"};

      expect(
        () => client.listSessions(token: "T"),
        throwsA(isA<SkcodeApiException>()),
      );
    });

    test("injectText: a 403 (write scope missing) throws SkcodeApiException", () async {
      adapter
        ..status = 403
        ..body = {"error": "forbidden"};

      expect(
        () => client.injectText("s1", "x", token: "T"),
        throwsA(isA<SkcodeApiException>()),
      );
    });

    test("ratifySession: a 401 throws SkcodeUnauthorizedException", () async {
      adapter
        ..status = 401
        ..body = {"error": "unauthorized"};

      expect(
        () => client.ratifySession("s1", token: "STALE"),
        throwsA(isA<SkcodeUnauthorizedException>()),
      );
    });
  });
}
