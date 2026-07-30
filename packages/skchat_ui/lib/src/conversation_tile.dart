import 'package:flutter/material.dart';

import 'chat_text.dart';
import 'models/conversation.dart';
import 'theme/glass_widgets.dart';
import 'theme/sovereign_colors.dart';

/// A single conversation row in the extracted chats list (reconciled spec 3.2).
///
/// This is a FAITHFUL SUBSET of the app's
/// `lib/features/chats/widgets/conversation_tile.dart`: it renders the same
/// Sovereign Glass card, soul-color [SoulAvatar], name, timestamp, E2E badge,
/// last-message preview (via [displayTextFor]), delivery status and unread
/// count, but it is a plain [StatelessWidget] with NO Riverpod, NO
/// `peer_trust_store` provider graph and NO Hive. That entanglement is why the
/// full ConsumerWidget tile cannot move into this package yet (the import gate,
/// spec 3.2 step 4, forbids skchat_ui importing a shell/app package).
///
/// TODO(skchat-ui-extraction): restore the two dropped affordances once their
/// dependencies are extracted into this package:
///   * the per-row / aggregate trust badge (needs `peer_trust_store`,
///     `trust_badge`, `group_trust`, all Riverpod providers), and
///   * the group composite avatar (needs `group_composite_avatar`).
/// A group row currently falls back to a [SoulAvatar] with the group initials
/// instead of the composite avatar.
class ConversationListTile extends StatelessWidget {
  const ConversationListTile({
    super.key,
    required this.conversation,
    this.onTap,
  });

  final Conversation conversation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final soul = conversation.resolvedSoulColor;
    final unread = conversation.unreadCount > 0;
    final outboundLast = _isOutboundLast(conversation);
    final preview = conversation.isTyping
        ? _typingText(conversation)
        : (displayTextFor(conversation.lastMessage) ?? '[system message]');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Faithful-subset avatar: the composite group avatar is a TODO, so
            // a group row uses the same SoulAvatar with its group initials.
            SoulAvatar(
              soulColor: soul,
              initials: conversation.resolvedInitials,
              isOnline: conversation.isOnline,
              isAgent: conversation.isAgent,
              size: 48,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.displayName,
                          style: tt.titleSmall?.copyWith(
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(conversation.lastMessageTime),
                        style: tt.labelSmall?.copyWith(
                          color:
                              unread ? soul : SovereignColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
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
                      if (outboundLast && !conversation.isTyping) ...[
                        DeliveryStatus(
                          status: conversation.lastDeliveryStatus,
                          soulColor: soul,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          preview,
                          style: tt.bodySmall?.copyWith(
                            color: conversation.isTyping
                                ? soul.withValues(alpha: 0.8)
                                : unread
                                    ? SovereignColors.textPrimary
                                    : SovereignColors.textSecondary,
                            fontStyle: conversation.isTyping
                                ? FontStyle.italic
                                : FontStyle.normal,
                            fontWeight:
                                unread ? FontWeight.w500 : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unread) ...[
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

  /// Whether the last message was sent by the local user. Approximated from
  /// the delivery status being a sent/delivered/read marker while not typing
  /// (mirrors the app tile's `isOutboundLast` extension).
  bool _isOutboundLast(Conversation c) =>
      !c.isTyping &&
      (c.lastDeliveryStatus == 'sent' ||
          c.lastDeliveryStatus == 'delivered' ||
          c.lastDeliveryStatus == 'read');

  String _typingText(Conversation c) =>
      c.isAgent ? '${c.displayName} is composing...' : 'typing...';

  static const List<String> _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  /// Relative time formatting. Kept intl-free so the package adds no new
  /// dependency beyond skworld_module_api + Flutter (import gate, spec 3.2
  /// step 4).
  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return _weekdays[local.weekday - 1];
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '$mm/$dd';
  }
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
