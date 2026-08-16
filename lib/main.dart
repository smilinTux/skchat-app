import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/build_info.dart';
import 'core/theme/theme.dart';
import 'core/router/app_router.dart';
import 'core/providers/theme_provider.dart';
import 'core/providers/density_provider.dart';
import 'core/widgets/deploy_freshness_banner.dart';
import 'data/hive_adapters.dart';
import 'services/diag/diag_error_sink.dart';
import 'services/diag/diag_event.dart';
import 'services/diag/diag_log_provider.dart';
import 'services/skcomms_sync.dart';
import 'services/identity_service.dart';
import 'services/pq_prekey_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive for local persistence.
  await Hive.initFlutter();
  Hive.registerAdapter(ChatMessageAdapter());
  Hive.registerAdapter(ConversationAdapter());

  // Wire the diagnostics ring buffer (card 0a5b8e07) into the global sink
  // BEFORE installing the global error handlers just below, so those
  // handlers can never fire into a null sink: `FlutterError.onError` /
  // `PlatformDispatcher.instance.onError` are not even replaced yet at the
  // point this line returns. Never throws (see initDiagLogAndWireSink doc);
  // a diagnostics-boot failure must not be able to keep the app from
  // launching.
  final diagLog = await initDiagLogAndWireSink();

  installGlobalErrorSinks();

  // Keep the host console quiet outside debug builds: no debugPrint spew.
  // Framework error dumps are handled by installGlobalErrorSinks above (it
  // swallows in release and delegates to the default handler in debug, same
  // split this block used to encode on its own).
  if (!kDebugMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Pre-open the boxes the router's startup redirect depends on (backend
  // config lives in `settings`; the onboarding-complete flag in `onboarding`)
  // so the redirect can read hydrated state as early as possible. Each open is
  // isolated in its own try/catch: a corrupt or locked box must NEVER brick
  // launch, on failure we drop the box from disk and fall through to defaults
  // (first-run / build defaults), which is always a safe, recoverable state.
  // The type params match every later `Hive.openBox` call for these boxes
  // (`settings` as <String>, `onboarding` as <dynamic>) so re-opens elsewhere
  // return the same instance without a type conflict.
  await _openBoxSafely<String>('settings');
  await _openBoxSafely<dynamic>('onboarding');

  // Full-screen OLED experience, hide system UI chrome.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [diagLogProvider.overrideWithValue(diagLog)],
      child: const SKChatApp(),
    ),
  );
}

/// Monotonic, session-scoped sequence number for events built here. There is
/// no ring buffer yet to own this (card b62da57c, in flight on its own
/// branch); a local counter is a faithful stand-in per [DiagEvent.seq]'s own
/// doc ("assigned by the caller"), and this is the caller until that lands.
int _diagSeq = 0;

/// Installs the two global error sinks: `FlutterError.onError` and
/// `PlatformDispatcher.instance.onError` each record a `lifecycle.error`
/// [DiagEvent] (spec section 4.2) carrying only the error's runtime TYPE
/// name, never its message or stack text. That restriction is the direct
/// fix for the incident this whole design answers: an exception message
/// logged empty five times told nobody anything, and a separate leak spoke
/// an internal string aloud as if it were the agent's own words. The
/// catalog (`diag_codes.dart`) structurally cannot carry a message for
/// `lifecycle.error`, so this function does not have to trust itself to
/// leave one out.
///
/// [debugMode] defaults to [kDebugMode] and exists only so tests can drive
/// both branches directly; `flutter test` always runs with asserts enabled
/// (i.e. as a debug build), so the release branch cannot be reached by
/// flipping the real [kDebugMode]. `test/main_error_sinks_test.dart`
/// documents this the same way `diag_event_test.dart` already does for
/// `DiagEvent.tryCreate`.
///
/// Behaviour is unchanged from before this function existed, on top of now
/// also emitting an event:
/// - Release: both handlers swallow. `FlutterError.onError` still writes
///   nothing to the host console (this is exactly the block it replaces);
///   `PlatformDispatcher.onError` reports the error handled and does not
///   call whatever handler preceded it.
/// - Debug: both handlers delegate to whatever handler was installed before
///   this call, so local development keeps seeing full framework error
///   output (red screens, console dumps) exactly as before.
///
/// Fail-open: nothing in the emit path below can throw past
/// [_emitLifecycleError], which catches everything itself, so the
/// swallow/delegate decision above always runs regardless of whether
/// recording the event succeeded.
@visibleForTesting
void installGlobalErrorSinks({bool debugMode = kDebugMode}) {
  final FlutterExceptionHandler? previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _emitLifecycleError(details.exception);
    if (debugMode) {
      previousFlutterOnError?.call(details);
    }
    // Release: swallow, unchanged from before this sink existed. A
    // sovereign release build must not write to the host console.
  };

  final ErrorCallback? previousPlatformOnError =
      PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _emitLifecycleError(error);
    if (debugMode) {
      return previousPlatformOnError?.call(error, stack) ?? false;
    }
    // Release: report handled, matching the FlutterError policy above.
    return true;
  };
}

