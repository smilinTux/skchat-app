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
        child: StandaloneScaffold(module: SkcodeModule()),
      ),
    );
  }
}
