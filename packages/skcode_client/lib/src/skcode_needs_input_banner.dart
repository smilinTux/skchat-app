import "package:flutter/material.dart";

import "skcode_activity_taxonomy.dart";
import "skcode_tone_style.dart";

/// The needs_input permission banner (card C-5, spec section 7.1 / AC2): a
/// `needs_input` event (render class [ActivityRenderClass.permission], tone
/// [ActivityTone.admin], already classified by card C-4's taxonomy) pins
/// this banner directly above the inject composer, never buried in the
/// transcript scroll where an operator could miss it while an agent session
/// sits blocked.
///
/// Today the ONLY emitter of `needs_input` on hostd is a failed ratify gate
/// (`skharness daemon.py::ratify_session`: "a failed gate needs an
/// operator"), so this banner's two actions map onto hostd's two write
/// routes the way the spec's routing table states it
/// ("ratify/approve needs_input"):
///   * **Approve** calls `POST .../ratify` again (retry the grade now that
///     an operator has looked; ratify only ever grades, it never
///     merges/commits/pushes, so approving here can never actuate more than
///     hostd's own `/ratify` route already does).
///   * **Deny** sends a literal `"n"` keystroke through `POST .../inject`
///     (the general "answer the running session" surface): hostd has no
///     dedicated deny/reject route, and `needs_input` is a general
///     permission-prompt render class (per `skcode_activity_taxonomy.dart`'s
///     doc comment) that is not hard-wired to the ratify-gate case forever,
///     so a plain negative keystroke is the honest answer to "no" for
///     whatever is on the other end of the PTY.
/// Either action dismisses the banner locally once it resolves; a fresh
/// `needs_input` event (a new [ActivityRecord] row id) pins a fresh banner.
class SkcodeNeedsInputBanner extends StatelessWidget {
  const SkcodeNeedsInputBanner({
    super.key,
    required this.text,
    required this.onApprove,
    required this.onDeny,
    this.busy = false,
  });

  /// The needs_input event's own text (falls back to a generic label
  /// upstream when empty; see `SkcodeSessionScreen`).
  final String text;

  final VoidCallback onApprove;
  final VoidCallback onDeny;

  /// True while an Approve/Deny action is in flight: both buttons disable
  /// (never allow a double-fire onto `/ratify` or `/inject`).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final adminColor = skcodeToneColor(context, ActivityTone.admin);

    return Material(
      key: const Key("skcodeNeedsInputBanner"),
      color: adminColor.withValues(alpha: 0.12),
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: adminColor, width: 3))),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_outlined, color: adminColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: adminColor),
              ),
            ),
            TextButton(
              key: const Key("skcodeNeedsInputDeny"),
              onPressed: busy ? null : onDeny,
              child: const Text("Deny"),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const Key("skcodeNeedsInputApprove"),
              onPressed: busy ? null : onApprove,
              child: const Text("Approve"),
            ),
          ],
        ),
      ),
    );
  }
}
