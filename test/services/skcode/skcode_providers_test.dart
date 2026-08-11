import "dart:async";
import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/audience_token_service.dart";
import "package:skchat/services/daemon_config.dart";
import "package:skchat/services/skcode/skcode_api_client.dart";
import "package:skchat/services/skcode/skcode_providers.dart";
import "package:skchat/services/skcode/skcode_session_store.dart";
import "package:skchat/services/skcode/skcode_ws_transport.dart";
import "package:skchat/services/skcomms_client.dart";

class _FakeWsTransport implements SkcodeWsTransport {
  final _controller = StreamController<dynamic>.broadcast();
  int? _closeCode;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }

  void simulateClose(int? code) {
    _closeCode = code;
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

/// Canned adapter for both the audience-token mint endpoint AND the skcode
/// archive-events endpoint, so the WHOLE real provider chain (session store
/// -> AudienceTokenService -> SKCommsClient -> Dio) can be exercised without
/// a network.
class _CannedAdapter implements HttpClientAdapter {
  int mintCalls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains("audience-token")) {
      mintCalls++;
      return ResponseBody.fromString(
        jsonEncode({
          "token": "WIRE-$mintCalls",
          "expires_at": DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    // GET /skcode/api/v1/sessions/{sid}/events
    return ResponseBody.fromString(
      jsonEncode({"sid": "s1", "events": <Map<String, dynamic>>[]}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  group("skcodeWsUri", () {
    test("builds wss://<origin>/skcode/api/v1/sessions/<sid>/stream?token=<wire>",
        () {
      final uri = skcodeWsUri("https://daemon.local", "s-123", "TOK");
      expect(uri.toString(),
          "wss://daemon.local/skcode/api/v1/sessions/s-123/stream?token=TOK");
    });

    test("maps http -> ws and strips a trailing slash", () {
      final uri = skcodeWsUri("http://localhost:9384/", "s1", "T");
      expect(uri.toString(),
          "ws://localhost:9384/skcode/api/v1/sessions/s1/stream?token=T");
    });

    test("encodes the token as a safe query component", () {
      final uri = skcodeWsUri("https://daemon.local", "s1", "a b/c");
      // `Uri.encodeQueryComponent` uses `+` for space (standard
      // application/x-www-form-urlencoded), which a standard query-string
      // decoder (FastAPI/Starlette on the daemon side) decodes back to a
      // literal space identically to `%20`.
      expect(uri.query, "token=a+b%2Fc");
    });
  });

  group("provider wiring end-to-end", () {
    test("skcodeSessionStoreProvider connects through the REAL "
        "AudienceTokenService + SKCommsClient chain, and invalidateToken "
        "both clears the service cache and invalidates the Riverpod future",
        () async {
      final adapter = _CannedAdapter();
      final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = adapter;
      final skcommsClient = SKCommsClient(dio: dio);

      final transports = <_FakeWsTransport>[];

      final container = ProviderContainer(
        overrides: [
          skcommsClientProvider.overrideWithValue(skcommsClient),
          daemonUrlProvider.overrideWith(() => _FixedDaemonUrl("http://localhost:9384")),
          // The default skcodeApiClientProvider builds its OWN internal Dio
          // (no adapter override reaches it), so it is pointed at the same
          // canned adapter explicitly here rather than hitting a real socket.
          skcodeApiClientProvider.overrideWithValue(SkcodeApiClient(dio: dio)),
          skcodeWsTransportFactoryProvider.overrideWithValue((uri) {
            final t = _FakeWsTransport();
            transports.add(t);
            return t;
          }),
        ],
      );
      addTearDown(container.dispose);

      final states = <SkcodeSessionState>[];
      final sub = container.listen(
        skcodeSessionStoreProvider("s1"),
        (prev, next) => states.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      // Let the microtask-scheduled start() + archive fetch + WS connect run.
      await pumpEventQueue();

      expect(transports, hasLength(1),
          reason: "the store must have connected through the overridden WS factory");
      expect(container.read(skcodeSessionStoreProvider("s1")).phase,
          SkcodeConnectionPhase.connected);
      expect(adapter.mintCalls, greaterThanOrEqualTo(1));

      // Prime a SEPARATE watcher of `audienceTokenForAudienceProvider` (the
      // stand-in for some other module surface, e.g. `SkcodeSurface` calling
      // `shell.auth.token()`), so it caches its own resolved Future the same
      // way a real widget would.
      final tokenBefore =
          await container.read(audienceTokenForAudienceProvider(kSkcodeAudience).future);
      expect(tokenBefore, isNotNull);

      // Drive a 1008: the notifier's invalidateToken callback must both
      // clear AudienceTokenService's cache AND invalidate the
      // audienceTokenForAudienceProvider family member, so the NEXT mint is
      // a genuine re-fetch (a fresh WIRE-N token), not the same cached one.
      final mintsBeforeClose = adapter.mintCalls;
      transports.single.simulateClose(1008);
      await pumpEventQueue();

      expect(transports, hasLength(2), reason: "the 1008 must trigger exactly one retry connect");
      expect(adapter.mintCalls, greaterThan(mintsBeforeClose),
          reason: "invalidateToken must force a real re-mint, not replay the cache");
      expect(container.read(skcodeSessionStoreProvider("s1")).phase,
          SkcodeConnectionPhase.connected);

      // The OTHER watcher's provider must have actually been invalidated and
      // refetched: a fresh (different) token, not the same cached Future
      // replayed. This is the second half of the fix (`ref.invalidate`),
      // proven independently of the store's own direct `tokenService.mint()`
      // call.
      final tokenAfter =
          await container.read(audienceTokenForAudienceProvider(kSkcodeAudience).future);
      expect(tokenAfter, isNot(tokenBefore),
          reason: "ref.invalidate(audienceTokenForAudienceProvider(...)) must force a "
              "real refetch for every watcher, not just the store's own direct mint() call");
    });
  });
}

/// Overrides `daemonUrlProvider`'s Notifier build to a fixed value without
/// touching Hive (the real notifier's `_loadPersisted` opens a Hive box,
/// which is not initialized in a plain `flutter_test` unit test).
class _FixedDaemonUrl extends DaemonConfigNotifier {
  _FixedDaemonUrl(this._url);
  final String _url;

  @override
  String build() => _url;
}
