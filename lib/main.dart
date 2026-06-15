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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the host console quiet outside debug builds: no debugPrint spew and no
  // framework error dumps written out to the host's stdout/stderr. Debug builds
  // (`flutter run`/`--debug`) stay fully verbose so failures are still visible.
  if (!kDebugMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
    FlutterError.onError = (FlutterErrorDetails details) {
      // Swallow — a sovereign release build must not write to the host console.
    };
  }

  // Initialize Hive for local persistence.
  await Hive.initFlutter();
  Hive.registerAdapter(ChatMessageAdapter());
  Hive.registerAdapter(ConversationAdapter());

  // Full-screen OLED experience — hide system UI chrome.
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

/// Root widget — wires Riverpod, GoRouter, and the Sovereign Glass theme.
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
