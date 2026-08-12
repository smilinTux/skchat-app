import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skcode_client/skcode_client.dart';

import '../../services/audience_token_service.dart';
import '../../services/identity_service.dart';
import '../shell/app_shell_context.dart';
import 'live_skcode_module.dart';

/// Host route that MOUNTS the live `skcode_client` [SkworldModule] inside the
/// app shell (card C-10, spec section 4.1: "Registry flip in
/// `module_registry.dart`: skcode grade 'A', route `/code` now mounts the
/// native module through the same pattern as `module_host_screen.dart`").
///
/// This mirrors `SkchatModuleHostScreen` (`lib/features/shell/
/// module_host_screen.dart`) exactly, one level over for skcode: it builds
/// the live module via [buildLiveSkcodeModule] (card C-3b's factory) and
/// renders it through `module.build(context, shell)` with a concrete
/// [AppShellContext]. That context bridges three real shell surfaces into
/// the pure module:
///
///   * THEME - `Theme.of(context)`, the live Sovereign Glass ThemeData.
///   * BUS   - an [AppShellBus] whose `navigate` maps `skworld://skcode/...`
///     deep links onto the app GoRouter via `context.go` (this screen is
///     mounted DIRECTLY at `/code` inside the shell's `ShellRoute`, not
///     pushed, so `context.go` is the correct navigation call here, same as
///     every other primary-tab route).
///   * AUTH  - an [AppAuthContext] scoped to the `skcode` audience (card
///     C-10's generalization of [AppAuthContext] to take an explicit
///     audience/scopes pair rather than the skchat-only defaults), carrying
///     [kSkcodeInjectScope] and [kSkcodeDispatchScope] the same way the
///     package's own inject-composer / New-Session / cancel gates already
///     expect to read them off `AuthContext.hasScope`.
///
/// Unlike `SkchatModuleHostScreen`'s `late final _module` (built once),
/// [buildLiveSkcodeModule] is called from [build] on every rebuild per its
/// own doc comment ("Call it from a WidgetRef-bearing build ... not once in
/// initState, so it stays reactive to a runtime daemon-URL change"):
/// `SkcodeModule` is an immutable data-plus-callbacks holder, so a fresh
/// instance each build is cheap and the underlying `SkcodeSurface` state
/// (session store, api client) survives rebuilds normally through Flutter's
/// element diffing.
///
/// A small "open classic" affordance floats above the mounted module and
/// pushes `/code/legacy` (the iframe pane, still live per this card's own
/// parity finding: see the C-10 handoff notes for exactly which iframe
/// capability the native pane does not yet reproduce).
class SkcodeModuleHostScreen extends ConsumerStatefulWidget {
  const SkcodeModuleHostScreen({super.key});

  @override
  ConsumerState<SkcodeModuleHostScreen> createState() =>
      _SkcodeModuleHostScreenState();
}

class _SkcodeModuleHostScreenState
    extends ConsumerState<SkcodeModuleHostScreen> {
  /// The concrete bus. Built here (not in [build]) so its broadcast stream is
  /// created once and disposed with the route, matching
  /// `SkchatModuleHostScreen`'s own reasoning.
  late final AppShellBus _bus;

  @override
  void initState() {
    super.initState();
    _bus = AppShellBus(
      // A mapped deep link drives the app GoRouter.
      onNavigate: (location) {
        if (mounted) context.go(location);
      },
      // An unmapped deep link degrades to a SnackBar instead of crashing.
      onUnhandled: (deeplink) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No route for $deeplink')),
        );
      },
    );
  }

  @override
  void dispose() {
    _bus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The device PGP fingerprint stands in as the current agent subject.
    final identity = ref.watch(identityKeyPairProvider).valueOrNull;

    // The audience-token minter rides the app's authenticated client. It
    // returns null (module runs tokenless) while the backend mint flag is
    // off, matching every other mounted module's degrade path.
    final audienceTokens = ref.watch(audienceTokenServiceProvider);

    final shell = AppShellContext(
      theme: Theme.of(context),
      bus: _bus,
      auth: AppAuthContext(
        audience: kSkcodeAudience,
        scopes: const {kSkcodeInjectScope, kSkcodeDispatchScope},
        subjectFqid: identity?.fingerprint,
        tokenMinter: audienceTokens.mint,
      ),
    );

    final module = buildLiveSkcodeModule(ref);
    final moduleWidget = module.build(context, shell);

    return Stack(
      children: [
        moduleWidget,
        Positioned(
          right: 12,
          bottom: 12,
          child: SafeArea(
            child: Material(
              key: const Key('skcodeOpenClassicButton'),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              shape: const StadiumBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => context.go('/code/legacy'),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.open_in_browser_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Open classic',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
