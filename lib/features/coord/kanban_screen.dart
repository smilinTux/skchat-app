import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/skcapstone_client.dart';

/// Native Kanban board. Reads the coord board (columns x cards) from
/// GET /api/kanban and MOVES a card between columns (tap a card -> Move to...),
/// via the same /api/card mutation endpoints the SKDashboard console uses,
/// proxied same-origin by the webui. Read + move only; the richer mutations
/// (assign/label/note) stay in the dashboard pane for now.
class KanbanScreen extends ConsumerStatefulWidget {
  const KanbanScreen({super.key});

  @override
  ConsumerState<KanbanScreen> createState() => _KanbanScreenState();
}

class _KanbanScreenState extends ConsumerState<KanbanScreen> {
  KanbanBoard? _board;
  bool _loading = true;
  bool _offline = false;
  bool _busy = false;
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
    final board = await ref.read(skCapstoneClientProvider).getKanban();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _board = board;
      _offline = board == null;
    });
  }

  List<KanbanCard> get _visible {
    final all = _board?.cards ?? const <KanbanCard>[];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((c) {
      return c.title.toLowerCase().contains(q) ||
          c.swimlane.toLowerCase().contains(q) ||
          (c.owner ?? '').toLowerCase().contains(q) ||
          c.labels.any((l) => l.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _move(KanbanCard card, String column) async {
    Navigator.of(context).maybePop();
    setState(() => _busy = true);
    final ok = await ref.read(skCapstoneClientProvider).moveCard(card.id, column);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Moved to ${_columnLabel(column)}'
          : 'Move failed (dashboard offline?)'),
    ));
    if (ok) await _load();
  }

  void _openCard(KanbanCard card) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _CardSheet(
        card: card,
        columns: _board?.columns ?? const [],
        onMove: (col) => _move(card, col),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kanban'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh',
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _offline
              ? _KanbanOffline(onRetry: _load)
              : _buildBoard(context),
    );
  }

  Widget _buildBoard(BuildContext context) {
    final board = _board!;
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search cards, lanes, owners, labels',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: board.columns.length,
            itemBuilder: (context, i) {
              final col = board.columns[i];
              final cards =
                  visible.where((c) => c.status == col).toList();
              return _ColumnView(
                column: col,
                label: _columnLabel(col),
                cards: cards,
                onTapCard: _openCard,
              );
            },
          ),
        ),
      ],
    );
  }
}

String _columnLabel(String col) {
  if (col.isEmpty) return col;
  return col[0].toUpperCase() + col.substring(1);
}

Color _priorityColor(String? p) {
  switch (p) {
    case 'critical':
      return const Color(0xFFEF4444);
    case 'high':
      return const Color(0xFFF59E0B);
    case 'low':
      return const Color(0xFF64748B);
    case 'medium':
    default:
      return const Color(0xFF38BDF8);
  }
}

class _ColumnView extends StatelessWidget {
  const _ColumnView({
    required this.column,
    required this.label,
    required this.cards,
    required this.onTapCard,
  });

  final String column;
  final String label;
  final List<KanbanCard> cards;
  final ValueChanged<KanbanCard> onTapCard;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: 300,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Text(label.toUpperCase(),
                    style: tt.labelLarge?.copyWith(letterSpacing: 0.6)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${cards.length}',
                      style: tt.labelSmall
                          ?.copyWith(color: cs.onSecondaryContainer)),
                ),
              ],
            ),
          ),
          Expanded(
            child: cards.isEmpty
                ? Center(
                    child: Text('empty',
                        style: tt.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: cards.length,
                    itemBuilder: (context, i) =>
                        _CardTile(card: cards[i], onTap: () => onTapCard(cards[i])),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({required this.card, required this.onTap});
  final KanbanCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 5, right: 8),
                    decoration: BoxDecoration(
                      color: _priorityColor(card.priority),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(card.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if ((card.kind ?? '').isNotEmpty)
                    _MiniChip(text: card.kind!.toUpperCase(), color: cs.primary),
                  if (card.swimlane.isNotEmpty)
                    _MiniChip(text: card.swimlane, color: cs.onSurfaceVariant),
                  if ((card.priority ?? '').isNotEmpty)
                    _MiniChip(
                        text: card.priority!,
                        color: _priorityColor(card.priority)),
                  if ((card.owner ?? '').isNotEmpty)
                    Text('@${card.owner}',
                        style: tt.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: color)),
    );
  }
}

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

class _CardSheet extends ConsumerStatefulWidget {
  const _CardSheet({
    required this.card,
    required this.columns,
    required this.onMove,
  });

  final KanbanCard card;
  final List<String> columns;
  final ValueChanged<String> onMove;

  @override
  ConsumerState<_CardSheet> createState() => _CardSheetState();
}

class _CardSheetState extends ConsumerState<_CardSheet> {
  List<CardSuggestion>? _suggestions;
  bool _loadingSuggestions = false;
  String? _queuing; // the suggestion text currently being queued

  Future<void> _suggest() async {
    setState(() => _loadingSuggestions = true);
    final s =
        await ref.read(skCapstoneClientProvider).getCardSuggestions(widget.card.id);
    if (!mounted) return;
    setState(() {
      _loadingSuggestions = false;
      _suggestions = s;
    });
  }

  Future<void> _queue(CardSuggestion sug) async {
    setState(() => _queuing = sug.text);
    final runId = await ref.read(skCapstoneClientProvider).queueAi(
          widget.card.id,
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
    final card = widget.card;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(card.title, style: tt.titleMedium),
              const SizedBox(height: 6),
              Text(
                [
                  if ((card.kind ?? '').isNotEmpty) card.kind,
                  if (card.swimlane.isNotEmpty) card.swimlane,
                  if ((card.priority ?? '').isNotEmpty) card.priority,
                  if ((card.owner ?? '').isNotEmpty) '@${card.owner}',
                  'in ${_columnLabel(card.status)}',
                ].whereType<String>().join('  ·  '),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (card.labels.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: card.labels
                      .map((l) => Chip(
                            label: Text(l),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 16),
              Text('MOVE TO',
                  style: tt.labelSmall?.copyWith(
                      letterSpacing: 0.8, color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.columns
                    .where((c) => c != card.status)
                    .map((c) => OutlinedButton(
                          onPressed: () => widget.onMove(c),
                          child: Text(_columnLabel(c)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 20),
              Text('NEXT STEPS (AI)',
                  style: tt.labelSmall?.copyWith(
                      letterSpacing: 0.8, color: cs.onSurfaceVariant)),
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
                  label: Text(
                      _loadingSuggestions ? 'Thinking...' : 'Suggest next steps'),
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
              const SizedBox(height: 4),
              Text(
                'Queue dispatches an agent to work this card. "propose" analyses '
                'only, "execute" produces a draft.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
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

class _KanbanOffline extends StatelessWidget {
  const _KanbanOffline({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48),
          const SizedBox(height: 12),
          Text('Board unavailable',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Could not reach the coordination board through the daemon.',
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
