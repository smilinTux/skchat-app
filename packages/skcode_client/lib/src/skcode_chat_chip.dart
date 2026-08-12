import "package:flutter/material.dart";

/// The phone-tier project-chat entry point (card C-12, spec section 7,
/// "PHONE ... project chat is a header chip on the landing and session
/// screens that pushes the group's native skchat thread screen"). Below
/// pane width 900 there is no room for a chat column or even a collapsed
/// tab, so the whole ask-left-watch-right layout gives way to this single
/// honest affordance: tap it, read/answer in the real thread screen, switch
/// back. Spec 7's own words: "that is a real limitation of the decision,
/// not something this spec can style away."
///
/// This widget renders the chip only; [onTap] is the caller's job (normally
/// pushing whatever the host's project-chat builder returns). Carries no
/// chat transport of its own.
class SkcodeChatChip extends StatelessWidget {
  const SkcodeChatChip({super.key, required this.onTap, this.repo});

  final VoidCallback onTap;

  /// The bound repo, shown in the label when known (`Chat: <repo>`); a null
  /// or empty value renders the bare "Chat" label instead.
  final String? repo;

  @override
  Widget build(BuildContext context) {
    final label = (repo != null && repo!.isNotEmpty) ? "Chat: $repo" : "Chat";
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          key: const Key("skcodeChatChip"),
          avatar: const Icon(Icons.forum_outlined, size: 18),
          label: Text(label),
          onPressed: onTap,
        ),
      ),
    );
  }
}
