// Me > Logs, half 2: server-reported service health.
//
// GET /api/v1/health, against the fixed contract:
//
//   {"generated_at": "2026-08-16T12:00:00Z",
//    "services": [{"id":"stt","label":"Speech to text","state":"up",
//                   "detail":"200 in 34ms","latency_ms":34,
//                   "checked_at":"2026-08-16T12:00:00Z"}]}
//
// `state` is exactly `up` | `down` | `unknown`. Known ids: stt, tts, llm,
// sfu, webui (built in parallel against this endpoint as of card
// b62da57c's Me > Logs follow-up; it may 404 if the server side has not
// landed yet).
//
// HONESTY RULES this file exists to enforce (never soften these):
//
//  1. Never show green the client did not verify. A network failure (the
//     client cannot reach the server at all) and a 404 (the endpoint isn't
//     deployed yet) BOTH collapse to [HealthUnavailable] here, which the UI
//     renders as every known service `unknown`, never `up` and never a
//     silently-empty section. A response this service cannot parse into the
//     contract shape is treated the same way, defensively -- an
//     unrecognized document is not evidence of health either.
//  2. A `state` value the server sends that is not exactly "up" or "down"
//     parses to [ServiceHealthState.unknown], never defaulted to `up`. Only
//     the literal strings "up" and "down" ever produce those states.
//  3. [HealthUnavailable] carries WHY (unreachable vs not-yet-deployed vs
//     unparseable) so the screen can say something honest rather than a
//     generic "error".
//
// The unreachable/not-deployed placeholder rows use [kKnownServiceLabels]
// for a human label (there is no server data to read one from yet); a real
// response's own `label` field is always preferred once one exists.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'diag/diag_error_sink.dart';
import 'diag/diag_interceptor.dart';

/// Verified-by-the-client-or-not state of one service. Three states, three
/// meanings -- never conflate `unknown` with either `up` or `down`:
///  - `up`: the server told us so, just now (see [ServiceHealth.checkedAt]).
///  - `down`: the server told us so, just now.
///  - `unknown`: nobody has verified this recently, or at all. This is the
///    ONLY legal state when the client cannot reach the server, or the
///    server sent something this client cannot make sense of.
enum ServiceHealthState { up, down, unknown }

ServiceHealthState _parseState(Object? raw) {
  switch (raw) {
    case 'up':
      return ServiceHealthState.up;
    case 'down':
      return ServiceHealthState.down;
    default:
      // Covers the literal "unknown", any other string, and a missing/
      // malformed value alike: only "up" and "down" are ever trusted.
      return ServiceHealthState.unknown;
  }
}

/// Human labels for the 5 known service ids, used ONLY when there is no
/// server-reported row to read a label from (the unreachable / not-deployed
/// placeholder list). A real `/api/v1/health` response's own `label` field
/// always wins once the server has spoken.
const Map<String, String> kKnownServiceLabels = {
  'stt': 'Speech to text',
  'tts': 'Text to speech',
  'llm': 'Language model',
  'sfu': 'Calling',
  'webui': 'Server',
};

/// Stable id order for the placeholder list, matching the task contract.
const List<String> kKnownServiceIds = ['stt', 'tts', 'llm', 'sfu', 'webui'];

/// One row of `GET /api/v1/health`'s `services` array.
class ServiceHealth {
  const ServiceHealth({
    required this.id,
    required this.label,
    required this.state,
    required this.checkedAt,
    this.detail,
    this.latencyMs,
  });

  final String id;
  final String label;
  final ServiceHealthState state;

  /// When THIS row was last checked. Always shown by the UI (honesty rule
  /// 3: "show the timestamp of the data, make stale data obviously stale").
  final DateTime checkedAt;

  /// Short human string from the server, e.g. "200 in 34ms". Never a raw
  /// exception or stack trace -- that is a server-side contract, not
  /// something this client can enforce, but nothing here fabricates one
  /// either.
  final String? detail;
  final int? latencyMs;

  factory ServiceHealth.fromJson(Map<String, dynamic> j, DateTime fallbackAt) {
    final id = j['id'] as String? ?? '';
    return ServiceHealth(
      id: id,
      label: (j['label'] as String?)?.trim().isNotEmpty == true
          ? j['label'] as String
          : (kKnownServiceLabels[id] ?? id),
      state: _parseState(j['state']),
      checkedAt: _parseTime(j['checked_at']) ?? fallbackAt,
      detail: j['detail'] as String?,
      latencyMs: (j['latency_ms'] as num?)?.toInt(),
    );
  }

  /// A placeholder row for [id] when there is no server data at all: state
  /// unknown, "checked" now (the moment the CLIENT gave up trying), no
  /// detail claimed. Used by [HealthUnavailable.placeholderServices].
  factory ServiceHealth.unknownPlaceholder(String id, DateTime asOf) =>
      ServiceHealth(
        id: id,
        label: kKnownServiceLabels[id] ?? id,
        state: ServiceHealthState.unknown,
        checkedAt: asOf,
      );
}

