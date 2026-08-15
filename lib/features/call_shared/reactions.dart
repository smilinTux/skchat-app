import "dart:async";
import "dart:convert";
import "dart:math";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../core/widgets/tap_feedback.dart";
import "../../services/livekit_call_service.dart";

/// In-call emoji reactions (Phase 2 polish).
///
/// A quick, fun way to react during a call, conference, or watch party. Tapping
/// the [ReactionsButton] opens a small picker of five emoji; the chosen one is
/// published over the LiveKit data channel on the "reaction" lane and floats up
/// the screen for every participant (via [ReactionsOverlay]).
///
/// The lane payload mirrors the [LaneService] shape (a JSON map with a "lane"
/// key) so it rides the exact same data-channel substrate as chat / whiteboard,
/// but reactions are ephemeral and fire-and-forget: not persisted, sent
/// unreliable, and deduped by a per-event id so a re-delivered packet never
/// double-animates.

/// The data-channel lane / topic reactions ride on.
const String kReactionLane = "reaction";

/// A quick reaction the user can pick. Kept a small, fun set on purpose.
class QuickReaction {
  const QuickReaction(this.emoji, this.label);

  final String emoji;
  final String label;
}

/// The five quick reactions offered in the picker.
const List<QuickReaction> kQuickReactions = <QuickReaction>[
  QuickReaction("\u{1F525}", "Fire"), // 🔥
  QuickReaction("\u{1F44F}", "Clap"), // 👏
  QuickReaction("\u{1F602}", "Laugh"), // 😂
  QuickReaction("❤️", "Heart"), // ❤️
  QuickReaction("\u{1F62E}", "Wow"), // 😮
];

/// A single reaction event, inbound or locally originated.
class ReactionEvent {
  const ReactionEvent({
    required this.id,
    required this.emoji,
    required this.from,
  });

  /// Unique per-emission id, used to dedup re-delivered packets.
  final String id;

  /// The emoji glyph to float.
  final String emoji;

  /// Sender identity (informational; the overlay does not label it).
  final String from;
}

/// Bridges the LiveKit data channel to a stream of [ReactionEvent]s and lets a
/// caller [send] one. Local sends are echoed onto the same stream so the sender
/// sees their own reaction float (LiveKit does not loop data back to self).
class ReactionsController {
  ReactionsController(this._lk) {
    _sub = _lk.dataChannel
        .where((m) => m.topic == kReactionLane)
        .listen(_onData);
  }

  final LiveKitCallService _lk;
  final StreamController<ReactionEvent> _ctl =
      StreamController<ReactionEvent>.broadcast();
  final Set<String> _seen = <String>{};
  final Random _rng = Random();
  StreamSubscription<({String topic, List<int> payload, String senderIdentity})>?
      _sub;

  /// Stream of reactions to animate (remote peers + the local echo).
  Stream<ReactionEvent> get events => _ctl.stream;

  void _onData(({String topic, List<int> payload, String senderIdentity}) m) {
    try {
      final decoded = jsonDecode(utf8.decode(m.payload));
      if (decoded is! Map) return;
      if (decoded["lane"] != kReactionLane) return;
      final emoji = decoded["emoji"] as String?;
      if (emoji == null || emoji.isEmpty) return;
      final id = (decoded["id"] as String?) ??
          "${m.senderIdentity}-${DateTime.now().microsecondsSinceEpoch}";
      _emit(ReactionEvent(
        id: id,
        emoji: emoji,
        from: (decoded["from"] as String?) ?? m.senderIdentity,
      ));
    } catch (_) {
      // Malformed reaction packet: ignore.
    }
  }

  /// Send [emoji] to the room and echo it locally so the sender sees it too.
  Future<void> send(String emoji, {required String from}) async {
    final who = from.isNotEmpty ? from : "guest";
    final id =
        "$who-${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 20)}";
    // Local echo first: the SFU does not deliver our own data back to us.
    _emit(ReactionEvent(id: id, emoji: emoji, from: who));
    final payload = <String, dynamic>{
      "lane": kReactionLane,
      "emoji": emoji,
      "from": who,
      "id": id,
    };
    try {
      // Fire-and-forget: reactions are ephemeral, so unreliable delivery keeps
      // them off the reliable channel's head-of-line queue.
      await _lk.sendData(
        topic: kReactionLane,
        payload: utf8.encode(jsonEncode(payload)),
        reliable: false,
      );
    } catch (_) {
      // Best-effort: the local echo already animated for the sender.
    }
  }

  void _emit(ReactionEvent e) {
    if (_seen.contains(e.id)) return;
    _seen.add(e.id);
    // Bound the dedup set so a long call does not leak ids unbounded.
    if (_seen.length > 512) _seen.clear();
    if (!_ctl.isClosed) _ctl.add(e);
  }

  void dispose() {
    _sub?.cancel();
    if (!_ctl.isClosed) _ctl.close();
  }
}

/// Scoped controller bound to the live [LiveKitCallService]. autoDispose so it
/// is torn down with the call; kept alive while [ReactionsOverlay] /
/// [ReactionsButton] are mounted (they watch it).
final reactionsControllerProvider =
    Provider.autoDispose<ReactionsController>((ref) {
  final lk = ref.watch(liveKitCallServiceProvider);
  final controller = ReactionsController(lk);
  ref.onDispose(controller.dispose);
  return controller;
});

// ── Reactions button + picker ───────────────────────────────────────────────

