import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// ClusterService — a second native client (alongside skbloom's own web UI) to
/// skbloom's EXISTING JSON/SSE control-plane API.
///
/// skbloom serves a `ThreadingHTTPServer` (see `skbloom/web/server.py`) that
/// projects its app-store + day-2 control plane over plain HTTP so a non-Python
/// client — explicitly, "the skchat Flutter Cluster-control module" — can drive
/// the sovereign stack:
///
///   GET  /api/services            list deployable services (+ tunables/secrets)
///   GET  /api/status              installed stacks (from ~/.skbloom/*.json)
///   POST /api/propose  {intent}   concierge plan for a natural-language intent
///   POST /api/up       {profile}  install flow — **SSE** step-progress stream
///   GET  /api/health?cluster=     live per-service readiness (kubectl)
///   POST /api/restart  {svc}      roll-restart a service deployment
///   POST /api/scale    {svc,n}    scale a service deployment
///   GET  /api/logs?cluster&svc    **SSE** log line stream
///
/// NO backend work happens here — this is purely a typed Dart consumer. The
/// base URL is the runtime-settable [BackendConfig.clusterUrl] (default
/// `http://localhost:8774`); never hard-coded.
/// ─────────────────────────────────────────────────────────────────────────
class ClusterService {
  ClusterService({Dio? dio, required String baseUrl})
      : _dio = dio ?? Dio(),
        _base = baseUrl;

  final Dio _dio;
  final String _base;

  // ── plain JSON reads ──────────────────────────────────────────────────────

  /// `GET /api/services` → the catalog of deployable services.
  Future<List<ClusterServiceDef>> listServices() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/api/services');
    final list = (r.data?['services'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return list.map(ClusterServiceDef.fromJson).toList();
  }

  /// `GET /api/status` → installed stacks reconstructed from the state files.
  Future<List<ClusterStack>> status() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/api/status');
    final list = (r.data?['clusters'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return list.map(ClusterStack.fromJson).toList();
  }

  /// `GET /api/health?cluster=` → live per-service readiness (fail-soft `[]`).
  Future<List<ServiceHealth>> health({String cluster = 'skbloom'}) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/api/health',
      queryParameters: {'cluster': cluster},
    );
    final list = (r.data?['services'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return list.map(ServiceHealth.fromJson).toList();
  }

  // ── plain JSON writes ─────────────────────────────────────────────────────

  /// `POST /api/propose {intent}` → the concierge's plan for a NL intent.
  Future<ClusterProposal> propose(String intent,
      {String cluster = 'skbloom'}) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/propose',
      data: {'intent': intent, 'cluster': cluster},
    );
    return ClusterProposal.fromJson(r.data ?? const {});
  }

