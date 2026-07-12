import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_widgets.dart';
import '../../core/theme/sovereign_colors.dart';
import '../../services/cluster_service.dart';
import 'cluster_provider.dart';

/// Cluster control screen, the operator hub for the sovereign stack.
///
/// A second native client to skbloom's existing JSON/SSE control plane
/// ([ClusterService]). Lets you, from your phone:
///   • see the installed stacks + live per-service readiness (`/api/status`,
///     `/api/health`),
///   • browse the deployable service catalog (`/api/services`),
///   • describe an intent → get a concierge plan (`/api/propose`) → confirm and
///     watch the install stream live (`/api/up`, SSE),
///   • run day-2 actions per service: restart / scale / tail logs
///     (`/api/restart`, `/api/scale`, `/api/logs`).
class ClusterScreen extends ConsumerWidget {
  const ClusterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(clusterOverviewProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: Text('Cluster', style: tt.displayLarge?.copyWith(fontSize: 24)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: SovereignColors.textSecondary),
            onPressed: () =>
                ref.read(clusterOverviewProvider.notifier).refresh(),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: SovereignColors.soulLumina),
        ),
        error: (e, _) => _Offline(error: e.toString()),
        data: (overview) => RefreshIndicator(
          color: SovereignColors.soulLumina,
          backgroundColor: SovereignColors.surfaceRaised,
          onRefresh: () => ref.read(clusterOverviewProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const _InstallPanel(),
              const SizedBox(height: 20),
              _SectionHeader('Installed Stacks', tt),
              if (overview.stacks.isEmpty)
                _EmptyHint('No stacks installed yet. Describe one above.', tt)
              else
                ...overview.stacks
                    .map((s) => _StackCard(stack: s, overview: overview)),
              const SizedBox(height: 24),
              _SectionHeader('Service Catalog', tt),
              ...overview.services.map((s) => _ServiceCatalogCard(def: s)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Concierge propose → confirm → up (SSE) ───────────────────────────────────

class _InstallPanel extends ConsumerStatefulWidget {
  const _InstallPanel();

  @override
  ConsumerState<_InstallPanel> createState() => _InstallPanelState();
}

class _InstallPanelState extends ConsumerState<_InstallPanel> {
  final _intent = TextEditingController();

  @override
  void dispose() {
    _intent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final install = ref.watch(installProvider);
    final notifier = ref.read(installProvider.notifier);

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome,
                  color: SovereignColors.soulLumina, size: 18),
              const SizedBox(width: 8),
              Text('Deploy a stack', style: tt.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _intent,
            style: tt.bodyMedium,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Describe what you want (e.g. "a postgres + redis stack")',
              hintStyle: tt.bodySmall
                  ?.copyWith(color: SovereignColors.textTertiary),
              filled: true,
              fillColor: SovereignColors.surfaceGlass,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: install.running
                    ? null
                    : () {
                        final text = _intent.text.trim();
                        if (text.isNotEmpty) notifier.propose(text);
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: SovereignColors.soulLumina,
                ),
                icon: const Icon(Icons.psychology_alt, size: 18),
                label: const Text('Propose'),
              ),
              if (install.proposal != null || install.events.isNotEmpty) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: notifier.reset,
                  child: const Text('Clear'),
                ),
              ],
            ],
          ),
          if (install.error != null) ...[
            const SizedBox(height: 10),
            Text(install.error!,
                style: tt.bodySmall
                    ?.copyWith(color: SovereignColors.accentDanger)),
          ],
          if (install.proposal != null && install.events.isEmpty)
            _ProposalView(
              proposal: install.proposal!,
              running: install.running,
              onConfirm: () => notifier.confirmAndUp(),
            ),
          if (install.events.isNotEmpty)
            _UpStreamView(
              events: install.events,
              running: install.running,
              done: install.done,
            ),
        ],
      ),
    );
  }
}

class _ProposalView extends StatelessWidget {
  const _ProposalView({
    required this.proposal,
    required this.running,
    required this.onConfirm,
  });

