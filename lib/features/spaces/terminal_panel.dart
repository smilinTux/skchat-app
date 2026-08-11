import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/backend_config.dart" show backendConfigProvider;
import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";

/// Terminal lane (Tier 4): a shared command console scoped to a Space. Commands
/// typed here are broadcast over the "term" data-lane to the room; an agent with
/// a term execution backend (skreachd) responds with streamed output + an exit
/// code. State is persisted + replayed (catch-up) for late joiners. No command
/// is executed locally, this client only broadcasts and renders.
class TerminalPanel extends ConsumerStatefulWidget {
  const TerminalPanel({super.key, required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  ConsumerState<TerminalPanel> createState() => _TerminalPanelState();
}

/// A single rendered line in the terminal log, tagged so we can color it.
class _TermLine {
  const _TermLine(this.text, this.kind);
  final String text;

  /// One of: "cmd" (echoed input), "stdout", "stderr", "exit".
  final String kind;
}

class _TerminalPanelState extends ConsumerState<TerminalPanel> {
  late final LaneService _lane;
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final List<_TermLine> _lines = <_TermLine>[];

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
    _lane.catchUp("term").then((events) {
      for (final e in events) {
        _applyRemote(e);
      }
    });
    _lane.inbound.where((j) => j["lane"] == "term").listen(_applyRemote);
  }

  /// Apply an inbound term event (from catch-up or a live peer) to the log.
  void _applyRemote(Map<String, dynamic> e) {
    final action = e["action"];
    switch (action) {
      case "run":
        final cmd = e["cmd"] as String?;
        if (cmd != null) _append(_TermLine("\$ $cmd", "cmd"));
        break;
      case "output":
        final chunk = e["chunk"] as String?;
        if (chunk != null) {
          final stream = (e["stream"] as String?) ?? "stdout";
          _append(_TermLine(chunk, stream == "stderr" ? "stderr" : "stdout"));
        }
        break;
      case "exit":
        final code = e["code"];
        _append(_TermLine("[exit ${code ?? "?"}]", "exit"));
        break;
    }
  }

  /// Append a line, rebuild, and auto-scroll to the bottom.
  void _append(_TermLine line) {
    if (!mounted) return;
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtl.hasClients) return;
      _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
    });
  }

  /// Submit the typed command: echo locally + broadcast the run envelope.
  void _submit() {
    final cmd = _inputCtl.text.trim();
    if (cmd.isEmpty) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _append(_TermLine("\$ $cmd", "cmd"));
    _lane.publish({
      "lane": "term",
      "action": "run",
      "cmd": cmd,
      "id": id,
      "from": widget.identity,
    });
    _inputCtl.clear();
  }

  Color _colorFor(String kind) {
    switch (kind) {
      case "cmd":
        return SovereignColors.accentEncrypt;
      case "stderr":
        return SovereignColors.accentDanger;
      case "exit":
        return SovereignColors.textTertiary;
      default:
        return SovereignColors.textPrimary;
    }
  }

  @override
  void dispose() {
    _inputCtl.dispose();
    _scrollCtl.dispose();
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
            "Terminal",
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: SovereignColors.surfaceGlass,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "⚠ No exec backend connected, commands are broadcast to the "
              "room; an agent with the term backend will respond.",
              style: TextStyle(
                color: SovereignColors.accentWarning,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: SovereignColors.surfaceBase,
                borderRadius: BorderRadius.circular(10),
              ),
              child: _lines.isEmpty
                  ? const Text(
                      "No output yet.",
                      style: TextStyle(
                        fontFamily: "monospace",
                        color: SovereignColors.textTertiary,
                        fontSize: 13,
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtl,
                      itemCount: _lines.length,
                      itemBuilder: (context, i) {
                        final line = _lines[i];
                        return Text(
                          line.text,
                          style: TextStyle(
                            fontFamily: "monospace",
                            color: _colorFor(line.kind),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                "\$ ",
                style: TextStyle(
                  fontFamily: "monospace",
                  color: SovereignColors.accentEncrypt,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _inputCtl,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(
                    fontFamily: "monospace",
                    color: SovereignColors.textPrimary,
                    fontSize: 14,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: "type a command…",
                    hintStyle: TextStyle(
                      fontFamily: "monospace",
                      color: SovereignColors.textTertiary,
                    ),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send_rounded,
                    color: SovereignColors.accentEncrypt),
                onPressed: _submit,
                tooltip: "Run (broadcast)",
              ),
            ],
          ),
        ],
      ),
    );
  }
}
