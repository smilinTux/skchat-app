import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/shell/app_shell_context.dart";
import "package:skchat/services/audience_token_service.dart";
import "package:skchat/services/skcomms_client.dart";

/// Canned-response adapter for the audience-token endpoint. Counts hits so a
/// test can assert the cache path skips the second network round-trip, and can
/// be scripted to return a chosen status code or to throw a transport error.
/// Mirrors the project's existing service-test mocking style (see
/// skcomms_client_auth_test.dart).
class _AudienceTokenAdapter implements HttpClientAdapter {
  _AudienceTokenAdapter({this.status = 200, this.body, this.throwNetwork = false});

  int status;
  Object? body;
  bool throwNetwork;
  int hitCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hitCount++;
    if (throwNetwork) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: "simulated network failure",
      );
    }
    return ResponseBody.fromString(
      jsonEncode(body ?? const {}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Build an [AppAuthContext] whose token() rides an [AudienceTokenService] over
/// a mocked Dio, so the assertions exercise the real token()->service->client
/// chain, not a hand-rolled fake.
({AppAuthContext auth, _AudienceTokenAdapter adapter}) _wire(
  _AudienceTokenAdapter adapter, {
  DateTime Function()? now,
}) {
  final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
    ..httpClientAdapter = adapter;
  final client = SKCommsClient(dio: dio);
  final service = AudienceTokenService(client: client, now: now);
  return (auth: AppAuthContext(tokenMinter: service.mint), adapter: adapter);
}

void main() {
  group("AppAuthContext.token() mints an audience token", () {
    test("200 {token, expires_at}: returns the token and caches it", () async {
      final future = DateTime.now().add(const Duration(hours: 1));
      final adapter = _AudienceTokenAdapter(
        body: {
          "token": "AUD-TOKEN-1",
          "audience": "skchat",
          "expires_at": future.millisecondsSinceEpoch ~/ 1000,
        },
      );
      final wired = _wire(adapter);

      final first = await wired.auth.token();
      expect(first, "AUD-TOKEN-1");
      expect(adapter.hitCount, 1);

      // Second call is served from the cache: no new network round-trip.
      final second = await wired.auth.token();
      expect(second, "AUD-TOKEN-1");
      expect(adapter.hitCount, 1, reason: "cached token must not re-fetch");
    });

    test("re-mints once the cached token is near expiry", () async {
      // Expire 10s from the frozen clock; the 30s safety margin makes it stale
      // immediately, so the second call re-mints rather than reusing the cache.
      final clock = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final adapter = _AudienceTokenAdapter(
        body: {
          "token": "AUD-TOKEN-EXP",
          "expires_at": clock.add(const Duration(seconds: 10)).toIso8601String(),
        },
      );
      final wired = _wire(adapter, now: () => clock);

      expect(await wired.auth.token(), "AUD-TOKEN-EXP");
      expect(await wired.auth.token(), "AUD-TOKEN-EXP");
      expect(adapter.hitCount, 2, reason: "near-expiry token must re-mint");
    });

    test("404 (endpoint inert / flag off): returns null and does not throw",
        () async {
      final adapter = _AudienceTokenAdapter(status: 404, body: {"error": "not found"});
      final wired = _wire(adapter);

      final token = await wired.auth.token();
      expect(token, isNull);
      expect(adapter.hitCount, 1);
    });

    test("network error: returns null and does not throw", () async {
      final adapter = _AudienceTokenAdapter(throwNetwork: true);
      final wired = _wire(adapter);

      final token = await wired.auth.token();
      expect(token, isNull);
    });

    test("401 (unauthorized): returns null and does not throw", () async {
      final adapter = _AudienceTokenAdapter(status: 401, body: {"error": "unauthorized"});
      final wired = _wire(adapter);

      expect(await wired.auth.token(), isNull);
    });

    test("malformed 200 (missing token field): returns null", () async {
      final adapter = _AudienceTokenAdapter(body: {"audience": "skchat"});
      final wired = _wire(adapter);

      expect(await wired.auth.token(), isNull);
    });

    test("no minter wired: token() returns null (prior stub behavior)",
        () async {
      const auth = AppAuthContext(subjectFqid: "fp");
      expect(await auth.token(), isNull);
    });
  });

  group("AudienceTokenService.invalidate", () {
    // Trap 2 (card f2e35195): mint()'s freshness check is CLOCK-based only.
    // A token can be unexpired and still rejected server-side (revoked,
    // verifier restarted, PDP policy changed): that is exactly what an HTTP
    // 401 or WS 1008 close means. Re-minting without first invalidating the
    // cache is a no-op: mint() sees the still-clock-fresh cached token and
    // hands back the SAME stale token, so the retry fails identically. This
    // test proves invalidate() breaks that loop: after invalidate(), the
    // next mint() call MUST hit the network again even though the cached
    // token has not clock-expired.
    test("forces a re-mint even when the cached token has not clock-expired",
        () async {
      final farFuture = DateTime.now().add(const Duration(hours: 1));
      final adapter = _AudienceTokenAdapter(
        body: {
          "token": "AUD-TOKEN-STALE",
          "expires_at": farFuture.millisecondsSinceEpoch ~/ 1000,
        },
      );
      final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = adapter;
      final service = AudienceTokenService(client: SKCommsClient(dio: dio));

      final first = await service.mint("skcode");
      expect(first, "AUD-TOKEN-STALE");
      expect(adapter.hitCount, 1);

      // Still comfortably clock-fresh (expires in ~1h): a plain mint() call
      // must serve the cache, NOT re-fetch.
      final second = await service.mint("skcode");
      expect(second, "AUD-TOKEN-STALE");
      expect(adapter.hitCount, 1,
          reason: "clock-fresh token must be served from cache");

      // Simulate the server rejecting it anyway (revoked / 1008 / PDP
      // change): the caller invalidates, then re-mints once.
      adapter.body = {
        "token": "AUD-TOKEN-FRESH",
        "expires_at": farFuture.millisecondsSinceEpoch ~/ 1000,
      };
      service.invalidate("skcode");

      final third = await service.mint("skcode");
      expect(third, "AUD-TOKEN-FRESH",
          reason: "invalidate() must force mint() to hit the network again "
              "and pick up the new token, not replay the stale cached one");
      expect(adapter.hitCount, 2);
    });

    test("invalidating an audience with nothing cached is a no-op", () {
      final adapter = _AudienceTokenAdapter(body: const {});
      final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = adapter;
      final service = AudienceTokenService(client: SKCommsClient(dio: dio));

      expect(() => service.invalidate("skcode"), returnsNormally);
    });

    test("invalidating one audience does not disturb another's cache",
        () async {
      final farFuture = DateTime.now().add(const Duration(hours: 1));
      final adapter = _AudienceTokenAdapter(
        body: {
          "token": "SHARED-BODY-TOKEN",
          "expires_at": farFuture.millisecondsSinceEpoch ~/ 1000,
        },
      );
      final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = adapter;
      final service = AudienceTokenService(client: SKCommsClient(dio: dio));

      await service.mint("skcode");
      await service.mint("skchat");
      expect(adapter.hitCount, 2);

      service.invalidate("skcode");

      // skchat's cache is untouched: no new network round-trip for it.
      await service.mint("skchat");
      expect(adapter.hitCount, 2,
          reason: "invalidate(skcode) must not evict the skchat cache entry");

      // skcode was invalidated: mint() must hit the network again.
      await service.mint("skcode");
      expect(adapter.hitCount, 3);
    });
  });
}
