import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// Mirrors `skcode_api_client_test.dart`'s `_RecordingAdapter`: a canned
/// response adapter that records every request, so these tests can assert on
/// the exact path fetched AND on the `Authorization` header that rides it.
///
/// The header assertion is the point of card C-14a. Card C-9's digest client
/// GET-ed a bare URL with no auth at all, against a host that never existed;
/// the digest now rides [SkcodeApiClient] on the same Bearer-authenticated
/// read plane as sessions and jobs, so a regression that drops the header is
/// exactly the thing this file has to catch.
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
  late SkcodeApiClient client;

  setUp(() {
    adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    client = SkcodeApiClient(dio: dio, baseUrl: "https://hostd.skworld.io");
  });

  group("fetchDigest", () {
    test("GETs hostd's digest route on the origin, carrying the Bearer token",
        () async {
      adapter.body = "{}";
      await client.fetchDigest(token: "wire-token");

      final req = adapter.requests.single;
      expect(req.method, "GET");
      expect(
        req.uri.toString(),
        "https://hostd.skworld.io/skcode/api/v1/watchdog/digest",
      );
      expect(req.headers["Authorization"], "Bearer wire-token");
      // Never in a query string: the whole point of the native client over
      // the old iframe's `?token=` hack (see SkcodeApiClient's class doc).
      expect(req.uri.query, isEmpty);
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

      final digest = await client.fetchDigest(token: "t");

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

      final digest = await client.fetchDigest(token: "t");

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

    test("a 404 throws SkcodeDigestNotFoundException (nothing published yet)",
        () async {
      adapter
        ..status = 404
        ..body = '{"detail": "no digest has been published yet"}';

      await expectLater(
        client.fetchDigest(token: "t"),
        throwsA(isA<SkcodeDigestNotFoundException>()),
      );
    });

    test("a 401 throws SkcodeUnauthorizedException, NOT a not-found",
        () async {
      // The two must never collapse: "no digest exists" and "you are not
      // allowed to read it" have different fixes.
      adapter
        ..status = 401
        ..body = "unauthorized";

      await expectLater(
        client.fetchDigest(token: "stale"),
        throwsA(isA<SkcodeUnauthorizedException>()),
      );
    });

    test("a 500 throws SkcodeApiException (not NotFound, not Parse)",
        () async {
      adapter
        ..status = 500
        ..body = "boom";

      await expectLater(
        client.fetchDigest(token: "t"),
        throwsA(isA<SkcodeApiException>()),
      );
    });

    test(
        "a 200 with corrupt bytes throws SkcodeDigestParseException, the "
        "state hostd deliberately leaves to this client", () async {
      // hostd serves the artifact's raw bytes unexamined, so a corrupt file
      // arrives as a 200 with an unparseable body rather than a 500.
      adapter
        ..status = 200
        ..body = "<html>not json</html>";

      await expectLater(
        client.fetchDigest(token: "t"),
        throwsA(isA<SkcodeDigestParseException>()),
      );
    });

    test("a JSON array (not an object) throws SkcodeDigestParseException",
        () async {
      adapter
        ..status = 200
        ..body = "[1, 2, 3]";

      await expectLater(
        client.fetchDigest(token: "t"),
        throwsA(isA<SkcodeDigestParseException>()),
      );
    });

    test("an empty body throws SkcodeDigestParseException", () async {
      adapter
        ..status = 200
        ..body = "";

      await expectLater(
        client.fetchDigest(token: "t"),
        throwsA(isA<SkcodeDigestParseException>()),
      );
    });
  });
}
