import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:skchat_ui/skchat_ui.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

/// The standalone contract, named so the boot gate can assert it directly:
/// the standalone runner hosts every [SkworldModule] with a NULL
/// [ShellContext]. A null shell IS the standalone signal (reconciled spec 3.2
/// step 1): the module falls back to its own theme / login / router rather than
/// composing into a shell. There is no shell in this process, by construction.
const ShellContext? kStandaloneShell = null;

/// Hosts a [SkworldModule] under the standalone runner with GlassNavBar chrome.
///
/// This is the "GlassNavBar chrome" half of the thin runner (spec 3.2 step 3):
/// a frosted-glass bottom [NavigationBar] fed by the module's own
/// [ModuleNav] metadata, with the module body rendered above it. The body is
/// built by calling [SkworldModule.build] with [kStandaloneShell] (null), so
/// the module runs in standalone mode.
///
/// It imports ONLY skchat_ui (for the Sovereign Glass theme tokens) and
/// skworld_module_api (the contract). It never imports the app shell package
/// `package:skchat` (enforced by tool/standalone_import_gate.sh).
class StandaloneScaffold extends StatelessWidget {
  const StandaloneScaffold({super.key, required this.module});

  /// The subapp to host. Standalone builds it with a null shell.
  final SkworldModule module;

  @override
  Widget build(BuildContext context) {
    final nav = module.nav;
    return Scaffold(
      extendBody: true,
      // Standalone mode: hand the module a NULL ShellContext. This is the
      // whole point of the boot gate (spec 3.2 step 4): the module renders
      // with `shell == null`.
      body: module.build(context, kStandaloneShell),
      bottomNavigationBar: _GlassNavBar(
        destinations: [
          NavigationDestination(
            icon: Icon(nav.icon),
            label: nav.label,
          ),
          // A parked "Me" destination keeps the standalone chrome honest as a
          // multi-destination nav; the standalone identity/profile surface
          // lands with the standalone login follow-up.
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Me',
          ),
        ],
      ),
    );
  }
}

/// A frosted-glass wrapper around a Material 3 [NavigationBar], styled to the
/// Sovereign Glass tokens (spec 3.2 step 3 "GlassNavBar chrome"). Kept local to
/// the standalone runner so the chrome never leaks a dependency on the app
/// shell.
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({required this.destinations});

  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: const BoxDecoration(
            color: SovereignColors.surfaceGlass,
            border: Border(
              top: BorderSide(
                color: SovereignColors.surfaceGlassBorder,
                width: 1,
              ),
            ),
          ),
          child: NavigationBar(
            backgroundColor: Colors.transparent,
            // Only the skchat destination is live in this thin runner; the
            // parked "Me" tab is a placeholder for the standalone identity
            // surface (login follow-up), so selection stays on index 0.
            selectedIndex: 0,
            destinations: destinations,
          ),
        ),
      ),
    );
  }
}
