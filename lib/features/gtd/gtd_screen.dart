import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/skcapstone_client.dart';

/// Native GTD screen. Lists GTD items (next-actions / inbox / waiting-for) from
/// GET /api/gtd. Each item opens a sheet with the same "Suggest next steps (AI)"
/// + one-push Queue actions as kanban cards: because a GTD item materializes a
/// shadow card (`gtd-ID`), it reuses the exact `/api/card` ai-suggestions and
/// queue-ai routes, all proxied same-origin by the webui.
class GtdScreen extends ConsumerStatefulWidget {
  const GtdScreen({super.key});

  @override
  ConsumerState<GtdScreen> createState() => _GtdScreenState();
}

const _lists = <String, String>{
  'next-actions': 'Next',
  'inbox': 'Inbox',
  'waiting-for': 'Waiting',
  'someday-maybe': 'Someday',
};

class _GtdScreenState extends ConsumerState<GtdScreen> {
  List<GtdItem>? _items;
  bool _loading = true;
  String _list = 'next-actions';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await ref.read(skCapstoneClientProvider).getGtdNext(list: _list);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _openItem(GtdItem item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GtdItemSheet(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GTD'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: 'Refresh',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final e in _lists.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(e.value),
                      selected: _list == e.key,
                      onSelected: (_) {
                        setState(() => _list = e.key);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_items == null || _items!.isEmpty)
              ? Center(
                  child: Text(
                    'Nothing here (or offline).',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _items!.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = _items![i];
                      return ListTile(
                        title: Text(it.text),
                        subtitle: Text(
                          [
                            if ((it.context ?? '').isNotEmpty) it.context,
                            if ((it.priority ?? '').isNotEmpty) it.priority,
                            if ((it.source ?? '').isNotEmpty) it.source,
                          ].whereType<String>().join('  ·  '),
                        ),
                        trailing: const Icon(Icons.auto_awesome_outlined),
                        onTap: () => _openItem(it),
                      );
                    },
                  ),
                ),
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

class _GtdItemSheet extends ConsumerStatefulWidget {
  const _GtdItemSheet({required this.item});
  final GtdItem item;

  @override
  ConsumerState<_GtdItemSheet> createState() => _GtdItemSheetState();
}

class _GtdItemSheetState extends ConsumerState<_GtdItemSheet> {
  List<CardSuggestion>? _suggestions;
  bool _loadingSuggestions = false;
  String? _queuing;

  Future<void> _suggest() async {
    setState(() => _loadingSuggestions = true);
    final s = await ref
        .read(skCapstoneClientProvider)
        .getCardSuggestions(widget.item.cardId);
    if (!mounted) return;
    setState(() {
      _loadingSuggestions = false;
      _suggestions = s;
    });
  }

  Future<void> _queue(CardSuggestion sug) async {
    setState(() => _queuing = sug.text);
    final runId = await ref.read(skCapstoneClientProvider).queueAi(
          widget.item.cardId,
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
    final item = widget.item;
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
              Text(item.text, style: tt.titleMedium),
              const SizedBox(height: 6),
              Text(
                [
                  if ((item.context ?? '').isNotEmpty) item.context,
                  if ((item.priority ?? '').isNotEmpty) item.priority,
                  if ((item.status ?? '').isNotEmpty) 'status: ${item.status}',
                ].whereType<String>().join('  ·  '),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
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
                'Queue dispatches an agent to work this item. GTD execute is '
                'draft-only: the agent prepares a draft, you send it.',
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