/// Builds and dispatches a `lifecycle.error` [DiagEvent] for [error]. Never
/// throws: event construction and dispatch are both wrapped here so a bug
/// in either can never propagate into, or suppress, the caller's own error
/// handling in [installGlobalErrorSinks]. That property matters more than
/// any event this could ever record.
void _emitLifecycleError(Object error) {
  try {
    emitDiagEvent(
      DiagEvent.tryCreate(
        seq: _diagSeq++,
        ts: DateTime.now(),
        level: DiagLevel.error,
        category: DiagCategory.lifecycle,
        code: 'lifecycle.error',
        fields: <String, Object>{
          'buildId': kBuildId,
          'errorType': error.runtimeType.toString(),
        },
      ),
    );
  } catch (_) {
    // Fail-open: see installGlobalErrorSinks doc.
  }
}

/// Open a Hive box, tolerating a corrupt/locked box so a bad on-disk file can
/// never prevent the app from launching. On any failure the box is deleted
/// from disk (best-effort) and the caller proceeds on defaults; the notifiers
/// that own these boxes re-open them lazily and re-seed from their own
/// compile-time defaults.
Future<void> _openBoxSafely<T>(String name) async {
  try {
    await Hive.openBox<T>(name);
  } catch (_) {
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {
      // Nothing more we can safely do; fall through to defaults.
    }
  }
}

/// Root widget, wires Riverpod, GoRouter, and the Sovereign Glass theme.
class SKChatApp extends ConsumerWidget {
  const SKChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final density = ref.watch(densityProvider);
    final router = ref.watch(appRouterProvider);

    // Eagerly start the sync service so polling begins immediately.
    ref.watch(skcommsSyncProvider);

    // Eagerly load the local PGP identity from secure storage.
    ref.watch(identityKeyPairProvider);

    // PQC Q5: generate (once) + publish this device's hybrid prekey so DMs go
    // hybrid post-quantum. Best-effort; no-op when no PQ backend is available.
    ref.watch(pqBootstrapProvider);

    return MaterialApp.router(
      title: 'SKChat',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: SovereignTheme.light(density: density),
      darkTheme: SovereignTheme.dark(density: density),
      routerConfig: router,
      // Density sets BASE sizes; the OS text scaler multiplies on top of
      // that (Flutter's default behavior for every Text that doesn't
      // override it, unchanged here). This is the ONLY place OS scaling is
      // touched: it clamps the pathological high end (max 2.0x, matching
      // the golden tests) while leaving the full small-text range alone, so
      // a low-vision user on compact still gets big text and a sharp-eyed
      // user on comfortable still gets roomy text. Never pass
      // TextScaler.noScaling and never read textScaleFactor to "correct"
      // sizes anywhere else; test/font_literal_guard_test.dart enforces it.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 2.0,
        child: DeployFreshnessBanner(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
