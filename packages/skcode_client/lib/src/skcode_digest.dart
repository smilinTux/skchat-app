import "dart:convert";

import "package:dio/dio.dart";

/// The Dart mirror of one `WatchdogEvent` (skos watchdog spec 2026-08-10,
/// section 6.2): `{ts, source, kind, object, severity, summary, link: {uri,
/// http}, ref, meta}`. Every field defaults to an empty/neutral value rather
/// than throwing, because a digest is rendered best-effort: one malformed
/// entry must never take down the whole tab.
class SkcodeDigestLink {
  const SkcodeDigestLink({this.uri = "", this.http = ""});

  /// The `skworld://<moduleId>/<path>` form (watchdog spec 6.2/8), or empty
  /// when the event's target has no shell-resolvable authority.
  final String uri;

  /// The working `https://` fallback (watchdog spec 8: "the load-bearing
  /// one until a skworld:// resolver exists outside the Flutter shell" -
  /// which is exactly what card C-9 is). Rendered when [uri] is empty.
  final String http;

  factory SkcodeDigestLink.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SkcodeDigestLink();
    return SkcodeDigestLink(
      uri: json["uri"] as String? ?? "",
      http: json["http"] as String? ?? "",
    );
  }

  bool get isEmpty => uri.isEmpty && http.isEmpty;

  /// The uri to actually open: [uri] (shell-resolvable) preferred over
  /// [http] (watchdog spec 8's fallback), matching the priority the spec
  /// gives once a resolver exists ("the Flutter shell can upgrade rendering
  /// later without re-collecting anything").
  String get preferred => uri.isNotEmpty ? uri : http;
}

/// One digest line: a `problems` or `notable` entry (watchdog spec 6.2/6.4).
class SkcodeDigestEvent {
  const SkcodeDigestEvent({
    this.ts = "",
    this.source = "",
    this.kind = "",
    this.object = "",
    this.severity = "info",
    this.summary = "",
    this.link = const SkcodeDigestLink(),
    this.ref = "",
  });

  final String ts;
  final String source;
  final String kind;
  final String object;

  /// `info` | `notable` | `problem` (watchdog spec 6.2). Passed through
  /// unchanged; this tab never re-derives or reclassifies a severity the
  /// watchdog already assigned deterministically.
  final String severity;
  final String summary;
  final SkcodeDigestLink link;

  /// The dedupe key everywhere upstream (watchdog spec 6.2); rendered as the
  /// row's stable key so a re-fetch does not reshuffle the list.
  final String ref;

  factory SkcodeDigestEvent.fromJson(Map<String, dynamic> json) {
    return SkcodeDigestEvent(
      ts: json["ts"] as String? ?? "",
      source: json["source"] as String? ?? "",
      kind: json["kind"] as String? ?? "",
      object: json["object"] as String? ?? "",
      severity: json["severity"] as String? ?? "info",
      summary: json["summary"] as String? ?? "",
      link: SkcodeDigestLink.fromJson(json["link"] as Map<String, dynamic>?),
      ref: json["ref"] as String? ?? "",
    );
  }
}

/// The Dart mirror of the digest JSON shape (watchdog spec 6.4): `{date,
/// window: {from, to}, headline, problems: [...], notable: [...],
/// info_counts, per_source: {...}, grading?: {...}}`.
///
/// Only the fields this tab renders are kept ([date], [headline], [problems],
/// [notable], [infoCount]): `per_source`/`grading`/`window` are read by
/// nothing here (spec's own division of labor - this is a renderer, not a
/// second collector - so it has no reason to parse fields it never shows).
class SkcodeDigest {
  const SkcodeDigest({
    this.date = "",
    this.headline = "",
    this.problems = const [],
    this.notable = const [],
    this.infoCount = 0,
  });

  final String date;
  final String headline;
  final List<SkcodeDigestEvent> problems;
  final List<SkcodeDigestEvent> notable;