  /// `POST /api/restart {cluster, service}` → roll-restart a deployment.
  Future<ClusterActionResult> restart(String service,
      {String cluster = 'skbloom'}) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/restart',
      data: {'cluster': cluster, 'service': service},
    );
    return ClusterActionResult.fromJson(r.data ?? const {});
  }

  /// `POST /api/scale {cluster, service, replicas}` → scale a deployment.
  Future<ClusterActionResult> scale(String service, int replicas,
      {String cluster = 'skbloom'}) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/scale',
      data: {'cluster': cluster, 'service': service, 'replicas': replicas},
    );
    return ClusterActionResult.fromJson(r.data ?? const {});
  }

  // ── SSE streams ───────────────────────────────────────────────────────────

  /// `POST /api/up` → the install flow as a Server-Sent-Events step stream.
  ///
  /// skbloom emits one `data: {json}\n\n` frame per named step (see
  /// `_stream_up`). Each frame is decoded into an [UpEvent]. The stream
  /// completes when the response body ends.
  Stream<UpEvent> up(ClusterProfile profile) {
    return _sse(
      method: 'POST',
      path: '/api/up',
      body: profile.toJson(),
    ).map((frame) => UpEvent.fromJson(_decodeFrame(frame)));
  }

  /// `GET /api/logs?cluster&service` → a Server-Sent-Events log-line stream.
  ///
  /// Each frame is `data: "<line>"\n\n` (a JSON-encoded string).
  Stream<String> logs(String service, {String cluster = 'skbloom'}) {
    return _sse(
      method: 'GET',
      path: '/api/logs',
      query: {'cluster': cluster, 'service': service},
    ).map((frame) {
      final decoded = jsonDecode(frame);
      return decoded is String ? decoded : frame;
    });
  }

  /// Core SSE consumer: opens a streamed dio response, reassembles the byte
  /// chunks into lines, and yields the JSON payload of each `data:` field. A
  /// blank line terminates an event (per the SSE spec); skbloom emits exactly
  /// one `data:` line per event so we yield on each `data:` directly.
  Stream<String> _sse({
    required String method,
    required String path,
    Map<String, dynamic>? query,
    Object? body,
  }) async* {
    final resp = await _dio.request<ResponseBody>(
      '$_base$path',
      data: body,
      queryParameters: query,
      options: Options(
        method: method,
        responseType: ResponseType.stream,
        headers: {'Accept': 'text/event-stream'},
      ),
    );
    final stream = resp.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in stream) {
      if (line.startsWith('data:')) {
        yield line.substring(5).trimLeft();
      }
    }
  }

  /// The `data:` payload of an `/api/up` frame is the JSON object directly.
  Map<String, dynamic> _decodeFrame(String frame) {
    final decoded = jsonDecode(frame);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Models — mirror the shapes produced by skbloom/web/server.py.
// ─────────────────────────────────────────────────────────────────────────

/// One row of `GET /api/services`.
class ClusterServiceDef {
  const ClusterServiceDef({
    required this.name,
    required this.capability,
    required this.provider,
    required this.ha,
    required this.minReplicas,
    required this.config,
    required this.secrets,
  });

  final String name;
  final String capability;
  final String provider;
  final bool ha;
  final int minReplicas;

  /// Tunable knobs (key → default) for the tune panel.
  final Map<String, dynamic> config;

  /// Secret KEY names only (skbloom never sends values).
  final List<String> secrets;

  factory ClusterServiceDef.fromJson(Map<String, dynamic> j) =>
      ClusterServiceDef(
        name: (j['name'] ?? '') as String,
        capability: (j['capability'] ?? '') as String,
        provider: (j['provider'] ?? '') as String,
        ha: (j['ha'] ?? false) as bool,
        minReplicas: (j['min_replicas'] ?? 1) as int,
        config: (j['config'] as Map?)?.cast<String, dynamic>() ?? const {},
        secrets:
            (j['secrets'] as List<dynamic>? ?? const []).cast<String>(),
      );
}

/// One installed stack from `GET /api/status`.
class ClusterStack {
  const ClusterStack({
    required this.cluster,
    required this.stepsDone,
    required this.complete,
    required this.services,
  });

  final String cluster;
  final int stepsDone;
  final bool complete;
  final List<DeployedService> services;

  factory ClusterStack.fromJson(Map<String, dynamic> j) => ClusterStack(
        cluster: (j['cluster'] ?? '') as String,
        stepsDone: (j['steps_done'] ?? 0) as int,
        complete: (j['complete'] ?? false) as bool,
        services: (j['services'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(DeployedService.fromJson)
            .toList(),
      );
}

/// A deployed service entry inside a [ClusterStack].
class DeployedService {
  const DeployedService({required this.name, this.url});

  final String name;
  final String? url;

  factory DeployedService.fromJson(Map<String, dynamic> j) => DeployedService(
        name: (j['name'] ?? '') as String,
        url: j['url'] as String?,
      );
}

/// One row of `GET /api/health`.
class ServiceHealth {
  const ServiceHealth({
    required this.name,
    required this.ready,
    required this.total,
    required this.healthy,
  });

  final String name;
  final int ready;
  final int total;
  final bool healthy;

  factory ServiceHealth.fromJson(Map<String, dynamic> j) => ServiceHealth(
        name: (j['name'] ?? '') as String,
        ready: (j['ready'] ?? 0) as int,
        total: (j['total'] ?? 0) as int,
        healthy: (j['healthy'] ?? false) as bool,
      );
}

/// The result of `POST /api/propose`.
class ClusterProposal {
  const ClusterProposal({
    required this.reply,
    required this.cluster,
    required this.services,
    required this.plan,
    required this.rotationSecrets,
    required this.rotationCerts,
    required this.rotationAllAutomatic,
  });

  /// The concierge's natural-language reply.
  final String reply;

  /// Proposed cluster name.
  final String cluster;

  /// Proposed service list.
  final List<String> services;

  /// The named-step plan (no side effects — a dry run).
  final List<String> plan;

  final int rotationSecrets;
  final int rotationCerts;
  final bool rotationAllAutomatic;

  /// Build the [ClusterProfile] this proposal implies (fed to `/api/up`).
  ClusterProfile toProfile({bool tls = false, List<String> seed = const []}) =>
      ClusterProfile(cluster: cluster, services: services, tls: tls, seed: seed);

  factory ClusterProposal.fromJson(Map<String, dynamic> j) {
    final profile = (j['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rotation =
        (j['rotation'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ClusterProposal(
      reply: (j['reply'] ?? '') as String,
      cluster: (profile['cluster'] ?? 'skbloom') as String,
      services:
          (profile['services'] as List<dynamic>? ?? const []).cast<String>(),
      plan: (j['plan'] as List<dynamic>? ?? const []).cast<String>(),
      rotationSecrets: (rotation['secrets'] ?? 0) as int,
      rotationCerts: (rotation['certs'] ?? 0) as int,
      rotationAllAutomatic: (rotation['all_automatic'] ?? false) as bool,
    );
  }
}

/// The install profile POSTed to `/api/up`.
class ClusterProfile {
  const ClusterProfile({
    required this.cluster,
    required this.services,
    this.tls = false,
    this.seed = const [],
    this.configOverrides = const {},
  });

  final String cluster;
  final List<String> services;
  final bool tls;
  final List<String> seed;
  final Map<String, dynamic> configOverrides;

  Map<String, dynamic> toJson() => {
        'cluster': cluster,
        'services': services,
        'tls': tls,
        'seed': seed,
        'config_overrides': configOverrides,
      };
}

/// One SSE step-event frame from `/api/up` (shape produced by `iter_steps`).
class UpEvent {
  const UpEvent({required this.step, required this.status, this.detail, this.raw = const {}});

  /// The named step (e.g. `deploy:postgres`).
  final String step;

  /// Step status (e.g. `start`, `ok`, `error`, `done`).
  final String status;

  /// Optional human-readable detail / message.
  final String? detail;

  /// The full decoded frame (for fields we don't model explicitly).
  final Map<String, dynamic> raw;

  bool get isError => status.toLowerCase() == 'error' || raw['error'] != null;

  factory UpEvent.fromJson(Map<String, dynamic> j) => UpEvent(
        step: (j['step'] ?? j['name'] ?? '') as String,
        status: (j['status'] ?? j['event'] ?? '') as String,
        detail: (j['detail'] ?? j['message'] ?? j['error']) as String?,
        raw: j,
      );
}

/// The `{ok, output}` envelope from restart/scale.
class ClusterActionResult {
  const ClusterActionResult({required this.ok, required this.output});

  final bool ok;
  final String output;

  factory ClusterActionResult.fromJson(Map<String, dynamic> j) =>
      ClusterActionResult(
        ok: (j['ok'] ?? false) as bool,
        output: (j['output'] ?? '') as String,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Provider — repoints live when the user changes the cluster base URL.
// ─────────────────────────────────────────────────────────────────────────

final clusterServiceProvider = Provider<ClusterService>((ref) {
  final base = ref.watch(backendConfigProvider.select((c) => c.clusterUrl));
  return ClusterService(baseUrl: base);
});
