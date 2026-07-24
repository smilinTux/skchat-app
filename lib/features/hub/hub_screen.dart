import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../services/consent_service.dart';
import '../../services/self_identity_provider.dart';
import '../conf/conf_screen.dart' show ConfArgs;

/// HubScreen, the operator "Ops" surface.
///
/// The bottom nav stays small (5 items), so the operator-control surfaces that
/// don't fit there live here as discoverable glass tiles. Every destination is
/// reachable in <= 2 taps (Ops tab -> tile).
///
/// Tiles route to: /cluster, /coord, /recordings, /conf, /groups.
/// (SkMap moved to the swipe-up app drawer, it is now a registry module.)
/// Room is intentionally left for a future /facetime tile (added by a parallel
/// branch), see [_OpsTile] list below.
class HubScreen extends ConsumerWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The unified self identity: the daemon's identity for an operator
    // (unchanged), or this device's own per-device identity for a guest, so
    // a guest-hosted conference never derives its room from the operator's
    // fingerprint. Watch it (ignoring the value) purely so this widget
    // rebuilds once it resolves; the actual value selection goes through the
    // operator-aware synchronous helper below, which never falls back to the
    // operator's identity for a guest, even pre-resolution.
    ref.watch(selfIdentityProvider);
    final selfFingerprint = selfFingerprintNowFromWidget(ref);
    final selfDisplayName = selfDisplayNameNowFromWidget(ref);
    final pendingRequests = ref.watch(consentPendingCountProvider);

    final tiles = <_OpsTile>[
      _OpsTile(
        label: 'Cluster',
        description: 'skbloom cluster control',
        icon: Icons.hub_outlined,
        accent: SovereignColors.soulJarvis,
        onTap: () => context.go(AppRoutes.cluster),
      ),
      _OpsTile(
        label: 'skos Files',
        description: 'Browse + search the sovereign disk (P7 access plane)',
        icon: Icons.folder_special_outlined,
        accent: SovereignColors.soulLumina,
        onTap: () => context.go(AppRoutes.skosFiles),
      ),
      _OpsTile(
        label: 'skos Control',
        description: 'Per-node health & access-plane status',
        icon: Icons.dns_outlined,
        accent: SovereignColors.accentEncrypt,
        onTap: () => context.go(AppRoutes.skosControl),
      ),
      _OpsTile(
        label: 'Coord Board',
        description: 'Agent coordination tasks',
        icon: Icons.dashboard_customize_outlined,
        accent: SovereignColors.soulLumina,
        onTap: () => context.go(AppRoutes.coord),
      ),
      _OpsTile(
        label: 'Recordings',
        description: 'Call & space recordings',
        icon: Icons.fiber_manual_record_outlined,
        accent: SovereignColors.accentDanger,
        onTap: () => context.go(AppRoutes.recordings),
      ),
      _OpsTile(
        label: 'Conferences',
        description: 'Sovereign video rooms',
        icon: Icons.video_camera_front_outlined,
        accent: SovereignColors.accentEncrypt,
        // /conf needs a ConfArgs(identity) via `extra`. Start a fresh room
        // using the resolved self identity: the operator's daemon
        // fingerprint (unchanged) when this device is enrolled, or this
        // device's own per-device guest id otherwise.
        onTap: () => context.push(
          AppRoutes.conf,
          extra: ConfArgs(
            identity: selfFingerprint.isNotEmpty
                ? selfFingerprint
                : selfDisplayName,
            name: selfDisplayName,
            role: 'host',
            createTitle: 'Conference',
          ),
        ),
      ),
      _OpsTile(
        label: 'Contact Requests',
        description: pendingRequests > 0
            ? '$pendingRequests pending first-contact '
                '${pendingRequests == 1 ? 'request' : 'requests'}'
            : 'Review first-contact requests',
        icon: Icons.person_add_alt_1_outlined,
        accent: SovereignColors.soulLumina,
        badge: pendingRequests,
        onTap: () => context.go(AppRoutes.requests),
      ),
    ];

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 8),
              sliver: SliverToBoxAdapter(
                child: _HubHeader(),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              sliver: SliverList.separated(
                itemCount: tiles.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, i) => tiles[i],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HubHeader extends StatelessWidget {
  const _HubHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Operator Hub',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: SovereignColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Control surfaces for your sovereign node',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: SovereignColors.textSecondary,
              ),
        ),
      ],
    );
  }
}

class _OpsTile extends StatelessWidget {
  const _OpsTile({
    required this.label,
    required this.description,
    required this.icon,
    required this.accent,
    required this.onTap,
    this.badge = 0,
  });

  final String label;
  final String description;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  /// Unread/pending count rendered as a pill before the chevron (hidden at 0).
  final int badge;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: SovereignColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: SovereignColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
          if (badge > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                badge > 99 ? '99+' : '$badge',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: SovereignColors.surfaceBase,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          const Icon(
            Icons.chevron_right_rounded,
            color: SovereignColors.textTertiary,
          ),
        ],
      ),
    );
  }
}
