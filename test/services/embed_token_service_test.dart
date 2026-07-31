import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/embed_token_service.dart';
import 'package:skchat/services/skcomms_client.dart';

/// Canned-response adapter for the embed-token endpoint. Counts hits so a test
/// can assert the cache path skips the second network round-trip, and can be
/// scripted to return a chosen status code or to throw a transport error.
/// Mirrors the audience-token service test's mocking style.
class _EmbedTokenAdapter implements HttpClientAdapter {
  _EmbedTokenAdapter({this.status = 200, this.body, this.throwNetwork = false});

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
        reason: 'simulated network failure',
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

EmbedTokenService _wire(_EmbedTokenAdapter adapter, {DateTime Function()? now}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:9384'))
    ..httpClientAdapter = adapter;
  final client = SKCommsClient(dio: dio);
  return EmbedTokenService(client: client, now: now);
}

void main() {
  group('EmbedTokenService.mint', () {
    test('200 {token, expires_at}: returns the token and caches it', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'EMBED-TOKEN-1',
          'module': 'skdashboard',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      final first = await svc.mint('skdashboard');
      expect(first, 'EMBED-TOKEN-1');
      expect(adapter.hitCount, 1);

      // Second call is served from cache: no new round-trip.
      final second = await svc.mint('skdashboard');
      expect(second, 'EMBED-TOKEN-1');
      expect(adapter.hitCount, 1);
    });

    test('cache is keyed by module: a different module re-mints', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'EMBED-TOKEN',
          'module': 'skos',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      await svc.mint('skdashboard');
      await svc.mint('skos');
      // Two distinct modules -> two mints even though the body is the same shape.
      expect(adapter.hitCount, 2);
    });

    test('404 (mint flag off / inert) returns null, never throws', () async {
      final svc = _wire(_EmbedTokenAdapter(status: 404, body: const {}));
      expect(await svc.mint('skos'), isNull);
    });

    test('network error returns null, never throws', () async {
      final svc = _wire(_EmbedTokenAdapter(throwNetwork: true));
      expect(await svc.mint('skdashboard'), isNull);
    });

    test('malformed body (no token) returns null', () async {
      final svc = _wire(_EmbedTokenAdapter(body: const {'module': 'skos'}));
      expect(await svc.mint('skos'), isNull);
    });

    test('expired cache re-mints', () async {
      // expires_at is in the past relative to the injected clock, so the cached
      // token is treated as stale and a second mint fires.
      final past = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'EMBED-STALE',
          'module': 'skdashboard',
          'expires_at': past.toIso8601String(),
        },
      );
      final svc = _wire(adapter, now: () => DateTime.now().toUtc());

      await svc.mint('skdashboard');
      await svc.mint('skdashboard');
      expect(adapter.hitCount, 2);
    });
  });
}
