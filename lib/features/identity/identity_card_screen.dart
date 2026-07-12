import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../core/theme/glass_widgets.dart';
import '../../models/conversation.dart';
import '../../services/skcomms_client.dart';

/// Agent Identity Card screen.
///
/// Displays a rich profile for any CapAuth-identified peer (human or agent).
/// Navigation is handled by the caller (Jarvis), this screen receives the
/// [Conversation] it describes and an optional [onSendMessage] callback.
///
/// Route: `/identity/:peerId`
/// Expects `extra: IdentityCardArgs(conversation: ...)` via GoRouter.
class IdentityCardScreen extends ConsumerWidget {
  const IdentityCardScreen({
    super.key,
    required this.conversation,
    this.onSendMessage,
  });

  /// The peer whose identity is being displayed.
  final Conversation conversation;

  /// Called when the user taps "Send Message". The navigator pop + push to
  /// conversation is wired by Jarvis via this callback.
  final VoidCallback? onSendMessage;

  // ── Real identity data ─────────────────────────────────────────────────────
  // Sourced from the [Conversation] (populated from the SKComms daemon's
  // /api/v1/peers) and the resolved peer record (see [_peerInfoProvider]).
  // No values are fabricated: anything the daemon does not provide is shown as
  // an honest "unknown" state rather than a placeholder constant.

  /// CapAuth FQID in the daemon's canonical form, e.g. `capauth:lumina@skworld.io`.
  String get _capAuthId =>
      'capauth:${conversation.peerId.toLowerCase()}@skworld.io';

  /// The peer's real PGP fingerprint, or null if the daemon hasn't supplied one.
  ///
  /// [Conversation.soulFingerprint] is populated from `peer.fingerprint`, but
  /// the chats provider falls back to the peer name when the daemon returns
  /// null. We treat a value that equals the peer name (case-insensitive) as
  /// "no real fingerprint" so we never present a name as a key fingerprint.
  String? _resolvedFingerprint(PeerInfo? peer) {
    final fromPeer = peer?.fingerprint;
    if (fromPeer != null && fromPeer.trim().isNotEmpty) return fromPeer;
    final fromConv = conversation.soulFingerprint;
    if (fromConv == null || fromConv.trim().isEmpty) return null;
    if (fromConv.toLowerCase() == conversation.peerId.toLowerCase()) {
      return null; // name fallback, not a real fingerprint
    }
    return fromConv;
  }

