import "package:dio/dio.dart";

import "skcode_digest.dart";
import "skcode_dispatch_targets.dart";
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

/// Thrown by [SkcodeApiClient.dispatch] / [SkcodeApiClient.cancelSession] on
/// a 403: the caller carried the `skcode.dispatch` scope (a 401 would have
/// fired instead) but capauth's PDP denied the specific decision
/// (`daemon.py::authorize_dispatch`), e.g. an enrollment-posture gate or a
/// repo the allowlist does not cover. Kept distinct from the generic
/// [SkcodeApiException] so the dispatch form / cancel affordance can show
/// "not authorized" as its own clear state rather than folding it into a
/// bare network-failure message (card C-6: "a dispatch rejection (403 from
/// PDP) needs a clear state, never a crash or a silent no-op").
class SkcodeDispatchForbiddenException implements Exception {
  const SkcodeDispatchForbiddenException([this.message = "not authorized"]);
  final String message;

  @override
  String toString() => "SkcodeDispatchForbiddenException: $message";
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

  Options _bearer(String token, {ResponseType? responseType}) => Options(
    headers: {"Authorization": "Bearer $token"},
    responseType: responseType,
  );

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

  /// `GET /skcode/api/v1/watchdog/digest` (card C-14a): the read-only view
  /// over the skwatchdog's published `latest/digest.json`, scope
  /// `skcode.stream`, the SAME read scope as [listSessions] / [listJobs]. It
  /// is a view, never a store: there is no publish/regenerate/delete route
  /// anywhere on this surface, and this method never writes, caches, or
  /// recomputes anything from what it parses.
  ///
  /// Three server states, kept as three distinct outcomes here because they
  /// mean three different things to an operator:
  ///
  ///  * **404** -> [SkcodeDigestNotFoundException]: nothing has been published
  ///    yet (the watchdog may simply not have run). hostd never answers a
  ///    fabricated empty 200 for this, so it can never be mistaken for a
  ///    genuinely quiet day.
  ///  * **401** -> [SkcodeUnauthorizedException] (via [_wrap]): the caller is
  ///    not authorized. Callers re-mint once through `onAuthRejected` and
  ///    retry, exactly as they do for sessions and jobs.
  ///  * **200 with a body that will not parse** ->
  ///    [SkcodeDigestParseException]: hostd serves the artifact's raw bytes
  ///    unexamined, so a corrupt file lands here rather than as a 500.
  ///
  /// Requested as [ResponseType.plain] on purpose: Dio's own JSON decoding
  /// would surface a corrupt body as a generic transport failure, which would
  /// collapse "the artifact is corrupt" into "the host is unreachable". The
  /// body is parsed by [parseSkcodeDigestBody] instead, which raises the
  /// precise exception. The digest JSON shape itself is untouched (this reads
  /// exactly what skos `assemble_digest()` wrote).
  Future<SkcodeDigest> fetchDigest({required String token}) async {
    final Response<String> resp;
    try {
      resp = await _dio.get<String>(
        "/skcode/api/v1/watchdog/digest",
        options: _bearer(token, responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw SkcodeDigestNotFoundException(
          _detail(e) ?? "no digest has been published yet",
        );
      }
      throw _wrap(e);
    }
    return parseSkcodeDigestBody(resp.data);
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

  /// `GET /skcode/api/v1/dispatch/targets` (spec 3.1, card C-6): the
  /// advisory options a dispatch-scoped device may render in a New Session
  /// form. EVERY value this client's dispatch form offers for
  /// repo/harness/profile/model comes from parsing this one response
  /// (`SkcodeDispatchTargets.fromJson`, see that class's own doc comment for
  /// the no-hardcoded-fallback rule) -- this method adds nothing on top of
  /// it.
  Future<SkcodeDispatchTargets> fetchDispatchTargets({required String token}) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        "/skcode/api/v1/dispatch/targets",
        options: _bearer(token),
      );
      return SkcodeDispatchTargets.fromJson(resp.data ?? const {});
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `POST /skcode/api/v1/dispatch` (spec 3.1, card C-6): spawn a new
  /// session. [repo]/[branch]/[model] may be empty strings (the server
  /// accepts and defaults them, `daemon.py::dispatch_route`); every argument
  /// here is exactly what the caller chose from [fetchDispatchTargets]'s
  /// response (or, for [branch]/[permissionMode]/[mode]/[prompt], the
  /// protocol-level fields that are not part of the targets response at
  /// all -- see `skcode_dispatch_form.dart`'s doc comment for which fields
  /// fall in which bucket). This method performs no allowlist check of its
  /// own: the repo allowlist is enforced server-side only, by design (card
  /// C-6 non-negotiable).
  ///
  /// Throws [SkcodeDispatchForbiddenException] on a 403 (PDP denied) and
  /// [SkcodeApiException] on a 400 (spawn rejected, e.g. a stale/altered
  /// repo choice the server no longer allows) with the server's own detail
  /// message surfaced verbatim, so the form can render a clear state for
  /// each rather than a bare "request failed".
  Future<SkcodeDispatchResult> dispatch({
    required String repo,
    required String branch,
    required String profile,
    required String permissionMode,
    required String mode,
    required String prompt,
    required String harness,
    required String model,
    required String token,
  }) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        "/skcode/api/v1/dispatch",
        data: {
          "repo": repo,
          "branch": branch,
          "profile": profile,
          "permission_mode": permissionMode,
          "mode": mode,
          "prompt": prompt,
          "harness": harness,
          "model": model,
        },
        options: _bearer(token),
      );
      return SkcodeDispatchResult.fromJson(resp.data ?? const {});
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 403) {
        throw SkcodeDispatchForbiddenException(_detail(e) ?? "dispatch not authorized");
      }
      if (status == 400) {
        throw SkcodeApiException(_detail(e) ?? "dispatch rejected");
      }
      throw _wrap(e);
    }
  }

  /// `POST /skcode/api/v1/sessions/{sid}/cancel` (spec section 8, card
  /// C-6): idempotent by construction on the server
  /// (`daemon.py::cancel_session`) -- an unknown or already-finished [sid]
  /// answers 200 with `{"cancelled": false, "reason": ...}` rather than an
  /// error, so this method only throws for a genuine transport/auth/authz
  /// failure (401/403/network), never for "there was nothing to cancel".
  /// Rides the SAME `skcode.dispatch` scope + PDP decision path as
  /// [dispatch] (spec: "cancel ... rides the dispatch scope through the
  /// same PDP decision path as dispatch and inject"), so a 403 here means
  /// exactly what it means on [dispatch]: scope present, PDP said no.
  Future<SkcodeCancelResult> cancelSession(String sid, {required String token}) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        "/skcode/api/v1/sessions/$sid/cancel",
        options: _bearer(token),
      );
      return SkcodeCancelResult.fromJson(resp.data ?? const {});
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        throw SkcodeDispatchForbiddenException(_detail(e) ?? "cancel not authorized");
      }
      throw _wrap(e);
    }
  }

  /// Pulls FastAPI's `{"detail": "..."}` error body out of a [DioException],
  /// when present, so a 400/403 can surface the server's OWN reason
  /// (`HTTPException(403, "dispatch not authorized")` etc.) rather than a
  /// generic client-invented message.
  String? _detail(DioException e) {
    final data = e.response?.data;
    if (data is Map && data["detail"] is String) return data["detail"] as String;
    return null;
  }

  Exception _wrap(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return const SkcodeUnauthorizedException();
    return SkcodeApiException(e.message ?? "skcode-hostd request failed");
  }
}
