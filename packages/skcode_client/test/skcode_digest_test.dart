import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// Mirrors `skcode_api_client_test.dart`'s `_RecordingAdapter`: a canned
/// response adapter that records every request so the tests below can assert
/// on the exact URL fetched (no path-building here, unlike [SkcodeApiClient]:
/// [SkcodeDigestClient] fetches the whole URL the caller hands it).
class _RecordingAdapter implements HttpClientAdapter {
  int status = 200;
  String? body;
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
      body ?? "",
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
  late SkcodeDigestClient client;

  const digestUrl = "https://atlas.skworld.io/watchdog/latest/digest.json";

  setUp(() {
    adapter = _RecordingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    client = SkcodeDigestClient(dio: dio);
  });

  group("fetchLatest", () {
    test("GETs exactly the URL handed to it, no base/path building",
        () async {
      adapter.body = "{}";
      await client.fetchLatest(digestUrl);

      final req = adapter.requests.single;
      expect(req.method, "GET");
      expect(req.uri.toString(), digestUrl);
    });

    test("parses date, headline, problems, notable, and info_counts",
        () async {
      adapter.body = '''
      {
        "date": "2026-08-11",
        "headline": "Quiet day.",
        "problems": [
          {
            "ts": "2026-08-11T06:12:03Z",
            "source": "fleet",
            "kind": "ServiceCrashLoop",
            "object": "skchat-daemon@dot41",
            "severity": "problem",
            "summary": "daemon restarted 4 times",
            "link": {"uri": "skworld://skcode/session/s-1", "http": "https://x"},
            "ref": "fleet:1"
          }
        ],
        "notable": [
          {"summary": "PR merged", "severity": "notable", "source": "git"}
        ],
        "info_counts": {"scheduler": 3, "coord_autocode": 1}
      }
      ''';

      final digest = await client.fetchLatest(digestUrl);

      expect(digest.date, "2026-08-11");
      expect(digest.headline, "Quiet day.");
      expect(digest.problems, hasLength(1));
      expect(digest.problems.single.summary, "daemon restarted 4 times");
      expect(digest.problems.single.severity, "problem");
      expect(digest.problems.single.link.uri, "skworld://skcode/session/s-1");
      expect(digest.problems.single.link.http, "https://x");
      expect(digest.problems.single.ref, "fleet:1");
      expect(digest.notable, hasLength(1));
      expect(digest.notable.single.summary, "PR merged");
      expect(digest.infoCount, 4);
    });

    test("tolerates missing problems/notable/info_counts (empty/zero)",
        () async {
      adapter.body = '{"date": "2026-08-11", "headline": "All quiet."}';

      final digest = await client.fetchLatest(digestUrl);

      expect(digest.problems, isEmpty);
      expect(digest.notable, isEmpty);
      expect(digest.infoCount, 0);
    });

    test("SkcodeDigestLink.preferred prefers uri over http", () {
      const withUri = SkcodeDigestLink(uri: "skworld://x/y", http: "https://x");
      expect(withUri.preferred, "skworld://x/y");

      const httpOnly = SkcodeDigestLink(http: "https://x");
      expect(httpOnly.preferred, "https://x");

      expect(const SkcodeDigestLink().isEmpty, isTrue);
      expect(withUri.isEmpty, isFalse);
    });

    test("a 404 throws SkcodeDigestNotFoundException (no digest published)",
        () async {
      adapter
        ..status = 404
        ..body = "not found";

      expect(
        () => client.fetchLatest(digestUrl),
        throwsA(isA<SkcodeDigestNotFoundException>()),
      );
    });

    test("a 500 throws SkcodeDigestFetchException (not NotFound)", () async {
      adapter
        ..status = 500
        ..body = "boom";

      expect(
        () => client.fetchLatest(digestUrl),
        throwsA(isA<SkcodeDigestFetchException>()),
      );
    });

    test("non-JSON body throws SkcodeDigestParseException, not a crash",
        () async {
      adapter
        ..status = 200
        ..body = "<html>not json</html>";

      expect(
        () => client.fetchLatest(digestUrl),
        throwsA(isA<SkcodeDigestParseException>()),
      );
    });

    test("a JSON array (not an object) throws SkcodeDigestParseException",
        () async {
      adapter
        ..status = 200
        ..body = "[1, 2, 3]";

      expect(
        () => client.fetchLatest(digestUrl),
        throwsA(isA<SkcodeDigestParseException>()),
      );
    });

    test("an empty body throws SkcodeDigestParseException", () async {
      adapter
        ..status = 200
        ..body = "";

      expect(
        () => client.fetchLatest(digestUrl),
        throwsA(isA<SkcodeDigestParseException>()),
      );
    });
  });
}
