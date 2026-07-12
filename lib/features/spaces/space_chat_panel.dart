import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";
import "../../services/spaces_service.dart";

/// In-Space text chat over the data-lane substrate (Tier 4). Uses the "chat"
/// lane: messages go live over the LiveKit data channel and are persisted +
/// replayed via the server lane store. The first real consumer of [LaneService].
class SpaceChatPanel extends ConsumerStatefulWidget {
  const SpaceChatPanel({
    super.key,
    required this.spaceId,
    required this.identity,
  });

  final String spaceId;
  final String identity;

  @override
  ConsumerState<SpaceChatPanel> createState() => _SpaceChatPanelState();
}

class _SpaceChatPanelState extends ConsumerState<SpaceChatPanel> {
  late final LaneService _lane;
  final List<Map<String, dynamic>> _msgs = [];
  final TextEditingController _ctl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _lane = LaneService(
      livekit: ref.read(liveKitCallServiceProvider),
      baseUrl: kDefaultWebuiUrl,
      spaceId: widget.spaceId,
    );
    _lane.catchUp("chat").then((events) {
      if (!mounted) return;
      setState(() => _msgs.addAll(events));
      _jumpToEnd();
    });
    _lane.inbound.where((j) => j["lane"] == "chat").listen((j) {
      if (!mounted) return;
      setState(() => _msgs.add(j));
      _jumpToEnd();
    });
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    final msg = <String, dynamic>{
      "lane": "chat",
      "from": widget.identity,
      "text": text,
      "ts": DateTime.now().millisecondsSinceEpoch,
    };
    _ctl.clear();
    setState(() => _msgs.add(msg));
    _jumpToEnd();
    await _lane.publish(msg);
  }

  @override
  void dispose() {
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
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
            "Space Chat",
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _msgs.isEmpty
                ? const Center(
                    child: Text(
                      "No messages yet, say hello to the room.",
                      style: TextStyle(color: SovereignColors.textTertiary),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _msgs.length,
                    itemBuilder: (context, i) {
                      final m = _msgs[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: "${m['from'] ?? '?'}: ",
                                style: const TextStyle(
                                  color: SovereignColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: "${m['text'] ?? ''}",
                                style: const TextStyle(
                                  color: SovereignColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctl,
                  style: const TextStyle(color: SovereignColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: "Message the room…",
                    hintStyle: TextStyle(color: SovereignColors.textTertiary),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.send_rounded,
                  color: SovereignColors.accentEncrypt,
                ),
                onPressed: _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
