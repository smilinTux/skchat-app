import "dart:convert";

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

/// Thrown when skcode-hostd answers 404 on `GET /api/v1/watchdog/digest`: no
/// `latest/` artifact has been published yet (a normal, expected state before
/// the watchdog's first run, or if it has never run on this environment).
///
/// hostd is deliberate about this (skharness `digest.py` / `daemon.py`): a
/// missing file, a missing directory, and a permission error all answer 404,
/// and it NEVER fabricates a 200 with an empty digest, because "nothing has
/// been published" and "today was quiet" are different facts. [SkcodeDigestTab]
/// keeps them different on this side too, rendering this as its own honest
/// "no digest published yet" state rather than an error or an empty digest.
class SkcodeDigestNotFoundException implements Exception {
  const SkcodeDigestNotFoundException([this.message = "no digest published"]);
  final String message;

  @override
  String toString() => "SkcodeDigestNotFoundException: $message";
}

/// The response body was not parseable JSON, or not a JSON object at all: the
/// published artifact is corrupt.
///
/// This is a reachable state by design, not a defensive branch. hostd serves
/// the digest file's raw bytes unexamined (it never parses them, so it can
/// never "fix" or fabricate a digest), which means a corrupt artifact arrives
/// here as a 200 with an unparseable body rather than as a 500. Kept distinct
/// from [SkcodeUnauthorizedException] / [SkcodeApiException] /
/// [SkcodeDigestNotFoundException] so the tab renders "the published digest is
/// corrupt" rather than folding it into "could not reach the host".
class SkcodeDigestParseException implements Exception {
  const SkcodeDigestParseException(this.message);
  final String message;

  @override
  String toString() => "SkcodeDigestParseException: $message";
}

/// Parses a digest response body into a [SkcodeDigest], throwing
/// [SkcodeDigestParseException] for anything that is not a JSON object.
///
/// Lives here rather than in [SkcodeApiClient] so the digest's whole shape
/// (envelope, events, links, and what "unreadable" means) stays in one file;
/// the API client owns only the HTTP call and the Bearer header.
SkcodeDigest parseSkcodeDigestBody(String? body) {
  if (body == null || body.trim().isEmpty) {
    throw const SkcodeDigestParseException("empty digest response");
  }
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw SkcodeDigestParseException("could not parse digest JSON: $e");
  }
  if (decoded is! Map<String, dynamic>) {
    throw const SkcodeDigestParseException(
      "digest response was not a JSON object",
    );
  }
  return SkcodeDigest.fromJson(decoded);
}

// NOTE (card C-14a): there is deliberately NO digest-specific HTTP client in
// this file any more. Card C-9 shipped one (`SkcodeDigestClient`) that GET-ed
// a bare `digestUrl` with no Authorization header, on the assumption that the
// digest was a public static artifact published beside the Atlas brief.
// Nothing ever served that URL: the artifact is a 0600 owner-only file with no
// HTTP exposure at all, so the Digest tab was inert from the day it shipped.
// hostd now serves the same file at `GET /api/v1/watchdog/digest` under the
// `skcode.stream` read scope, so the digest rides [SkcodeApiClient] with the
// same Bearer token and the same re-mint-once seam as sessions and jobs.
// See [SkcodeApiClient.fetchDigest]. Do not reintroduce an unauthenticated
// second HTTP path here.
