import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/skcapstone_client.dart';
import '../shared/ai_suggestions_panel.dart';

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
        onChanged: _load,
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

class _CardSheet extends StatelessWidget {
  const _CardSheet({
    required this.card,
    required this.columns,
    required this.onMove,
    required this.onChanged,
  });

  final KanbanCard card;
  final List<String> columns;
  final ValueChanged<String> onMove;

  /// Called after a change-management action (validate/schedule/arm)
  /// succeeds, so the board behind this sheet refreshes its chips. The sheet
  /// itself keeps showing the snapshot it opened with (like `onMove`, which
  /// pops the sheet before reloading); the caller decides when to refetch.
  final VoidCallback onChanged;

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
              if (card.isChange) ...[
                const SizedBox(height: 16),
                _ChangeManagementSection(card: card, onChanged: onChanged),
              ],
              const SizedBox(height: 16),
              Text('MOVE TO',
                  style: tt.labelSmall?.copyWith(
                      letterSpacing: 0.8, color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: columns
                    .where((c) => c != card.status)
                    .map((c) => OutlinedButton(
                          onPressed: () => onMove(c),
                          child: Text(_columnLabel(c)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 20),
              AiSuggestionsPanel(
                cardId: card.id,
                footnote: card.isChange
                    ? 'Queue dispatches an agent to work this change. '
                        '"Propose"/"Dry-run" analyse only; "Prepare" drafts a '
                        'sandboxed PR for CAB review (still mode=execute on '
                        'the wire).'
                    : 'Queue dispatches an agent to work this card. '
                        '"propose" analyses only, "execute" produces a draft.',
                isChangeCard: card.isChange,
                changeItilStatus: card.itilStatus,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// CM P2.5: ticket-state chips (CAB tally / validation / window) plus the
/// Validate / Schedule / Arm buttons for a change card. Calls the NEW
/// `/api/change/{id}/*` routes on the same authenticated dashboard client
/// [AiSuggestionsPanel] uses for `queue-ai`; the chips render straight from
/// `card.chips` (no refetch), per the design doc.
class _ChangeManagementSection extends ConsumerStatefulWidget {
  const _ChangeManagementSection({required this.card, required this.onChanged});

  final KanbanCard card;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ChangeManagementSection> createState() =>
      _ChangeManagementSectionState();
}

class _ChangeManagementSectionState
    extends ConsumerState<_ChangeManagementSection> {
  bool _busy = false;

  void _report(ChangeActionResult result, String successMessage) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.ok ? successMessage : (result.error ?? 'Failed')),
    ));
    if (result.ok) widget.onChanged();
  }

  Future<void> _validate() async {
    setState(() => _busy = true);
    final result =
        await ref.read(skCapstoneClientProvider).validateChange(widget.card.id);
    final passed = result.data?['validation']?['passed'] == true;
    _report(result, passed ? 'Validation PASSED' : 'Validation FAILED');
  }

  Future<void> _arm() async {
    setState(() => _busy = true);
    final result = await ref
        .read(skCapstoneClientProvider)
        .armChangeDeploy(widget.card.id);
    _report(result, 'Deploy armed');
  }

  Future<void> _unschedule() async {
    setState(() => _busy = true);
    final result = await ref
        .read(skCapstoneClientProvider)
        .unscheduleChange(widget.card.id);
    _report(result, 'Unscheduled');
  }

  Future<void> _schedule() async {
    final choice = await showModalBottomSheet<_ScheduleChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _ScheduleSheet(),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    final result = await ref.read(skCapstoneClientProvider).scheduleChange(
          widget.card.id,
          windowStart: choice.windowStart,
          windowEnd: choice.windowEnd,
          asap: choice.asap,
          note: choice.note,
        );
    _report(result, 'Scheduled');
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final card = widget.card;
    final chips = card.chips;
    final scheduled = card.itilStatus == 'scheduled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CHANGE MANAGEMENT',
            style: tt.labelSmall
                ?.copyWith(letterSpacing: 0.8, color: cs.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if ((card.itilStatus ?? '').isNotEmpty)
              _MiniChip(text: card.itilStatus!, color: cs.primary),
            if (chips != null) _CabChip(tally: chips.cab),
            if (chips?.validation != null)
              _ValidationChipView(v: chips!.validation!),
            if (chips != null) _WindowChipView(w: chips.window),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _validate,
              child: const Text('Validate'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _schedule,
              child: Text(scheduled ? 'Reschedule' : 'Schedule'),
            ),
            if (scheduled)
              OutlinedButton(
                onPressed: _busy ? null : _unschedule,
                child: const Text('Unschedule'),
              ),
            if (scheduled)
              FilledButton(
                onPressed: _busy ? null : _arm,
                child: const Text('Arm deploy'),
              ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ],
    );
  }
}

class _CabChip extends StatelessWidget {
  const _CabChip({required this.tally});
  final ChangeCabTally tally;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = tally.rejected > 0
        ? const Color(0xFFEF4444)
        : (tally.approved > 0 ? const Color(0xFF22C55E) : cs.onSurfaceVariant);
    final human = tally.humanDecision != null ? ', human: ${tally.humanDecision}' : '';
    return _MiniChip(
      text: 'CAB ${tally.approved}A/${tally.rejected}R/${tally.abstain}Ab$human',
      color: color,
    );
  }
}

class _ValidationChipView extends StatelessWidget {
  const _ValidationChipView({required this.v});
  final ChangeValidationVerdict v;

