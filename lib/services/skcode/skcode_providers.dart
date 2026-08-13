import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:skcode_client/skcode_client.dart";

import "../audience_token_service.dart";
import "../daemon_config.dart";

/// The Riverpod wiring for the skcode transport layer (card C-3). As of card
/// C-3b, [SkcodeApiClient] / [SkcodeSessionStore] / [SkcodeSessionsListStore]
/// / [SkcodeWsTransport] / [kSkcodeAudience] / [skcodeWsUri] all live in
/// `package:skcode_client` (pure, no Riverpod, no host services). What stays
/// HERE is exactly the host wiring the package's import gate forbids it from
/// holding itself: binding those pure classes to `daemonUrlProvider` /
/// `daemonWsUrlProvider` and to the real [AudienceTokenService], and
/// reacting to a rejected token by invalidating the right Riverpod future.
/// See `lib/features/skcode/live_skcode_module.dart` for the composition-root
/// factory (`buildLiveSkcodeModule`) that hands `SkcodeModule` its `origin`
/// and `onAuthRejected`, mirroring this same host/package split one level up.

/// [SkcodeApiClient] bound to the runtime-configurable daemon URL (same
/// origin as every other daemon-facing client; the `/skcode/*` proxy lives
/// on that same host, see `package:skcode_client`'s `skcode_api_client.dart`
/// doc comment).
final skcodeApiClientProvider = Provider<SkcodeApiClient>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return SkcodeApiClient(baseUrl: baseUrl);
});

/// The WS transport factory `SkcodeSessionStoreNotifier` connects through.
/// Overridable in tests (a `ProviderContainer` override swaps in a fake
/// transport with no real socket); production keeps the default
/// `SkcodeWsTransport.connect`.
final skcodeWsTransportFactoryProvider =
    Provider<SkcodeWsTransport Function(Uri uri)>((ref) {
      return SkcodeWsTransport.connect;
    });

/// One [SkcodeSessionStore] per open session id, wired to the app's real
/// [SkcodeApiClient], [AudienceTokenService], and [daemonWsUrlProvider].
///
/// Kicks the store off (`start()`) on first watch and tears it down
/// (`dispose()`) when the last watcher goes away, so a session's WS
/// connection lives exactly as long as something is watching it (a
/// transcript screen, C-4).
class SkcodeSessionStoreNotifier
    extends FamilyNotifier<SkcodeSessionState, String> {
  SkcodeSessionStore? _store;
  StreamSubscription<SkcodeSessionState>? _sub;

  @override
  SkcodeSessionState build(String sid) {
    final apiClient = ref.watch(skcodeApiClientProvider);
    final tokenService = ref.watch(audienceTokenServiceProvider);
    final wsBaseUrl = ref.watch(daemonWsUrlProvider);
    final connectTransport = ref.watch(skcodeWsTransportFactoryProvider);

    final store = SkcodeSessionStore(
      sid: sid,
      apiClient: apiClient,
      mintToken: () => tokenService.mint(kSkcodeAudience),
      onAuthRejected: () {
        // Both halves of the fix for the "cached-but-stale" trap (spec 4.2):
        // drop the service's own cache entry AND tell Riverpod's
        // FutureProvider.family to actually refetch on its next watch,
        // rather than replaying the stale future it already resolved.
        tokenService.invalidate(kSkcodeAudience);
        ref.invalidate(audienceTokenForAudienceProvider(kSkcodeAudience));
      },
      connectTransport: connectTransport,
      buildWsUri: (sid, token) => skcodeWsUri(wsBaseUrl, sid, token),
    );
    _store = store;
    _sub = store.states.listen((s) => state = s);

    ref.onDispose(() {
      _sub?.cancel();
      store.dispose();
    });

    // build() must return synchronously; kick the async connect off right
    // after without blocking it.
    scheduleMicrotask(store.start);

    return store.state;
  }

  /// Exposed for a host widget that wants the underlying store directly
  /// (e.g. to await `store.states` in a test, or call `dispose()` early).
  SkcodeSessionStore? get debugStore => _store;
}

final skcodeSessionStoreProvider =
    NotifierProviderFamily<SkcodeSessionStoreNotifier, SkcodeSessionState, String>(
      SkcodeSessionStoreNotifier.new,
    );

/// The polled sessions list (spec 4.3: `GET /sessions`, 15s while the rail
/// is visible). A rail widget calls `startPolling()`/`stopPolling()` as it
/// mounts/unmounts; this notifier does not poll on its own just because
/// something is watching the provider, since the poll is opt-in per the
/// spec's "while the rail is visible" qualifier.
class SkcodeSessionsListNotifier
    extends Notifier<AsyncValue<List<SkcodeSessionSummary>>> {
  SkcodeSessionsListStore? _store;
  StreamSubscription<SkcodeSessionsPoll>? _sub;

  @override
  AsyncValue<List<SkcodeSessionSummary>> build() {
    final apiClient = ref.watch(skcodeApiClientProvider);
    final tokenService = ref.watch(audienceTokenServiceProvider);

    final store = SkcodeSessionsListStore(
      apiClient: apiClient,
      mintToken: () => tokenService.mint(kSkcodeAudience),
    );
    _store = store;
    // This provider only serves `SkcodeSessionRouteScreen`'s "find the
    // matching row by sid" lookup (a cold deep link resolving its own
    // interactive/repo metadata), not any rendering of the rail's honest
    // unauthorized/unreachable/empty states (card C-19) -- those live
    // entirely inside `SkcodeSessionsRail`'s own store instance in
    // `package:skcode_client`. So this unwraps straight to the last known
    // list and drops [SkcodeSessionsPoll.failureKind] on the floor
    // deliberately, same as it dropped a failed poll on the floor before
    // C-19 (a failed poll here was already silently skipped, leaving
    // `state` on its last emitted value).
    _sub = store.sessions.listen((poll) => state = AsyncValue.data(poll.sessions));

    ref.onDispose(() {
      _sub?.cancel();
      store.dispose();
    });

    return const AsyncValue.loading();
  }

  void startPolling() => _store?.startPolling();
  void stopPolling() => _store?.stopPolling();
}

final skcodeSessionsListProvider = NotifierProvider<
  SkcodeSessionsListNotifier,
  AsyncValue<List<SkcodeSessionSummary>>
>(SkcodeSessionsListNotifier.new);
