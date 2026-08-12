import "package:flutter/material.dart";

import "skcode_activity_taxonomy.dart";
import "skcode_event.dart";
import "skcode_tone_style.dart";

/// The transcript (card C-4, spec section 6/7 part 2): [events] rendered
/// through [buildSkcodeTranscript], one row per activity, each row's left
/// edge color-coded by [ActivityTone] so a human can scan blast radius
/// without reading a word. `suppressed` events never reach this list (the
/// reducer drops them); they still appear in `SkcodeRawRail`.
///
/// Card C-12 (spec 7.2, "two auto-following scrollables side by side"): this
/// list owns its OWN scroll, independently of whatever sits beside it (the
/// project chat column, at the four-column tier). It follow-tails new
/// activity by default (auto-scrolls to the newest row) and disengages the
/// instant the operator scrolls away from the bottom, replacing auto-scroll
/// with a [Key('skcodeTranscriptJumpToLatest')] pill until they tap it or
/// scroll back down themselves. Nothing here ever reads or drives another
/// column's [ScrollController]: "the two scrolls are never linked" (spec
/// 7.2) holds simply because this widget never sees the other column's
/// controller at all.
class SkcodeTranscriptList extends StatefulWidget {
  const SkcodeTranscriptList({super.key, required this.events});

  final List<SkcodeEvent> events;

  @override
  State<SkcodeTranscriptList> createState() => _SkcodeTranscriptListState();
}

/// How far (px) from the bottom the operator must scroll before follow-tail
/// disengages. A small dead zone so a stray pixel of overscroll bounce (iOS
/// physics) never falsely disengages tailing.
const _kSkcodeFollowTailSlack = 24.0;

class _SkcodeTranscriptListState extends State<SkcodeTranscriptList> {
  final _controller = ScrollController();
  bool _followTail = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // Follow-tail defaults to true (spec 7.2), so the first frame must
    // actually SIT at the bottom to match -- otherwise a freshly opened
    // transcript with more rows than fit on screen would render scrolled to
    // the (empty, oldest) top while claiming to be tailing.
    if (widget.events.isNotEmpty) _scrollToLatest(animate: false);
  }

  @override
  void didUpdateWidget(SkcodeTranscriptList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.events.length != oldWidget.events.length && _followTail) {
      _scrollToLatest(animate: false);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final distanceFromBottom =
        _controller.position.maxScrollExtent - _controller.position.pixels;
    final atBottom = distanceFromBottom <= _kSkcodeFollowTailSlack;
    if (atBottom != _followTail) {
      setState(() => _followTail = atBottom);
    }
  }

  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final target = _controller.position.maxScrollExtent;
      if (animate) {
        _controller.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      } else {
        _controller.jumpTo(target);
      }
    });
  }

  void _jumpToLatest() {
    setState(() => _followTail = true);
    _scrollToLatest();
  }

  @override
  Widget build(BuildContext context) {
    final records = buildSkcodeTranscript(widget.events);
    if (records.isEmpty) {
      return const Center(child: Text("No activity yet"));
    }
    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          itemCount: records.length,
          itemBuilder: (context, index) => _TranscriptRow(record: records[index]),
        ),
        if (!_followTail)
          Positioned(
            right: 12,
            bottom: 12,
            child: _JumpToLatestPill(onTap: _jumpToLatest),
          ),
      ],
    );
  }
}

/// The follow-tail "jump to latest" affordance (spec 7.2). Deliberately a
/// small, low-chrome pill rather than a full FloatingActionButton: it must
/// never compete visually with the composer or the taxonomy's own tone
/// colors sitting directly above it.
class _JumpToLatestPill extends StatelessWidget {
  const _JumpToLatestPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key("skcodeTranscriptJumpToLatest"),
      color: theme.colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(16),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 16, color: theme.colorScheme.onInverseSurface),
              const SizedBox(width: 6),
              Text(
                "Jump to latest",
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onInverseSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.record});

  final ActivityRecord record;

  @override
  Widget build(BuildContext context) {
    final toneColor = skcodeToneColor(context, record.tone);
    final classLabel = skcodeRenderClassLabel(record.renderClass);
    final title = record.label ??
        (record.event.text.isNotEmpty ? record.event.text : classLabel);

    return Container(
      key: ValueKey(record.rowId),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: toneColor, width: 3)),
      ),
      child: ListTile(
        dense: true,
        leading: _StatusIcon(status: record.status, color: toneColor),
        title: Text(title),
        subtitle: Text(
          "$classLabel · ${skcodeToneLabel(record.tone)}",
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: toneColor),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final ToolStatus? status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case ToolStatus.executing:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        );
      case ToolStatus.completed:
        return Icon(Icons.check_circle_outline, color: color, size: 18);
      case ToolStatus.failed:
        return Icon(Icons.error_outline, color: color, size: 18);
      case ToolStatus.pending:
        return Icon(Icons.hourglass_empty, color: color, size: 18);
      case null:
        return Icon(Icons.circle, color: color, size: 8);
    }
  }
}
