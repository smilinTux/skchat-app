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
    if (state == null || state.available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model settings unavailable (daemon offline)')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
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
            for (final m in state.available)
              ListTile(
                leading: Icon(m.local ? Icons.computer_outlined : Icons.cloud_outlined),
                title: Text(m.label),
                subtitle: Text(m.id),
                trailing: m.id == state.model
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : null,
                selected: m.id == state.model,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  final updated = await svc.setModel(agent, m.id);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        updated != null
                            ? '${state.agent} now replies via ${m.label}'
                            : 'Failed to set model',
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
