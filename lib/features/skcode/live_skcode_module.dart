import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:skcode_client/skcode_client.dart";

import "../../services/audience_token_service.dart";
import "../../services/daemon_config.dart";

/// Builds the mountable skcode module wired to the app's real transport
/// config (card C-3b).
///
/// This is the app-side half of the seam card C-3b introduced:
/// [SkcodeModule] takes [SkcodeModule.origin] and
/// [SkcodeModule.onAuthRejected] through its constructor because nothing in
/// `ShellContext` / `AuthContext` says where skcode-hostd lives, and
/// [AuthContext.token] alone cannot express "that token was rejected, get me
/// a fresh one." This factory supplies both, mirroring
/// `buildLiveSkchatModule()` (`lib/features/chats/live_chats_surface.dart`):
///
///   * [SkcodeModule.origin] - the runtime-configurable daemon URL
///     (`daemonUrlProvider`), the same origin `skcodeApiClientProvider`
///     already resolves (`lib/services/skcode/skcode_providers.dart`).
///   * [SkcodeModule.onAuthRejected] - both halves of the fix for the
///     "cached-but-stale" trap (mirrors `SkcodeSessionStoreNotifier` in
///     `lib/services/skcode/skcode_providers.dart`): drops
///     `AudienceTokenService`'s OWN cache entry for `kSkcodeAudience` (what a
///     mounted module's `AuthContext.token()` actually reads through its
///     `tokenMinter`, see `module_host_screen.dart`'s
///     `audienceTokens.mint` pattern, which bypasses the Riverpod
///     FutureProvider entirely) AND invalidates
///     `audienceTokenForAudienceProvider(kSkcodeAudience)` for any other
///     watcher (e.g. the legacy `SkcodePane`). Only doing the second half
///     would leave a mounted `AuthContext.token()` call replaying the exact
///     stale token that was just rejected.
///
/// Call it from a `WidgetRef`-bearing `build` (a `ConsumerWidget` /
/// `ConsumerState`), not once in `initState`, so it stays reactive to a
/// runtime daemon-URL change the same way `skcodeApiClientProvider` does.
///
/// Not wired into a route yet: [SkcodeModule.build] itself is still the C-2
/// skeleton (no transcript UI consumes [SkcodeModule.origin] /
/// [SkcodeModule.onAuthRejected] yet), and mounting skcode into the shell is
/// card C-10's registry flip, deliberately last. This factory exists now so
/// C-4 and C-10 do not have to invent the injection seam themselves.
SkcodeModule buildLiveSkcodeModule(WidgetRef ref) {
  final origin = ref.watch(daemonUrlProvider);
  return SkcodeModule(
    origin: origin,
    onAuthRejected: () {
      ref.read(audienceTokenServiceProvider).invalidate(kSkcodeAudience);
      ref.invalidate(audienceTokenForAudienceProvider(kSkcodeAudience));
    },
  );
}
