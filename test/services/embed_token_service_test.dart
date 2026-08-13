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

  /// The decoded JSON request bodies seen, in order (so a test can assert the
  /// `mode` sent to the mint endpoint).
  final List<Map<String, dynamic>> requestBodies = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hitCount++;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final bytes = chunks.expand((c) => c).toList();
      if (bytes.isNotEmpty) {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) {
          requestBodies.add(Map<String, dynamic>.from(decoded));
        }
      }
    }
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

    test('default mode is ro; sends mode=ro in the request body', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'RO-TOKEN',
          'module': 'skos',
          'mode': 'ro',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      expect(await svc.mint('skos'), 'RO-TOKEN');
      expect(adapter.requestBodies.single['mode'], 'ro');
    });

    test('rw mode is passed through to the mint endpoint', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'RW-TOKEN',
          'module': 'skdashboard',
          'mode': 'rw',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      expect(await svc.mint('skdashboard', mode: 'rw'), 'RW-TOKEN');
      expect(adapter.requestBodies.single['module'], 'skdashboard');
      expect(adapter.requestBodies.single['mode'], 'rw');
    });

    test('cache is keyed by module AND mode: ro and rw are separate', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'TOKEN',
          'module': 'skdashboard',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      await svc.mint('skdashboard'); // ro (default)
      await svc.mint('skdashboard', mode: 'rw'); // different key -> re-mints
      expect(adapter.hitCount, 2);
      // Same (module, mode) again is served from cache.
      await svc.mint('skdashboard', mode: 'rw');
      expect(adapter.hitCount, 2);
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

  group('EmbedTokenService.clearCache', () {
    test('drops the cached token so the next mint hits the backend again',
        () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'EMBED-TOKEN-1',
          'module': 'skdashboard',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      await svc.mint('skdashboard');
      expect(adapter.hitCount, 1);

      // Still fresh: a second mint before clearCache is served from cache.
      await svc.mint('skdashboard');
      expect(adapter.hitCount, 1);

      svc.clearCache('skdashboard');

      // Cache dropped: the next mint re-hits the backend even though the
      // previous token had not actually expired.
      await svc.mint('skdashboard');
      expect(adapter.hitCount, 2);
    });

    test('clears BOTH ro and rw entries for the module', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'TOKEN',
          'module': 'skdashboard',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      await svc.mint('skdashboard'); // ro
      await svc.mint('skdashboard', mode: 'rw'); // rw
      expect(adapter.hitCount, 2);

      svc.clearCache('skdashboard');

      await svc.mint('skdashboard');
      await svc.mint('skdashboard', mode: 'rw');
      expect(adapter.hitCount, 4);
    });

    test('does not touch a DIFFERENT module\'s cache', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'TOKEN',
          'module': 'skos',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      await svc.mint('skdashboard');
      await svc.mint('skos');
      expect(adapter.hitCount, 2);

      svc.clearCache('skdashboard');

      // skos is untouched: still served from cache.
      await svc.mint('skos');
      expect(adapter.hitCount, 2);

      // skdashboard was cleared: re-mints.
      await svc.mint('skdashboard');
      expect(adapter.hitCount, 3);
    });
  });

  group('EmbedTokenService.currentExpiry', () {
    test('returns null when nothing has been minted for the module', () {
      final svc = _wire(_EmbedTokenAdapter(body: const {}));
      expect(svc.currentExpiry('skdashboard'), isNull);
    });

    test('returns the cached expiry after a mint, keyed by mode', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'TOKEN',
          'module': 'skdashboard',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      expect(svc.currentExpiry('skdashboard'), isNull);
      await svc.mint('skdashboard');
      expect(svc.currentExpiry('skdashboard'), future);
      // The rw slot is a separate cache key: still unminted.
      expect(svc.currentExpiry('skdashboard', mode: 'rw'), isNull);
    });

    test('returns null again after clearCache', () async {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final adapter = _EmbedTokenAdapter(
        body: {
          'token': 'TOKEN',
          'module': 'skdashboard',
          'expires_at': future.toIso8601String(),
        },
      );
      final svc = _wire(adapter);

      await svc.mint('skdashboard');
      expect(svc.currentExpiry('skdashboard'), isNotNull);

      svc.clearCache('skdashboard');
      expect(svc.currentExpiry('skdashboard'), isNull);
    });
  });
}
