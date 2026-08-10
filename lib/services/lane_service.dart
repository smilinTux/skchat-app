import "dart:convert";

import "package:dio/dio.dart";

import "livekit_call_service.dart";

/// The lane contract [LaneService] fulfills, factored out so callers can
/// depend on the shape instead of the concrete Dio/LiveKit implementation.
/// This is the DI seam that lets a widget/notifier test substitute a fake
/// lane (no network, no LiveKit room) instead of exercising the real
/// service, and lets it assert on which publish path an event took.
abstract class LaneLike {
  /// Inbound lane events (decoded JSON maps carrying a "lane" key) from peers.
  Stream<Map<String, dynamic>> get inbound;

  /// Publish a lane event: live over the data channel + persisted server-side.
  Future<void> publish(Map<String, dynamic> payload);

  /// Publish a lane event live only, over the data channel, with NO server
  /// mirror. For events a late joiner must never replay (see
  /// [LaneService.publishEphemeral] for why a persisted heartbeat floods the
  /// lane store).
  Future<void> publishEphemeral(Map<String, dynamic> payload);

  /// Replay persisted events for a lane on join (catch-up).
  Future<List<Map<String, dynamic>>> catchUp(String lane);
}

/// Client-side data-lane substrate (Tier 4). Publishes lane events over the
/// LiveKit data channel for live peers AND mirrors them to the server lane
/// store (Tier 2: /spaces/{id}/lanes/event), and replays persisted state on
/// join (/spaces/{id}/lanes/{lane}/state). Mirrors the web livekit.html client.
class LaneService implements LaneLike {
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

  @override
  Stream<Map<String, dynamic>> get inbound => _lk.dataChannel.map((m) {
        try {
          final j = jsonDecode(utf8.decode(m.payload));
          return j is Map<String, dynamic> ? j : <String, dynamic>{};
        } catch (_) {
          return <String, dynamic>{};
        }
      }).where((j) => j.containsKey("lane"));

  @override
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

  /// Live-only publish: the data channel send with NO server mirror.
  ///
  /// [publish] mirrors every event to the server lane store, and [catchUp]
  /// replays that whole stored list to late joiners. A heartbeat published
  /// through [publish] every 3 seconds would put roughly 2400 events in the
  /// store for a two hour movie, and every late joiner would replay all of
  /// them through drift correction on join, a seek storm that ends on a
  /// stale position (the last persisted heartbeat, not the live one). Use
  /// this for events a late joiner must never replay; keep using [publish]
  /// for events a late joiner DOES need (load/play/pause/seek).
  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async {
    final lane = (payload["lane"] as String?) ?? "chat";
    await _lk.sendData(topic: lane, payload: utf8.encode(jsonEncode(payload)));
  }

  @override
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
