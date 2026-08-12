import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/skcode/live_skcode_module.dart";
import "package:skchat/services/audience_token_service.dart";
import "package:skchat/services/daemon_config.dart";
import "package:skchat/services/skcomms_client.dart";
import "package:skcode_client/skcode_client.dart";

/// Canned adapter for the audience-token mint endpoint only, so
/// [buildLiveSkcodeModule]'s `onAuthRejected` wiring can be exercised through
/// the REAL `AudienceTokenService` + `SKCommsClient` chain, mirroring
/// `test/services/skcode/skcode_providers_test.dart`'s "provider wiring
/// end-to-end" style.
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
}

/// Overrides `daemonUrlProvider`'s Notifier build to a fixed value without
/// touching Hive (the real notifier's `_loadPersisted` opens a Hive box,
/// which is not initialized in a plain `flutter_test` widget test).
class _FixedDaemonUrl extends DaemonConfigNotifier {
  _FixedDaemonUrl(this._url);
  final String _url;

  @override
  String build() => _url;
}

void main() {
  testWidgets(
      "buildLiveSkcodeModule injects origin from daemonUrlProvider",
      (tester) async {
    late SkcodeModule module;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          daemonUrlProvider
              .overrideWith(() => _FixedDaemonUrl("https://daemon.example")),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              module = buildLiveSkcodeModule(ref);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(module.origin, "https://daemon.example");
  });

  testWidgets(
      "buildLiveSkcodeModule's onAuthRejected callback fires and forces a "
      "real re-mint (not the cached token replayed), proving the C-3b "
      "constructor-injection seam actually reaches the Riverpod invalidate "
      "the architecture spec calls for",
      (tester) async {
    final adapter = _CannedAdapter();
    final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
      ..httpClientAdapter = adapter;
    final skcommsClient = SKCommsClient(dio: dio);

    late WidgetRef capturedRef;
    late SkcodeModule module;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          skcommsClientProvider.overrideWithValue(skcommsClient),
          daemonUrlProvider
              .overrideWith(() => _FixedDaemonUrl("http://localhost:9384")),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              module = buildLiveSkcodeModule(ref);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(module.onAuthRejected, isNotNull);

    // `AudienceTokenService.mint()` rides a REAL dio HTTP call (against the
    // canned adapter, no real socket, but still genuine async I/O plumbing).
    // `testWidgets` runs its body inside a fake-async zone that only
    // advances real Timers/Futures on an explicit pump, so real network
    // round trips must run inside `tester.runAsync` or they hang forever
    // (this hung for the full 10-minute default test timeout before this
    // fix; verified by direct repro).
    await tester.runAsync(() async {
      // Prime a cached mint, exactly like a mounted SkcodeSurface calling
      // AuthContext.token() would.
      final tokenBefore = await capturedRef
          .read(audienceTokenForAudienceProvider(kSkcodeAudience).future);
      expect(tokenBefore, isNotNull);
      expect(adapter.mintCalls, 1);

      // Reading the SAME provider again without invalidation replays the
      // cached Future: no new mint call, same token.
      final tokenStillCached = await capturedRef
          .read(audienceTokenForAudienceProvider(kSkcodeAudience).future);
      expect(tokenStillCached, tokenBefore);
      expect(adapter.mintCalls, 1);

      // The callback the transport layer invokes on a 401/1008 (card C-3b's
      // "onAuthRejected", proven directly here, independent of the session
      // store's own reconnect test in packages/skcode_client). Both halves
      // fire: AudienceTokenService's own cache (what a mounted
      // AuthContext.token() reads) AND the Riverpod future (what this test,
      // and the legacy SkcodePane, watch).
      module.onAuthRejected!();

      final tokenAfter = await capturedRef
          .read(audienceTokenForAudienceProvider(kSkcodeAudience).future);
      expect(adapter.mintCalls, 2,
          reason: "onAuthRejected must force a real re-mint, not replay the "
              "cached Future");
      expect(tokenAfter, isNot(tokenBefore),
          reason: "the re-mint must produce a genuinely fresh token");
    });
  });
}
