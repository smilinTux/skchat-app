import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/theme.dart';
import '../../../models/conversation.dart';
import '../../../core/chat_text.dart';
import '../../identity/widgets/trust_badge.dart';
import '../../../services/peer_trust_store.dart';
import '../group_trust.dart';
import 'group_composite_avatar.dart';

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

  /// A 1:1 row is never a group. Group rows never show/record trust
  /// standing (there is no single peer key to anchor it to).
  bool get _isDirect => conversation.isGroup != true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final soul = conversation.resolvedSoulColor;

    // 1:1 tier: resolve for any direct row (the provider maps a
    // missing/keyless/peerId-fallback fingerprint to `unverifiable`).
    final directTier = _isDirect
        ? ref
            .watch(peerTrustTierProvider(
                (peerId: conversation.peerId,
                    fingerprint: conversation.soulFingerprint)))
            .valueOrNull
        : null;

    // Group tier: watch each member's tier (memoized per (peerId,fingerprint)
    // across the app) and fold to one aggregate. red if any keyed member is
    // unverified, amber if all keyed are verified, null if keyless.
    final PeerTrustTier? groupTier = _isDirect
        ? null
        : foldGroupTier(conversation.members.map((m) => ref
            .watch(peerTrustTierProvider(
                (peerId: m.identityUri, fingerprint: m.soulFingerprint)))
            .valueOrNull));

    final PeerTrustTier? badgeTier = _isDirect ? directTier : groupTier;
    // A badge only makes sense for a REAL key (red = unverified, amber =
    // verified); unverifiable/none shows nothing.
    final showBadge =
        badgeTier == PeerTrustTier.red || badgeTier == PeerTrustTier.amber;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Invisible: records the sight once per mount (see
            // _RecordPeerSightState) instead of on every rebuild of this
            // row. recordSight is already a no-op for an unchanged/non-real
            // key, so this is a perf nicety, not a correctness need.
            if (_isDirect)
              _RecordPeerSight(
                peerId: conversation.peerId,
                fingerprint: conversation.soulFingerprint,
              ),
            // ── Avatar ──────────────────────────────────────────────────
            if (_isDirect)
              SoulAvatar(
                soulColor: soul,
                initials: conversation.resolvedInitials,
                isOnline: conversation.isOnline,
                isAgent: conversation.isAgent,
                size: 48,
              )
            else
              GroupCompositeAvatar(
                members: conversation.members,
                fallbackColor: soul,
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
                      if (showBadge) ...[
                        const SizedBox(width: 6),
                        TrustBadge(
                            tier: selfTierForPeer(badgeTier!), compact: true),
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

/// Invisible widget whose sole job is firing [PeerTrustController.recordSight]
/// once when it mounts, and again only if the (peerId, fingerprint) pair it
/// is given actually changes. Guards against the un-keyed [ListView.builder]
/// in the chats list reusing this row's Element/State for a DIFFERENT
/// conversation at the same index (list reorder), where a plain "recorded
/// once ever" bool would wrongly skip recording the new peer's first sight.
/// recordSight itself is a no-op for an unchanged or non-real key, so this
/// is purely a perf nicety, not a correctness need.
class _RecordPeerSight extends ConsumerStatefulWidget {
  const _RecordPeerSight({required this.peerId, required this.fingerprint});

  final String peerId;
  final String? fingerprint;

  @override
  ConsumerState<_RecordPeerSight> createState() => _RecordPeerSightState();
}

class _RecordPeerSightState extends ConsumerState<_RecordPeerSight> {
  @override
  void initState() {
    super.initState();
    _record();
  }

  @override
  void didUpdateWidget(covariant _RecordPeerSight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId ||
        oldWidget.fingerprint != widget.fingerprint) {
      _record();
    }
  }

  void _record() {
    final peerId = widget.peerId;
    final fingerprint = widget.fingerprint;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(peerTrustControllerProvider).recordSight(peerId, fingerprint);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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
