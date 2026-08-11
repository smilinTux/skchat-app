import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

/// The standalone contract, named so the boot gate can assert it directly:
/// the standalone runner hosts every [SkworldModule] with a NULL
/// [ShellContext]. A null shell IS the standalone signal (module contract
/// standard section 3.1): the module falls back to its own theme / login /
/// router rather than composing into a shell. There is no shell in this
/// process, by construction.
const ShellContext? kStandaloneShell = null;

/// Hosts a [SkworldModule] under the standalone runner with a minimal nav
/// chrome.
///
/// This is the "own nav chrome" half of the thin runner (card C-2): a bottom
/// [NavigationBar] fed by the module's own [ModuleNav] metadata, with the
/// module body rendered above it. The body is built by calling
/// [SkworldModule.build] with [kStandaloneShell] (null), so the module runs
/// in standalone mode.
///
/// It imports ONLY skcode_client (transitively, via its caller) and
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
      // Standalone mode: hand the module a NULL ShellContext. This is the
      // whole point of the boot gate: the module renders with
      // `shell == null`.
      body: module.build(context, kStandaloneShell),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
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
