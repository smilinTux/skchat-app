// Client observability: the ring buffer plus its bounded persisted tail.
//
// See docs/superpowers/specs/2026-08-14-client-observability-ai-support-design.md
// section 4.2. Card b62da57c (Obs P1.2). Builds on diag_event.dart and
// diag_codes.dart (card cebbee31, merged, unchanged here). Sinks that call
// [DiagLog.emit] (card 7cebe96a), the dio breadcrumb interceptor
// (270ea324) and the redaction canary (893f55fa) are separate cards; this
// file exposes only [DiagLog] itself, kept deliberately small.
//
// WHY the caps and the never-per-event rule (the incident behind this
// design): a phone doing a disk write per log line is observability that
// degrades the device, which gets it switched off, and then it protects
// nothing. So persistence here happens ONLY on a debounce timer, on
// [flush] called explicitly (the app-pause/detach hook and snapshot
// capture, both later cards), and never as a side effect of [emit].
//
// WHY the persisted tail exists at all: the failure this whole design
// targets is the one nobody can reproduce on demand (skworld-100 died
// mid-call and the only witness was a silence). A crash must keep its last
// moments, so the tail is prepended back onto the ring on the next launch.

import 'dart:async';
import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'diag_event.dart';

/// Name of the Hive box the persisted tail lives in.
const String kDiagLogBoxName = 'diag_log';

/// Single key under which the whole bounded tail is stored, as a
/// `List<Map<String, dynamic>>` of JSON-safe-encoded events (oldest to
/// newest). One key, one value: there is nothing else in this box, so a
/// flush is always a single [Box.put] rather than N per-event writes.
const String _kTailStorageKey = 'tail';

/// In-memory ring buffer of [DiagEvent]s with a bounded, debounced,
/// crash-surviving persisted tail.
///
/// Two independent bounds, spec 4.2:
/// - The in-memory ring: a hard cap of [ringCapacity] events (default
///   1000), a fixed-size slot array plus a write cursor -- the 1001st
///   event overwrites the slot the 1st occupied, never a growing list.
/// - The persisted tail: at most [persistedTailMaxEvents] (default 300)
///   of the ring's newest events, AND at most [persistedTailMaxBytes]
///   (default 256 KiB) once JSON-encoded, whichever bounds tighter for a
///   given flush. Oldest-first trimming, same policy the snapshot builder
///   (spec 4.9, a later card) uses.
///
/// Persistence never happens inside [emit]. It happens on a debounce
/// timer ([debounceInterval], default 30 s) and whenever a caller invokes
/// [flush] directly.
class DiagLog {
  DiagLog({
    this.ringCapacity = 1000,
    this.persistedTailMaxEvents = 300,
    this.persistedTailMaxBytes = 256 * 1024,
    Duration debounceInterval = const Duration(seconds: 30),
    DateTime Function()? now,
    Future<Box<dynamic>> Function()? openBox,
  })  : assert(ringCapacity > 0, 'ringCapacity must be positive'),
        _debounceInterval = debounceInterval,
        _now = now ?? DateTime.now,
        _openBox = openBox ?? (() => Hive.openBox<dynamic>(kDiagLogBoxName)),
        _ring = List<DiagEvent?>.filled(ringCapacity, null);

  /// Hard cap on the in-memory ring. Spec default: 1000.
  final int ringCapacity;

  /// Hard cap on how many of the ring's newest events a flush persists.
  /// Spec default: 300.
  final int persistedTailMaxEvents;

  /// Hard cap, in bytes of the JSON-encoded tail, on what a flush
  /// persists. Spec default: 256 KiB. Binds independently of
  /// [persistedTailMaxEvents]; whichever is tighter for the current
  /// events wins (see [_boundedTailPayload]).
  final int persistedTailMaxBytes;

  final Duration _debounceInterval;
  final DateTime Function() _now;
  final Future<Box<dynamic>> Function() _openBox;

  // --- Ring buffer: fixed-size slot array + write cursor (spec 4.2: "a
  // plain fixed-size list with a write cursor; no dependency"). ---
  final List<DiagEvent?> _ring;
  int _writeCursor = 0;
  int _liveCount = 0;
  int _nextSeq = 0;

  Box<dynamic>? _box;
  Timer? _debounceTimer;
  bool _dirtySincePersist = false;
  bool _disposed = false;

  final StreamController<DiagEvent> _controller =
      StreamController<DiagEvent>.broadcast();

  /// Live stream of every event this instance accepts, in emission order.
  /// A dropped (invalid) event never reaches this stream.
  Stream<DiagEvent> get eventStream => _controller.stream;

  /// True once the persisted box opened successfully. False in
  /// memory-only mode (box never opened, or opening failed and the
  /// corrupt/unopenable fallback below took over) -- [flush] is then a
  /// no-op rather than a crash.
  bool get isPersistenceAvailable => _box != null;