  final ClusterProposal proposal;
  final bool running;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(proposal.reply, style: tt.bodyMedium),
          const SizedBox(height: 10),
          if (proposal.services.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: proposal.services
                  .map((s) => _Chip(s, SovereignColors.soulLumina))
                  .toList(),
            ),
          const SizedBox(height: 10),
          Text(
            '${proposal.plan.length} steps · '
            '${proposal.rotationSecrets} secrets / '
            '${proposal.rotationCerts} certs auto-rotated'
            '${proposal.rotationAllAutomatic ? "" : " (some manual)"}',
            style: tt.bodySmall?.copyWith(color: SovereignColors.textSecondary),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (running || proposal.services.isEmpty) ? null : onConfirm,
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentEncrypt,
            ),
            icon: const Icon(Icons.rocket_launch, size: 18),
            label: const Text('Confirm & install'),
          ),
        ],
      ),
    );
  }
}

class _UpStreamView extends StatelessWidget {
  const _UpStreamView({
    required this.events,
    required this.running,
    required this.done,
  });

  final List<UpEvent> events;
  final bool running;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: SovereignColors.soulLumina),
                )
              else
                Icon(done ? Icons.check_circle : Icons.cancel,
                    size: 16,
                    color: done
                        ? SovereignColors.accentEncrypt
                        : SovereignColors.accentWarning),
              const SizedBox(width: 8),
              Text(
                running
                    ? 'Installing…'
                    : (done ? 'Install complete' : 'Stopped'),
                style: tt.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: SovereignColors.surfaceGlass,
              borderRadius: BorderRadius.circular(10),
            ),
            child: ListView(
              shrinkWrap: true,
              children: events.map((e) {
                final color = e.isError
                    ? SovereignColors.accentDanger
                    : SovereignColors.textSecondary;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${e.step}  ·  ${e.status}'
                    '${e.detail != null ? "  ${e.detail}" : ""}',
                    style: tt.bodySmall
                        ?.copyWith(color: color, fontFamily: 'monospace'),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Installed stack card + day-2 actions ─────────────────────────────────────

class _StackCard extends StatelessWidget {
  const _StackCard({required this.stack, required this.overview});

  final ClusterStack stack;
  final ClusterOverview overview;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(stack.complete ? Icons.verified : Icons.hourglass_bottom,
                  size: 18,
                  color: stack.complete
                      ? SovereignColors.accentEncrypt
                      : SovereignColors.accentWarning),
              const SizedBox(width: 8),
              Text(stack.cluster, style: tt.titleMedium),
              const Spacer(),
              Text('${stack.stepsDone} steps',
                  style: tt.bodySmall
                      ?.copyWith(color: SovereignColors.textTertiary)),
            ],
          ),
          const SizedBox(height: 4),
          ...stack.services.map((s) {
            final h = overview.healthFor(s.name);
            return _DeployedServiceRow(
              cluster: stack.cluster,
              service: s.name,
              url: s.url,
              health: h,
            );
          }),
          if (stack.services.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('No services deployed.',
                  style: tt.bodySmall
                      ?.copyWith(color: SovereignColors.textTertiary)),
            ),
        ],
      ),
    );
  }
}

class _DeployedServiceRow extends ConsumerWidget {
  const _DeployedServiceRow({
    required this.cluster,
    required this.service,
    required this.url,
    required this.health,
  });

  final String cluster;
  final String service;
  final String? url;
  final ServiceHealth? health;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _HealthDot(health: health),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(service, style: tt.bodyMedium),
                if (health != null)
                  Text('${health!.ready}/${health!.total} ready',
                      style: tt.bodySmall
                          ?.copyWith(color: SovereignColors.textTertiary)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz,
                color: SovereignColors.textSecondary),
            color: SovereignColors.surfaceRaised,
            onSelected: (v) => _onAction(context, ref, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'restart', child: Text('Restart')),
              PopupMenuItem(value: 'scale', child: Text('Scale…')),
              PopupMenuItem(value: 'logs', child: Text('Logs')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onAction(
      BuildContext context, WidgetRef ref, String action) async {
    final svc = ref.read(clusterServiceProvider);
    switch (action) {
      case 'restart':
        _toast(context, 'Restarting $service…');
        try {
          final r = await svc.restart(service, cluster: cluster);
          if (context.mounted) {
            _toast(context, r.ok ? 'Restarted $service' : 'Restart failed');
          }
        } catch (e) {
          if (context.mounted) _toast(context, 'Restart error: $e');
        }
        break;
      case 'scale':
        final n = await _askReplicas(context);
        if (n == null) return;
        try {
          final r = await svc.scale(service, n, cluster: cluster);
          if (context.mounted) {
            _toast(context, r.ok ? 'Scaled $service → $n' : 'Scale failed');
          }
        } catch (e) {
          if (context.mounted) _toast(context, 'Scale error: $e');
        }
        break;
      case 'logs':
        _showLogs(context, ref, cluster, service);
        break;
    }
  }
}

Future<int?> _askReplicas(BuildContext context) async {
  final ctrl = TextEditingController(text: '1');
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: SovereignColors.surfaceRaised,
      title: const Text('Scale replicas'),
      content: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Replicas'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
          child: const Text('Scale'),
        ),
      ],
    ),
  );
}