  Color get _soulColor => conversation.resolvedSoulColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Resolve the live peer record (real fingerprint + last-seen) from the
    // daemon. Falls back gracefully when the daemon is offline or unknown.
    final peerAsync = ref.watch(_peerInfoProvider(conversation.peerId));
    final peer = peerAsync.valueOrNull;
    final fingerprint = _resolvedFingerprint(peer);
    final lastSeen = peer?.lastSeen;
    // "Verified" is only true when we hold a real cryptographic fingerprint for
    // the peer; otherwise the identity is unverified (no fake date/badge).
    final isVerified = fingerprint != null;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          _SovereignSliverAppBar(
            conversation: conversation,
            soulColor: _soulColor,
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 20),
                _IdentitySection(
                  capAuthId: _capAuthId,
                  fingerprint: fingerprint,
                  isVerified: isVerified,
                  isOnline: conversation.isOnline,
                  lastSeen: lastSeen,
                  soulColor: _soulColor,
                ),
                const SizedBox(height: 12),
                _EncryptionSection(
                  isVerified: isVerified,
                  hasFingerprint: fingerprint != null,
                  soulColor: _soulColor,
                ),
                const SizedBox(height: 24),
                _SendMessageButton(
                  displayName: conversation.displayName,
                  soulColor: _soulColor,
                  onPressed: onSendMessage ?? () => Navigator.of(context).pop(),
                ),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Peer resolution provider
// ─────────────────────────────────────────────────────────────────────────────

/// Resolves the live [PeerInfo] for a given peer id from the SKComms daemon.
///
/// Returns null when the daemon is offline or the peer is not yet known, in
/// which case the card falls back to whatever the [Conversation] already
/// carries (and shows honest "unknown" states for anything missing).
final _peerInfoProvider =
    FutureProvider.family<PeerInfo?, String>((ref, peerId) async {
  final client = ref.watch(skcommsClientProvider);
  try {
    if (!await client.isAlive()) return null;
    final peers = await client.getPeers();
    final wanted = peerId.toLowerCase();
    for (final p in peers) {
      if (p.name.toLowerCase() == wanted) return p;
    }
    return null;
  } catch (_) {
    return null;
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Sliver App Bar with soul-color gradient hero header
// ─────────────────────────────────────────────────────────────────────────────

class _SovereignSliverAppBar extends StatelessWidget {
  const _SovereignSliverAppBar({
    required this.conversation,
    required this.soulColor,
  });

  final Conversation conversation;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 240,
      pinned: true,
      backgroundColor: SovereignColors.surfaceBase,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, color: SovereignColors.textPrimary),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: const Text(
        'Agent Profile',
        style: TextStyle(
          color: SovereignColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: _HeaderBackground(
          conversation: conversation,
          soulColor: soulColor,
        ),
      ),
    );
  }
}

class _HeaderBackground extends StatelessWidget {
  const _HeaderBackground({
    required this.conversation,
    required this.soulColor,
  });

  final Conversation conversation;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Soul-color radial glow
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.2,
              colors: [
                soulColor.withValues(alpha: 0.22),
                soulColor.withValues(alpha: 0.06),
                SovereignColors.surfaceBase,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        ),
        // Blur layer for the glass feel
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 0, sigmaY: 0),
          child: const SizedBox.expand(),
        ),
        // Avatar + name centered
        SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              // Large soul avatar with glowing ring
              _GlowingAvatar(conversation: conversation, soulColor: soulColor),
              const SizedBox(height: 14),
              Text(
                conversation.displayName.toUpperCase(),
                style: TextStyle(
                  color: SovereignColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                  shadows: [
                    Shadow(
                      color: soulColor.withValues(alpha: 0.6),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              if (conversation.isAgent)
                Text(
                  'Sovereign AI Agent',
                  style: TextStyle(
                    color: soulColor.withValues(alpha: 0.8),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2,
                  ),
                )
              else
                Text(
                  conversation.isOnline ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: conversation.isOnline
                        ? SovereignColors.accentEncrypt
                        : SovereignColors.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlowingAvatar extends StatelessWidget {
  const _GlowingAvatar({required this.conversation, required this.soulColor});

  final Conversation conversation;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: soulColor.withValues(alpha: 0.5),
            blurRadius: 28,
            spreadRadius: 4,
          ),
        ],
      ),
      child: SoulAvatar(
        soulColor: soulColor,
        initials: conversation.resolvedInitials,
        imageUrl: conversation.avatarUrl,
        size: 88,
        isOnline: conversation.isOnline,
        isAgent: conversation.isAgent,
        ringWidth: 3,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Identity section
// ─────────────────────────────────────────────────────────────────────────────

class _IdentitySection extends StatelessWidget {
  const _IdentitySection({
    required this.capAuthId,
    required this.fingerprint,
    required this.isVerified,
    required this.isOnline,
    required this.lastSeen,
    required this.soulColor,
  });

  final String capAuthId;

  /// Real PGP fingerprint, or null when the daemon has not supplied one.
  final String? fingerprint;
  final bool isVerified;
  final bool isOnline;
  final DateTime? lastSeen;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(title: 'Identity', soulColor: soulColor),
          const SizedBox(height: 12),
          _InfoRow(
            icon: Icons.fingerprint,
            label: 'CapAuth ID',
            value: capAuthId,
            soulColor: soulColor,
            monospace: true,
            isSmall: true,
          ),
          const SizedBox(height: 8),
          _FingerprintRow(fingerprint: fingerprint, soulColor: soulColor),
          const SizedBox(height: 8),
          _InfoRow(
            icon: isVerified ? Icons.verified : Icons.gpp_maybe,
            label: 'Verified',
            value: isVerified
                ? 'Key on file'
                : 'Unverified, no key on file',
            soulColor: soulColor,
            valueColor: isVerified
                ? SovereignColors.accentEncrypt
                : SovereignColors.textTertiary,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            icon: isOnline ? Icons.circle : Icons.schedule,
            label: 'Presence',
            value: isOnline
                ? 'Online'
                : (lastSeen != null
                    ? 'Last seen ${_relativeTime(lastSeen!)}'
                    : 'Offline'),
            soulColor: soulColor,
            valueColor: isOnline
                ? SovereignColors.accentEncrypt
                : SovereignColors.textPrimary,
          ),
        ],
      ),
    );
  }
}

/// Compact relative-time formatter (e.g. "2h ago", "3d ago").
String _relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({required this.fingerprint, required this.soulColor});

