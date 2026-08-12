import "package:dio/dio.dart";

import "skcode_event.dart";
import "skcode_job_run.dart";

/// One row of `GET /skcode/api/v1/sessions`, mirroring skharness's
/// `SessionDescriptor.to_dict()` (skcode Code-section card C-1).
class SkcodeSessionSummary {
  const SkcodeSessionSummary({
    required this.sid,
    this.host = "",
    this.harness = "",
    this.repo = "",
    this.branch = "",
    this.model = "",
    this.state = "running",
    this.lastActivity = 0.0,
    this.lastMessage = "",
    this.quality = "sandbox",
    this.permissionMode = "manual",
    this.mode = "direct",
    this.source = "interactive",
  });

  final String sid;
  final String host;
  final String harness;
  final String repo;
  final String branch;
  final String model;

  /// "running" | "idle" | "ended" | "spawning".
  final String state;
  final double lastActivity;
  final String lastMessage;
  final String quality;
  final String permissionMode;

  /// "direct" | "interactive".
  final String mode;

  /// "interactive" | "autocode" | "attach" (same vocabulary as
  /// [SkcodeEvent.source]): the rail groups sessions by this.
  final String source;

  factory SkcodeSessionSummary.fromJson(Map<String, dynamic> json) {
    return SkcodeSessionSummary(
      sid: json["sid"] as String? ?? "",
      host: json["host"] as String? ?? "",
      harness: json["harness"] as String? ?? "",
      repo: json["repo"] as String? ?? "",
      branch: json["branch"] as String? ?? "",
      model: json["model"] as String? ?? "",
      state: json["state"] as String? ?? "running",
      lastActivity: (json["last_activity"] as num?)?.toDouble() ?? 0.0,
      lastMessage: json["last_message"] as String? ?? "",
      quality: json["quality"] as String? ?? "sandbox",
      permissionMode: json["permission_mode"] as String? ?? "manual",
      mode: json["mode"] as String? ?? "direct",
      source: json["source"] as String? ?? "interactive",
    );
  }
}

/// Thrown when skcode-hostd (through the `/skcode/*` proxy) answers 401: the
/// wire token is missing, expired, or was rejected. The caller (the session
/// store) is expected to invalidate its cached audience token, re-mint
/// exactly once, and retry.
class SkcodeUnauthorizedException implements Exception {
  const SkcodeUnauthorizedException([this.message = "unauthorized"]);
  final String message;

  @override
  String toString() => "SkcodeUnauthorizedException: $message";
}

/// Any other non-2xx response or transport failure talking to skcode-hostd.
class SkcodeApiException implements Exception {
  const SkcodeApiException(this.message);
  final String message;

  @override
  String toString() => "SkcodeApiException: $message";
}

/// HTTP client for skcode-hostd's read-only session plane, reached through
/// the app's existing same-origin `/skcode/*` proxy
/// (`skchat/src/skchat/webui.py::skcode_proxy`), never a direct daemon port
/// (spec 4.2/4.3): callers pass the runtime daemon base URL (the same one
/// [daemonWsUrlProvider]'s HTTP sibling `daemonUrlProvider` already resolves)
/// and this client appends the `/skcode/api/v1/...` paths.
///
/// GRADE A RULE THIS CLASS EXISTS TO ENFORCE: `Authorization: Bearer <wire>`
/// is set directly on every request via [Options]. The wire token NEVER
/// appears in a URL or query string on the HTTP side — that is the entire
/// point of the native client over the old iframe's `?token=` hack. (WS is
/// the one place the token stays in `?token=`, by design; see
/// `skcode_ws_transport.dart` / `skcode_session_store.dart`.)
class SkcodeApiClient {
  SkcodeApiClient({Dio? dio, String? baseUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _stripSlash(baseUrl ?? "http://localhost:9384"),
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
            ),
          ) {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = _stripSlash(baseUrl);
    }
  }

  final Dio _dio;

  static String _stripSlash(String s) {
    var out = s.trim();
    while (out.endsWith("/")) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  Options _bearer(String token) =>
      Options(headers: {"Authorization": "Bearer $token"});

  /// `GET /skcode/api/v1/sessions`.
  Future<List<SkcodeSessionSummary>> listSessions({
    required String token,
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        "/skcode/api/v1/sessions",
        options: _bearer(token),
      );
      final rows = (resp.data?["sessions"] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      return rows.map(SkcodeSessionSummary.fromJson).toList();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `GET /skcode/api/v1/sessions/{sid}/events?before_seq=N&limit=M`, the
  /// archive-paging endpoint (spec 5.3): the reconnect/scrollback path, same
  /// read scope as the live WS tail.
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async {
    try {
      final queryParameters = <String, dynamic>{"limit": limit};
      if (beforeSeq != null) queryParameters["before_seq"] = beforeSeq;
      final resp = await _dio.get<Map<String, dynamic>>(
        "/skcode/api/v1/sessions/$sid/events",
        queryParameters: queryParameters,
        options: _bearer(token),
      );
      final rows = (resp.data?["events"] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      return rows.map(SkcodeEvent.fromJson).toList();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `GET /skcode/api/v1/jobs` (spec section 8, card C-8): the read-only
  /// view over the scheduler's cron ledger, scope `skcode.stream` (the same
  /// read scope as [listSessions]; there is no write scope for jobs in v1,
  /// deliberately -- no run-now/retry/cancel exists on this surface). Rows
  /// come back exactly as the server computed them (including `stale` /
  /// `staleness_s`); this client performs no staleness math of its own.
  Future<List<SkcodeJobRun>> listJobs({required String token}) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        "/skcode/api/v1/jobs",
        options: _bearer(token),
      );
      final rows = (resp.data?["jobs"] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      return rows.map(SkcodeJobRun.fromJson).toList();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `POST /skcode/api/v1/sessions/{sid}/inject`, body `{"text": text}`
  /// (spec 3.1). This is the P1 session WRITE surface: operator text sent
  /// into a running session as keystrokes. hostd's own audit record stores a
  /// sha256 plus the byte length of [text], NEVER the raw text (skharness
  /// `daemon.py::inject_session`); this client does nothing on top of that
  /// contract except NOT logging or printing [text] anywhere itself, so no
  /// call site here may add a `print`/`debugPrint`/log line that echoes it.
  /// Requires a [token] carrying [kSkcodeInjectScope].
  Future<void> injectText(String sid, String text, {required String token}) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        "/skcode/api/v1/sessions/$sid/inject",
        data: {"text": text},
        options: _bearer(token),
      );
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `POST /skcode/api/v1/sessions/{sid}/ratify`, no body (spec 3.1). Runs
  /// the autocode twin gate over the session's existing worktree diff;
  /// grades only, never merges/commits/pushes
  /// (skharness `daemon.py::ratify_session`). Requires a [token] carrying
  /// [kSkcodeInjectScope] (the same write scope as [injectText]: ratify is a
  /// write-class action even though it never touches the repo).
  Future<void> ratifySession(String sid, {required String token}) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        "/skcode/api/v1/sessions/$sid/ratify",
        options: _bearer(token),
      );
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Exception _wrap(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return const SkcodeUnauthorizedException();
    return SkcodeApiException(e.message ?? "skcode-hostd request failed");
  }
}