void _showLogs(
    BuildContext context, WidgetRef ref, String cluster, String service) {
  final svc = ref.read(clusterServiceProvider);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: SovereignColors.surfaceRaised,
    isScrollControlled: true,
    builder: (ctx) => _LogSheet(stream: svc.logs(service, cluster: cluster), title: service),
  );
}

class _LogSheet extends StatelessWidget {
  const _LogSheet({required this.stream, required this.title});

  final Stream<String> stream;
  final String title;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (_, controller) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Logs · $title', style: tt.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<String>>(
                stream: _accumulate(stream),
                builder: (_, snap) {
                  final lines = snap.data ?? const <String>[];
                  if (lines.isEmpty) {
                    return Text('Waiting for logs…',
                        style: tt.bodySmall
                            ?.copyWith(color: SovereignColors.textTertiary));
                  }
                  return ListView.builder(
                    controller: controller,
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Text(
                      lines[i],
                      style: tt.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: SovereignColors.textSecondary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Fold the line stream into a growing list for the ListView.
  Stream<List<String>> _accumulate(Stream<String> src) async* {
    final acc = <String>[];
    await for (final line in src) {
      acc.add(line);
      yield List.unmodifiable(acc);
    }
  }
}

// ── Service catalog card ─────────────────────────────────────────────────────

class _ServiceCatalogCard extends StatelessWidget {
  const _ServiceCatalogCard({required this.def});

  final ClusterServiceDef def;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(def.name, style: tt.titleSmall),
                    if (def.ha) ...[
                      const SizedBox(width: 6),
                      _Chip('HA', SovereignColors.accentEncrypt),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${def.capability}'
                  '${def.provider.isNotEmpty ? " · ${def.provider}" : ""}',
                  style: tt.bodySmall
                      ?.copyWith(color: SovereignColors.textSecondary),
                ),
              ],
            ),
          ),
          if (def.secrets.isNotEmpty)
            Tooltip(
              message: '${def.secrets.length} secret(s)',
              child: const Icon(Icons.key,
                  size: 16, color: SovereignColors.textTertiary),
            ),
        ],
      ),
    );
  }
}

// ── Small shared widgets ─────────────────────────────────────────────────────

class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.health});

  final ServiceHealth? health;

  @override
  Widget build(BuildContext context) {
    final Color c;
    if (health == null) {
      c = SovereignColors.textTertiary;
    } else if (health!.healthy) {
      c = SovereignColors.accentEncrypt;
    } else {
      c = SovereignColors.accentWarning;
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, this.tt);

  final String label;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(label,
          style: tt.titleMedium?.copyWith(color: SovereignColors.textPrimary)),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text, this.tt);

  final String text;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text,
          style: tt.bodySmall?.copyWith(color: SovereignColors.textTertiary)),
    );
  }
}

class _Offline extends ConsumerWidget {
  const _Offline({required this.error});

  final String error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off,
                size: 48, color: SovereignColors.textTertiary),
            const SizedBox(height: 16),
            Text('skbloom unreachable',
                style: tt.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Could not reach the cluster control API. Set the cluster base '
              'URL in Profile, or port-forward skbloom (default :8774).',
              style:
                  tt.bodySmall?.copyWith(color: SovereignColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(clusterOverviewProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor: SovereignColors.surfaceRaised,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
