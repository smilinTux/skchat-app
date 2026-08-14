import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skcode_client/skcode_client.dart';

import '../../services/audience_token_service.dart';
import '../../services/daemon_config.dart';
import '../../services/identity_service.dart';
import '../../services/skcode/skcode_providers.dart';
import '../shell/app_shell_context.dart';

/// The two skcode deep-link TARGETS (card C-10, the added requirement beyond
/// the original card): real screens for `AppRoutes.codeSession`
/// (`/code/s/:sid`) and `AppRoutes.codeDigest` (`/code/digest`).
///
/// Card C-9 built `mapSkcodeDeeplink` against these route CONSTANTS, and its
/// own routing tests pass by building a throwaway test router with spy
/// screens — so a `skworld://skcode/session/<sid>` / `skworld://skcode/digest`
/// link resolved to a STRING that no `GoRoute` actually served in the running
/// app. This file is what makes that resolution land on a real screen, so a
/// tapped watchdog-digest line is clickable end to end, not just provably
/// mapped in a unit test.
///
/// Both screens live in the HOST app (not `package:skcode_client`) for the
/// same reason `skcode_providers.dart` and `live_skcode_module.dart` do:
/// they need Riverpod, `daemonUrlProvider`, and `AudienceTokenService`, all
/// of which the package's import gate forbids it from touching itself.

/// `/code/s/:sid`: a single session pushed full screen when reached directly
/// (a deep link, not a tap on an already-fetched [SkcodeSessionsRail] row).
///
/// The rail already knows a tapped session's own `mode` / `repo`
/// (`SkcodeSessionSummary`) before it ever pushes `SkcodeSessionScreen`, so
/// it can thread `interactive` / `repo` through directly
/// (`SkcodeSessionsRail._openSession`). A cold deep link has no such summary
/// in hand, so this screen starts the shared [skcodeSessionsListProvider]
/// polling (idempotent: a no-op if the rail is already polling it elsewhere)
/// and looks the matching row up by [sid] once a poll resolves, defaulting
/// `interactive: false` / `repo: ''` (the screen's own fail-closed default)
/// until then. This means the inject composer may briefly not render on a
/// fresh cold deep link into an interactive session; it appears as soon as
/// the sessions list poll returns the matching row. That is a real, small
/// gap against opening the same session from the rail, noted rather than
/// hidden.
class SkcodeSessionRouteScreen extends ConsumerStatefulWidget {
  const SkcodeSessionRouteScreen({super.key, required this.sid});

  final String sid;

  @override
  ConsumerState<SkcodeSessionRouteScreen> createState() =>
      _SkcodeSessionRouteScreenState();
}

class _SkcodeSessionRouteScreenState
    extends ConsumerState<SkcodeSessionRouteScreen> {
  @override
  void initState() {
    super.initState();
    // Kick off the shared sessions-list poll so this route's session
    // metadata (interactive / repo) can resolve even when the rail was
    // never mounted first in this app session (a cold deep link straight to
    // `/code/s/:sid`). `startPolling` is idempotent, so this is a safe no-op
    // when the rail already started it.
    Future.microtask(
      () => ref.read(skcodeSessionsListProvider.notifier).startPolling(),
    );
  }

  SkcodeSessionSummary? _findSummary(List<SkcodeSessionSummary> sessions) {
    for (final s in sessions) {
      if (s.sid == widget.sid) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityKeyPairProvider).valueOrNull;
    final audienceTokens = ref.watch(audienceTokenServiceProvider);
    final origin = ref.watch(daemonUrlProvider);
    final apiClient = ref.watch(skcodeApiClientProvider);
    final sessionsList = ref.watch(skcodeSessionsListProvider).asData?.value;
    final summary = sessionsList == null ? null : _findSummary(sessionsList);

    return SkcodeSessionScreen(
      sid: widget.sid,
      apiClient: apiClient,
      origin: origin,
      mintToken: () => audienceTokens.mint(kSkcodeAudience),
      onAuthRejected: () {
        audienceTokens.invalidate(kSkcodeAudience);
        ref.invalidate(audienceTokenForAudienceProvider(kSkcodeAudience));
      },
      auth: AppAuthContext(
        audience: kSkcodeAudience,
        scopes: const {kSkcodeInjectScope, kSkcodeDispatchScope},
        subjectFqid: identity?.fingerprint,
        tokenMinter: audienceTokens.mint,
      ),
      interactive: summary?.mode == 'interactive',
      repo: summary?.repo ?? '',
    );
  }
}

/// `/code/digest`: the artifact pane's Digest tab, reachable directly (the
/// full-screen phone/deep-link target) rather than only as a tab inside the
/// artifact pane's own bottom sheet (`SkcodeSurface._openDigest`).
///
/// Card C-14a made this screen live. Card C-9 built the renderer against a
/// bare, unauthenticated `digestUrl` that no host could ever fill in (the
/// digest artifact is a 0600 owner-only file with no HTTP exposure), so this
/// route rendered "Digest not configured" permanently. skcode-hostd now serves
/// the same artifact at `GET /api/v1/watchdog/digest` on the `skcode.stream`
/// read scope, so the tab needs exactly the three things every other skcode
/// screen in this file already wires: the shared [SkcodeApiClient], a token
/// minter, and the `onAuthRejected` invalidation pair that lets a 401 re-mint
/// once instead of replaying a rejected token.
class SkcodeDigestRouteScreen extends ConsumerWidget {
  const SkcodeDigestRouteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audienceTokens = ref.watch(audienceTokenServiceProvider);
    final apiClient = ref.watch(skcodeApiClientProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Digest')),
      body: SkcodeDigestTab(
        apiClient: apiClient,
        mintToken: () => audienceTokens.mint(kSkcodeAudience),
        onAuthRejected: () {
          audienceTokens.invalidate(kSkcodeAudience);
          ref.invalidate(audienceTokenForAudienceProvider(kSkcodeAudience));
        },
        onOpenLink: (uri) {
          final route = mapSkcodeDeeplink(uri) ?? mapSkchatDeeplink(uri);
          if (route != null) context.go(route);
        },
      ),
    );
  }
}
