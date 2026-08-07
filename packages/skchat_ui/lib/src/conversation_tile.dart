import 'package:flutter/material.dart';

import 'chat_text.dart';
import 'group_composite_avatar.dart';
import 'models/conversation.dart';
import 'models/peer_trust.dart';
import 'theme/glass_widgets.dart';
import 'theme/sovereign_colors.dart';
import 'trust_badge.dart';

/// A single conversation row in the extracted chats list (reconciled spec 3.2).
///
/// This is a FAITHFUL SUBSET of the app's
/// `lib/features/chats/widgets/conversation_tile.dart`: it renders the same
/// Sovereign Glass card, soul-color avatar, name, timestamp, E2E badge,
/// last-message preview (via [displayTextFor]), delivery status and unread
/// count, plus the two pieces the earlier increments deferred:
///   * the TRUST BADGE, rendered from the injected [trust] view-model (a
///     package-pure [PeerTrust] the app resolves from `peer_trust_store` /
///     `group_trust` and hands in; null means no badge), and
///   * the GROUP COMPOSITE AVATAR ([GroupCompositeAvatar]) for a group row,
///     falling back to the [SoulAvatar] with initials for a 1:1.
///
/// It stays a plain [StatelessWidget] with NO Riverpod, NO `peer_trust_store`
/// provider graph and NO Hive: the trust standing is INJECTED as [trust]
/// (resolved app-side), never imported, so the import gate (spec 3.2 step 4)
/// still holds and a standalone / unwired mount renders cleanly with no badge.
class ConversationListTile extends StatelessWidget {
  const ConversationListTile({
    super.key,
    required this.conversation,
    this.onTap,
    this.trust,
  });

  final Conversation conversation;
  final VoidCallback? onTap;

  /// Injected trust view-model for this row (resolved app-side from the real
  /// trust store). Null renders no badge, so standalone / unwired still works.
  final PeerTrust? trust;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final soul = conversation.resolvedSoulColor;
    final unread = conversation.unreadCount > 0;
    final outboundLast = _isOutboundLast(conversation);
    final preview = conversation.isTyping
        ? _typingText(conversation)
        : (displayTextFor(conversation.lastMessage) ?? '[system message]');

    // guest-dm C3: a guest DM renders with the anti-spoofing title (alias wins,
    // else `guest: <name>` in untrusted styling) - never the raw group name.
    final isGuest = conversation.isGuestDm;
    final title = isGuest ? conversation.guestTitle : conversation.displayName;
    // An operator alias renders like a real contact; a guest self-name is
    // visually marked untrusted so a guest naming itself "Chef" cannot pass as a
    // real contact.
    final untrustedName = isGuest && !conversation.hasGuestAlias;
    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // A group row renders the composite/stacked-member avatar; a 1:1
            // row keeps the soul-color SoulAvatar with its initials.
            if (conversation.isGroup)
              GroupCompositeAvatar(
                members: conversation.members,
                fallbackColor: soul,
                size: 48,
              )
            else
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
                          title,
                          style: tt.titleSmall?.copyWith(
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w600,
                            color: untrustedName
                                ? SovereignColors.accentWarning
                                : null,
                            fontStyle:
                                untrustedName ? FontStyle.italic : FontStyle.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // guest-dm C3: a Guest badge marks the row as an untrusted
                      // guest DM even when an operator alias makes the title read
                      // like a real contact.
                      if (isGuest) ...[
                        const SizedBox(width: 6),
                        const _GuestChip(),
                      ],
                      // Trust badge (injected). Renders only when the app fed
                      // trust data for this row; mirrors the app tile placing
                      // it right after the name, before the timestamp.
                      if (trust != null) ...[
                        const SizedBox(width: 6),
                        TrustBadge(level: trust!.level, compact: true),
                      ],
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
                        isGuest
                            ? (conversation.isGuestRevoked
                                ? 'Revoked'
                                : conversation.isGuestExpired
                                    ? 'Expired'
                                    : 'Guest DM')
                            : conversation.isGroup
                                ? 'Group'
                                : 'E2E',
                        style: tt.labelSmall?.copyWith(
                          color: conversation.isGuestInactive
                              ? SovereignColors.textTertiary
                              : isGuest
                                  ? SovereignColors.accentWarning
                                  : SovereignColors.accentEncrypt,
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
    // A revoked/expired guest DM is dimmed (still visible, no longer live).
    return conversation.isGuestInactive
        ? Opacity(opacity: 0.55, child: tile)
        : tile;
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

/// guest-dm C3: a small "Guest" chip marking an untrusted guest-DM row.
class _GuestChip extends StatelessWidget {
  const _GuestChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: SovereignColors.accentWarning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: SovereignColors.accentWarning.withValues(alpha: 0.4)),
      ),
      child: const Text(
        'Guest',
        style: TextStyle(
          color: SovereignColors.accentWarning,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
