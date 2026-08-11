/// SkcodeEvent: the Dart mirror of skharness's `SessionEvent` wire shape
/// (`skharness/src/skharness/events.py::SessionEvent.to_dict()`, skcode
/// Code-section card C-1, spec 2026-08-11 section 5.1).
///
/// v2 adds three fields ADDITIVELY on top of the original four
/// (`type`/`text`/`ts`/`data`): `seq`, `sid`, `source`. An older frame that
/// omits them still parses (`seq` 0, `sid` "", `source` "interactive"),
/// mirroring the server's own additive-only contract.
///
/// `seq` is a per-session monotonic counter assigned AT APPEND by the
/// daemon's session buffer, and it is process-local: it resets to 1 the
/// moment the daemon restarts, while `ts` keeps climbing. That is why no
/// code in this app may use `seq` alone (or `sid`+`seq` alone) as a dedup or
/// identity key; see `skcode_event_merge.dart`.
class SkcodeEvent {
  const SkcodeEvent({
    required this.type,
    this.text = "",
    required this.ts,
    this.data = const {},
    this.seq = 0,
    this.sid = "",
    this.source = "interactive",
  });

  /// One of `status | assistant_text | tool_call | tool_result | diff |
  /// needs_input`. Kept as a raw String (not an enum) here: the taxonomy
  /// mapping onto render classes/tones is card C-4's job, not the
  /// transport layer's.
  final String type;

  final String text;

  /// Epoch seconds (may carry sub-second precision), server-assigned.
  final double ts;

  final Map<String, dynamic> data;

  /// Per-session monotonic counter, local to one daemon process. Resets on
  /// daemon restart. NEVER a dedup/identity key on its own.
  final int seq;

  /// Session id this event belongs to.
  final String sid;

  /// `interactive` | `autocode` | `attach`. Unknown values pass through
  /// unchanged (the server itself does not enforce an enum here).
  final String source;

  factory SkcodeEvent.fromJson(Map<String, dynamic> json) {
    final rawData = json["data"];
    return SkcodeEvent(
      type: json["type"] as String? ?? "status",
      text: json["text"] as String? ?? "",
      ts: (json["ts"] as num?)?.toDouble() ?? 0.0,
      data: rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : const <String, dynamic>{},
      seq: (json["seq"] as num?)?.toInt() ?? 0,
      sid: json["sid"] as String? ?? "",
      source: json["source"] as String? ?? "interactive",
    );
  }

  Map<String, dynamic> toJson() => {
        "type": type,
        "text": text,
        "ts": ts,
        "data": data,
        "seq": seq,
        "sid": sid,
        "source": source,
      };

  @override
  String toString() =>
      "SkcodeEvent(sid: $sid, seq: $seq, ts: $ts, type: $type)";
}
