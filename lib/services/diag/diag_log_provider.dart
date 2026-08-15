// Client observability: wiring `DiagLog` (diag_log.dart) into the running
// app. Card 0a5b8e07 (Obs P1, wiring half). This file does not add any new
// diagnostic behavior of its own -- it is the seam that makes the already-
// merged, previously-inert Phase 1 pieces (diag_event.dart, diag_codes.dart,
// diag_log.dart, diag_interceptor.dart) actually record something.
//
// Two things live here:
//
//   - [diagLogProvider]: Riverpod access to the app's single [DiagLog], for
//     future consumers (the Me > Logs screen is a separate follow-up card,
//     out of scope here, but this is the seam it will read from). Matches
//     this repo's "service + provider per file" convention -- see e.g.
//     `device_list_service.dart`'s `deviceListServiceProvider` or
//     `livekit_call_service.dart`'s `liveKitCallServiceProvider`.
//   - [initDiagLogAndWireSink]: constructs that DiagLog, initializes its
//     persisted tail, and assigns it to [diagEventSink] (diag_error_sink.dart)
//     -- the single assignment that file's own header comment has been
//     waiting for since it shipped null-by-default.
//
// WHY a plain top-level function instead of the widget-tree "eager
// ref.watch in SKChatApp.build()" idiom this app uses for e.g.
// `skcommsSyncProvider` / `identityKeyPairProvider` / `pqBootstrapProvider`:
// those are fine to hydrate on the first frame. DiagLog is not -- its whole
// job is to catch errors from AS EARLY AS POSSIBLE, including ones thrown
// while the widget tree itself is first constructed, so it must be live
// before `runApp()`. Only `main()` can guarantee that ordering, so this is
// called from there, once, and the resulting instance is threaded into the
// widget tree via `ProviderScope(overrides: [diagLogProvider.overrideWithValue(diagLog)])`
// (the override pattern already documented, if not yet used, on
// `liveKitCallServiceProvider`) rather than left to construct itself lazily.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diag_error_sink.dart';
import 'diag_log.dart';

/// Riverpod access to the app's [DiagLog].
///
/// Production code never falls through to this default factory: `main.dart`
/// overrides it with the already-[DiagLog.init]ed singleton (via
/// [initDiagLogAndWireSink]) before the widget tree is built. The default
/// here exists only so a widget test, or any future screen that reaches this
/// provider without that override, gets a working (if memory-only --
/// `init()` was never called on it, so `isPersistenceAvailable` is false)
/// [DiagLog] instead of a Riverpod "missing override" crash.
final diagLogProvider = Provider<DiagLog>((ref) => DiagLog());

/// Constructs the app's single [DiagLog], initializes its persisted tail,
/// and points [diagEventSink] at it.
///
/// Call once, from `main()`, BEFORE `installGlobalErrorSinks()`: that
/// ordering is what guarantees the global error sinks can never fire into a
/// null sink, because they are not even installed (i.e. `FlutterError.onError`
/// / `PlatformDispatcher.instance.onError` have not been replaced yet) at the
/// point this returns.
///
/// Never throws. [DiagLog.init] already documents "never throws" as part of
/// its own contract (an unopenable/corrupt persisted box falls back to
/// memory-only mode rather than propagating), but this wraps it again anyway
/// so that even a violation of that contract -- or any other bug in this
/// one-time boot plumbing -- can never be the reason the app fails to boot.
/// On failure, the returned [DiagLog] is simply un-initialized (equivalent
/// to memory-only mode: `isPersistenceAvailable` is false) and is still
/// wired to [diagEventSink], so the rest of the app behaves exactly as if
/// persistence were unavailable this run rather than losing diagnostics
/// entirely.
Future<DiagLog> initDiagLogAndWireSink() async {
  final diagLog = DiagLog();
  try {
    await diagLog.init();
  } catch (_) {
    // Fail-open: see doc above. `diagLog` is still fully usable, memory-only.
  }
  // [DiagEventSink] is `void Function(DiagEvent event)`: it hands over an
  // already-built, already-validated event (that is what every producer --
  // the dio interceptor, the global error sinks -- constructs via
  // `DiagEvent.tryCreate`). [DiagLog.emit] does not accept one of those; it
  // BUILDS its own from raw `{level, category, code, fields}` and assigns
  // its own ring-scoped `seq`/`ts` as it does. This one-line adapter is the
  // seam between the two shapes, re-deriving emit's raw arguments from the
  // event producers already built. This is not a workaround: both
  // `diag_interceptor.dart` (its `seq` doc) and `main.dart`
  // (`installGlobalErrorSinks`) already document their own seq/ts as a
  // placeholder "until the real ring buffer renumbers or ignores it" --
  // this is that renumbering.
  diagEventSink = (event) => diagLog.emit(
        level: event.level,
        category: event.category,
        code: event.code,
        fields: event.fields,
      );
  return diagLog;
}
