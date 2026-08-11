import "skcode_event.dart";
import "skcode_event_merge.dart";

// Ported from Buzz's activity render taxonomy, Apache-2.0.
//   Sources: buzz/desktop/src/features/agents/ui/agentSessionTypes.ts
//            buzz/desktop/src/features/agents/ui/agentSessionToolClassifier.ts
//   License: Apache-2.0 (Block, Inc.), https://github.com/block/buzz
//
// Buzz's render class union uses `relay-op` for its CLI-relay tool category;
// this port generalizes that to [ActivityRenderClass.mcpOp] since hostd's MCP
// tool calls (`mcp__<server>__<tool>`) are the SKWorld analogue. [diff] is
// added because hostd emits a first-class `diff` SessionEvent Buzz has no
// equivalent for. Unlike Buzz (which leaves harness tools toneless), EVERY
// class here carries an [ActivityTone]: the whole point of this taxonomy is
// scanning an agent session's blast radius (what did it read, what did it
// write, what did it touch that needs admin attention) at a glance, spec
// section 6 of `skos/docs/specs/2026-08-11-skworld-code-section-architecture.md`.

/// How one activity renders in the transcript / raw rail (spec section 6).
///
/// `thought` and `image` are reserved for event shapes hostd does not emit
/// yet (extended-thinking blocks, image attachments); they are still part of
/// the enum because the taxonomy is meant to outlive the current emitter set.
enum ActivityRenderClass {
  message,
  fileEdit,
  fileRead,
  skillRead,
  shell,
  mcpOp,
  status,
  thought,
  plan,
  permission,
  diff,
  image,
  error,
  generic,
  raw,
  suppressed,
}

/// The blast-radius signal every [ActivityRenderClass] carries (spec section
/// 6: "unlike Buzz, every class gets a tone").
enum ActivityTone { read, write, admin, neutral }

/// Lifecycle of a `tool_call` row. A `tool_call` opens [executing]; the
/// matching `tool_result` closes it to [completed], or to [failed] when the
/// result carries `is_error` (spec section 6, mirroring Buzz's error
/// override). [pending] is available for a call a client wants to render
/// before the daemon has echoed it back; nothing in this package emits it
/// yet.
enum ToolStatus { executing, completed, failed, pending }

/// The canonical (class -> tone) default, proving every [ActivityRenderClass]
/// has a tone even for classes the current classifier never reaches on its
/// own (see [ActivityRenderClass] doc comment on `thought`/`image`). The
/// classifier below returns a per-event tone directly; this map exists as
/// the "every class gets a tone" contract a caller (or a test) can check
/// independent of any one event.
const Map<ActivityRenderClass, ActivityTone> kDefaultToneForClass = {
  ActivityRenderClass.message: ActivityTone.neutral,
  ActivityRenderClass.fileEdit: ActivityTone.write,
  ActivityRenderClass.fileRead: ActivityTone.read,
  ActivityRenderClass.skillRead: ActivityTone.read,
  ActivityRenderClass.shell: ActivityTone.write,
  ActivityRenderClass.mcpOp: ActivityTone.write,
  ActivityRenderClass.status: ActivityTone.neutral,
  ActivityRenderClass.thought: ActivityTone.neutral,
  ActivityRenderClass.plan: ActivityTone.neutral,
  ActivityRenderClass.permission: ActivityTone.admin,
  ActivityRenderClass.diff: ActivityTone.write,
  ActivityRenderClass.image: ActivityTone.neutral,
  ActivityRenderClass.error: ActivityTone.neutral,
  ActivityRenderClass.generic: ActivityTone.neutral,
  ActivityRenderClass.raw: ActivityTone.neutral,
  ActivityRenderClass.suppressed: ActivityTone.neutral,
};

/// The result of classifying one [SkcodeEvent] in isolation: what it renders
/// as, its tone, its tool-call lifecycle status (only meaningful for
/// `tool_call`/`tool_result`), and an optional override label for the two
/// rows the mapping table names explicitly ("Launched agent", "Ran tool").
class ActivityClassification {
  const ActivityClassification({
    required this.renderClass,
    required this.tone,
    this.status,
    this.label,
  });

  final ActivityRenderClass renderClass;
  final ActivityTone tone;
  final ToolStatus? status;
  final String? label;

  @override
  String toString() =>
      "ActivityClassification(renderClass: $renderClass, tone: $tone, "
      "status: $status, label: $label)";
}

/// `tool_call` names hostd's `claude_code.py` adapter passes through
/// verbatim in `data.name` (spec section 6 mapping table).
const _kFileReadTools = {"Read", "Glob", "Grep", "WebFetch", "WebSearch"};
const _kFileEditTools = {"Edit", "Write", "NotebookEdit"};
const _kAgentLaunchTools = {"Task", "Agent"};

