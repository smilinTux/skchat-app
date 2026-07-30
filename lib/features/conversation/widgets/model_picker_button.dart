import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/sovereign_colors.dart';
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
              if (hasModels)
                ModelPickerModelsSection(
                  models: state.catalog.models,
                  selection: state.selection,
                  onSelect: (id) =>
                      _select(context, ctx, svc, agent, state, id),
                ),
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

/// The "Models" half of the picker: a section header carrying a "Free only"
/// filter toggle, then one row per model. Free models always show a "FREE"
/// badge (visible even with the filter off); the toggle narrows the list to
/// `free == true` models. Reads the gateway's per-model `free` flag via
/// [filterModelsByFree]. Local session state, no persistence.
class ModelPickerModelsSection extends StatefulWidget {
  const ModelPickerModelsSection({
    super.key,
    required this.models,
    required this.selection,
    required this.onSelect,
  });

  final List<AgentModel> models;
  final String selection;
  final ValueChanged<String> onSelect;

  @override
  State<ModelPickerModelsSection> createState() => ModelPickerModelsSectionState();
}

class ModelPickerModelsSectionState extends State<ModelPickerModelsSection> {
  bool _freeOnly = false;

  @override
  Widget build(BuildContext context) {
    final hasFree = widget.models.any((m) => m.free == true);
    final visible = filterModelsByFree(widget.models, freeOnly: _freeOnly);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Models',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              if (hasFree)
                FilterChip(
                  label: const Text('Free only'),
                  selected: _freeOnly,
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    Icons.savings_outlined,
                    size: 18,
                    color: _freeOnly
                        ? SovereignColors.accentEncrypt
                        : SovereignColors.textSecondary,
                  ),
                  selectedColor:
                      SovereignColors.accentEncrypt.withValues(alpha: 0.18),
                  checkmarkColor: SovereignColors.accentEncrypt,
                  onSelected: (v) => setState(() => _freeOnly = v),
                ),
            ],
          ),
        ),
        if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text('No free models available'),
          )
        else
          for (final m in visible)
            ListTile(
              leading: Icon(
                m.free == true
                    ? Icons.savings_outlined
                    : Icons.cloud_outlined,
              ),
              title: Row(
                children: [
                  Flexible(child: Text(m.displayLabel)),
                  if (m.free == true) ...[
                    const SizedBox(width: 8),
                    const _FreeBadge(),
                  ],
                ],
              ),
              subtitle: m.provider.isNotEmpty ? Text(m.provider) : null,
              trailing: m.id == widget.selection
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : null,
              selected: m.id == widget.selection,
              onTap: () => widget.onSelect(m.id),
            ),
      ],
    );
  }
}

/// Small Sovereign Glass "FREE" pill shown on models the gateway serves at no
/// cost, so they read as free even when the "Free only" filter is off.
class _FreeBadge extends StatelessWidget {
  const _FreeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: SovereignColors.accentEncrypt.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: SovereignColors.accentEncrypt.withValues(alpha: 0.5),
        ),
      ),
      child: const Text(
        'FREE',
        style: TextStyle(
          color: SovereignColors.accentEncrypt,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