  /// Real PGP fingerprint, or null when none is available from the daemon.
  final String? fingerprint;
  final Color soulColor;

  Future<void> _copyToClipboard(BuildContext context) async {
    final fp = fingerprint;
    if (fp == null) return;
    await Clipboard.setData(ClipboardData(text: fp));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Fingerprint copied'),
        backgroundColor: SovereignColors.surfaceRaised,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasFp = fingerprint != null;
    return Row(
      children: [
        Icon(Icons.key, size: 15, color: soulColor.withValues(alpha: 0.7)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Fingerprint',
                style: TextStyle(
                  color: SovereignColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              GestureDetector(
                onTap: hasFp ? () => _copyToClipboard(context) : null,
                child: Text(
                  hasFp ? fingerprint! : 'Unknown, no key on file',
                  style: TextStyle(
                    color: hasFp
                        ? SovereignColors.textPrimary
                        : SovereignColors.textTertiary,
                    fontSize: 13,
                    fontFamily: hasFp ? 'JetBrainsMono' : null,
                    letterSpacing: hasFp ? 0.5 : 0,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasFp)
          IconButton(
            icon: Icon(Icons.copy,
                size: 15, color: soulColor.withValues(alpha: 0.6)),
            onPressed: () => _copyToClipboard(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Copy fingerprint',
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Encryption section
// ─────────────────────────────────────────────────────────────────────────────

class _EncryptionSection extends StatelessWidget {
  const _EncryptionSection({
    required this.isVerified,
    required this.hasFingerprint,
    required this.soulColor,
  });

  /// True when we hold a real fingerprint for the peer.
  final bool isVerified;
  final bool hasFingerprint;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(title: 'Encryption', soulColor: soulColor),
          const SizedBox(height: 12),
          _InfoRow(
            icon: hasFingerprint ? Icons.lock : Icons.lock_open,
            label: 'PGP Key',
            value: hasFingerprint ? 'On file' : 'Not yet exchanged',
            soulColor: soulColor,
            valueColor: hasFingerprint
                ? SovereignColors.accentEncrypt
                : SovereignColors.textTertiary,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            icon: Icons.verified_user,
            label: 'Trust Level',
            value: isVerified ? 'Verified' : 'Unverified',
            soulColor: soulColor,
            valueColor: isVerified
                ? SovereignColors.accentEncrypt
                : SovereignColors.textTertiary,
          ),
          const SizedBox(height: 14),
          // "Verify Key" placeholder button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                // Placeholder, Jarvis wires the fingerprint comparison screen.
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Fingerprint comparison coming soon'),
                    backgroundColor: SovereignColors.surfaceRaised,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              },
              icon: Icon(Icons.qr_code_scanner, size: 16, color: soulColor),
              label: Text(
                'Compare Fingerprints',
                style: TextStyle(color: soulColor, fontSize: 13),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: soulColor.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Send Message button
// ─────────────────────────────────────────────────────────────────────────────

class _SendMessageButton extends StatelessWidget {
  const _SendMessageButton({
    required this.displayName,
    required this.soulColor,
    required this.onPressed,
  });

  final String displayName;
  final Color soulColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              soulColor.withValues(alpha: 0.85),
              soulColor,
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: soulColor.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ElevatedButton.icon(
          onPressed: () {
            HapticFeedback.lightImpact();
            onPressed();
          },
          icon: const Icon(Icons.send_rounded, size: 18, color: Colors.black87),
          label: Text(
            'Send Message to $displayName',
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helper widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.soulColor});

  final String title;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: soulColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: SovereignColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.soulColor,
    this.valueColor,
    this.monospace = false,
    this.isSmall = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color soulColor;
  final Color? valueColor;
  final bool monospace;
  final bool isSmall;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 15,
          color: soulColor.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: SovereignColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: valueColor ?? SovereignColors.textPrimary,
                  fontSize: isSmall ? 12 : 14,
                  fontWeight: FontWeight.w500,
                  fontFamily: monospace ? 'JetBrainsMono' : null,
                  letterSpacing: monospace ? 0.3 : 0,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Route argument wrapper (used by GoRouter extra)
// ─────────────────────────────────────────────────────────────────────────────

/// Passed as `extra` when navigating to the identity card route.
class IdentityCardArgs {
  const IdentityCardArgs({
    required this.conversation,
    this.onSendMessage,
  });

  final Conversation conversation;
  final VoidCallback? onSendMessage;
}
