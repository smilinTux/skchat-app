import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'skcode_api_client.dart';
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
/// SCOPE: card C-2 built the mount/standalone-boot skeleton; card C-3b
/// moved the transport layer ([SkcodeApiClient], [SkcodeSessionStore],
/// [SkcodeSessionsListStore], [SkcodeWsTransport]) into this package as
/// siblings and added [origin] / [onAuthRejected] as the injection seam;
/// card C-4 wired that transport into a real render layer (the sessions
/// rail, the activity taxonomy, the transcript, the raw rail) inside
/// [SkcodeSurface]. The existing iframe at `lib/features/skcode/` stays the
/// LIVE `/code` surface until the registry flip (card C-10, deliberately
/// last); this module is fully built but not yet the one the app actually
/// mounts.
class SkcodeModule implements SkworldModule {
  const SkcodeModule({this.origin, this.onAuthRejected, this.apiClient});

  /// Where skcode-hostd lives (card C-3b): the one thing missing from
  /// [ShellContext] / [AuthContext] that pushed the transport layer into the
  /// host app in card C-3. The mounted host passes its runtime-configurable
  /// daemon URL (`buildLiveSkcodeModule()`,
  /// `lib/features/skcode/live_skcode_module.dart`); the standalone runner
  /// passes its own. Consumed by [SkcodeSurface] (card C-4) to build its
  /// [SkcodeApiClient] and to construct each session's WS URI.
  final String? origin;

  /// Invoked on an HTTP 401 or WS close 1008 from the transport layer (card
  /// C-3b: `SkcodeSessionStore`'s own `onAuthRejected`, one level down). The
  /// mounted host implements this as
  /// `ref.invalidate(audienceTokenForAudienceProvider(kSkcodeAudience))`, so
  /// the next [AuthContext.token] call genuinely re-mints instead of
  /// replaying a cached, rejected token. [AuthContext.token] alone cannot
  /// express "that token was rejected, get me a fresh one"; this callback is
  /// the missing half. Forwarded to every [SkcodeSessionStore] the rendered
  /// sessions rail / session screen own (card C-4).
  final VoidCallback? onAuthRejected;

  /// Test seam only (see [SkcodeSurface.apiClient]): lets a widget test
  /// inject a fake [SkcodeApiClient] so `build()` never opens a real socket.
  /// Production always constructs with this omitted.
  final SkcodeApiClient? apiClient;

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
    // path (module contract standard section 3.1). [origin] and
    // [onAuthRejected] are forwarded straight through (card C-4): they are
    // consumed by the session stores [SkcodeSurface] now owns.
    return SkcodeSurface(
      shell: shell,
      origin: origin,
      onAuthRejected: onAuthRejected,
      apiClient: apiClient,
    );
  }
}