/// A round control-bar button that opens the emoji picker. Drop it into a call
/// control bar alongside the mic / camera / share buttons. [identity] is the
/// sender label attached to outgoing reactions.
class ReactionsButton extends ConsumerWidget {
  const ReactionsButton({super.key, required this.identity});

  final String identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch keeps the controller alive for the life of the control bar.
    ref.watch(reactionsControllerProvider);
    return Semantics(
      button: true,
      label: "React",
      child: TapFeedback(
        onTap: () => _openPicker(context, ref),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1A1D22),
                border: Border.all(color: const Color(0xFF2A2D34), width: 1.5),
              ),
              child: const Icon(
                Icons.add_reaction_outlined,
                color: SovereignColors.textPrimary,
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "React",
              style: TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(reactionsControllerProvider);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final r in kQuickReactions)
                Semantics(
                  button: true,
                  label: r.label,
                  child: TapFeedback(
                    onTap: () => Navigator.of(sheetCtx).pop(r.emoji),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: SovereignColors.soulLumina
                                .withValues(alpha: 0.10),
                            border: Border.all(
                              color: SovereignColors.soulLumina
                                  .withValues(alpha: 0.35),
                            ),
                          ),
                          child: Text(
                            r.emoji,
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          r.label,
                          style: const TextStyle(
                            color: SovereignColors.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await controller.send(picked, from: identity);
    }
  }
}

// ── Floating overlay ────────────────────────────────────────────────────────

/// A full-bleed, tap-transparent overlay that floats received reactions up the
/// screen and fades them out. Stack this over the call body (it is wrapped in
/// [IgnorePointer], so it never eats touches).
class ReactionsOverlay extends ConsumerStatefulWidget {
  const ReactionsOverlay({super.key});

  @override
  ConsumerState<ReactionsOverlay> createState() => _ReactionsOverlayState();
}

class _ReactionsOverlayState extends ConsumerState<ReactionsOverlay> {
  final List<_ActiveReaction> _active = <_ActiveReaction>[];
  final Random _rng = Random();
  StreamSubscription<ReactionEvent>? _sub;

  @override
  void initState() {
    super.initState();
    // Subscribe after the first build so build()'s ref.watch has registered a
    // listener that keeps the autoDispose controller alive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sub = ref.read(reactionsControllerProvider).events.listen(_onReaction);
    });
  }

  void _onReaction(ReactionEvent e) {
    if (!mounted) return;
    // Horizontal lane in [-0.7, 0.7] so simultaneous reactions spread out.
    final laneX = (_rng.nextDouble() * 1.4) - 0.7;
    final key = UniqueKey();
    setState(() => _active.add(_ActiveReaction(key, e.emoji, laneX)));
    // Cap concurrent glyphs so a reaction storm cannot pile up unbounded.
    if (_active.length > 40) {
      setState(() => _active.removeAt(0));
    }
  }

  void _remove(Key key) {
    if (!mounted) return;
    setState(() => _active.removeWhere((a) => a.key == key));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the controller alive while the overlay is mounted.
    ref.watch(reactionsControllerProvider);
    return IgnorePointer(
      child: Stack(
        children: [
          for (final a in _active)
            _FloatingEmoji(
              key: a.key,
              emoji: a.emoji,
              laneX: a.laneX,
              onDone: () => _remove(a.key),
            ),
        ],
      ),
    );
  }
}

class _ActiveReaction {
  _ActiveReaction(this.key, this.emoji, this.laneX);

  final Key key;
  final String emoji;
  final double laneX;
}

/// One emoji that rises from the lower third, pops, drifts, and fades. Removes
/// itself via [onDone] when the animation completes.
class _FloatingEmoji extends StatefulWidget {
  const _FloatingEmoji({
    super.key,
    required this.emoji,
    required this.laneX,
    required this.onDone,
  });

  final String emoji;
  final double laneX;
  final VoidCallback onDone;

  @override
  State<_FloatingEmoji> createState() => _FloatingEmojiState();
}

class _FloatingEmojiState extends State<_FloatingEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac;
  late final double _drift;

  @override
  void initState() {
    super.initState();
    // Small sideways drift so a column of the same emoji is not a straight line.
    _drift = (Random().nextDouble() * 0.24) - 0.12;
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      });
    _ac.forward();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) {
        final t = _ac.value;
        // Vertical: rise from near the bottom (0.82) to the upper area (-0.65).
        final y = reduced ? 0.4 : (0.82 - (t * 1.47));
        final x = widget.laneX + (reduced ? 0.0 : _drift * t);
        // Opacity: quick fade-in, hold, fade-out over the last third.
        final opacity = reduced
            ? (1.0 - t).clamp(0.0, 1.0)
            : t < 0.12
                ? (t / 0.12)
                : t > 0.7
                    ? (1.0 - ((t - 0.7) / 0.3)).clamp(0.0, 1.0)
                    : 1.0;
        // Scale: a little pop at the start, settling to full size.
        final scale = reduced
            ? 1.0
            : t < 0.18
                ? (0.6 + (t / 0.18) * 0.55)
                : 1.15 - ((t - 0.18) / 0.82) * 0.15;
        return Align(
          alignment: Alignment(x.clamp(-0.95, 0.95), y),
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Text(
                widget.emoji,
                style: const TextStyle(
                  fontSize: 44,
                  shadows: [
                    Shadow(
                      color: Colors.black54,
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
