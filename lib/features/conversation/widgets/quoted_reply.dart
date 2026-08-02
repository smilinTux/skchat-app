import 'package:flutter/material.dart';
import '../../../core/theme/theme.dart';
import '../../../core/chat_text.dart';
import '../../../models/chat_message.dart';
import '../../../services/pq_dm_codec.dart';

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

  /// Muted placeholder shown when the replied-to message is a hybrid-sealed DM
  /// this device could not open (or a raw `pqdm1:` token that reached the quote
  /// un-resolved). Kept generic on purpose: a compact quote should not leak the
  /// internal "can't be opened on this device" detail, only that it is sealed.
  static const String sealedPreviewText = '🔐 Encrypted message';

  /// Whether the replied-to message must render as a sealed placeholder rather
  /// than as text. Two signals, either is sufficient:
  /// - [ChatMessage.pqLocked]: the provider tried to open the token and could
  ///   NOT (no key / sealed to another device) — the same locked state the main
  ///   bubble shows.
  /// - the stored [ChatMessage.content] is STILL a raw `pqdm1:` token: a
  ///   defensive guard so the quote never renders ciphertext even if an
  ///   un-decrypted copy slips through (the main bubble reads the same decrypted
  ///   `content`, so this keeps the two in lock-step).
  bool get _sealed {
    final o = original;
    if (o == null) return false;
    return o.pqLocked || PqDmCodec.isHybridToken(o.content);
  }

  @override
  Widget build(BuildContext context) {
    final sealed = _sealed;
    final senderLabel = original == null
        ? ''
        : (original!.isOutbound ? 'You' : (original!.senderName ?? 'Them'));
    final preview = original == null
        ? 'Original message'
        : (sealed
            ? sealedPreviewText
            : (displayTextFor(original!.content) ?? original!.content));

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
              style: TextStyle(
                fontSize: 12.5,
                color: SovereignColors.textSecondary
                    .withValues(alpha: sealed ? 0.7 : 1.0),
                fontStyle: sealed ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
