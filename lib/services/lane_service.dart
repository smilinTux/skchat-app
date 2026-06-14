import "dart:convert";

import "package:dio/dio.dart";

import "livekit_call_service.dart";

/// Client-side data-lane substrate (Tier 4). Publishes lane events over the
/// LiveKit data channel for live peers AND mirrors them to the server lane
/// store (Tier 2: /spaces/{id}/lanes/event), and replays persisted state on
/// join (/spaces/{id}/lanes/{lane}/state). Mirrors the web livekit.html client.
class LaneService {
  LaneService({
    required LiveKitCallService livekit,
    required String baseUrl,
    required String spaceId,
  })  : _lk = livekit,
        _baseUrl = baseUrl.replaceAll(RegExp(r"/+$"), ""),
        _spaceId = spaceId;

  final LiveKitCallService _lk;
  final String _baseUrl;
  final String _spaceId;
  final Dio _dio = Dio();

  /// Inbound lane events (decoded JSON maps carrying a "lane" key) from peers.
  Stream<Map<String, dynamic>> get inbound => _lk.dataChannel.map((m) {
        try {
          final j = jsonDecode(utf8.decode(m.payload));
          return j is Map<String, dynamic> ? j : <String, dynamic>{};
        } catch (_) {
          return <String, dynamic>{};
        }
      }).where((j) => j.containsKey("lane"));

  /// Publish a lane event: live over the data channel + persisted server-side.
  Future<void> publish(Map<String, dynamic> payload) async {
    final lane = (payload["lane"] as String?) ?? "chat";
    await _lk.sendData(topic: lane, payload: utf8.encode(jsonEncode(payload)));
    try {
      await _dio.post(
        "$_baseUrl/spaces/$_spaceId/lanes/event",
        data: payload,
        options: Options(headers: const {"Content-Type": "application/json"}),
      );
    } catch (_) {
      // Live data-channel path already delivered; persistence is best-effort.
    }
  }

  /// Replay persisted events for a lane on join (catch-up).
  Future<List<Map<String, dynamic>>> catchUp(String lane) async {
    try {
      final r = await _dio.get("$_baseUrl/spaces/$_spaceId/lanes/$lane/state");
      if (r.statusCode == 200) {
        final data = r.data is String ? jsonDecode(r.data) : r.data;
        final events = (data["events"] as List?) ?? const [];
        return events.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return const [];
  }
}
