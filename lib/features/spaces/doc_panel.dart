import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/backend_config.dart" show backendConfigProvider;
import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";

/// Collaborative doc lane (Tier 4): a shared plaintext document synced across
/// the Space over the data-lane substrate. Simple last-write-wins (not CRDT):
/// every keystroke is debounced and published on the "doc" lane; every client
/// applies the latest remote text. State is persisted + replayed (catch-up) for
/// late joiners.
class DocPanel extends ConsumerStatefulWidget {
  const DocPanel({super.key, required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  ConsumerState<DocPanel> createState() => _DocPanelState();
}

class _DocPanelState extends ConsumerState<DocPanel> {
  late final LaneService _lane;
  final TextEditingController _ctl = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  /// True while we are programmatically applying a remote update, so the
  /// controller's onChanged callback does NOT echo it back out (clobber loop).
  bool _applyingRemote = false;

  @override
  void initState() {
    super.initState();
    _lane = LaneService(
      livekit: ref.read(liveKitCallServiceProvider),
      // RUNTIME base, not the compile-time constant: kDefaultWebuiUrl is ""
      // unless a dart-define sets it, and the web deploy does not, so an
      // empty base sent every HTTP call into LaneService's swallowing catch
      // and silently killed this lane's catch-up replay.
      baseUrl: ref.read(backendConfigProvider).skchatWebuiUrl,
      spaceId: widget.spaceId,
    );
    _lane.catchUp("doc").then((events) {
      if (events.isEmpty) return;
      // Last-write-wins: only the LAST event's text matters on catch-up.
      _applyRemote(events.last, force: true);
    });
    _lane.inbound.where((j) => j["lane"] == "doc").listen(_applyRemote);
  }

  /// Apply an inbound doc event WITHOUT re-publishing (avoids sync loops).
  ///
  /// Skips the overwrite while the local user is actively typing (field has
  /// focus) so we never clobber in-progress edits, unless [force] is set
  /// (used for the initial catch-up at join). No-ops if the text is unchanged.
  void _applyRemote(Map<String, dynamic> e, {bool force = false}) {
    if (!mounted) return;
    final text = e["text"] as String?;
    if (text == null) return;
    if (text == _ctl.text) return;
    if (!force && _focus.hasFocus) return;
    _applyingRemote = true;
    _ctl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _applyingRemote = false;
  }

  /// Local edit handler: debounce ~400ms then publish the full document.
  void _onChanged(String _) {
    if (_applyingRemote) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _publishDoc);
  }

  Future<void> _publishDoc() async {
    if (!mounted) return;
    await _lane.publish({
      "lane": "doc",
      "from": widget.identity,
      "text": _ctl.text,
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    _focus.dispose();
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: SovereignColors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            "Shared Doc",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            "last edit wins",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: SovereignColors.textTertiary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SovereignColors.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TextField(
                controller: _ctl,
                focusNode: _focus,
                onChanged: _onChanged,
                expands: true,
                maxLines: null,
                minLines: null,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(color: SovereignColors.textPrimary),
                decoration: const InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: "Start typing, everyone in the Space sees it…",
                  hintStyle: TextStyle(color: SovereignColors.textTertiary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
