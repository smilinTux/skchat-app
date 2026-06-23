import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_config.dart';

/// Result of starting / joining a group A/V call.
///
/// Returned by `POST /api/v1/groups/{id}/call/{start|join}` — the deterministic
/// LiveKit room (derived from the group id), the caller's room-scoped member
/// token, the SFU WebSocket URL, and the member roster. The Flutter call screen
/// connects with [token] via [LiveKitCallService.connectWithToken].
class GroupCallSession {
  const GroupCallSession({
    required this.groupId,
    required this.room,
    required this.identity,
    required this.token,
    required this.livekitUrl,
    this.members = const [],
    this.rung = const [],
  });

  /// The group this call belongs to.
  final String groupId;

  /// Deterministic LiveKit room name (derived from the group id server-side).
  final String room;

  /// The caller's LiveKit identity in the room (their membership URI).
  final String identity;

  /// Member-scoped LiveKit JWT (publish + subscribe + data; not room admin).
  final String token;

  /// SFU WebSocket URL to connect to (public-aware on the server).
  final String livekitUrl;

  /// The group's member roster (so the UI can show who could join).
  final List<Map<String, dynamic>> members;

  /// Member URIs that were rung when the call started (empty for a join).
  final List<String> rung;

  factory GroupCallSession.fromJson(Map<String, dynamic> json) {
    return GroupCallSession(
      groupId: json['group_id'] as String? ?? '',
      room: json['room'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
      token: json['token'] as String? ?? '',
      livekitUrl: json['livekit_url'] as String? ?? '',
      members: ((json['members'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
      rung: ((json['rung'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

/// Live participant snapshot for a group call's room (from the SFU).
class GroupCallParticipants {
  const GroupCallParticipants({
    required this.room,
    required this.active,
    this.participants = const [],
    this.members = const [],
  });

  final String room;

  /// Count of participants currently connected to the room.
  final int active;

  /// Identities currently connected (from the SFU's RoomService).
  final List<Map<String, dynamic>> participants;

  /// The group's full membership roster.
  final List<Map<String, dynamic>> members;

  factory GroupCallParticipants.fromJson(Map<String, dynamic> json) {
    return GroupCallParticipants(
      room: json['room'] as String? ?? '',
      active: (json['active'] as num?)?.toInt() ?? 0,
      participants: ((json['participants'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
      members: ((json['members'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }
}

/// HTTP client for the Phase-3 group A/V call endpoints (the WEB path).
///
/// The Flutter app is a web build, so group calls go over the same-origin webui
/// HTTP API (NOT the CLI). All three endpoints are membership-gated server-side:
/// a non-member is refused a token (403).
class GroupCallService {
  GroupCallService({String? baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? kDefaultDaemonUrl,
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 10),
                headers: {'Content-Type': 'application/json'},
              ),
            ) {
    if (dio != null && baseUrl != null) _dio.options.baseUrl = baseUrl;
  }

  final Dio _dio;

  /// POST /api/v1/groups/{id}/call/start — mint a member token + ring members.
  ///
  /// [ring] (default true) fans a CALL_INVITE out to every other member so they
  /// get the standard incoming-call surface. [topic] labels the ring.
  Future<GroupCallSession> startCall(
    String groupId, {
    String? topic,
    bool ring = true,
  }) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/v1/groups/$groupId/call/start',
      data: {'ring': ring, if (topic != null && topic.isNotEmpty) 'topic': topic},
    );
    return GroupCallSession.fromJson(resp.data ?? const {});
  }

  /// POST /api/v1/groups/{id}/call/join — mint a member token (no ring).
  ///
  /// Used by a late-joiner / a member answering the ring: joins the in-progress
  /// room without re-ringing anyone.
  Future<GroupCallSession> joinCall(String groupId) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/v1/groups/$groupId/call/join',
      data: const {},
    );
    return GroupCallSession.fromJson(resp.data ?? const {});
  }

  /// GET /api/v1/groups/{id}/call/participants — who's currently in the room.
  Future<GroupCallParticipants> participants(String groupId) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '/api/v1/groups/$groupId/call/participants',
    );
    return GroupCallParticipants.fromJson(resp.data ?? const {});
  }
}

/// GroupCallService bound to the runtime-configurable daemon URL (same-origin
/// webui), mirroring [skcommsClientProvider].
final groupCallServiceProvider = Provider<GroupCallService>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return GroupCallService(baseUrl: baseUrl);
});
