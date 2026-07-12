import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import 'access_client.dart';
import 'skos_models.dart';
import 'skos_providers.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// SkosControlScreen, the (light) skos control surface (P9).
/// ─────────────────────────────────────────────────────────────────────────
///
/// For each node on the access plane it shows the `health` / `node_info`
/// picture, up/down, hostname, exposed-tool count, the exposed-root allowlist
///, so the operator can see the sovereign fabric at a glance. Cluster actions
/// (promote replica, grant scope, re-index) are stubbed behind a clearly
/// labelled TODO until the exec/RBAC tools (P7 A6/A7) are wired.
class SkosControlScreen extends ConsumerWidget {
  const SkosControlScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodes = ref.watch(knownNodesProvider);
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              sliver: SliverToBoxAdapter(child: _ControlHeader()),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              sliver: SliverList.separated(
                itemCount: nodes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) => _NodeCard(node: nodes[i]),
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 96),
              sliver: SliverToBoxAdapter(child: _ClusterActions()),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlHeader extends StatelessWidget {
  const _ControlHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'skos Control',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: SovereignColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'The sovereign access plane, one brain, one disk',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: SovereignColors.textSecondary,
              ),
        ),
      ],
    );
  }
}

class _NodeCard extends ConsumerWidget {
  const _NodeCard({required this.node});
  final String node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infoAsync = ref.watch(nodeInfoProvider(node));
    final baseUrl = kAccessNodes[node] ?? '-';

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusDot(async: infoAsync),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      accessNodeLabel(node),
                      style: const TextStyle(
                        color: SovereignColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      baseUrl,
                      style: const TextStyle(
                          color: SovereignColors.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded,
                    color: SovereignColors.textSecondary, size: 20),
                tooltip: 'Re-check',
                onPressed: () => ref.invalidate(nodeInfoProvider(node)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          infoAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) => _Detail(
              icon: Icons.error_outline_rounded,
              label: 'Error',
              value: e.toString(),
              color: SovereignColors.accentDanger,
            ),
            data: (info) => _NodeDetails(info: info),
          ),
        ],
      ),
    );
  }
}

class _NodeDetails extends StatelessWidget {
  const _NodeDetails({required this.info});
  final NodeInfo info;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Detail(
          icon: info.up ? Icons.check_circle_rounded : Icons.cancel_rounded,
          label: 'Status',
          value: info.up ? 'up' : 'down${info.detail != null ? ' · ${info.detail}' : ''}',
          color: info.up
              ? SovereignColors.accentEncrypt
              : SovereignColors.accentDanger,
        ),
        if (info.hostname != null)
          _Detail(
              icon: Icons.computer_rounded,
              label: 'Host',
              value: info.hostname!),
        _Detail(
            icon: Icons.build_circle_outlined,
            label: 'Tools',
            value: '${info.toolCount}'),
        if (info.exposedRoots.isNotEmpty)
          _Detail(
              icon: Icons.folder_open_rounded,
              label: 'Roots',
              value: info.exposedRoots.join(', ')),
        if (info.version != null)
          _Detail(
              icon: Icons.tag_rounded, label: 'Version', value: info.version!),
        if (info.up && info.detail != null)
          _Detail(
              icon: Icons.info_outline_rounded,
              label: 'Detail',
              value: info.detail!),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.async});
  final AsyncValue<NodeInfo> async;

  @override
  Widget build(BuildContext context) {
    final color = async.maybeWhen(
      data: (i) =>
          i.up ? SovereignColors.accentEncrypt : SovereignColors.accentDanger,
      error: (_, _) => SovereignColors.accentDanger,
      orElse: () => SovereignColors.textTertiary,
    );
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 16, color: color ?? SovereignColors.textTertiary),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            child: Text(label,
                style: const TextStyle(
                    color: SovereignColors.textSecondary, fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  color: color ?? SovereignColors.textPrimary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cluster actions, stubbed behind a clearly-labelled TODO. The promote /
/// grant-scope / re-index actions ride P7 A6 (RBAC scope grants) + A7 (skreachd
/// exec), neither of which the Flutter client drives yet.
class _ClusterActions extends StatelessWidget {
  const _ClusterActions();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.construction_rounded,
                  color: SovereignColors.accentWarning, size: 18),
              SizedBox(width: 8),
              Text('Cluster actions',
                  style: TextStyle(
                      color: SovereignColors.textPrimary,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          // TODO(P9-actions): wire to P7 A6 (RBAC scope grants) + A7 (skreachd
          // exec). Each action = a capauth-gated /tool call on the target node:
          //   • Promote replica  → pg_promote on .41 (run via skreachd)
          //   • Grant write scope → skcomms.access.grants for this identity
          //   • Re-index file     → write-back re-index into skingest
          // Left as disabled stubs until the exec/RBAC tools land.
          _StubAction(
              icon: Icons.swap_vert_rounded,
              label: 'Promote replica (.41 → primary)'),
          _StubAction(
              icon: Icons.vpn_key_rounded, label: 'Grant write scope'),
          _StubAction(
              icon: Icons.sync_rounded, label: 'Re-index corpus'),
          const SizedBox(height: 4),
          const Text(
            'Disabled until the exec/RBAC tools (P7 A6/A7) are wired.',
            style:
                TextStyle(color: SovereignColors.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _StubAction extends StatelessWidget {
  const _StubAction({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Opacity(
        opacity: 0.5,
        child: Row(
          children: [
            Icon(icon, size: 18, color: SovereignColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: SovereignColors.textSecondary, fontSize: 13)),
            ),
            const Icon(Icons.lock_outline_rounded,
                size: 14, color: SovereignColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
