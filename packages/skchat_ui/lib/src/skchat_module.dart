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
///
/// LIVE DATA (spec 3.2): the real conversation list lives in the app's
/// `chatsProvider` (Riverpod + Hive + skcomms_client), which cannot cross the
/// import gate into this pure package. So the module exposes a [bodyBuilder]
/// injection seam: the app constructs `SkchatModule(bodyBuilder: ...)` and
/// returns a ConsumerWidget that watches `chatsProvider` and feeds
/// [ChatsSurface] a live `List<Conversation>`. Because that widget is a
/// ConsumerWidget on the app side, every provider change rebuilds it and
/// re-injects a fresh list, so a plain one-shot list is enough for a live feed
/// (the reactivity lives in the app's watcher, not the package). When
/// [bodyBuilder] is null (standalone, or an unwired mount) the module falls back
/// to [ChatsSurface] with its representative sample, so both modes still render.
class SkchatModule implements SkworldModule {
  const SkchatModule({this.bodyBuilder});

  /// App-provided body for the mounted/standalone surface. The app passes a
  /// builder returning a Riverpod adapter wired to the real conversation feed
  /// (see `lib/features/chats/live_chats_surface.dart`). Null falls back to the
  /// sample-backed [ChatsSurface] so the package stays runnable on its own.
  final Widget Function(BuildContext context, ShellContext? shell)? bodyBuilder;

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
    // When the app injected a [bodyBuilder], render the LIVE feed it wires;
    // otherwise fall back to the sample-backed surface (standalone / unwired).
    final builder = bodyBuilder;
    if (builder != null) return builder(context, shell);
    return ChatsSurface(shell: shell);
  }
}