/// `mcp__<server>__<tool>`, spec section 6. Non-greedy on the server segment
/// so a server or tool name that itself contains `__` still splits at the
/// first/last separator sensibly (matches Buzz's own MCP tool-name parsing
/// intent).
final RegExp _kMcpToolPattern = RegExp(r"^mcp__(.+?)__(.+)$");

/// mcpOp verb heuristic (spec section 6): `get/list/search/status/show` are
/// read, `kms/fortress/trustee/rotate` are admin, everything else is write.
/// Admin is checked first: a name that could plausibly match both a read and
/// an admin verb (unlikely in practice, but the table does not specify
/// precedence) should not hide a high-privilege operation behind a read tone.
ActivityTone _mcpVerbTone(String toolName) {
  final lower = toolName.toLowerCase();
  const adminVerbs = ["kms", "fortress", "trustee", "rotate"];
  const readVerbs = ["get", "list", "search", "status", "show"];
  if (adminVerbs.any(lower.contains)) return ActivityTone.admin;
  if (readVerbs.any(lower.contains)) return ActivityTone.read;
  return ActivityTone.write;
}

/// Harness heartbeat / keepalive noise (spec section 6: "harness heartbeat
/// noise -> suppressed/neutral", the explicit noise valve). No emitter in
/// `skharness`'s `claude_code.py` adapter sends this today (verified at
/// implementation time by grepping the adapter), so the wire shape here is
/// the anticipated one, matching the vocabulary hostd already uses for
/// `status.data.subtype` (`init`/`attached`/`result`): a `subtype` of
/// `"heartbeat"`, or a bare boolean `data.heartbeat` flag on any event type
/// for a harness that has no natural `status` frame to piggyback on.
bool _isHeartbeatNoise(SkcodeEvent event) {
  final subtype = event.data["subtype"];
  if (subtype is String && subtype.toLowerCase() == "heartbeat") return true;
  return event.data["heartbeat"] == true;
}

/// Classify a `tool_call` event by its tool name (spec section 6 mapping
/// table). Every `tool_call` opens [ToolStatus.executing]; the matching
/// `tool_result` closes it (see [buildSkcodeTranscript]).
ActivityClassification _classifyToolCall(SkcodeEvent event) {
  final name = (event.data["name"] as String?) ?? event.text;

  if (_kFileReadTools.contains(name)) {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.fileRead,
      tone: ActivityTone.read,
      status: ToolStatus.executing,
    );
  }
  if (_kFileEditTools.contains(name)) {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.fileEdit,
      tone: ActivityTone.write,
      status: ToolStatus.executing,
    );
  }
  if (name == "Bash") {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.shell,
      tone: ActivityTone.write,
      status: ToolStatus.executing,
    );
  }
  if (name == "Skill") {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.skillRead,
      tone: ActivityTone.read,
      status: ToolStatus.executing,
    );
  }
  if (_kAgentLaunchTools.contains(name)) {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.generic,
      tone: ActivityTone.write,
      status: ToolStatus.executing,
      label: "Launched agent",
    );
  }
  if (name == "TodoWrite") {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.plan,
      tone: ActivityTone.neutral,
      status: ToolStatus.executing,
    );
  }
  final mcpMatch = _kMcpToolPattern.firstMatch(name);
  if (mcpMatch != null) {
    final toolPart = mcpMatch.group(2) ?? "";
    return ActivityClassification(
      renderClass: ActivityRenderClass.mcpOp,
      tone: _mcpVerbTone(toolPart),
      status: ToolStatus.executing,
    );
  }
  return const ActivityClassification(
    renderClass: ActivityRenderClass.generic,
    tone: ActivityTone.neutral,
    status: ToolStatus.executing,
    label: "Ran tool",
  );
}

