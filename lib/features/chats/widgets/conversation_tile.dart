import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/theme.dart';
import '../../../models/conversation.dart';
import '../../../core/chat_text.dart';
import '../../identity/widgets/trust_badge.dart';
import '../../../services/peer_trust_store.dart';

/// Glass card tile representing a single conversation in the chat list.
/// Shows soul-color avatar, name, last message, timestamp, encryption badge,
/// delivery status, and unread count.
class ConversationTile extends ConsumerWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final Conversation conversation;
  final VoidCallback onTap;

  /// A 1:1 row (never a group) with a known soul fingerprint has trust
  /// standing worth showing/recording. Group rows and fingerprint-less rows
  /// stay silent.
  bool get _hasTrustStanding =>
      conversation.isGroup != true &&
      (conversation.soulFingerprint?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final soul = conversation.resolvedSoulColor;

    // Only 1:1 rows with a known fingerprint have trust standing. Recording
    // the sight here (post-frame, so it never runs mid-build) keeps the TOFU
    // store fresh; recordSight is a no-op when the fingerprint is unchanged,
    // so an occasional extra call on rebuild is harmless.
    PeerTrustTier? tier;
    if (_hasTrustStanding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(peerTrustControllerProvider)
            .recordSight(conversation.peerId, conversation.soulFingerprint);
      });
      tier = ref
          .watch(peerTrustTierProvider(
              (peerId: conversation.peerId,
                  fingerprint: conversation.soulFingerprint)))
          .valueOrNull ??
          PeerTrustTier.red;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── Avatar ──────────────────────────────────────────────────
            SoulAvatar(
              soulColor: soul,
              initials: conversation.resolvedInitials,
              isOnline: conversation.isOnline,
              isAgent: conversation.isAgent,
              size: 48,
            ),
            const SizedBox(width: 12),

            // ── Main content ─────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + timestamp row
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.displayName,
                          style: tt.titleSmall?.copyWith(
                            fontWeight: conversation.unreadCount > 0
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (tier != null) ...[
                        const SizedBox(width: 6),
                        TrustBadge(tier: selfTierForPeer(tier), compact: true),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(conversation.lastMessageTime),
                        style: tt.labelSmall?.copyWith(
                          color: conversation.unreadCount > 0
                              ? soul
                              : SovereignColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),

                  // Last message + unread badge row
                  Row(
                    children: [
                      // Encrypt badge
                      const EncryptBadge(size: 11),
                      const SizedBox(width: 4),
                      Text(
                        conversation.isGroup ? 'Group' : 'E2E',
                        style: tt.labelSmall?.copyWith(
                          color: SovereignColors.accentEncrypt,
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (!conversation.isOutboundLast)
                        Expanded(
                          child: Text(
                            conversation.isTyping
                                ? _typingText(conversation)
                                : (displayTextFor(conversation.lastMessage) ??
                                    '[system message]'),
                            style: tt.bodySmall?.copyWith(
                              color: conversation.isTyping
                                  ? soul.withValues(alpha: 0.8)
                                  : conversation.unreadCount > 0
                                  ? SovereignColors.textPrimary
                                  : SovereignColors.textSecondary,
                              fontStyle: conversation.isTyping
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              fontWeight: conversation.unreadCount > 0
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        Expanded(
                          child: Row(
                            children: [
                              DeliveryStatus(
                                status: conversation.lastDeliveryStatus,
                                soulColor: soul,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  displayTextFor(conversation.lastMessage) ??
                                      '[system message]',
                                  style: tt.bodySmall?.copyWith(
                                    color: SovereignColors.textSecondary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Unread badge
                      if (conversation.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(
                          count: conversation.unreadCount,
                          soulColor: soul,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _typingText(Conversation c) {
    if (c.isAgent) {
      return '${c.displayName} is composing...';
    }
    return 'typing...';
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return DateFormat('EEE').format(local);
    return DateFormat('MM/dd').format(local);
  }
}

extension on Conversation {
  /// Whether the last message was sent by the local user.
  /// Approximated from deliveryStatus being present without isTyping.
  bool get isOutboundLast =>
      !isTyping &&
      (lastDeliveryStatus == 'sent' ||
          lastDeliveryStatus == 'delivered' ||
          lastDeliveryStatus == 'read');
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.soulColor});

  final int count;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: soulColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
