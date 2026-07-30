import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/audience_token_service.dart';
import '../../services/identity_service.dart';
import '../chats/live_chats_surface.dart';
import 'app_shell_context.dart';

/// Host route that MOUNTS the live `skchat_ui` [SkworldModule] inside the app.
///
/// This is the concrete proof of the reconciled spec 3.2 mount: it builds
/// [buildLiveSkchatModule] (the real module wired to the app's `chatsProvider`
/// feed) and renders it through `module.build(context, shell)` with a concrete
/// [AppShellContext]. That context bridges three real shell surfaces into the
/// pure module:
///
///   * THEME  - `Theme.of(context)`, the app's live Sovereign Glass ThemeData,
///     so the mounted module renders in the shell's look rather than its own
///     standalone fallback.
///   * BUS    - an [AppShellBus] whose `navigate` maps `skworld://skchat/...`
///     deep links onto the app GoRouter (`context.go`), with a SnackBar
///     fallback for any link that maps to no route.
///   * AUTH   - an [AppAuthContext] scoped to the `skchat` audience, carrying
///     the device identity as its subject (token mint is stubbed, see its
///     TODO).
///
/// It is a top-level (non-shell) route reached via `context.push`, so the
/// system back gesture pops it and it never disturbs the primary Chats tab or
/// the bottom-nav highlight logic. The live native Chats tab is untouched;
/// this route only proves the module mounts and renders live.
class SkchatModuleHostScreen extends ConsumerStatefulWidget {
  const SkchatModuleHostScreen({super.key});

  @override
  ConsumerState<SkchatModuleHostScreen> createState() =>
      _SkchatModuleHostScreenState();
}

class _SkchatModuleHostScreenState
    extends ConsumerState<SkchatModuleHostScreen> {
  /// The live skchat module (wired to `chatsProvider` via its bodyBuilder).
  late final _module = buildLiveSkchatModule();

  /// The concrete bus. Built here (not in [build]) so its broadcast stream is
  /// created once and disposed with the route.
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
    // returns null (module runs tokenless) while the backend mint flag is off.
    final audienceTokens = ref.watch(audienceTokenServiceProvider);

    final shell = AppShellContext(
      theme: Theme.of(context),
      bus: _bus,
      auth: AppAuthContext(
        subjectFqid: identity?.fingerprint,
        tokenMinter: audienceTokens.mint,
      ),
    );

    // The whole point: render the LIVE module with a NON-NULL shell context.
    return _module.build(context, shell);
  }
}
