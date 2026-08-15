// Network breadcrumbs: the dio diagnostic interceptor.
//
// See docs/superpowers/specs/2026-08-14-client-observability-ai-support-design.md
// section 4.3 (interceptor behavior) and section 3 Decision 3 (the failure
// kind classification this exists to produce). Coord card 270ea324.
//
// THE POINT: the incident that motivated this whole design produced
// `ERROR skchat.voice_engine.stt: STT failed:` five times, because
// `str()` on an httpx connect timeout is EMPTY. A caught exception's
// MESSAGE is not a reliable diagnostic signal; its TYPE is. This
// interceptor classifies failures at the `DioExceptionType` / underlying
// exception TYPE level and never reads `.toString()` or `.message` from
// the failure into anything that leaves it, so a client-side connect
// timeout against a dead dependency survives as `kind: connectTimeout,
// host: ..., port: ...` instead of an empty string.
//
// Shape follows `operator_auth_interceptor.dart`: a small, pure,
// independently-testable top-level function per concern
// (`classifyNetFailure`, `pathTemplate`) plus one `InterceptorsWrapper`
// factory, fail-open throughout (a diagnostics bug must never fail the
// request it is observing, spec section 6).
//
// EMIT SEAM: `buildDiagInterceptor` takes a plain
// `void Function(DiagEvent event) emit` callback rather than any reference
// to `DiagLog` (the ring buffer, `diag_log.dart`). That file is being
// written concurrently on its own branch as of this card; this interceptor
// does not import it or depend on its shape. Wiring
// `dio.interceptors.add(buildDiagInterceptor(diagLog.emit))` (or whatever
// the ring buffer's real emit method ends up being called) is left to
// whoever lands that card and the per-client wiring into skcomms_client,
// device_list_service, skcapstone_client, pq_prekey_service etc (spec 4.3
// lists those call sites; out of scope here per the card, "the interceptor
// only").

import 'package:dio/dio.dart';

import 'diag_event.dart';
import 'diag_net_classify.dart';

/// Extra-map key holding this request's [_DiagRequestState]. Set once in
/// [buildDiagInterceptor]'s `onRequest`, kept across an auth-retry because
/// `buildOperatorAuthInterceptor`'s retry builds its replay via
/// `options.copyWith(extra: {...options.extra, ...})`, which copies the
/// VALUE (a reference to the same mutable [_DiagRequestState] instance) into
/// the new extra map. That shared reference is what makes the "exactly one
/// event per failed request, no duplicates on retry" guarantee work: the
/// retried request and the original both see the same state object.
const _kDiagStateKey = 'skDiagRequestState';

/// Per-logical-request state: when it started (for `durationMs`, measured
/// end to end across an auth retry) and whether a `net.request_failed`
/// event has already been emitted for it.
class _DiagRequestState {
  _DiagRequestState(this.startedAt);
  final DateTime startedAt;
  bool emitted = false;
}

/// A path segment that looks like an identifier rather than a fixed route
/// keyword: all-digits, a UUID, or 8+ hex characters (covers numeric ids,
/// UUIDs, and hex ids/fingerprints like a device fingerprint or short group
/// id). Anything else is assumed to be a stable route keyword (`api`, `v1`,
/// `messages`, `health`, `deps`, ...) and left as-is.
final RegExp _identifierSegment = RegExp(
  r'^(?:[0-9]+'
  r'|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  r'|[0-9a-fA-F]{8,})$',
);

/// Reduces a concrete request URI to its path TEMPLATE: every identifier-
/// shaped segment becomes `:id`, everything else is left alone. Built from
/// [Uri.pathSegments], which never includes the query string, so a
/// pathTemplate can never carry query parameters (spec Decision 3, "never
/// query strings").
///
/// Examples: `/api/v1/messages/12345/read` -> `/api/v1/messages/:id/read`;
/// `/api/v1/devices/d4f3281efa92` -> `/api/v1/devices/:id`;
/// `/api/v1/health/deps` -> unchanged (no identifier-shaped segment).
String pathTemplate(Uri uri) {
  if (uri.pathSegments.isEmpty) {
    return uri.path.isEmpty ? '/' : uri.path;
  }
  final templated = uri.pathSegments
      .map((segment) => _identifierSegment.hasMatch(segment) ? ':id' : segment)
      .join('/');
  return '/$templated';
}

