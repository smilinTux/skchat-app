import 'package:flutter/material.dart';
import 'package:skchat_ui/skchat_ui.dart';

import 'standalone_login.dart';
import 'standalone_scaffold.dart';

/// The standalone skchat app (reconciled spec 3.2 step 3): a thin runner that
/// wraps the [SkchatModule] (skchat_ui) with its own MaterialApp theme, its own
/// login seam, and GlassNavBar chrome, and runs the module in STANDALONE mode
/// (`shell == null`).
///
/// This is what deploys to :8088 until the umbrella cutover. It is deliberately
/// tiny: the whole subapp UI lives in the skchat_ui package, so this runner is
/// only the standalone chrome (theme + login + nav) around it.
///
/// IMPORT BOUNDARY: it imports only skchat_ui (module + theme) and, transitively
/// through the scaffold, skworld_module_api. It never imports the app shell
/// package `package:skchat` (enforced by tool/standalone_import_gate.sh, spec
/// 3.2 step 3 "ZERO shell imports").
class SkchatStandaloneApp extends StatelessWidget {
  const SkchatStandaloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SKChat',
      debugShowCheckedModeBanner: false,
      theme: SovereignTheme.light(),
      darkTheme: SovereignTheme.dark(),
      themeMode: ThemeMode.dark,
      // Its own login seam (no shell to auth against), then the module hosted
      // with a null shell under GlassNavBar chrome.
      home: const StandaloneLoginGate(
        child: StandaloneScaffold(module: SkchatModule()),
      ),
    );
  }
}
