import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'chats_surface.dart';

/// The skchat subapp as a mountable SKWorld module.
///
/// This is the UI facet of the single subapp contract (reconciled spec 2.3):
/// the concrete `implements SkworldModule` that the signed
/// `skworld.module.json` (spec 3.1) points its `entry.flutter_package` at
/// (`{path: "packages/skchat_ui", package: "skchat_ui"}`). Its metadata mirrors
/// the manifest's `nav` block exactly: id `skchat`, icon chat, order 20, label
/// "Chats", deep-link authority `skworld://skchat/`.
///
/// It MUST render in both modes (spec 3.2 step 1 nullability rule):
///   * mounted   (`shell != null`): compose into the shell,
///   * standalone (`shell == null`): run under its own runner
///     (`apps/skchat_standalone`, a later increment), with no shell surfaces.
/// [build] handles both by handing the nullable [ShellContext] straight to
/// [ChatsSurface].
class SkchatModule implements SkworldModule {
  const SkchatModule();

  @override
  String get id => 'skchat';

  @override
  ModuleNav get nav => const ModuleNav(
        label: 'Chats',
        icon: Icons.chat,
        order: 20,
        deeplinkPrefix: 'skworld://skchat/',
      );

  @override
  Widget build(BuildContext context, ShellContext? shell) {
    // Passing the nullable shell through is the whole standalone signal: a null
    // shell drives the standalone path, a non-null shell the mounted path.
    return ChatsSurface(shell: shell);
  }
}
