import 'package:dio/dio.dart';
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
        provider: j['provider'] as String? ?? '',
        label: j['label'] as String?,
        local: j['local'] as bool? ?? false,
        free: j['free'] as bool?,
      );
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
  /// Posts `selection` (the current daemon key); the daemon also still
  /// accepts the old `model` key, but a fresh client always writes the
  /// current one.
  Future<AgentModelState?> setSelection(String agent, String selection) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/api/v1/agent/model',
        data: {'agent': agent, 'selection': selection},
      );
      final d = resp.data;
      if (d == null) return null;
      return _parse({'agent': agent, ...d});
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

/// `http://host:9384` → `http://host:9385` (the skchat daemon API port).
String _modelBaseFromDaemonUrl(String daemonUrl) {
  final uri = Uri.tryParse(normalizeDaemonUrl(daemonUrl));
  if (uri == null || uri.host.isEmpty) return 'http://127.0.0.1:9385';
  return uri.replace(port: 9385).toString();
}
