import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/theme/theme.dart';
import 'core/router/app_router.dart';
import 'core/providers/theme_provider.dart';
import 'data/hive_adapters.dart';
import 'services/skcomms_sync.dart';
import 'services/identity_service.dart';
import 'services/pq_prekey_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the host console quiet outside debug builds: no debugPrint spew and no
  // framework error dumps written out to the host's stdout/stderr. Debug builds
  // (`flutter run`/`--debug`) stay fully verbose so failures are still visible.
  if (!kDebugMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
    FlutterError.onError = (FlutterErrorDetails details) {
      // Swallow, a sovereign release build must not write to the host console.
    };
  }

  // Initialize Hive for local persistence.
  await Hive.initFlutter();
  Hive.registerAdapter(ChatMessageAdapter());
  Hive.registerAdapter(ConversationAdapter());

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
    const ProviderScope(child: SKChatApp()),
  );
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
      theme: SovereignTheme.light(),
      darkTheme: SovereignTheme.dark(),
      routerConfig: router,
    );
  }
}
