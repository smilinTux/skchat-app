import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";
import "../../services/spaces_service.dart";
import "watch_video_stub.dart" if (dart.library.html) "watch_video_web.dart";

/// Watch-together lane (Tier 4): a shared video synced across the Space over the
/// data-lane substrate. Any participant can load a URL and play/pause/seek; the
/// "watch" lane broadcasts the action and every client applies it, staying in
/// sync. State is persisted + replayed (catch-up) for late joiners.
class WatchPanel extends ConsumerStatefulWidget {
  const WatchPanel({super.key, required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  ConsumerState<WatchPanel> createState() => _WatchPanelState();
}

class _WatchPanelState extends ConsumerState<WatchPanel> {
  late final LaneService _lane;
  final WatchVideoController _vc = WatchVideoController();
  final TextEditingController _urlCtl = TextEditingController();
  String? _url;

  @override
  void initState() {
    super.initState();
    _lane = LaneService(
      livekit: ref.read(liveKitCallServiceProvider),
      baseUrl: kDefaultWebuiUrl,
      spaceId: widget.spaceId,
    );
    _lane.catchUp("watch").then((events) {
      for (final e in events) {
        _applyRemote(e);
      }
    });
    _lane.inbound.where((j) => j["lane"] == "watch").listen(_applyRemote);
  }

  /// Apply an inbound watch event WITHOUT re-publishing (avoids sync loops).
  void _applyRemote(Map<String, dynamic> e) {
    final action = e["action"];
    switch (action) {
      case "load":
        final url = e["url"] as String?;
        if (url != null) {
          _vc.load(url);
          if (mounted) setState(() => _url = url);
        }
        break;
      case "play":
        _vc.play();
        break;
      case "pause":
        _vc.pause();
        break;
      case "seek":
        final t = (e["t"] as num?)?.toDouble();
        if (t != null) _vc.seekTo(t);
        break;
    }
  }

  Future<void> _publish(Map<String, dynamic> payload) async {
    payload["lane"] = "watch";
    payload["from"] = widget.identity;
    await _lane.publish(payload);
  }

  void _load() {
    final url = _urlCtl.text.trim();
    if (url.isEmpty) return;
    _vc.load(url);
    setState(() => _url = url);
    _publish({"action": "load", "url": url});
  }

  void _play() {
    _vc.play();
    _publish({"action": "play", "t": _vc.position});
  }

  void _pause() {
    _vc.pause();
    _publish({"action": "pause", "t": _vc.position});
  }

  void _syncPosition() {
    final t = _vc.position;
    _vc.seekTo(t);
    _publish({"action": "seek", "t": t});
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        color: SovereignColors.surfaceCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: SovereignColors.textTertiary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Text(
            "Watch Together",
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: WatchVideo(controller: _vc),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlCtl,
                  style: const TextStyle(color: SovereignColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: "YouTube / Rumble / mp4 URL…",
                    hintStyle: TextStyle(color: SovereignColors.textTertiary),
                  ),
                  onSubmitted: (_) => _load(),
                ),
              ),
              TextButton(
                onPressed: _load,
                child: const Text("Load",
                    style: TextStyle(color: SovereignColors.accentEncrypt)),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded,
                    color: SovereignColors.textPrimary),
                onPressed: _play,
                tooltip: "Play (synced)",
              ),
              IconButton(
                icon: const Icon(Icons.pause_rounded,
                    color: SovereignColors.textPrimary),
                onPressed: _pause,
                tooltip: "Pause (synced)",
              ),
              IconButton(
                icon: const Icon(Icons.sync_rounded,
                    color: SovereignColors.accentEncrypt),
                onPressed: _syncPosition,
                tooltip: "Sync everyone to my position",
              ),
            ],
          ),
        ],
      ),
    );
  }
}
