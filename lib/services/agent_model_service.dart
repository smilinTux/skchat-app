import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_config.dart';

/// A selectable reply model advertised by the skchat daemon's catalog.
///
/// The current daemon shape (`catalog.models`) carries only `id`, `provider`
/// and `free`, no `label`. The old back-compat shape (`available`) carries
/// `id`, `label`, `provider`, `local`. Both parse into this one class; use
/// [displayLabel] to get text for the UI regardless of which shape sent it.
class AgentModel {
  const AgentModel({
    required this.id,
    required this.provider,
    this.label,
    this.local = false,
    this.free,
  });

  final String id;
  final String provider;

  /// Only present on the old `available` shape; null on the new catalog.
  final String? label;

  /// Only meaningful on the old `available` shape (new catalog has no
  /// concept of "local" at the model level, roles resolve to a backend).
  final bool local;

  /// Only present on the new catalog shape: true when SKGateway serves this
  /// model at no cost.
  final bool? free;

  /// Text to show in the picker: the server label when present (old shape),
  /// otherwise the raw model id (new catalog shape, id is display-ready).
  String get displayLabel => label ?? id;

  factory AgentModel.fromJson(Map<String, dynamic> j) => AgentModel(
        id: j['id'] as String? ?? '',
        // The gateway `/v1/models` catalog labels the source as `provider`;
        // some entries carry only OpenAI-style `owned_by`. Fall back to it so
        // the picker still shows nvidia/openrouter/etc.
        provider: (j['provider'] as String?)?.trim().isNotEmpty == true
            ? (j['provider'] as String)
            : (j['owned_by'] as String? ?? ''),
        label: j['label'] as String?,
        local: j['local'] as bool? ?? false,
        free: j['free'] as bool?,
      );
}

/// Filters [models] to only free-flagged entries when [freeOnly] is true;
/// returns the list unchanged when false. Pure (no widget/Riverpod deps) so
/// the picker's "Free only" toggle is unit-testable over a fake catalog.
List<AgentModel> filterModelsByFree(
  List<AgentModel> models, {
  required bool freeOnly,
}) {
  if (!freeOnly) return models;
  return models.where((m) => m.free == true).toList();
}

/// The roles and models an agent's selection can be set to.
class AgentCatalog {
  const AgentCatalog({this.roles = const [], this.models = const []});

  final List<String> roles;
  final List<AgentModel> models;

