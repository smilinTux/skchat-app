import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../audience_token_service.dart";
import "../daemon_config.dart";
import "skcode_api_client.dart";
import "skcode_session_store.dart";
import "skcode_sessions_list_store.dart";
import "skcode_ws_transport.dart";

/// The audience [SkcodeSessionStore] / [SkcodeSessionsListStore] mint tokens
/// for. Matches the manifest `auth.audience` for the skcode module (spec
/// 4.2/13).
const kSkcodeAudience = "skcode";

/// [SkcodeApiClient] bound to the runtime-configurable daemon URL (same
/// origin as every other daemon-facing client; the `/skcode/*` proxy lives
/// on that same host, see `skcode_api_client.dart`).
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

/// `wss://<origin>/skcode/api/v1/sessions/<sid>/stream?token=<wire>`
/// (matches `skchat/src/skchat/webui.py::_skcode_ws_url`'s browser-facing
/// contract exactly). The token stays in the query string HERE and ONLY
/// here — see `skcode_api_client.dart`'s doc comment for why HTTP never
/// carries it this way.
///
/// [baseUrl] is normally already ws(s):// (production passes
/// `ref.watch(daemonWsUrlProvider)`, which has already done the http(s) ->
/// ws(s) mapping), but an http(s):// base is converted here too so this
/// function is correct on its own regardless of which base a caller (or a
/// test) happens to hand it.
Uri skcodeWsUri(String baseUrl, String sid, String token) {
  var base = baseUrl.trim();
  while (base.endsWith("/")) {
    base = base.substring(0, base.length - 1);
  }
  if (base.startsWith("https://")) {
    base = "wss://${base.substring("https://".length)}";
  } else if (base.startsWith("http://")) {
    base = "ws://${base.substring("http://".length)}";
  }
  return Uri.parse(
    "$base/skcode/api/v1/sessions/$sid/stream?token=${Uri.encodeQueryComponent(token)}",
  );
}

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
      invalidateToken: () {
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
  StreamSubscription<List<SkcodeSessionSummary>>? _sub;

  @override
  AsyncValue<List<SkcodeSessionSummary>> build() {
    final apiClient = ref.watch(skcodeApiClientProvider);
    final tokenService = ref.watch(audienceTokenServiceProvider);

    final store = SkcodeSessionsListStore(
      apiClient: apiClient,
      mintToken: () => tokenService.mint(kSkcodeAudience),
    );
    _store = store;
    _sub = store.sessions.listen((list) => state = AsyncValue.data(list));

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
