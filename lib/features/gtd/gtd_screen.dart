import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/skcapstone_client.dart';
import '../shared/ai_suggestions_panel.dart';

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

class _GtdItemSheet extends StatelessWidget {
  const _GtdItemSheet({required this.item});
  final GtdItem item;

  @override
  Widget build(BuildContext context) {
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
              AiSuggestionsPanel(
                cardId: item.cardId,
                footnote: 'Queue dispatches an agent to work this item. GTD '
                    'execute is draft-only: the agent prepares a draft, you '
                    'send it.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