  factory AgentCatalog.fromJson(Map<String, dynamic> j) => AgentCatalog(
        roles: (j['roles'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        models: (j['models'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AgentModel.fromJson)
            .toList(),
      );
}

/// The current selection for an agent (a role or a concrete model) plus the
/// catalog of roles/models it can be set to.
class AgentModelState {
  const AgentModelState({
    required this.agent,
    required this.selection,
    required this.catalog,
    this.kind = 'model',
    this.resolvedModel,
    this.stale = false,
  });

  final String agent;

  /// The currently active role name or model id.
  final String selection;

  /// `'role'` or `'model'`, classifies [selection].
  final String kind;

  /// Best-effort concrete model [selection] resolves to (a role resolves
  /// through skos.models; a direct model selection resolves to itself).
  final String? resolvedModel;

  final AgentCatalog catalog;

  /// True when SKGateway returned no models this round (roles/skos are
  /// unaffected), so the "Models" half of the picker may be stale.
  final bool stale;

  /// Back-compat accessor for the pre-catalog `model` field.
  String get model => selection;

  /// Back-compat accessor for the pre-catalog flat `available` list.
  List<AgentModel> get available => catalog.models;
}

/// The public-safe curated card for a model (the gateway model dex). Carried
/// on `/v1/models` (and so through the daemon), minus the operator-internal
/// `notes` which the gateway strips before the funnel. Every field is
/// optional: a model with no curated card simply has `card == null`.
class ModelCard {
  const ModelCard({
    this.displayName,
    this.org,
    this.summary,
    this.goodAt = const [],
    this.tier,
    this.contextLength,
    this.maxOutputTokens,
    this.supportedParameters = const [],
    this.modality,
    this.params,
    this.quant,
    this.speed,
    this.license,
  });

  final String? displayName;
  final String? org;
  final String? summary;
  final List<String> goodAt;
  final String? tier; // local | free-remote | paid-cloud
  final int? contextLength;
  final int? maxOutputTokens;
  final List<String> supportedParameters;
  final String? modality;
  final String? params;
  final String? quant;
  final String? speed;
  final String? license;

  bool get tools => supportedParameters.contains('tools');
  bool get vision => (modality ?? '').contains('image');

  factory ModelCard.fromJson(Map<String, dynamic> j) => ModelCard(
        displayName: j['display_name'] as String?,
        org: j['org'] as String?,
        summary: j['summary'] as String?,
        goodAt: (j['good_at'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        tier: j['tier'] as String?,
        contextLength: (j['context_length'] as num?)?.toInt(),
        maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt(),
        supportedParameters: (j['supported_parameters'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        modality: j['modality'] as String?,
        params: (j['params'] ?? j['size']) as String?,
        quant: j['quant'] as String?,
        speed: j['speed'] as String?,
        license: j['license'] as String?,
      );
}

/// A discovered gateway model plus whether it is ENABLED (advertised on the
/// gateway allowlist, and so offered in the picker / to the brain). `card`
/// carries the curated model-dex card when the gateway has one for this id.
class ManagedModel {
  const ManagedModel({
    required this.id,
    required this.provider,
    required this.advertised,
    this.free,
    this.card,
  });

  final String id;
  final String provider;
  final bool advertised;
  final bool? free;
  final ModelCard? card;

  factory ManagedModel.fromJson(Map<String, dynamic> j) => ManagedModel(
        id: j['id'] as String? ?? '',
        provider: (j['provider'] as String?)?.trim().isNotEmpty == true
            ? j['provider'] as String
            : (j['owned_by'] as String? ?? 'gateway'),
        advertised: j['advertised'] as bool? ?? false,
        free: j['free'] as bool?,
        card: j['card'] is Map<String, dynamic>
            ? ModelCard.fromJson(j['card'] as Map<String, dynamic>)
            : null,
      );
}

/// The full discovered catalog + the currently-enabled id set, for the
/// "Manage models" screen. `source` is `gateway` normally, or `curated` when
/// the gateway admin was unreachable and the daemon degraded to curated.
class ManagedModelsState {
  const ManagedModelsState({
    required this.models,
    required this.enabled,
    this.source = 'gateway',
  });

  final List<ManagedModel> models;
  final Set<String> enabled;
  final String source;

  factory ManagedModelsState.fromJson(Map<String, dynamic> j) => ManagedModelsState(
        models: (j['models'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ManagedModel.fromJson)
            .toList(),
        enabled: (j['enabled'] as List? ?? const [])
            .map((e) => e.toString())
            .toSet(),
        source: j['source'] as String? ?? 'gateway',
      );
}

/// Reads/writes the per-agent reply model via the skchat daemon
/// (`GET`/`POST /api/v1/agent/model` on port 9385).
///
/// The selection drives which model the consciousness bridge uses for the
/// agent's next reply (routed through SKGateway).
class AgentModelService {
  AgentModelService({String? baseUrl})
      : _baseUrl = baseUrl ?? 'http://127.0.0.1:9385',
        _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );

  final String _baseUrl;
  final Dio _dio;

  /// `capauth:lumina@skworld.io` → `lumina`
  static String agentFromPeerId(String peerId) {
    final s =
        peerId.startsWith('capauth:') ? peerId.substring('capauth:'.length) : peerId;
    return s.split('@').first;
  }

  Future<AgentModelState?> getModel(String agent) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/api/v1/agent/model',
        queryParameters: {'agent': agent},
      );
      final d = resp.data;
      return d == null ? null : _parse(d);
    } catch (_) {
      return null;
    }
  }

  /// Set [agent]'s selection to a role name or a concrete model id.
  /// Posts BOTH keys: `model` (the key the shipped daemon actually reads, see
  /// daemon.py: `data.get("model")`) and `selection` (forward-compat for a
  /// daemon that adopts the catalog shape). Sending only `selection` lands as
  /// `None` on the current daemon -> 400 "unknown model" (the failed-to-set
  /// error the picker showed).
  Future<AgentModelState?> setSelection(String agent, String selection) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/api/v1/agent/model',
        data: {'agent': agent, 'model': selection, 'selection': selection},
      );
      final d = resp.data;
      if (d == null) return null;
      return _parse({'agent': agent, ...d});
    } catch (_) {
      return null;
    }
  }

  /// Fetch the model-ENABLEMENT view: every discovered model + which are
  /// enabled (advertised). Drives the "Manage models" screen. Returns null on
  /// any failure (daemon offline), so the screen shows an offline state.
  Future<ManagedModelsState?> listManagedModels() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/api/v1/models/manage',
      );
      final d = resp.data;
      return d == null ? null : ManagedModelsState.fromJson(d);
    } catch (_) {
      return null;
    }
  }

  /// Persist the ENABLED set (the full list of ids to advertise; empty =
  /// advertise everything). Returns the refreshed view, or null on failure.
  Future<ManagedModelsState?> setEnabledModels(List<String> enabled) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/api/v1/models/manage',
        data: {'enabled': enabled},
      );
      final d = resp.data;
      return d == null ? null : ManagedModelsState.fromJson(d);
    } catch (_) {
      return null;
    }
  }

  /// Parses either the current daemon shape (`selection`/`kind`/`catalog`)
  /// or the pre-catalog shape (`model`/`available`), whichever the daemon
  /// sent, so an older daemon still drives a working picker.
  AgentModelState _parse(Map<String, dynamic> d) {
    final rawCatalog = d['catalog'] as Map<String, dynamic>?;
    final catalog = rawCatalog != null
        ? AgentCatalog.fromJson(rawCatalog)
        : AgentCatalog(
            roles: const [],
            models: (d['available'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(AgentModel.fromJson)
                .toList(),
          );
    final selection =
        d['selection'] as String? ?? d['model'] as String? ?? '';
    return AgentModelState(
      agent: d['agent'] as String? ?? '',
      selection: selection,
      kind: d['kind'] as String? ?? 'model',
      resolvedModel: d['resolved_model'] as String?,
      catalog: catalog,
      stale: d['stale'] as bool? ?? false,
    );
  }
}

final agentModelServiceProvider = Provider<AgentModelService>((ref) {
  final daemonUrl = ref.watch(daemonUrlProvider);
  return AgentModelService(baseUrl: _modelBaseFromDaemonUrl(daemonUrl));
});

/// Resolve the base URL for the skchat daemon model API (`/api/v1/agent/model`,
/// served by the skchat daemon on port 9385).
///
/// The daemon port differs from the SKComms daemon that [daemonUrlProvider]
/// points at, and how it is reached depends on the platform:
///
///   * NATIVE: the daemon runs locally on a distinct port, so swap to 9385
///     (`http://host:9384` -> `http://host:9385`).
///   * WEB: the app is served same-origin behind the reverse proxy / tailnet
///     funnel. The daemon port (9385) is bound to 127.0.0.1 and is NOT
///     reachable from the browser, and `daemon_proxy.py` (the same-origin
///     `/api/v1` proxy) carries no `agent/model` route. The funnel DOES expose
///     the daemon at the `/daemon` path (it strips the prefix and forwards to
///     :9385), so route the model API through it: `<origin>/daemon`.
///     A bare `uri.replace(port: 9385)` would produce `<origin>:9385`, which the
///     funnel does not serve (the daemon offline error the picker showed).
String _modelBaseFromDaemonUrl(String daemonUrl) {
  final normalized = normalizeDaemonUrl(daemonUrl);
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.host.isEmpty) return 'http://127.0.0.1:9385';
  if (kIsWeb) return '$normalized/daemon';
  return uri.replace(port: 9385).toString();
}