  /// All events currently held in the ring, oldest first. A fresh
  /// unmodifiable snapshot each call; mutating the ring afterward (via
  /// [emit]) never retroactively changes a list already returned.
  List<DiagEvent> get events {
    if (_liveCount < ringCapacity) {
      return List<DiagEvent>.unmodifiable(
        _ring.sublist(0, _liveCount).cast<DiagEvent>(),
      );
    }
    // Full ring: the oldest live slot is the one the cursor is about to
    // overwrite next.
    final ordered = <DiagEvent>[
      ..._ring.sublist(_writeCursor).cast<DiagEvent>(),
      ..._ring.sublist(0, _writeCursor).cast<DiagEvent>(),
    ];
    return List<DiagEvent>.unmodifiable(ordered);
  }

  /// Open the persisted box and, on success, prepend whatever tail it
  /// already holds onto the ring so a crash's last moments survive a
  /// restart (spec 4.2, AC5). Mirrors the repo's `_openBoxSafely` pattern
  /// in `main.dart`: on ANY failure to open, best-effort delete the
  /// unopenable file from disk and continue memory-only. Never throws --
  /// a diagnostics bug must not be able to stop the app from launching
  /// (spec section 6).
  Future<void> init() async {
    try {
      _box = await _openBox();
    } catch (_) {
      try {
        await Hive.deleteBoxFromDisk(kDiagLogBoxName);
      } catch (_) {
        // Nothing more we can safely do; proceed memory-only.
      }
      _box = null;
      return;
    }
    _restorePersistedTail();
  }

  void _restorePersistedTail() {
    final box = _box;
    if (box == null) return;
    Object? raw;
    try {
      raw = box.get(_kTailStorageKey);
    } catch (_) {
      return;
    }
    if (raw is! List) return;
    var maxSeqSeen = -1;
    for (final item in raw) {
      if (item is! Map) continue;
      final restored = _decodeEvent(item);
      if (restored == null) continue; // one bad entry never sinks the rest
      _pushToRing(restored);
      if (restored.seq > maxSeqSeen) maxSeqSeen = restored.seq;
    }
    if (maxSeqSeen >= 0) {
      _nextSeq = maxSeqSeen + 1;
    }
    // Restoring is not itself a reason to re-flush; the box already has
    // exactly this data.
    _dirtySincePersist = false;
  }

  /// Validate `fields` against the catalog and, if it is a legal event,
  /// append it to the ring. Invalid input is dropped (fail-open, spec
  /// section 6) rather than thrown to the caller; call sites are expected
  /// to pass registered codes, so this mirrors [DiagEvent.tryCreate]'s own
  /// contract rather than adding a second one.
  ///
  /// Never writes to disk. Schedules the debounce timer if one is not
  /// already pending; the timer (or an explicit [flush] call from the
  /// pause/detach hook or snapshot capture) is the only path to disk.
  DiagEvent? emit({
    required DiagLevel level,
    required DiagCategory category,
    required String code,
    Map<String, Object> fields = const {},
  }) {
    final event = DiagEvent.tryCreate(
      seq: _nextSeq,
      ts: _now(),
      level: level,
      category: category,
      code: code,
      fields: fields,
    );
    if (event == null) return null;
    _nextSeq++;
    _pushToRing(event);
    _dirtySincePersist = true;
    _controller.add(event);
    _scheduleDebouncedFlush();
    return event;
  }

  void _pushToRing(DiagEvent event) {
    _ring[_writeCursor] = event;
    _writeCursor = (_writeCursor + 1) % ringCapacity;
    if (_liveCount < ringCapacity) _liveCount++;
  }

  void _scheduleDebouncedFlush() {
    if (_debounceTimer != null) return; // already pending
    _debounceTimer = Timer(_debounceInterval, () {
      _debounceTimer = null;
      unawaited(flush());
    });
  }

