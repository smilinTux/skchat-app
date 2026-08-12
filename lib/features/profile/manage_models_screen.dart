import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/agent_model_service.dart';

/// Which view of the models screen is showing: the enable/disable Manage list,
/// or the read-only Cards (model dex).
enum _ModelsView { manage, cards }

/// Manage models: enable/disable which discovered models the gateway advertises
/// (and so which are offered in the reply-model picker and to the brain). Writes
/// the gateway advertise allowlist through the skchat daemon
/// (`/api/v1/models/manage`). The SAME allowlist backs the SKDashboard console,
/// so both surfaces stay in sync. A Cards view renders the curated model dex.
class ManageModelsScreen extends ConsumerStatefulWidget {
  const ManageModelsScreen({super.key});

  @override
  ConsumerState<ManageModelsScreen> createState() => _ManageModelsScreenState();
}

class _ManageModelsScreenState extends ConsumerState<ManageModelsScreen> {
  ManagedModelsState? _state;
  final Set<String> _enabled = {};
  bool _loading = true;
  bool _saving = false;
  bool _offline = false;
  bool _freeOnly = false;
  String _query = '';
  _ModelsView _view = _ModelsView.manage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offline = false;
    });
    final svc = ref.read(agentModelServiceProvider);
    final state = await svc.listManagedModels();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (state == null) {
        _offline = true;
        return;
      }
      _state = state;
      _enabled
        ..clear()
        ..addAll(state.enabled);
    });
  }

  Future<void> _save() async {
    final all = _state?.models ?? const <ManagedModel>[];
    // If everything is enabled, persist an EMPTY allowlist (= advertise all),
    // so models discovered later are included automatically. Otherwise persist
    // the exact enabled subset.
    final enableAll = all.isNotEmpty && all.every((m) => _enabled.contains(m.id));
    final payload = enableAll ? <String>[] : _enabled.toList();

    setState(() => _saving = true);
    final svc = ref.read(agentModelServiceProvider);
    final result = await svc.setEnabledModels(payload);
    if (!mounted) return;
    setState(() => _saving = false);
    final ok = result != null;
    if (ok) {
      setState(() {
        _state = result;
        _enabled
          ..clear()
          ..addAll(result.enabled);
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Saved: ${_enabled.length} model${_enabled.length == 1 ? '' : 's'} enabled'
            : 'Could not save (gateway/daemon offline)'),
      ),
    );
  }

  List<ManagedModel> get _visible {
    final models = _state?.models ?? const <ManagedModel>[];
    final q = _query.trim().toLowerCase();
    return models.where((m) {
      if (_freeOnly && m.free != true) return false;
      if (q.isEmpty) return true;
      return m.id.toLowerCase().contains(q) || m.provider.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final total = _state?.models.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage models'),
        actions: [
          if (!_loading && !_offline && _view == _ModelsView.manage)
            _saving
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 18),
                    child: Center(
                      child: SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : TextButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _offline
              ? _OfflineState(onRetry: _load)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Enabled models are offered in the reply-model picker and to '
                        'the brain, everywhere. $total discovered · ${_enabled.length} enabled.',
                        style: tt.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if ((_state?.source ?? 'gateway') == 'curated')
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: _Banner(
                          text: 'Gateway admin unreachable — showing curated models only.',
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: SegmentedButton<_ModelsView>(
                        segments: const [
                          ButtonSegment(
                            value: _ModelsView.manage,
                            icon: Icon(Icons.tune),
                            label: Text('Manage'),
                          ),
                          ButtonSegment(
                            value: _ModelsView.cards,
                            icon: Icon(Icons.style_outlined),
                            label: Text('Cards'),
                          ),
                        ],
                        selected: {_view},
                        onSelectionChanged: (s) =>
                            setState(() => _view = s.first),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              decoration: InputDecoration(
                                isDense: true,
                                prefixIcon: const Icon(Icons.search),
                                hintText: _view == _ModelsView.cards
                                    ? 'Search models, orgs, capabilities'
                                    : 'Filter by id or provider',
                                border: const OutlineInputBorder(),
                              ),
                              onChanged: (v) => setState(() => _query = v),
                            ),
                          ),
                          if (_view == _ModelsView.manage) ...[
                            const SizedBox(width: 8),
                            FilterChip(
                              label: const Text('Free'),
                              selected: _freeOnly,
                              onSelected: (v) => setState(() => _freeOnly = v),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_view == _ModelsView.manage) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: () => setState(() {
                                for (final m in _visible) {
                                  _enabled.add(m.id);
                                }
                              }),
                              child: const Text('Enable all shown'),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                for (final m in _visible) {
                                  _enabled.remove(m.id);
                                }
                              }),
                              child: const Text('Disable all shown'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _visible.length,
                          itemBuilder: (context, i) {
                            final m = _visible[i];
                            return SwitchListTile(
                              dense: true,
                              value: _enabled.contains(m.id),
                              onChanged: (on) => setState(() {
                                if (on) {
                                  _enabled.add(m.id);
                                } else {
                                  _enabled.remove(m.id);
                                }
                              }),
                              title: Text(m.id, style: tt.bodyMedium),
                              subtitle: Row(
                                children: [
                                  Text(m.provider, style: tt.bodySmall),
                                  if (m.free == true) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .secondaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text('FREE',
                                          style: tt.labelSmall?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSecondaryContainer,
                                          )),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ] else
                      Expanded(
                        child: _ModelDexView(models: _visible),
                      ),
                  ],
                ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              )),
    );
  }
}

