import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "backend_config.dart";

/// Result of starting an HLS egress via POST /livekit/hls/start.
///
/// The backend turns the room's shared video into a plain HLS stream and hands
/// back a reachable [hlsUrl] (served over the .158 Funnel on 443) plus the
/// [egressId] used to stop it again. [reused] is true when an egress was already
/// active for the room and the backend handed back the existing one instead of
/// starting a second (the room-scoped single-egress guard).
class HlsCastSession {
  const HlsCastSession({
    required this.egressId,
    required this.hlsUrl,
    this.reused = false,
    this.status,
  });

  /// Egress id to pass to [CastService.stop].
  final String egressId;

  /// Public playlist URL a TV / Chromecast / AirPlay receiver can play.
  final String hlsUrl;

  /// True when the backend reused an already-active egress for the room.
  final bool reused;

  /// Egress status string (e.g. EGRESS_ACTIVE), when reported.
  final String? status;

  factory HlsCastSession.fromJson(Map<String, dynamic> json) {
    return HlsCastSession(
      egressId: (json["egress_id"] ?? "") as String,
      hlsUrl: (json["hls_url"] ?? "") as String,
      reused: (json["reused"] ?? false) == true,
      status: json["status"] as String?,
    );
  }
}

/// Drives the HLS TV-cast control plane on the SKChat web-UI:
/// POST /livekit/hls/start and POST /livekit/hls/stop.
///
/// The base URL follows the runtime [backendConfigProvider] (see
/// [castServiceProvider]) so switching federation instances repoints casting
/// too, exactly like [RecordingsService].
class CastService {
  CastService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = webuiBaseUrl ?? kDefaultSkchatWebuiUrl;

  final Dio _dio;
  final String _base;

  /// Start (or reuse) an HLS egress for [room].
  ///
  /// Idempotent per room server-side: two people tapping "Cast to TV" for the
  /// same room share ONE egress (the second call returns [HlsCastSession.reused]
  /// == true with the same egress id + URL).
  Future<HlsCastSession> start(String room) async {
    final r = await _dio.post<Map<String, dynamic>>(
      "$_base/livekit/hls/start",
      data: {"room": room},
      options: Options(headers: {"Content-Type": "application/json"}),
    );
    return HlsCastSession.fromJson(r.data ?? const {});
  }

  /// Stop the HLS egress identified by [egressId] (POST /livekit/hls/stop).
  ///
  /// Best-effort: swallows a backend error so leaving a call while casting can
  /// never throw out of the leave path. The egress also has a server-side idle
  /// stop as a backstop.
  Future<void> stop(String egressId) async {
    if (egressId.isEmpty) return;
    try {
      await _dio.post<Map<String, dynamic>>(
        "$_base/livekit/hls/stop",
        data: {"egress_id": egressId},
        options: Options(headers: {"Content-Type": "application/json"}),
      );
    } catch (_) {
      // Non-fatal: the operator can also stop it from the status page, and the
      // egress self-stops when the room empties.
    }
  }
}

/// Cast service repointed live by the runtime backend config.
final castServiceProvider = Provider<CastService>((ref) {
  final base = ref.watch(
    backendConfigProvider.select((c) => c.skchatWebuiUrl),
  );
  return CastService(webuiBaseUrl: base);
});
