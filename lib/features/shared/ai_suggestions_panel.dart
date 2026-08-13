import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/skcapstone_client.dart';

/// Shared "Suggest next steps (AI)" + one-push Queue block. Both the Kanban
/// card sheet and the GTD item sheet render the exact same UI against the
/// SAME `/api/card/{cardId}/ai-suggestions` and `/api/card/{cardId}/queue-ai`
/// routes (a GTD item's `cardId` is its `gtd-ID` shadow card), so this widget
/// is the single place that logic and its markup live.
class AiSuggestionsPanel extends ConsumerStatefulWidget {
  const AiSuggestionsPanel({super.key, required this.cardId, this.footnote});

  /// The card id suggestions/queue actions are scoped to. For GTD items this
  /// is the shadow card id (`gtd-ID`), not the GTD item id.
  final String cardId;

  /// Optional trailing caption shown under the suggestions (e.g. explaining
  /// what Queue/execute means in this context).
  final String? footnote;

  @override
  ConsumerState<AiSuggestionsPanel> createState() =>
      _AiSuggestionsPanelState();
}

class _AiSuggestionsPanelState extends ConsumerState<AiSuggestionsPanel> {
  List<CardSuggestion>? _suggestions;
  bool _loadingSuggestions = false;
  String? _queuing; // the suggestion text currently being queued

  Future<void> _suggest() async {
    setState(() => _loadingSuggestions = true);
    final s = await ref
        .read(skCapstoneClientProvider)
        .getCardSuggestions(widget.cardId);
    if (!mounted) return;
    setState(() {
      _loadingSuggestions = false;
      _suggestions = s;
    });
  }

  Future<void> _queue(CardSuggestion sug) async {
    setState(() => _queuing = sug.text);
    final runId = await ref.read(skCapstoneClientProvider).queueAi(
          widget.cardId,
          instruction: sug.text,
          mode: sug.mode,
        );
    if (!mounted) return;
    setState(() => _queuing = null);
    final ok = runId != null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Queued the AI to proceed ($runId)'
          : 'Could not queue (offline?)'),
    ));
    if (ok) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('NEXT STEPS (AI)',
            style: tt.labelSmall
                ?.copyWith(letterSpacing: 0.8, color: cs.onSurfaceVariant)),
        const SizedBox(height: 8),
        if (_suggestions == null)
          FilledButton.tonalIcon(
            onPressed: _loadingSuggestions ? null : _suggest,
            icon: _loadingSuggestions
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_outlined),
            label:
                Text(_loadingSuggestions ? 'Thinking...' : 'Suggest next steps'),
          )
        else if (_suggestions!.isEmpty)
          Text('No suggestions right now.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
        else
          Column(
            children: [
              for (final s in _suggestions!)
                _SuggestionTile(
                  suggestion: s,
                  busy: _queuing == s.text,
                  onQueue: () => _queue(s),
                ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _loadingSuggestions ? null : _suggest,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Re-suggest'),
                ),
              ),
            ],
          ),
        if (widget.footnote != null) ...[
          const SizedBox(height: 4),
          Text(
            widget.footnote!,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.suggestion,
    required this.busy,
    required this.onQueue,
  });

  final CardSuggestion suggestion;
  final bool busy;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final mc = _modeColor(suggestion.mode);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(suggestion.text, style: tt.bodyMedium),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: mc.withValues(alpha: 0.7)),
                    ),
                    child: Text(suggestion.mode,
                        style: tt.labelSmall?.copyWith(color: mc)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            busy
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : FilledButton(
                    onPressed: onQueue,
                    child: const Text('Queue'),
                  ),
          ],
        ),
      ),
    );
  }
}

/// Color for a suggestion's safety mode: execute (red, destructive/drafts a
/// change), dry-run (amber, reversible), propose (blue, analysis only).
Color _modeColor(String mode) {
  switch (mode) {
    case 'execute':
      return const Color(0xFFEF4444);
    case 'dry-run':
      return const Color(0xFFF59E0B);
    case 'propose':
    default:
      return const Color(0xFF38BDF8);
  }
}
