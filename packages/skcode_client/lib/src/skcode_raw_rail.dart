import "dart:convert";

import "package:flutter/material.dart";

import "skcode_activity_taxonomy.dart";
import "skcode_event.dart";
import "skcode_event_merge.dart";
import "skcode_tone_style.dart";

const _kPrettyJson = JsonEncoder.withIndent("  ");

/// The raw event rail (card C-4, spec section 6/7 part 3), Buzz's
/// `RawEventRail` shape: expandable rows showing `#seq`, a one-line
/// description, and a timestamp, with the full event pretty-printed as JSON
/// in mono when expanded.
///
/// Unlike [SkcodeTranscriptList], this renders EVERY event, including
/// `suppressed` ones (spec section 6: "suppressed is kept as the explicit
/// noise valve ... everything suppressed still appears in the raw rail").
/// Each row's key is [skcodeEventRowId], the same anchor id
/// [SkcodeTranscriptList] uses for the same underlying event, so the two
/// views can be cross-referenced (or, on phone, swapped for each other; see
/// `SkcodeSessionScreen`).
class SkcodeRawRail extends StatelessWidget {
  const SkcodeRawRail({super.key, required this.events});

  final List<SkcodeEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Center(child: Text("No events yet"));
    }
    // Computed once over the whole (ordered, single-session) window so an
    // ATTACH-mode terminal redraw gets the SAME "suppressed" answer here as
    // it does in the transcript reducer (see
    // [classifySkcodeEventsInContext]'s doc comment): the raw rail is the
    // noise valve an operator checks when something looks hidden, so it
    // must not silently disagree with the transcript about what got hidden.
    final classifications = classifySkcodeEventsInContext(events);
    return ListView.builder(
      itemCount: events.length,
      itemBuilder: (context, index) => _RawRailRow(
        event: events[index],
        classification: classifications[index],
      ),
    );
  }
}

class _RawRailRow extends StatelessWidget {
  const _RawRailRow({required this.event, required this.classification});

  final SkcodeEvent event;
  final ActivityClassification classification;

  String _description(ActivityClassification classification) {
    if (classification.label != null) return classification.label!;
    if (event.type == "tool_call" || event.type == "tool_result") {
      final name = event.data["name"] ?? event.data["tool_use_id"] ?? event.text;
      return "${event.type}: $name";
    }
    if (event.text.isNotEmpty) return "${event.type}: ${event.text}";
    return event.type;
  }

  String _formatTimestamp(double ts) {
    final millis = (ts * 1000).round();
    final dt = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, "0");
    return "${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}";
  }

  @override
  Widget build(BuildContext context) {
    final toneColor = skcodeToneColor(context, classification.tone);
    final rowId = skcodeEventRowId(event);
    final isSuppressed =
        classification.renderClass == ActivityRenderClass.suppressed;
    final pretty = _kPrettyJson.convert(event.toJson());

    return Container(
      key: ValueKey(rowId),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: toneColor, width: 3)),
      ),
      child: ExpansionTile(
        dense: true,
        title: Text(
          "#${event.seq}  ${_description(classification)}",
          style: isSuppressed
              ? TextStyle(
                  color: Theme.of(context).disabledColor,
                  fontStyle: FontStyle.italic,
                )
              : null,
        ),
        subtitle: Text(_formatTimestamp(event.ts)),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                pretty,
                // The ambient theme's own bodySmall size, only the family
                // swapped to mono: no fontSize literal here (density spec
                // section 7.1's font-literal guard), and it keeps the JSON
                // payload obeying OS accessibility text scaling exactly like
                // every other Text in this package.
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontFamily: "monospace"),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
