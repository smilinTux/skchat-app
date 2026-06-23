import 'package:flutter/material.dart';
import '../../../core/theme/theme.dart';
import '../../../core/chat_text.dart';
import '../../../models/chat_message.dart';

/// A compact quoted-reply block rendered *inside* a message bubble, above the
/// body, when the message has a `reply_to_id`. Tapping it asks the caller to
/// scroll to the original message.
///
/// [original] is the resolved replied-to message, or null if it isn't in the
/// loaded window (then we show a muted "Original message" placeholder so the
/// quote still renders).
class QuotedReply extends StatelessWidget {
  const QuotedReply({
    super.key,
    required this.original,
    required this.accent,
    this.onTap,
  });

  final ChatMessage? original;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final senderLabel = original == null
        ? ''
        : (original!.isOutbound ? 'You' : (original!.senderName ?? 'Them'));
    final preview = original == null
        ? 'Original message'
        : (displayTextFor(original!.content) ?? original!.content);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(color: accent, width: 3),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (senderLabel.isNotEmpty)
              Text(
                senderLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: SovereignColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
