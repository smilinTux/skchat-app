import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/sovereign_colors.dart';
import '../../../services/pq_conversation_service.dart';

/// 🔐 Post-quantum indicator for a conversation.
///
/// Renders a small shield + "PQ" pill ONLY when the conversation has been
/// hybrid-negotiated (`x25519-mlkem768`, both sides advertise a prekey and a
/// hybrid DM has been sealed/opened). For classical / not-yet-negotiated
/// conversations it renders nothing, so the existing 🔒 [EncryptBadge] still
/// communicates classical E2E without implying post-quantum.
class PostQuantumBadge extends ConsumerWidget {
  const PostQuantumBadge({super.key, required this.peerId, this.compact = false});

  /// The conversation peer (short name or fqid).
  final String peerId;

  /// Compact mode (chat-list tiles): icon only, no "PQ" label.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Normalize to the short key the service records under.
    final key = _short(peerId);
    final state = ref.watch(conversationPqStateProvider(key));
    if (state != PqConversationState.hybridPq) {
      return const SizedBox.shrink();
    }
    const color = SovereignColors.accentEncrypt;
    if (compact) {
      return const Tooltip(
        message: 'Post-quantum (X25519 + ML-KEM-768)',
        child: Icon(Icons.shield_moon_outlined, size: 12, color: color),
      );
    }
    return Tooltip(
      message: 'Hybrid post-quantum: X25519 + ML-KEM-768',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_moon_outlined, size: 13, color: color),
            SizedBox(width: 3),
            Text(
              'PQ',
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _short(String uri) {
    var s = uri.startsWith('capauth:') ? uri.substring('capauth:'.length) : uri;
    return s.split('@').first;
  }
}
