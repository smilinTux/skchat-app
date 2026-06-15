import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_config.dart';

/// A selectable reply model advertised by the skchat daemon.
class AgentModel {
  const AgentModel({
    required this.id,
    required this.label,
    required this.provider,
    required this.local,
  });

  final String id;
  final String label;
  final String provider;
  final bool local;

  factory AgentModel.fromJson(Map<String, dynamic> j) => AgentModel(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? (j['id'] as String? ?? ''),
        provider: j['provider'] as String? ?? '',
        local: j['local'] as bool? ?? false,
      );
}

/// The current model selection for an agent plus the list of available models.
class AgentModelState {
  const AgentModelState({
    required this.agent,
    required this.model,
    required this.available,
  });

  final String agent;
  final String model;
  final List<AgentModel> available;
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

  Future<AgentModelState?> setModel(String agent, String model) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/api/v1/agent/model',
        data: {'agent': agent, 'model': model},
      );
      final d = resp.data;
      if (d == null) return null;
      return _parse({'agent': agent, ...d});
    } catch (_) {
      return null;
    }
  }

  AgentModelState _parse(Map<String, dynamic> d) {
    final avail = (d['available'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AgentModel.fromJson)
        .toList();
    return AgentModelState(
      agent: d['agent'] as String? ?? '',
      model: d['model'] as String? ?? '',
      available: avail,
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
