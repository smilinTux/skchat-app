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
/// SCOPE (card C-2, extended by C-3b): [build] itself is still a skeleton
/// that only proves the mount and the standalone boot. No transcript UI
/// lives here yet (that is card C-4); the existing iframe at
/// `lib/features/skcode/` stays the live `/code` surface until the registry
/// flip. What C-3b DID add is the transport layer itself
/// ([SkcodeApiClient], [SkcodeSessionStore], [SkcodeSessionsListStore],
/// [SkcodeWsTransport]) as siblings in this package, plus [origin] and
/// [onAuthRejected] on this constructor as the seam C-4 will use to wire
/// them into a real body.
class SkcodeModule implements SkworldModule {
  const SkcodeModule({this.origin, this.onAuthRejected});

  /// Where skcode-hostd lives (card C-3b): the one thing missing from
  /// [ShellContext] / [AuthContext] that pushed the transport layer into the
  /// host app in card C-3. The mounted host passes its runtime-configurable
  /// daemon URL (`buildLiveSkcodeModule()`,
  /// `lib/features/skcode/live_skcode_module.dart`); the standalone runner
  /// passes its own. Not consumed by this skeleton's [build] yet (that is
  /// card C-4, which wires it into [SkcodeApiClient] / [SkcodeSessionStore]);
  /// injecting it here now means C-4 never has to touch this constructor's
  /// shape.
  final String? origin;

  /// Invoked on an HTTP 401 or WS close 1008 from the transport layer (card
  /// C-3b: `SkcodeSessionStore`'s own `onAuthRejected`, one level down). The
  /// mounted host implements this as
  /// `ref.invalidate(audienceTokenForAudienceProvider(kSkcodeAudience))`, so
  /// the next [AuthContext.token] call genuinely re-mints instead of
  /// replaying a cached, rejected token. [AuthContext.token] alone cannot
  /// express "that token was rejected, get me a fresh one"; this callback is
  /// the missing half. Not called by this skeleton's [build] yet (card C-4
  /// wires the real session store that calls it).
  final VoidCallback? onAuthRejected;

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