  /// Force a persistence write now. This is the ONLY place [DiagLog]
  /// touches disk (besides [init]'s read); [emit] never calls it directly,
  /// only [_scheduleDebouncedFlush] does, and callers are expected to call
  /// it themselves on app pause/detach and on snapshot capture (both wired
  /// by later cards). A no-op in memory-only mode and when nothing changed
  /// since the last flush, and fail-open: a write failure is swallowed,
  /// never propagated into app logic (spec section 6).
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final box = _box;
    if (box == null) return;
    if (!_dirtySincePersist) return;
    try {
      await box.put(_kTailStorageKey, _boundedTailPayload());
      _dirtySincePersist = false;
    } catch (_) {
      // Fail-open: never let a persistence failure reach app logic.
    }
  }

  /// Builds the tail to persist: the ring's newest events, walked from
  /// newest to oldest, kept while under BOTH [persistedTailMaxEvents] and
  /// [persistedTailMaxBytes] of JSON-encoded size. Whichever cap would be
  /// exceeded next stops the walk, so the tighter cap always wins for the
  /// current data, and the result is oldest-first (spec 4.9 uses the same
  /// "drop oldest first" policy for the snapshot builder).
  List<Map<String, dynamic>> _boundedTailPayload() {
    final all = events;
    final start = all.length > persistedTailMaxEvents
        ? all.length - persistedTailMaxEvents
        : 0;
    final candidates = all.sublist(start);

    final kept = <Map<String, dynamic>>[];
    var totalBytes = 0;
    for (var i = candidates.length - 1; i >= 0; i--) {
      final encoded = _encodeEvent(candidates[i]);
      final size = utf8.encode(jsonEncode(encoded)).length;
      if (kept.isEmpty && size > persistedTailMaxBytes) {
        // Even the single newest event alone busts the byte cap: nothing
        // can be persisted this flush without violating a hard cap.
        break;
      }
      if (kept.isNotEmpty && totalBytes + size > persistedTailMaxBytes) {
        break;
      }
      kept.insert(0, encoded);
      totalBytes += size;
    }
    return kept;
  }

  /// Releases the underlying Hive box (if any) and this log's stream
  /// controller. Safe to call more than once. Tests use this to reopen
  /// the same box name from a second [DiagLog] (simulating a restart);
  /// production callers are expected to call it on app shutdown, if ever.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _controller.close();
    final box = _box;
    _box = null;
    if (box != null && box.isOpen) {
      await box.close();
    }
  }

  // --- Storage codec: DiagEvent <-> a JSON-safe Map. Kept private and
  // local to this file; nothing outside diag_log.dart needs to know the
  // on-disk shape. Enum field values (NetFailureKind, CredentialKind) have
  // no native JSON representation, so they round-trip through a small
  // tagged wrapper; every other field type the catalog allows (String,
  // int, bool) is already JSON-safe. ---

  Map<String, dynamic> _encodeEvent(DiagEvent event) => <String, dynamic>{
        'seq': event.seq,
        'ts': event.ts.toIso8601String(),
        'level': event.level.name,
        'category': event.category.name,
        'code': event.code,
        'fields': event.fields.map(
          (key, value) => MapEntry(key, _encodeFieldValue(value)),
        ),
      };

  Object _encodeFieldValue(Object value) {
    if (value is NetFailureKind) {
      return <String, String>{'__enum': 'NetFailureKind', 'v': value.name};
    }
    if (value is CredentialKind) {
      return <String, String>{'__enum': 'CredentialKind', 'v': value.name};
    }
    return value; // String, int, bool: already JSON-safe.
  }

  /// Reconstructs a [DiagEvent] from a persisted map, or `null` if the
  /// entry cannot be safely reconstructed (unknown shape, a field type
  /// the catalog no longer accepts, etc). Deliberately never lets
  /// [DiagEvent.tryCreate]'s debug assert escape: a stray persisted
  /// entry from a prior build must never be able to crash startup.
  DiagEvent? _decodeEvent(Map<dynamic, dynamic> raw) {
    final seq = raw['seq'];
    final tsRaw = raw['ts'];
    final levelName = raw['level'];
    final categoryName = raw['category'];
    final code = raw['code'];
    final rawFields = raw['fields'];
    if (seq is! int ||
        tsRaw is! String ||
        levelName is! String ||
        categoryName is! String ||
        code is! String ||
        rawFields is! Map) {
      return null;
    }

    final DateTime ts;
    try {
      ts = DateTime.parse(tsRaw);
    } catch (_) {
      return null;
    }

    DiagLevel? level;
    for (final candidate in DiagLevel.values) {
      if (candidate.name == levelName) {
        level = candidate;
        break;
      }
    }
    DiagCategory? category;
    for (final candidate in DiagCategory.values) {
      if (candidate.name == categoryName) {
        category = candidate;
        break;
      }
    }
    if (level == null || category == null) return null;

    final fields = <String, Object>{};
    for (final entry in rawFields.entries) {
      final decoded = _decodeFieldValue(entry.value);
      if (decoded == null) return null;
      fields[entry.key.toString()] = decoded;
    }

    try {
      return DiagEvent.tryCreate(
        seq: seq,
        ts: ts,
        level: level,
        category: category,
        code: code,
        fields: fields,
      );
    } catch (_) {
      // A debug-mode assert inside tryCreate must not escape here: a
      // persisted entry that no longer satisfies the catalog (e.g. after
      // a code changed shape) is dropped, not fatal.
      return null;
    }
  }

  Object? _decodeFieldValue(Object? value) {
    if (value is String || value is int || value is bool) return value;
    if (value is Map) {
      final tag = value['__enum'];
      final v = value['v'];
      if (tag == 'NetFailureKind' && v is String) {
        for (final k in NetFailureKind.values) {
          if (k.name == v) return k;
        }
      }
      if (tag == 'CredentialKind' && v is String) {
        for (final k in CredentialKind.values) {
          if (k.name == v) return k;
        }
      }
    }
    return null;
  }
}