class _OfflineState extends StatelessWidget {
  const _OfflineState({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48),
          const SizedBox(height: 12),
          Text('Daemon offline', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Could not reach the skchat daemon to load the model catalog.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

String _fmtTokens(int? n) {
  if (n == null) return 'n/a';
  if (n >= 1000000) {
    final m = n / 1000000;
    return m == m.roundToDouble()
        ? '${m.toStringAsFixed(0)}M'
        : '${m.toStringAsFixed(1)}M';
  }
  if (n >= 1000) return '${(n / 1000).round()}K';
  return '$n';
}

String _tierLabel(String? t) => t == 'local'
    ? 'Sovereign'
    : t == 'paid-cloud'
        ? 'Paid cloud'
        : 'Free remote';

Color _tierColor(String? t) => t == 'local'
    ? const Color(0xFF34D399)
    : t == 'paid-cloud'
        ? const Color(0xFFC084FC)
        : const Color(0xFF38BDF8);

/// The model dex: curated cards grouped by sovereignty tier, read-only. Reads
/// the same catalog the Manage view uses; only renders models that have a
/// curated card (ManagedModel.card != null).
class _ModelDexView extends StatelessWidget {
  const _ModelDexView({required this.models});
  final List<ManagedModel> models;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final carded = models.where((m) => m.card != null).toList();
    if (carded.isEmpty) {
      return Center(child: Text('No carded models match.', style: tt.bodySmall));
    }
    const tiers = ['local', 'free-remote', 'paid-cloud'];
    const descs = {
      'local': 'Self-hosted on our own GPUs. Cloud-free.',
      'free-remote': 'Free-tier hosted models.',
      'paid-cloud': 'Metered API. Used deliberately.',
    };
    final children = <Widget>[];
    for (final t in tiers) {
      final group =
          carded.where((m) => (m.card!.tier ?? 'free-remote') == t).toList();
      if (group.isEmpty) continue;
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: _tierColor(t), shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text('${_tierLabel(t)} · ${group.length}', style: tt.labelLarge),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                descs[t] ?? '',
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ));
      for (final m in group) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: _DexCard(model: m),
        ));
      }
    }
    return ListView(children: children);
  }
}

class _DexCard extends StatelessWidget {
  const _DexCard({required this.model});
  final ManagedModel model;

  Widget _cap(BuildContext context, String label, bool on) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: on ? cs.primary : cs.outlineVariant),
      ),
      child: Text(
        '${on ? "✓" : "✕"} $label',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: on ? cs.primary : cs.onSurfaceVariant),
      ),
    );
  }

  Widget _stat(BuildContext context, String k, String v) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Text.rich(TextSpan(children: [
      TextSpan(
          text: '$k  ',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      TextSpan(text: v, style: tt.bodySmall),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final c = model.card!;
    final tc = _tierColor(c.tier);
    final stats = <Widget>[
      _stat(context, 'context', _fmtTokens(c.contextLength)),
      _stat(context, 'max out', _fmtTokens(c.maxOutputTokens)),
      if (c.params != null) _stat(context, 'params', c.params!),
      if (c.quant != null) _stat(context, 'quant', c.quant!),
      if (c.speed != null) _stat(context, 'speed', c.speed!),
      if (c.license != null) _stat(context, 'license', c.license!),
    ];
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: tc),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.displayName ?? model.id,
                                  style: tt.titleSmall),
                              const SizedBox(height: 2),
                              Text(
                                '${c.org ?? model.provider} · ${model.id}',
                                style: tt.bodySmall
                                    ?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: tc),
                          ),
                          child: Text(_tierLabel(c.tier),
                              style: tt.labelSmall?.copyWith(color: tc)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      _cap(context, 'tools', c.tools),
                      _cap(context, 'vision', c.vision),
                    ]),
                    if (c.summary != null) ...[
                      const SizedBox(height: 10),
                      Text(c.summary!, style: tt.bodyMedium),
                    ],
                    const SizedBox(height: 10),
                    Wrap(spacing: 16, runSpacing: 4, children: stats),
                    if (c.goodAt.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: c.goodAt
                            .map((g) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 2),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    border:
                                        Border.all(color: cs.outlineVariant),
                                  ),
                                  child: Text(g, style: tt.bodySmall),
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