DateTime? _parseTime(Object? raw) {
  if (raw is! String) return null;
  try {
    return DateTime.parse(raw).toUtc();
  } catch (_) {
    return null;
  }
}

/// A successfully parsed `/api/v1/health` document.
class HealthReport {
  const HealthReport({required this.generatedAt, required this.services});

  final DateTime generatedAt;
  final List<ServiceHealth> services;
}

/// Why [HealthResult] has no [HealthReport] this fetch.
enum HealthUnavailableReason {
  /// The client could not reach the server at all (DNS/refused/timeout/TLS/
  /// any transport-level failure). Honesty rule 1: this must read as "the
  /// APP cannot reach the server", not as a per-service outage.
  unreachable,

  /// The server answered but `/api/v1/health` itself 404s -- the endpoint
  /// has not been deployed yet (it is being built in parallel). Distinct
  /// from [unreachable] because the server IS reachable; only this one
  /// route is missing.
  notDeployed,

  /// The server answered 2xx but the body could not be parsed into the
  /// contract shape. Treated with the same "everything unknown" rendering
  /// as the other two -- an unparseable document is not evidence of health.
  unparseable,
}

/// The result of one health fetch: either a real [HealthReport], or
/// [HealthUnavailable] naming why there isn't one. There is deliberately no
/// third "partial" shape -- a fetch either produced a document this client
/// trusts, or it produced nothing trustworthy, in which case every service
/// renders unknown (never a mix that could look more confident than it is).
sealed class HealthResult {
  const HealthResult();
}

class HealthAvailable extends HealthResult {
  const HealthAvailable(this.report);
  final HealthReport report;
}

class HealthUnavailable extends HealthResult {
  const HealthUnavailable({required this.reason, required this.checkedAt});

  final HealthUnavailableReason reason;

  /// When the client gave up (now, from its own clock) -- there is no
  /// server timestamp to show, so this is what "stale" gets measured
  /// against for the unavailable banner.
  final DateTime checkedAt;

  /// Every known service, rendered `unknown` as of [checkedAt]. This is the
  /// list the screen renders for ANY unavailable reason: unreachable,
  /// not-yet-deployed, and unparseable all produce the identical "nothing
  /// verified" row set, by construction, so there is no code path where one
  /// of those three quietly renders differently from the others.
  List<ServiceHealth> get placeholderServices => [
        for (final id in kKnownServiceIds)
          ServiceHealth.unknownPlaceholder(id, checkedAt),
      ];
}

/// Talks to `GET {webui}/api/v1/health`. See file doc for the honesty
/// contract every branch of [fetch] upholds.
class HealthService {
  HealthService({Dio? dio, String? webuiBaseUrl, DateTime Function()? now})
      : _dio = dio ?? Dio(),
        _base = _strip(webuiBaseUrl ?? kDefaultSkchatWebuiUrl),
        _now = now ?? DateTime.now {
    // Network breadcrumbs, same placement as every other daemon-facing
    // client in this codebase (diag_interceptor.dart's own doc).
    _dio.interceptors.add(buildDiagInterceptor(emitDiagEvent));
  }

  final Dio _dio;
  final String _base;
  final DateTime Function() _now;

  static String _strip(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  Future<HealthResult> fetch() async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>('$_base/api/v1/health');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) {
        return HealthUnavailable(
          reason: HealthUnavailableReason.notDeployed,
          checkedAt: _now(),
        );
      }
      // Every other DioException (connect timeout, refused, DNS, TLS,
      // 5xx, cancel, unknown, ...) is "the app cannot reach the server"
      // from the operator's point of view -- honesty rule 1, not split
      // into finer client-visible categories here.
      return HealthUnavailable(
        reason: HealthUnavailableReason.unreachable,
        checkedAt: _now(),
      );
    } catch (_) {
      return HealthUnavailable(
        reason: HealthUnavailableReason.unreachable,
        checkedAt: _now(),
      );
    }

    final body = response.data;
    if (body is! Map) {
      return HealthUnavailable(
        reason: HealthUnavailableReason.unparseable,
        checkedAt: _now(),
      );
    }
    final map = body.cast<String, dynamic>();
    final generatedAt = _parseTime(map['generated_at']) ?? _now();
    final rawServices = map['services'];
    if (rawServices is! List) {
      return HealthUnavailable(
        reason: HealthUnavailableReason.unparseable,
        checkedAt: _now(),
      );
    }
    final services = rawServices
        .whereType<Map>()
        .map((m) => ServiceHealth.fromJson(m.cast<String, dynamic>(), generatedAt))
        .toList();
    return HealthAvailable(HealthReport(generatedAt: generatedAt, services: services));
  }
}

/// Health service repointed live by the runtime backend config, same
/// pattern as `recordingsServiceProvider` / `deviceListServiceProvider`.
final healthServiceProvider = Provider<HealthService>((ref) {
  final base = ref.watch(backendConfigProvider.select((c) => c.skchatWebuiUrl));
  return HealthService(webuiBaseUrl: base);
});
