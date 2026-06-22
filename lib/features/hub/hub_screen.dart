import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../conf/conf_screen.dart' show ConfArgs;
import '../profile/profile_screen.dart' show localIdentityProvider;

/// HubScreen — the operator "Ops" surface.
///
/// The bottom nav stays small (5 items), so the operator-control surfaces that
/// don't fit there live here as discoverable glass tiles. Every destination is
/// reachable in <= 2 taps (Ops tab -> tile).
///
/// Tiles route to: /cluster, /coord, /recordings, /conf, /groups.
/// Room is intentionally left for a future /facetime tile (added by a parallel
/// branch) — see [_OpsTile] list below.
class HubScreen extends ConsumerWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(localIdentityProvider);

    final tiles = <_OpsTile>[
      _OpsTile(
        label: 'Cluster',
        description: 'skbloom cluster control',
        icon: Icons.hub_outlined,
        accent: SovereignColors.soulJarvis,
        onTap: () => context.go(AppRoutes.cluster),
      ),
      _OpsTile(
        label: 'SkMap',
        description: 'Tactical map — live unit positions',
        icon: Icons.radar_outlined,
        accent: SovereignColors.soulJarvis,
        onTap: () => context.go(AppRoutes.skmap),
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
        // /conf needs a ConfArgs(identity) via `extra`. Start a fresh
        // sovereign-hosted room using the local node's fingerprint.
        onTap: () => context.push(
          AppRoutes.conf,
          extra: ConfArgs(
            identity: identity.fingerprint.isNotEmpty
                ? identity.fingerprint
                : identity.displayName,
            name: identity.displayName,
            role: 'host',
            createTitle: 'Conference',
          ),
        ),
      ),
      _OpsTile(
        label: 'Groups',
        description: 'Group chats & members',
        icon: Icons.group_outlined,
        accent: SovereignColors.soulChef,
        onTap: () => context.go(AppRoutes.groups),
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
  });

  final String label;
  final String description;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

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
          const Icon(
            Icons.chevron_right_rounded,
            color: SovereignColors.textTertiary,
          ),
        ],
      ),
    );
  }
}
