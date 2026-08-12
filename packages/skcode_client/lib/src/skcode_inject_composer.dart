import "package:flutter/material.dart";

import "skcode_activity_taxonomy.dart";
import "skcode_tone_style.dart";

/// The session-inject composer (card C-5, spec section 7.1: "Two composers,
/// one hard rule: they must be unmistakable").
///
/// In the four-column tier (card C-12, later) this composer sits in a column
/// adjacent to the project chat composer. Typing into the wrong one is the
/// worst cheap mistake that layout can produce, so the distinction lives in
/// chrome, not position:
///   * terminal-styled: mono font, a flat field (no rounded chat-bubble
///     border), a write-tone (amber) left border ([skcodeToneColor] with
///     [ActivityTone.write], the SAME color the transcript uses for a write
///     row, spec section 6).
///   * a persistent, NON-DISMISSABLE target chip reading `INJECT -> <sid>`
///     inside the field: no close/X affordance anywhere on it, because the
///     whole point is that the operator can never lose track of which
///     session their keystrokes are about to hit.
///   * the button verb is "Inject", never "Send".
///
/// This widget carries NO gate logic of its own (no scope check, no
/// interactive-session check): [SkcodeSessionScreen] decides whether to put
/// it in the tree at all, per AC4 ("composer is hidden entirely when the
/// token lacks skcode.inject or the session is not interactive"). Once
/// mounted, it is unconditionally visible.
///
/// Its [FocusNode] is constructed with `skipTraversal: true`, which excludes
/// it from the app's Tab traversal order entirely: Tab pressed anywhere else
/// can never land focus here, and Tab pressed while it happens to be focused
/// (via a direct tap) moves on to the next real traversal stop rather than
/// looping back. That is the mechanism behind spec 7.1's "the two never
/// share focus traversal (Tab does not move between them)" - this composer
/// is simply never a Tab stop for anything, chat composer included.
class SkcodeInjectComposer extends StatefulWidget {
  const SkcodeInjectComposer({super.key, required this.sid, required this.onInject});

  /// The session id this composer targets, shown verbatim in the target
  /// chip.
  final String sid;

  /// Called with the composer's current text on "Inject". This widget never
  /// talks to the network itself (matching every other transport-touching
  /// widget in this package, which reaches the wire only through an injected
  /// callback): the caller is responsible for the actual
  /// `POST .../inject` call and for never logging or echoing [text]
  /// anywhere, preserving hostd's sha256-plus-length-only audit property.
  final Future<void> Function(String text) onInject;

  @override
  State<SkcodeInjectComposer> createState() => _SkcodeInjectComposerState();
}

class _SkcodeInjectComposerState extends State<SkcodeInjectComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode(skipTraversal: true, debugLabel: "skcodeInjectComposer");
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text;
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onInject(text);
      _controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final amber = skcodeToneColor(context, ActivityTone.write);
    // The ambient theme's own bodyMedium size, family swapped to mono: no
    // fontSize literal here (density spec 7.1's font-literal guard,
    // `test/font_literal_guard_test.dart`), matching the exact pattern
    // `skcode_raw_rail.dart` already established for this package.
    final monoStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: "monospace");

    return Container(
      key: const Key("skcodeInjectComposer"),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              key: const Key("skcodeInjectFieldFrame"),
              // FLAT field: a rectangular container with only a colored left
              // edge, never an OutlineInputBorder / rounded chat-bubble
              // shape. That shape difference is itself part of the "share
              // no styling token" contract with a chat composer.
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(left: BorderSide(color: amber, width: 3)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  // The persistent, non-dismissable target chip. Deliberately
                  // no IconButton/close affordance anywhere near it.
                  Container(
                    key: const Key("skcodeInjectTargetChip"),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: amber.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      "INJECT -> ${widget.sid}",
                      style: monoStyle?.copyWith(color: amber, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key("skcodeInjectField"),
                      controller: _controller,
                      focusNode: _focusNode,
                      style: monoStyle,
                      maxLines: 1,
                      decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key("skcodeInjectButton"),
            onPressed: _sending ? null : _submit,
            // The verb is ALWAYS "Inject", never "Send" (spec 7.1): a
            // "Send" button next to a session transcript is exactly the
            // wrong-composer mistake this whole card exists to prevent.
            child: const Text("Inject"),
          ),
        ],
      ),
    );
  }
}
