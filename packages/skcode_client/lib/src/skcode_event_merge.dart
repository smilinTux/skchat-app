import "skcode_event.dart";

// Ported from Buzz's `mergeObserverEventWindows`, Apache-2.0.
//   Source:  buzz/desktop/src/features/agents/ui/agentSessionPanelLayout.ts
//   License: Apache-2.0 (Block, Inc.), https://github.com/block/buzz
//
// Buzz's original dedups on `(seq, timestamp)` because its store scopes to
// ONE agent/session at a time. SKWorld's SessionEvent carries `sid` in-band
// (spec 5.1) specifically so a future multi-session merged view is possible
// without re-parsing URLs, so the key here is `(sid, seq, ts)`, and NEVER
// `seq` alone or `(sid, seq)` alone: `seq` is a per-session counter LOCAL TO
// ONE DAEMON PROCESS. It resets to 1 the moment the daemon restarts, while
// `ts` keeps climbing, so a `(sid, seq)` key alone collapses a pre-restart
// event and an unrelated post-restart event that happen to share a seq
// number. See `test/services/skcode/skcode_event_merge_test.dart`'s
// "seq-resets-on-restart" group for the regression test that catches
// exactly this (a `(sid, seq)`-only key fails it: 6 rows collapse to 3).

/// Buzz's `MAX_OBSERVER_EVENTS`, `observerRelayStore.ts`.
const kMaxLiveSkcodeEvents = 3000;

/// Stable scroll-anchor row id shared by the transcript and the raw rail.
String skcodeEventRowId(SkcodeEvent e) => "${e.sid}:${e.seq}:${e.ts}";

/// The dedup key: `(sid, seq, ts)`. Never `seq` or `(sid, seq)` alone (see
/// the module doc comment above).
String _dedupKey(SkcodeEvent e) => "${e.sid}:${e.seq}:${e.ts}";

/// Merge a live event window with an archived (paged) window: dedup on
/// `(sid, seq, ts)`, live copy wins on a duplicate (it may carry incremental
/// transcript mutations the archived copy lacks), ascending (ts, seq) sort.
List<SkcodeEvent> mergeSkcodeEventWindows(
  List<SkcodeEvent> liveEvents,
  List<SkcodeEvent> archivedEvents,
) {
  final merged = <String, SkcodeEvent>{};
  for (final e in archivedEvents) {
    merged[_dedupKey(e)] = e;
  }
  for (final e in liveEvents) {
    // Live copy wins on a duplicate key: inserted second, overwrites.
    merged[_dedupKey(e)] = e;
  }
  final out = merged.values.toList()
    ..sort((a, b) {
      final tsCmp = a.ts.compareTo(b.ts);
      if (tsCmp != 0) return tsCmp;
      return a.seq.compareTo(b.seq);
    });
  return out;
}

/// Trim an ascending-sorted event list to the most recent [max] entries
/// (Buzz's live-window cap; the archive itself is never capped).
List<SkcodeEvent> capLiveSkcodeWindow(
  List<SkcodeEvent> ascendingEvents, {
  int max = kMaxLiveSkcodeEvents,
}) {
  if (ascendingEvents.length <= max) return ascendingEvents;
  return ascendingEvents.sublist(ascendingEvents.length - max);
}
