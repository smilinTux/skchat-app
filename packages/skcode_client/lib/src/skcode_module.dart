import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'skcode_surface.dart';

/// The skcode subapp as a mountable SKWorld module (card C-2, spec section
/// 4.1: "Where the code lives").
///
/// This is the UI facet of the single subapp contract: the concrete
/// `implements SkworldModule` that the signed `skworld.module.json` will
/// point its `entry.flutter_package` at once the registry flip (card C-10,
/// deliberately last) lands. Its metadata mirrors the manifest's `nav` block
/// and the existing Grade B `ModuleManifest` entry in
/// `lib/core/modules/module_registry.dart` (untouched by this card): id
/// `skcode`, icon terminal, order 15, label "Code", deep-link authority
/// `skworld://skcode/`.
///
/// It MUST render in both modes (module contract standard section 3.1, the
/// standalone-nullability rule):
///   * mounted    (`shell != null`): compose into the shell, using the
///     shell's theme, bus, and AuthContext.
///   * standalone (`shell == null`): run under its own runner
///     (`apps/skcode_standalone`), with its own capauth login and no shell
///     surfaces.
/// [build] handles both by handing the nullable [ShellContext] straight to
/// [SkcodeSurface].
///
/// SCOPE (card C-2): this is a skeleton that proves the mount and the
/// standalone boot. No transcript, session, or WS code lives here yet (that
/// is card C-3 and C-4); the existing iframe at `lib/features/skcode/` stays
/// the live `/code` surface until the registry flip.
class SkcodeModule implements SkworldModule {
  const SkcodeModule();

  @override
  String get id => 'skcode';

  @override
  ModuleNav get nav => const ModuleNav(
        label: 'Code',
        icon: Icons.terminal,
        order: 15,
        deeplinkPrefix: 'skworld://skcode/',
      );

  @override
  Widget build(BuildContext context, ShellContext? shell) {
    // Passing the nullable shell through is the whole standalone signal: a
    // null shell drives the standalone path, a non-null shell the mounted
    // path (module contract standard section 3.1).
    return SkcodeSurface(shell: shell);
  }
}