  /// Sum of `info_counts` (watchdog spec 6.4 is per-source; the tab only
  /// needs a total for a one-line "N quiet events" summary, not a breakdown).
  final int infoCount;

  factory SkcodeDigest.fromJson(Map<String, dynamic> json) {
    List<SkcodeDigestEvent> parseEvents(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(SkcodeDigestEvent.fromJson)
          .toList(growable: false);
    }

    int parseInfoCount(dynamic raw) {
      if (raw is num) return raw.toInt();
      if (raw is Map) {
        var total = 0;
        for (final v in raw.values) {
          if (v is num) total += v.toInt();
        }
        return total;
      }
      return 0;
    }

    return SkcodeDigest(
      date: json["date"] as String? ?? "",
      headline: json["headline"] as String? ?? "",
      problems: parseEvents(json["problems"]),
      notable: parseEvents(json["notable"]),
      infoCount: parseInfoCount(json["info_counts"]),
    );
  }
}

/// Thrown when the digest host answers 404: no `latest/` artifact has been
/// published yet (a normal, expected state before the watchdog's first run,
/// or if it has never run on this environment). [SkcodeDigestTab] renders
/// this as an honest "no digest published yet" state, never an error.
class SkcodeDigestNotFoundException implements Exception {
  const SkcodeDigestNotFoundException([this.message = "no digest published"]);
  final String message;

  @override
  String toString() => "SkcodeDigestNotFoundException: $message";
}

/// Any other non-2xx response or transport failure reaching the digest host.
class SkcodeDigestFetchException implements Exception {
  const SkcodeDigestFetchException(this.message);
  final String message;

  @override
  String toString() => "SkcodeDigestFetchException: $message";
}

/// The response body was not parseable JSON, or not a JSON object at all.
/// Kept distinct from [SkcodeDigestFetchException] so the tab can render a
/// different, more precise honest message ("digest content could not be
/// read" vs "could not reach the digest").
class SkcodeDigestParseException implements Exception {
  const SkcodeDigestParseException(this.message);
  final String message;

  @override
  String toString() => "SkcodeDigestParseException: $message";
}

/// Fetches the skwatchdog published `latest/` digest artifact over plain
/// https (watchdog spec section 9: "the artifact pane's Digest tab fetches
/// the published digest (the latest/ artifact over https, the load-bearing
/// link form the watchdog spec already mandates) and renders it").
///
/// Deliberately its own small client, NOT [SkcodeApiClient]: the digest lives
/// on the watchdog's publish host (beside the Atlas brief, watchdog spec
/// section 5), a different origin than skcode-hostd, and it is a published
/// static artifact with no capauth audience of its own, so no Bearer header
/// dance applies here. This client does exactly one thing: GET a full URL,
/// parse it as the digest JSON shape, never write anything, never cache
/// anything (division of labor: "no digest data is stored or recomputed
/// client-side; the artifact remains the single narrative surface").
class SkcodeDigestClient {
  SkcodeDigestClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  final Dio _dio;

  /// Fetches and parses the digest at [url] (the full `latest/` artifact
  /// URL; this client never builds a URL from a base + path, since the
  /// caller already knows the whole thing, matching how flexible/uncertain
  /// the watchdog's actual publish path still is at this stage).
  Future<SkcodeDigest> fetchLatest(String url) async {
    Response<String> response;
    try {
      response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw const SkcodeDigestNotFoundException();
      }
      throw SkcodeDigestFetchException(
        e.message ?? "digest fetch failed",
      );
    }

    final body = response.data;
    if (body == null || body.trim().isEmpty) {
      throw const SkcodeDigestParseException("empty digest response");
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const SkcodeDigestParseException(
          "digest response was not a JSON object",
        );
      }
      return SkcodeDigest.fromJson(decoded);
    } on SkcodeDigestParseException {
      rethrow;
    } catch (e) {
      throw SkcodeDigestParseException("could not parse digest JSON: $e");
    }
  }
}
