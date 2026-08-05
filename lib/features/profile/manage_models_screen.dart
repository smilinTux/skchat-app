import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/agent_model_service.dart';

/// Manage models: enable/disable which discovered models the gateway advertises
/// (and so which are offered in the reply-model picker and to the brain). Writes
/// the gateway advertise allowlist through the skchat daemon
/// (`/api/v1/models/manage`). The SAME allowlist backs the SKDashboard console,
/// so both surfaces stay in sync.
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
          if (!_loading && !_offline)
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
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              decoration: const InputDecoration(
                                isDense: true,
                                prefixIcon: Icon(Icons.search),
                                hintText: 'Filter by id or provider',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (v) => setState(() => _query = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilterChip(
                            label: const Text('Free'),
                            selected: _freeOnly,
                            onSelected: (v) => setState(() => _freeOnly = v),
                          ),
                        ],
                      ),
                    ),
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
