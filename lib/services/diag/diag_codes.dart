// The diagnostic event code catalog.
//
// See docs/superpowers/specs/2026-08-14-client-observability-ai-support-design.md
// section 4.1 for the source of truth this file implements. Every code
// listed there exists here with exactly the field keys and types that
// section declares.
//
// This map IS the privacy gate (spec 4.1, 7): the only way a new kind of
// event can exist is a code review where the reviewer reads the field list
// below and sees exactly what that event may carry. There is deliberately
// no field type for a free-form message: exception MESSAGES are never
// representable, only classified KINDS ([NetFailureKind]) and runtime type
// names (plain `String`, by convention holding a `.runtimeType.toString()`,
// e.g. `errorType` on the lifecycle codes). That is the direct fix for the
// incident this design exists for: `ERROR skchat.voice_engine.stt: STT
// failed:` with an empty `str(e)`, five times, telling nobody anything. A
// catalog with no message slot cannot reproduce that failure.

import 'diag_event.dart';

/// One allowed field on a [DiagCode]: its key, whether the catalog requires
/// it, and a predicate that accepts only correctly-typed values.
///
/// `isValidValue` is a predicate rather than a `Type` object because Dart
/// cannot test `value is someTypeVariable` for an arbitrary runtime `Type`;
/// a closure built from a concrete `is` check (see the factories below) is
/// the direct, generics-free way to express "this field is a String" /
/// "this field is a NetFailureKind" etc.
class DiagFieldSpec {
  const DiagFieldSpec._(
    this.key, {
    required this.typeName,
    required this.isValidValue,
    this.optional = false,
  });

  factory DiagFieldSpec.string(String key, {bool optional = false}) =>
      DiagFieldSpec._(
        key,
        typeName: 'String',
        isValidValue: (v) => v is String,
        optional: optional,
      );

  factory DiagFieldSpec.integer(String key, {bool optional = false}) =>
      DiagFieldSpec._(
        key,
        typeName: 'int',
        isValidValue: (v) => v is int,
        optional: optional,
      );

  factory DiagFieldSpec.boolean(String key, {bool optional = false}) =>
      DiagFieldSpec._(
        key,
        typeName: 'bool',
        isValidValue: (v) => v is bool,
        optional: optional,
      );

  factory DiagFieldSpec.netFailureKind(String key, {bool optional = false}) =>
      DiagFieldSpec._(
        key,
        typeName: 'NetFailureKind',
        isValidValue: (v) => v is NetFailureKind,
        optional: optional,
      );

  factory DiagFieldSpec.credentialKind(String key, {bool optional = false}) =>
      DiagFieldSpec._(
        key,
        typeName: 'CredentialKind',
        isValidValue: (v) => v is CredentialKind,
        optional: optional,
      );

  final String key;

  /// Human-readable type name, used only to build violation messages.
  final String typeName;

  final bool Function(Object value) isValidValue;

  /// If false (the default), [DiagCodes.firstViolation] rejects an event
  /// missing this field. Fields marked `?` in spec 4.1 pass `optional: true`.
  final bool optional;
}

/// One catalog entry: a registered code and its declared field contract.
class DiagCodeSpec {
  const DiagCodeSpec(this.code, this.fields);

  final String code;
  final List<DiagFieldSpec> fields;

  DiagFieldSpec? fieldSpec(String key) {
    for (final f in fields) {
      if (f.key == key) return f;
    }
    return null;
  }
}

/// The compile-time code catalog and the validation built on it.
///
/// Not instantiable; every member is static so the catalog reads as a
/// single reviewed table, matching spec 4.1's framing of "adding a code is
/// a code review event".
abstract final class DiagCodes {
  /// Spec 4.1, in source order. Roughly 25 codes are anticipated across all
  /// phases; these are the ones section 4.1 declares for Phase 1.
  static final Map<String, DiagCodeSpec> catalog = {
    for (final spec in _entries) spec.code: spec,
  };