  @override
  Widget build(BuildContext context) {
    final color = v.passed ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    final stale = v.stale ? ' (stale)' : '';
    return _MiniChip(
      text: '${v.passed ? 'PASS' : 'FAIL'} · ${v.checkCount} checks$stale',
      color: color,
    );
  }
}

class _WindowChipView extends StatelessWidget {
  const _WindowChipView({required this.w});
  final ChangeWindowChip w;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = w.label == 'MISSED' ? const Color(0xFFEF4444) : cs.onSurfaceVariant;
    return _MiniChip(text: w.label, color: color);
  }
}

/// Result of the schedule sheet: either ASAP, or an explicit window.
class _ScheduleChoice {
  const _ScheduleChoice({
    this.asap = false,
    this.windowStart,
    this.windowEnd,
    this.note = '',
  });

  final bool asap;
  final DateTime? windowStart;
  final DateTime? windowEnd;
  final String note;
}

/// Date-time-or-ASAP picker for `POST /api/change/{id}/schedule`.
/// `deploy_mode` is shown but LOCKED to "confirm": there is no control to
/// change it, matching [SKCapstoneClient.scheduleChange]/[buildScheduleBody],
/// which never send anything else (the backend 400s on any other value).
class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet();

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  bool _asap = false;
  DateTime? _start;
  DateTime? _end;
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickStart() async {
    final picked = await _pickDateTime(_start ?? DateTime.now());
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked =
        await _pickDateTime(_end ?? (_start ?? DateTime.now()).add(const Duration(hours: 2)));
    if (picked != null) setState(() => _end = picked);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final canSubmit = _asap || (_start != null && _end != null);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Schedule change', style: tt.titleMedium),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('ASAP'),
              subtitle:
                  const Text('Deploy as soon as CAB + the runner allow it'),
              value: _asap,
              onChanged: (v) => setState(() => _asap = v),
            ),
            if (!_asap) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Window start'),
                subtitle: Text(_start?.toLocal().toString() ?? 'Not set'),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickStart,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Window end'),
                subtitle: Text(_end?.toLocal().toString() ?? 'Not set'),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickEnd,
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('DEPLOY MODE',
                    style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(width: 8),
                _MiniChip(text: 'confirm (locked)', color: cs.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: canSubmit
                    ? () => Navigator.of(context).pop(_ScheduleChoice(
                          asap: _asap,
                          windowStart: _start,
                          windowEnd: _end,
                          note: _noteController.text,
                        ))
                    : null,
                child: const Text('Schedule'),
              ),
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
