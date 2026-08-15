// Client observability: the diagnostic event contract.
//
// See docs/superpowers/specs/2026-08-14-client-observability-ai-support-design.md
// section 4.1. This file, plus diag_codes.dart, is types and validation
// ONLY: no ring buffer, no sinks, no interceptor. Those build on this
// contract in later cards (b62da57c, 7cebe96a, 270ea324) and must not have
// to change this file to do it.
//
// Decision 1 (spec section 3): an event is `{seq, ts, level, category, code,
// fields}`. `code` comes from a registered catalog (diag_codes.dart); each
// code declares its allowed field keys and types. Free-form prose never
// enters the buffer.
//
// WHY this is enforced at construction, not left to callers: the incident
// that motivated this design logged `STT failed:` five times with an empty
// `str(e)` and told nobody anything, because the "event" was a string with
// no contract at all. A [DiagEvent] cannot exist with a code the catalog
// does not know, or a field the catalog does not declare for that code, or
// a field of the wrong type. Adding a code is therefore a code review
// event: the reviewer sees exactly which keys that event may carry, and
// that review IS the privacy gate (see diag_codes.dart for the catalog and
// the exception-message rule).

import 'diag_codes.dart';

/// Severity of a [DiagEvent].
///
/// `debug` events are the least trusted: per spec 4.2 they stay in the
/// in-memory ring only and are excluded from the persisted tail and from
/// snapshots by default. `info` and above are persisted and reportable.
enum DiagLevel { error, warn, info, debug }

/// Coarse subsystem a [DiagEvent] belongs to, matching the code's prefix
/// (`net.*` -> [net], `call.*` -> [call], etc). Carried on the event
/// itself (not derived from `code`) so a caller can filter/route without
/// parsing the code string.
enum DiagCategory { net, call, voice, auth, store, health, ui, lifecycle }

/// Network failure classification (spec Decision 3). Always derived from
/// `DioExceptionType` / `SocketException` type information by the
/// interceptor (a later card); NEVER from `Exception.toString()`. That
/// distinction is the actual fix for the incident: an empty `str(e)` on an
/// httpx connect timeout was the entire log line, and a KIND enum cannot be
/// empty the way a caught-exception string can.
enum NetFailureKind {
  dns,
  refused,
  connectTimeout,
  readTimeout,
  tls,
  http4xx,
  http5xx,
  aborted,
  unknown,
}

/// Which credential an auth event concerns. Only the KIND is representable,
/// never the credential value itself (spec 4.1: "never the value").
enum CredentialKind { session, audience, operator }

/// One structured diagnostic event.
///
/// Immutable and only constructible via [DiagEvent.tryCreate], which
/// validates `code` and `fields` against [DiagCodes.catalog]. There is no
/// public constructor: a `DiagEvent` that exists is, by construction, one
/// the catalog allows.
class DiagEvent {
  DiagEvent._({
    required this.seq,
    required this.ts,
    required this.level,
    required this.category,
    required this.code,
    required this.fields,
  });

  /// Monotonic, session-scoped sequence number. Assigned by the caller
  /// (the ring buffer, in a later card); this type does not generate it,
  /// so construction stays a pure function of its inputs and stays easy to
  /// unit test.
  final int seq;

  /// UTC timestamp. [tryCreate] normalizes whatever is passed via
  /// [DateTime.toUtc], so this is always UTC regardless of caller.
  final DateTime ts;

  final DiagLevel level;
  final DiagCategory category;

  /// The catalog code, e.g. `net.request_failed`. Always a key in
  /// [DiagCodes.catalog]; [tryCreate] guarantees this.
  final String code;

  /// Structured fields for this event. Unmodifiable: keys and value types
  /// are exactly what [DiagCodes.catalog] declares for [code], no more, no
  /// less required-field checking included.
  final Map<String, Object> fields;

  /// The only way to build a [DiagEvent]. Returns `null` if `code` is not
  /// registered in [DiagCodes.catalog], or if `fields` contains a key the
  /// catalog does not declare for `code`, or a declared key with a value of
  /// the wrong type, or is missing a field the catalog marks required.
  ///
  /// Two layers of rejection, both driven by the same check
  /// ([DiagCodes.firstViolation]):
  ///
  /// - In debug builds (asserts enabled, which is how `flutter test` runs),
  ///   invalid input trips an [AssertionError] immediately, so a mistake in
  ///   a call site is loud during development and in CI.
  /// - In release builds, Dart strips `assert(...)` entirely, so the
  ///   `if (violation != null) return null;` below is what actually
  ///   protects release. It does not depend on asserts being enabled, so
  ///   release behavior can be exercised in tests by calling
  ///   [DiagCodes.firstViolation] directly: that is the exact logic that
  ///   survives assert-stripping.
  ///
  /// A future ring buffer must treat `null` as "drop the event" (fail-open,
  /// per spec section 6): a diagnostics bug must never crash app logic.
  static DiagEvent? tryCreate({
    required int seq,
    required DateTime ts,
    required DiagLevel level,
    required DiagCategory category,
    required String code,
    Map<String, Object> fields = const {},
  }) {
    final violation = DiagCodes.firstViolation(code, fields);
    // Dart's flow analysis promotes `violation` to non-null `String` inside
    // this message expression (it is only evaluated when the condition
    // above is false, i.e. when violation != null), so no `?? fallback` is
    // needed or accepted without triggering a dead-code lint.
    assert(violation == null, violation);
    if (violation != null) {
      return null;
    }
    return DiagEvent._(
      seq: seq,
      ts: ts.toUtc(),
      level: level,
      category: category,
      code: code,
      fields: Map.unmodifiable(fields),
    );
  }

  @override
  String toString() =>
      'DiagEvent(seq: $seq, ts: $ts, level: $level, category: $category, '
      'code: $code, fields: $fields)';
}