  static final List<DiagCodeSpec> _entries = [
    DiagCodeSpec('net.request_failed', [
      DiagFieldSpec.netFailureKind('kind'),
      DiagFieldSpec.string('host'),
      DiagFieldSpec.integer('port'),
      DiagFieldSpec.string('pathTemplate'),
      DiagFieldSpec.string('method'),
      DiagFieldSpec.integer('status', optional: true),
      DiagFieldSpec.integer('durationMs'),
    ]),
    DiagCodeSpec('net.request_slow', [
      DiagFieldSpec.string('host'),
      DiagFieldSpec.integer('port'),
      DiagFieldSpec.string('pathTemplate'),
      DiagFieldSpec.integer('durationMs'),
    ]),
    DiagCodeSpec('auth.retry', [
      DiagFieldSpec.credentialKind('credential'),
      DiagFieldSpec.integer('status', optional: true),
    ]),
    DiagCodeSpec('auth.session_expired', [
      DiagFieldSpec.credentialKind('credential'),
      DiagFieldSpec.integer('status', optional: true),
    ]),
    DiagCodeSpec('auth.mint_failed', [
      DiagFieldSpec.credentialKind('credential'),
      DiagFieldSpec.integer('status', optional: true),
    ]),
    DiagCodeSpec('call.state', [
      DiagFieldSpec.string('state'),
      DiagFieldSpec.string('room'),
      DiagFieldSpec.integer('peerCount'),
    ]),
    DiagCodeSpec('call.quality', [
      DiagFieldSpec.string('quality'),
      DiagFieldSpec.string('participant'),
    ]),
    DiagCodeSpec('call.media_silent', [
      DiagFieldSpec.string('directionEnum'),
      DiagFieldSpec.integer('silentForMs'),
      DiagFieldSpec.boolean('trackActive'),
    ]),
    DiagCodeSpec('voice.turn', [
      DiagFieldSpec.string('stage'),
      DiagFieldSpec.integer('durationMs', optional: true),
    ]),
    DiagCodeSpec('health.change', [
      DiagFieldSpec.string('dep'),
      DiagFieldSpec.string('from'),
      DiagFieldSpec.string('to'),
      DiagFieldSpec.string('probe'),
    ]),
    DiagCodeSpec('beat.missed', [
      DiagFieldSpec.string('loop'),
      DiagFieldSpec.integer('expectedMs'),
      DiagFieldSpec.integer('silentForMs'),
    ]),
    DiagCodeSpec('store.box_corrupt', [
      DiagFieldSpec.string('box'),
      DiagFieldSpec.integer('bytes', optional: true),
    ]),
    DiagCodeSpec('store.flush_failed', [
      DiagFieldSpec.string('box'),
      DiagFieldSpec.integer('bytes', optional: true),
    ]),
    DiagCodeSpec('lifecycle.start', [
      DiagFieldSpec.string('buildId'),
      DiagFieldSpec.string('errorType', optional: true),
    ]),
    DiagCodeSpec('lifecycle.resume', [
      DiagFieldSpec.string('buildId'),
      DiagFieldSpec.string('errorType', optional: true),
    ]),
    DiagCodeSpec('lifecycle.error', [
      DiagFieldSpec.string('buildId'),
      DiagFieldSpec.string('errorType', optional: true),
    ]),
  ];

  static bool isRegistered(String code) => catalog.containsKey(code);

  /// Returns `null` if `fields` satisfies the catalog contract for `code`:
  /// `code` is registered, every key in `fields` is declared for that code,
  /// every declared value has the right type, and every non-optional
  /// declared field is present. Otherwise returns a human-readable
  /// description of the FIRST violation found.
  ///
  /// This function contains no `assert` and behaves identically whether
  /// asserts are enabled or stripped: it is the part of the contract that
  /// survives a release build, and [DiagEvent.tryCreate] calls it
  /// unconditionally for exactly that reason.
  static String? firstViolation(String code, Map<String, Object> fields) {
    final spec = catalog[code];
    if (spec == null) {
      return 'DiagEvent code "$code" is not registered in DiagCodes.catalog';
    }

    for (final key in fields.keys) {
      if (spec.fieldSpec(key) == null) {
        return 'DiagEvent code "$code" does not declare field "$key"';
      }
    }

    for (final field in spec.fields) {
      final present = fields.containsKey(field.key);
      if (!present) {
        if (!field.optional) {
          return 'DiagEvent code "$code" is missing required field '
              '"${field.key}"';
        }
        continue;
      }
      final value = fields[field.key] as Object;
      if (!field.isValidValue(value)) {
        return 'DiagEvent code "$code" field "${field.key}" must be a '
            '${field.typeName}, got ${value.runtimeType}';
      }
    }

    return null;
  }
}
