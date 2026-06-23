import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_config.dart';

/// Capability / service-discovery document fetched from the SKComms daemon.
///
/// The daemon advertises *which* transports + services this deployment actually
/// has (availability varies by config/access). The app reads it at
/// `{daemonBase}/api/v1/capabilities` (same-origin on web via the webui proxy)
/// and renders honest status — rather than the old hardcoded `[file]` fallback.

/// A coarse availability state shared by transports and services.
///
/// Mirrors the daemon's status vocabulary. The app collapses these onto a
/// status dot: up=green, configured/degraded=amber, unconfigured/down=grey.
enum CapStatus { up, configured, degraded, down, unconfigured, unknown }

CapStatus capStatusFromString(String? s) {
  switch (s) {
    case 'up':
      return CapStatus.up;
    case 'configured':
      return CapStatus.configured;
    case 'degraded':
      return CapStatus.degraded;
    case 'down':
      return CapStatus.down;
    case 'unconfigured':
      return CapStatus.unconfigured;
    default:
      return CapStatus.unknown;
  }
}

/// One advertised transport (file / syncthing / https / ws / tailscale /
/// webrtc / p2p / ble-mesh / lora / nostr).
class TransportCapability {
  const TransportCapability({
    required this.id,
    required this.protocol,
    required this.status,
    this.roles = const [],
    this.media = const [],
  });

  final String id;
  final String protocol;
  final CapStatus status;
  final List<String> roles;
  final List<String> media;

  factory TransportCapability.fromJson(Map<String, dynamic> json) {
    return TransportCapability(
      id: (json['id'] as String?) ?? 'unknown',
      protocol: (json['protocol'] as String?) ?? '',
      status: capStatusFromString(json['status'] as String?),
      roles: _stringList(json['roles']),
      media: _stringList(json['media']),
    );
  }
}

/// One advertised service (text / voice / video / file-transfer /
/// data-streaming / federation / access-plane / geo-cot).
class ServiceCapability {
  const ServiceCapability({
    required this.id,
    required this.status,
    this.via = const [],
  });

  final String id;
  final CapStatus status;
  final List<String> via;

  factory ServiceCapability.fromJson(Map<String, dynamic> json) {
    return ServiceCapability(
      id: (json['id'] as String?) ?? 'unknown',
      status: capStatusFromString(json['status'] as String?),
      via: _stringList(json['via']),
    );
  }
}

/// The full node capability document.
class NodeCapabilities {
  const NodeCapabilities({
    this.nodeId,
    this.label,
    this.host,
    this.transports = const [],
    this.services = const [],
  });

  final String? nodeId;
  final String? label;
  final String? host;
  final List<TransportCapability> transports;
  final List<ServiceCapability> services;

  bool get isEmpty => transports.isEmpty && services.isEmpty;

  factory NodeCapabilities.fromJson(Map<String, dynamic> json) {
    final node = (json['node'] as Map?)?.cast<String, dynamic>() ?? const {};
    return NodeCapabilities(
      nodeId: node['id'] as String?,
      label: node['label'] as String?,
      host: node['host'] as String?,
      transports: _mapList(json['transports'])
          .map(TransportCapability.fromJson)
          .toList(),
      services:
          _mapList(json['services']).map(ServiceCapability.fromJson).toList(),
    );
  }
}

List<String> _stringList(dynamic raw) {
  if (raw is List) {
    return raw.map((e) => e.toString()).toList();
  }
  return const [];
}

List<Map<String, dynamic>> _mapList(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }
  return const [];
}

/// Thin client for the capability endpoint. Kept separate from SKCommsClient so
/// it can be unit-tested with a mock Dio adapter.
class CapabilitiesClient {
  CapabilitiesClient({String? baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? kDefaultDaemonUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
                headers: {'Content-Type': 'application/json'},
              ),
            ) {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = baseUrl;
    }
  }

  final Dio _dio;

  /// GET /api/v1/capabilities — returns the node capability document, or null
  /// when the endpoint is missing/unreachable (older daemons / offline). The
  /// caller renders gracefully on null.
  Future<NodeCapabilities?> fetch() async {
    try {
      final resp = await _dio.get('/api/v1/capabilities');
      final data = resp.data;
      if (data is Map) {
        return NodeCapabilities.fromJson(data.cast<String, dynamic>());
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

final capabilitiesClientProvider = Provider<CapabilitiesClient>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return CapabilitiesClient(baseUrl: baseUrl);
});

/// Fetches the node capability document. Re-fetches when the daemon URL changes.
/// Resolves to null when the endpoint is unavailable so the Me screen degrades
/// gracefully instead of erroring.
final nodeCapabilitiesProvider =
    FutureProvider<NodeCapabilities?>((ref) async {
  final client = ref.watch(capabilitiesClientProvider);
  return client.fetch();
});
