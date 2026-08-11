import "package:flutter/material.dart";

import "skcode_activity_taxonomy.dart";
import "skcode_event.dart";
import "skcode_tone_style.dart";

/// The transcript (card C-4, spec section 6/7 part 2): [events] rendered
/// through [buildSkcodeTranscript], one row per activity, each row's left
/// edge color-coded by [ActivityTone] so a human can scan blast radius
/// without reading a word. `suppressed` events never reach this list (the
/// reducer drops them); they still appear in `SkcodeRawRail`.
class SkcodeTranscriptList extends StatelessWidget {
  const SkcodeTranscriptList({super.key, required this.events});

  final List<SkcodeEvent> events;

  @override
  Widget build(BuildContext context) {
    final records = buildSkcodeTranscript(events);
    if (records.isEmpty) {
      return const Center(child: Text("No activity yet"));
    }
    return ListView.builder(
      itemCount: records.length,
      itemBuilder: (context, index) => _TranscriptRow(record: records[index]),
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
