import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_model_service.dart';

/// App-bar action (shown for agent conversations) that lets the operator pick
/// which model the agent uses to generate its replies, e.g. Claude Opus 4.8
/// or the local qwen3.6-27b. The selection is persisted by the skchat daemon
/// and read by the consciousness bridge for the next reply.
class ModelPickerButton extends ConsumerWidget {
  const ModelPickerButton({super.key, required this.peerId});

  final String peerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      icon: const Icon(Icons.psychology_outlined),
      tooltip: 'Reply model',
      onPressed: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final svc = ref.read(agentModelServiceProvider);
    final agent = AgentModelService.agentFromPeerId(peerId);
    final state = await svc.getModel(agent);
    if (!context.mounted) return;
    final hasRoles = state != null && state.catalog.roles.isNotEmpty;
    final hasModels = state != null && state.catalog.models.isNotEmpty;
    if (state == null || (!hasRoles && !hasModels)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model settings unavailable (daemon offline)')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Reply model: ${state.agent}',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              if (hasRoles) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Text('Roles', style: Theme.of(ctx).textTheme.labelLarge),
                ),
                for (final role in state.catalog.roles)
                  ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text(role),
                    trailing: role == state.selection
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null,
                    selected: role == state.selection,
                    onTap: () => _select(context, ctx, svc, agent, state, role),
                  ),
              ],
              if (hasModels) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text('Models', style: Theme.of(ctx).textTheme.labelLarge),
                ),
                for (final m in state.catalog.models)
                  ListTile(
                    leading: Icon(
                      m.free == true ? Icons.savings_outlined : Icons.cloud_outlined,
                    ),
                    title: Text(m.displayLabel),
                    subtitle: m.provider.isNotEmpty ? Text(m.provider) : null,
                    trailing: m.id == state.selection
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null,
                    selected: m.id == state.selection,
                    onTap: () => _select(context, ctx, svc, agent, state, m.id),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _select(
    BuildContext context,
    BuildContext sheetContext,
    AgentModelService svc,
    String agent,
    AgentModelState state,
    String selection,
  ) async {
    Navigator.of(sheetContext).pop();
    final updated = await svc.setSelection(agent, selection);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          updated != null
              ? '${state.agent} now replies via $selection'
              : 'Failed to set model',
        ),
      ),
    );
  }
}