/// Classifies a [DioException] into the failure kind enum (spec Decision 3),
/// derived ONLY from `DioExceptionType` and, for `connectionError`/`unknown`,
/// the underlying error's TYPE (never `Exception.message`, never
/// `.toString()`). This is the actual fix for the empty `str(e)` incident:
/// a kind enum cannot be empty the way a caught-exception string can.
NetFailureKind classifyNetFailure(DioException err) {
  switch (err.type) {
    case DioExceptionType.connectionTimeout:
      return NetFailureKind.connectTimeout;
    case DioExceptionType.sendTimeout:
      // DioExceptionType has no distinct "write timeout" bucket and neither
      // does the spec's NetFailureKind enum (fixed, not ours to change): a
      // send timeout means the client could not push the request in time,
      // which is a connection-establishment-class stall, grouped with
      // connectTimeout rather than readTimeout (which means "we sent and
      // got no reply").
      return NetFailureKind.connectTimeout;
    case DioExceptionType.receiveTimeout:
      return NetFailureKind.readTimeout;
    case DioExceptionType.transformTimeout:
      // Occurs after data has already started arriving (stalled decoding
      // a received response), so it groups with readTimeout rather than
      // connectTimeout for the same reason receiveTimeout does.
      return NetFailureKind.readTimeout;
    case DioExceptionType.badCertificate:
      return NetFailureKind.tls;
    case DioExceptionType.badResponse:
      final status = err.response?.statusCode;
      if (status != null && status >= 400 && status < 500) {
        return NetFailureKind.http4xx;
      }
      if (status != null && status >= 500 && status < 600) {
        return NetFailureKind.http5xx;
      }
      return NetFailureKind.unknown;
    case DioExceptionType.cancel:
      return NetFailureKind.aborted;
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
      return classifyUnderlyingError(err.error);
  }
}

/// Builds the network-breadcrumb diagnostic interceptor. Attach it
/// immediately AFTER `buildOperatorAuthInterceptor` on every daemon Dio
/// client (spec 4.3), same as that interceptor is attached today.
///
/// On a failed request it emits exactly ONE `net.request_failed` [DiagEvent]
/// via [emit], carrying the classified [NetFailureKind] plus `host`, `port`,
/// [pathTemplate] (never the concrete path), `method`, optional `status`,
/// and `durationMs`. It NEVER records query strings, headers or bodies:
/// nothing in this file ever reads `options.queryParameters`,
/// `options.headers`, `options.data`, or the full `Uri` (only `.host`,
/// `.port` and `.pathSegments`).
///
/// Fail-open like the auth interceptor: any exception raised while
/// classifying or emitting is swallowed so a diagnostics bug can never fail
/// the request it is observing. `handler.next(...)` is always called with
/// the ORIGINAL request/error, unmodified; this interceptor only observes.
InterceptorsWrapper buildDiagInterceptor(void Function(DiagEvent event) emit) {
  // Session-local sequence counter. `DiagEvent.seq` is documented (see
  // diag_event.dart) as "assigned by the caller (the ring buffer, in a
  // later card)" -- this interceptor has no ring buffer to defer to yet, so
  // it assigns a local placeholder sequence scoped to THIS interceptor
  // instance. Whoever wires in the real `DiagLog` is free to renumber (or
  // ignore) it; nothing here assumes this counter is session-global.
  var seq = 0;

  return InterceptorsWrapper(
    onRequest: (options, handler) {
      try {
        options.extra[_kDiagStateKey] ??= _DiagRequestState(DateTime.now());
      } catch (_) {
        // Never block the request over a diagnostics bookkeeping failure.
      }
      return handler.next(options);
    },
    onError: (err, handler) {
      try {
        _recordFailure(err, emit, () => seq++);
      } catch (_) {
        // Never let a diagnostics bug surface as (or mask) the real error.
      }
      return handler.next(err);
    },
  );
}

void _recordFailure(
  DioException err,
  void Function(DiagEvent event) emit,
  int Function() nextSeq,
) {
  final options = err.requestOptions;
  final state = options.extra[_kDiagStateKey] as _DiagRequestState?;

  // Same logical request already recorded (the auth interceptor's retry
  // path re-enters this interceptor's onRequest/onError a second time for
  // the SAME shared _DiagRequestState, see the field doc above). Skip: one
  // event per failed request, not one per HTTP round trip underneath it.
  if (state != null && state.emitted) {
    return;
  }

  final uri = options.uri;
  final durationMs = state == null
      ? 0
      : DateTime.now().difference(state.startedAt).inMilliseconds;
  final status = err.response?.statusCode;

  final fields = <String, Object>{
    'kind': classifyNetFailure(err),
    'host': uri.host,
    'port': uri.port,
    'pathTemplate': pathTemplate(uri),
    'method': options.method,
    'durationMs': durationMs,
    'status': ?status,
  };

  // Mark BEFORE constructing/emitting: a malformed event (should not
  // happen, the catalog above matches diag_codes.dart exactly) must not
  // leave the dedupe guard open for a retry to double-fire.
  state?.emitted = true;

  final event = DiagEvent.tryCreate(
    seq: nextSeq(),
    ts: DateTime.now(),
    level: DiagLevel.error,
    category: DiagCategory.net,
    code: 'net.request_failed',
    fields: fields,
  );
  if (event != null) {
    emit(event);
  }
}
