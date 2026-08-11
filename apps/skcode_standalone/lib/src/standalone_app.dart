import 'package:flutter/material.dart';
import 'package:skcode_client/skcode_client.dart';

import 'standalone_login.dart';
import 'standalone_scaffold.dart';

/// The standalone skcode app (card C-2, spec section 4.1): a thin runner that
/// wraps the [SkcodeModule] (skcode_client) with its own MaterialApp theme,
/// its own login seam, and a minimal nav chrome, and runs the module in
/// STANDALONE mode (`shell == null`).
///
/// This is deliberately tiny: the whole subapp UI lives in the skcode_client
/// package, so this runner is only the standalone chrome (theme + login +
/// nav) around it. Mirrors `apps/skchat_standalone/lib/src/standalone_app.dart`.
///
/// IMPORT BOUNDARY: it imports only skcode_client (module) and, transitively
/// through the scaffold, skworld_module_api. It never imports the app shell
/// package `package:skchat` (enforced by tool/standalone_import_gate.sh,
/// "ZERO shell imports").
class SkcodeStandaloneApp extends StatelessWidget {
  const SkcodeStandaloneApp({super.key});

  /// The standalone runner's own default hostd origin (card C-3b, spec
  /// section 4.1: "standalone passes its own"). There is no shell here to
  /// supply a runtime-configurable daemon URL the way the mounted host's
  /// `buildLiveSkcodeModule()` does, so this is a fixed default matching the
  /// transport layer's own fallback (`SkcodeApiClient`'s default `baseUrl`).
  static const _standaloneOrigin = 'http://localhost:9384';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SKCode',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      themeMode: ThemeMode.dark,
      // Its own login seam (no shell to auth against), then the module hosted
      // with a null shell under the standalone nav chrome.
      home: const StandaloneLoginGate(
        child: StandaloneScaffold(
          module: SkcodeModule(
            origin: _standaloneOrigin,
            // No host, no cached audience token to invalidate: a no-op,
            // never called until C-4 wires a real session store here.
            onAuthRejected: _standaloneNoAuthRejected,
          ),
        ),
      ),
    );
  }
}

/// A top-level function (not a closure) so `onAuthRejected:` above stays a
/// compile-time constant and [SkcodeStandaloneApp]'s widget tree stays
/// `const` all the way down.
void _standaloneNoAuthRejected() {}
