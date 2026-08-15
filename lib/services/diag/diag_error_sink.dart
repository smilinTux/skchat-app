// Client observability: the swappable target for globally-emitted
// DiagEvents.
//
// This is deliberately the smallest possible seam. The global error sinks
// installed in main.dart (card 7cebe96a, spec section 4.2) need somewhere
// to put the lifecycle.error events they build, and the ring buffer that
// owns that somewhere (diag_log.dart, card b62da57c) is being built on its
// own branch in parallel. Rather than depend on that file's internals, or
// block on it landing first, this file defines only:
//
//   - [diagEventSink]: a settable target, `null` until the buffer wires
//     itself in (e.g. `diagEventSink = diagLog.emit;` during main()).
//   - [emitDiagEvent]: fail-open dispatch to that target.
//
// Nothing here assumes what the buffer looks like, so wiring it in later
// costs one assignment in main.dart and zero changes to this file.

import 'diag_event.dart';

/// A function that accepts one already-validated [DiagEvent].
typedef DiagEventSink = void Function(DiagEvent event);

/// The current destination for emitted events. `null` (the default) means
/// there is nowhere to put them yet, which [emitDiagEvent] treats as a
/// silent no-op, not an error. The ring buffer assigns this once it exists.
DiagEventSink? diagEventSink;

/// Fail-open dispatch of [event] to [diagEventSink].
///
/// Two guarantees, both load-bearing for the global error sinks that call
/// this from inside `FlutterError.onError` and `PlatformDispatcher.onError`:
///
/// - `event == null` (a rejected [DiagEvent], see [DiagEvent.tryCreate]) is
///   dropped silently.
/// - Any exception thrown by [diagEventSink] is caught and discarded here.
///   Observability must never be able to break the app it observes; that
///   property outranks every event it could ever record.
void emitDiagEvent(DiagEvent? event) {
  if (event == null) return;
  try {
    diagEventSink?.call(event);
  } catch (_) {
    // Fail-open, deliberately silent. See file doc.
  }
}
