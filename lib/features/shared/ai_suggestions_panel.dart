import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/skcapstone_client.dart';

/// Verbatim copy of `skcapstone.agent_run.gate()`'s blocked-execute reason
/// for a change ticket outside the draft window (design doc
/// docs/specs/2026-08-13-change-management-cab-ai-arch.md section 5.1).
/// Shown under a Prepare suggestion when the change's `itil_status` is not
/// `proposed`/`reviewing`, so the popout explains the block BEFORE the user
/// taps Queue rather than after a round trip. Keep this string byte-for-byte
/// in sync with `agent_run.py::gate()`.
const kChangeExecuteBlockedReason =
    "change tickets require a human/CAB vote to 'approved' before "
    "implementing; the agent may draft only (no self-approval)";

/// The change `itil_status` values in which `mode=execute` is allowed (the
/// wired executor is structurally draft-only, so this window is exactly
/// "may still draft the change" per `gate()`'s carve-out).
const kChangePrepareAllowedStatuses = {'proposed', 'reviewing'};

/// Change-card display label for a suggestion's wire mode. `execute` reads as
/// "Prepare" (design doc section 8: it is still `mode=execute` on the wire,
/// no new mode constant, this is a label only). Non-change cards keep the raw
/// mode text unchanged.
String changeModeLabel(String mode) {
  switch (mode) {
    case 'execute':
      return 'Prepare';
    case 'dry-run':
      return 'Dry-run';
    case 'propose':
      return 'Propose';
    default:
      return mode;
  }
}

/// Shared "Suggest next steps (AI)" + one-push Queue block. Both the Kanban
/// card sheet and the GTD item sheet render the exact same UI against the
/// SAME `/api/card/{cardId}/ai-suggestions` and `/api/card/{cardId}/queue-ai`
/// routes (a GTD item's `cardId` is its `gtd-ID` shadow card), so this widget
/// is the single place that logic and its markup live.
class AiSuggestionsPanel extends ConsumerStatefulWidget {
  const AiSuggestionsPanel({
    super.key,
    required this.cardId,
    this.footnote,
    this.isChangeCard = false,
    this.changeItilStatus,
  });

  /// The card id suggestions/queue actions are scoped to. For GTD items this
  /// is the shadow card id (`gtd-ID`), not the GTD item id.
  final String cardId;

  /// Optional trailing caption shown under the suggestions (e.g. explaining
  /// what Queue/execute means in this context).
  final String? footnote;

  /// CM P2.5: true only when [cardId] is a change ticket (`chg-*`/`kind ==
  /// 'change'`). Relabels the `execute` mode chip to "Prepare" and, when
  /// [changeItilStatus] blocks it, shows the gate's reason before Queue is
  /// even tapped. False (the default) leaves every other card unaffected.
  final bool isChangeCard;

  /// The change's folded `itil_status` (from the card's kanban payload, not
  /// refetched here). Only consulted when [isChangeCard] is true.
  final String? changeItilStatus;

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
                  isChangeCard: widget.isChangeCard,
                  changePrepareBlocked: widget.isChangeCard &&
                      s.mode == 'execute' &&
                      !kChangePrepareAllowedStatuses
                          .contains(widget.changeItilStatus),
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
    this.isChangeCard = false,
    this.changePrepareBlocked = false,
  });

  final CardSuggestion suggestion;
  final bool busy;
  final VoidCallback onQueue;

  /// CM P2.5: relabels this tile's mode chip (Propose/Dry-run/Prepare) when
  /// true; see [changeModeLabel].
  final bool isChangeCard;

  /// True when this is an `execute` (Prepare) suggestion on a change card
  /// whose `itil_status` is outside the draft window, i.e. the "Queue for
  /// AI" gate would block it server-side. Disables Queue and shows the
  /// gate's reason verbatim instead of spending a round trip to find out.
  final bool changePrepareBlocked;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final mc = _modeColor(suggestion.mode);
    final label =
        isChangeCard ? changeModeLabel(suggestion.mode) : suggestion.mode;
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
                    child: Text(label, style: tt.labelSmall?.copyWith(color: mc)),
                  ),
                  if (changePrepareBlocked) ...[
                    const SizedBox(height: 4),
                    Text(
                      kChangeExecuteBlockedReason,
                      style:
                          tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
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
                    onPressed: changePrepareBlocked ? null : onQueue,
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
