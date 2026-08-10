import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "watch_session.dart";

/// Watch-together lane (Tier 4): a shared video synced across the Space over the
/// data-lane substrate. Any participant can load a URL and play/pause/seek; the
/// "watch" lane broadcasts the action and every client applies it, staying in
/// sync. State is persisted + replayed (catch-up) for late joiners.
///
/// The panel is CONTROLS ONLY. The player itself lives on the Space's main
/// stage (space_room_screen.dart), rendering off the same [watchSessionProvider]
/// this panel writes to. A browser DOM element can only exist in one place: the
/// web surface keys its platform view on controller IDENTITY
/// (watch_video_web.dart), so a panel-owned WatchVideo for the SAME controller
/// would share that view with the stage's and the second mount would steal the
/// element out from under the first, blanking the stage. Routing every action
/// here through the shared session (instead of a private controller + lane of
/// its own) is also what makes the loader's OWN stage populate: LiveKit never
/// echoes a participant's own data send back to them (watch_session.dart, near
/// the applyRemote doc), so a self-contained panel leaves the loader's stage
/// empty. Going through the session's loadUrl (which calls controller.load
/// locally AND publishes) closes that gap.
class WatchPanel extends ConsumerStatefulWidget {
  const WatchPanel({super.key, required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  ConsumerState<WatchPanel> createState() => _WatchPanelState();
}

class _WatchPanelState extends ConsumerState<WatchPanel> {
  final TextEditingController _urlCtl = TextEditingController();

  WatchSessionArgs get _args =>
      WatchSessionArgs(spaceId: widget.spaceId, identity: widget.identity);

  void _load() {
    final url = _urlCtl.text.trim();
    if (url.isEmpty) return;
    ref.read(watchSessionProvider(_args).notifier).loadUrl(url);
  }

  void _play() {
    ref.read(watchSessionProvider(_args).notifier).play();
  }

  void _pause() {
    ref.read(watchSessionProvider(_args).notifier).pause();
  }

  void _syncPosition() {
    ref.read(watchSessionProvider(_args).notifier).syncPosition();
  }

  @override
  void dispose() {
    // The controller and the lane subscription belong to watchSessionProvider
    // now (autoDispose, shared with the stage); this widget owns nothing but
    // its own text field.
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(watchSessionProvider(_args));
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
          // No player here on purpose (see class doc): the stage is the
          // player's only mount point, this is just a status line.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              state.isActive
                  ? "Playing on the main stage above.\n${state.url}"
                  : "Load a video URL to watch together.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 13,
              ),
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