/// Classify one [SkcodeEvent] in isolation (spec section 6 mapping table).
///
/// This is the pure per-event classification the raw rail uses directly (one
/// row per event, independent of any other event) and the base the
/// transcript reducer ([buildSkcodeTranscript]) folds `tool_call`/
/// `tool_result` pairs on top of. A standalone `tool_result` classifies as
/// [ActivityRenderClass.raw]/neutral with its own [ToolStatus] ([completed]
/// or [failed]): in isolation it has no transcript identity of its own (the
/// mapping table's "tool_result with is_error -> error override on the open
/// call" only makes sense with the matching `tool_call` in hand), so [raw] is
/// the correct "this only makes sense in the raw feed" class for it.
ActivityClassification classifySkcodeEvent(SkcodeEvent event) {
  if (_isHeartbeatNoise(event)) {
    return const ActivityClassification(
      renderClass: ActivityRenderClass.suppressed,
      tone: ActivityTone.neutral,
    );
  }

  switch (event.type) {
    case "assistant_text":
      return const ActivityClassification(
        renderClass: ActivityRenderClass.message,
        tone: ActivityTone.neutral,
      );

    case "status":
      if (event.data["is_error"] == true) {
        return const ActivityClassification(
          renderClass: ActivityRenderClass.error,
          tone: ActivityTone.neutral,
        );
      }
      // init / attached / result-ok, and any other subtype hostd may add:
      // all render as a plain status line.
      return const ActivityClassification(
        renderClass: ActivityRenderClass.status,
        tone: ActivityTone.neutral,
      );

    case "needs_input":
      return const ActivityClassification(
        renderClass: ActivityRenderClass.permission,
        tone: ActivityTone.admin,
      );

    case "diff":
      return const ActivityClassification(
        renderClass: ActivityRenderClass.diff,
        tone: ActivityTone.write,
      );

    case "tool_call":
      return _classifyToolCall(event);

    case "tool_result":
      final isError = event.data["is_error"] == true;
      return ActivityClassification(
        renderClass: ActivityRenderClass.raw,
        tone: ActivityTone.neutral,
        status: isError ? ToolStatus.failed : ToolStatus.completed,
      );

    default:
      // An event type this taxonomy does not recognize at all (never a known
      // `tool_call` with an unrecognized NAME, which is handled inside
      // `_classifyToolCall` and gets the "Ran tool" label instead).
      return const ActivityClassification(
        renderClass: ActivityRenderClass.generic,
        tone: ActivityTone.neutral,
      );
  }
}

/// One row of the built transcript (spec section 6 / section 7): the render
/// class, tone, tool-call status, and optional label a `tool_call`/
/// `tool_result` pair (or any other single event) resolved to, plus the
/// originating [event] and its stable [rowId] (shared with the raw rail,
/// [skcodeEventRowId]).
class ActivityRecord {
  const ActivityRecord({
    required this.rowId,
    required this.event,
    required this.renderClass,
    required this.tone,
    this.status,
    this.label,
  });

  final String rowId;
  final SkcodeEvent event;
  final ActivityRenderClass renderClass;
  final ActivityTone tone;
  final ToolStatus? status;
  final String? label;

  ActivityRecord copyWith({ActivityRenderClass? renderClass, ToolStatus? status}) {
    return ActivityRecord(
      rowId: rowId,
      event: event,
      renderClass: renderClass ?? this.renderClass,
      tone: tone,
      status: status ?? this.status,
      label: label,
    );
  }
}

/// Fold a merged, ordered [SkcodeEvent] window (exactly what
/// [SkcodeSessionStore.state]'s `events` already is: deduped, `(ts, seq)`
/// sorted) into the rows the TRANSCRIPT renders (spec section 6/7 part 2).
///
/// Two things happen here that a plain per-event map does not do:
///  * `suppressed` events (the noise valve) are dropped entirely, never
///    becoming a transcript row (they still appear in the raw rail, which
///    classifies every event independently; see [classifySkcodeEvent] /
///    `SkcodeRawRail`).
///  * a `tool_result` never becomes its own row. It looks up its matching
///    open `tool_call` (by `data.id` == `data.tool_use_id`) and CLOSES that
///    row: [ToolStatus.completed] normally, [ToolStatus.failed] plus a
///    render-class override to [ActivityRenderClass.error] on `is_error`
///    (the tone is deliberately left untouched, spec section 6: "tool_result
///    ... error override on the open call, keeps tone" - so a failed file
///    write still reads as a write-tone error, not a neutral one). A result
///    with no matching open call (for example the archive window was
///    trimmed mid-call) is dropped silently; it still surfaces in the raw
///    rail on its own.
List<ActivityRecord> buildSkcodeTranscript(List<SkcodeEvent> events) {
  final records = <ActivityRecord>[];
  final openCallIndex = <String, int>{};

  for (final event in events) {
    if (event.type == "tool_result") {
      final id = event.data["tool_use_id"];
      final idx = id is String ? openCallIndex[id] : null;
      if (idx != null) {
        final isError = event.data["is_error"] == true;
        records[idx] = records[idx].copyWith(
          status: isError ? ToolStatus.failed : ToolStatus.completed,
          renderClass:
              isError ? ActivityRenderClass.error : records[idx].renderClass,
        );
      }
      continue;
    }

    final classification = classifySkcodeEvent(event);
    if (classification.renderClass == ActivityRenderClass.suppressed) {
      continue;
    }

    records.add(
      ActivityRecord(
        rowId: skcodeEventRowId(event),
        event: event,
        renderClass: classification.renderClass,
        tone: classification.tone,
        status: classification.status,
        label: classification.label,
      ),
    );

    if (event.type == "tool_call") {
      final id = event.data["id"];
      if (id is String) openCallIndex[id] = records.length - 1;
    }
  }

  return records;
}
