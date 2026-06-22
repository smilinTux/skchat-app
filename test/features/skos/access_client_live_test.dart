import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/skos/access_client.dart';
import 'package:skchat/features/skos/access_token_signer.dart';

/// Canned-response adapter that records every request so we can assert on the
/// path + body the live client builds. (Same pattern as the service tests.)
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.routes);

  /// path → response JSON.
  final Map<String, Object?> routes;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = routes[options.uri.path] ?? routes[options.path];
    if (body == null) {
      return ResponseBody.fromString(
        jsonEncode({'detail': 'no route'}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  group('AccessTokenSigner', () {
    test('POSTs {node,tool,arguments} to /api/v1/access/token and returns the '
        'token string', () async {
      final adapter = _RecordingAdapter({
        '/api/v1/access/token': {
          'token': '{"envelope":{"from_fqid":"lumina@chef.skworld"},'
              '"signature":"-----BEGIN PGP SIGNATURE-----..."}',
          'from_fqid': 'lumina@chef.skworld',
          'fingerprint': 'A' * 40,
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final signer =
          AccessTokenSigner(daemonBaseUrl: 'http://localhost:9384', dio: dio);

      final token =
          await signer.tokenForCall('.158', 'file_read', {'path': '/x'});

      // Returned the daemon-minted SignedEnvelope JSON string verbatim.
      expect(token, contains('PGP SIGNATURE'));
      expect(token, contains('from_fqid'));

      // Hit the mint endpoint with the right body.
      final req = adapter.requests.single;
      expect(req.uri.path, '/api/v1/access/token');
      expect(req.method, 'POST');
      final sent = req.data as Map;
      expect(sent['node'], '.158');
      expect(sent['tool'], 'file_read');
      expect(sent['arguments'], {'path': '/x'});
    });

    test('maps a 503 (no signing key) to a clear StateError', () async {
      final dio = Dio()
        ..httpClientAdapter = _ErrorAdapter(503, {'detail': 'no CapAuth key'});
      final signer =
          AccessTokenSigner(daemonBaseUrl: 'http://localhost:9384', dio: dio);

      expect(
        () => signer.tokenForCall('.41', 'file_read', const {}),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('No CapAuth signing key'))),
      );
    });
  });

  group('DaemonAccessClient (live path)', () {
    test('file_read POSTs /tool with {token, tool, arguments} and the minted '
        'token, then unwraps the result', () async {
      final adapter = _RecordingAdapter({
        '/tool': {
          'ok': true,
          'result': {'content': 'hello from the tailnet'},
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;

      // Stub token minting (proven separately above) so this test isolates the
      // /tool request shape.
      var tokenCalls = 0;
      Future<String> fakeToken(
        String node,
        String tool,
        Map<String, dynamic> args,
      ) async {
        tokenCalls++;
        return 'SIGNED-TOKEN-for:$node:$tool';
      }

      final client = DaemonAccessClient(
        dio: dio,
        tokenForCall: fakeToken,
        nodes: const {'.158': 'http://100.108.59.57:9386'},
      );

      final content = await client.readFile('.158', '/home/x/notes.md');
      expect(content, 'hello from the tailnet');

      // The token was minted exactly once and forwarded in the /tool body.
      expect(tokenCalls, 1);
      final req = adapter.requests.single;
      expect(req.uri.path, '/tool');
      expect(req.uri.host, '100.108.59.57');
      expect(req.method, 'POST');
      final sent = req.data as Map;
      expect(sent['token'], 'SIGNED-TOKEN-for:.158:file_read');
      expect(sent['tool'], 'file_read');
      expect(sent['arguments'], {'path': '/home/x/notes.md'});
    });

    test('read-only by default; writeFile throws AccessScopeException without a '
        'granted scope (no HTTP made)', () async {
      final adapter = _RecordingAdapter(const {});
      final dio = Dio()..httpClientAdapter = adapter;
      final client = DaemonAccessClient(
        dio: dio,
        tokenForCall: (n, t, a) async => 'tok',
      );

      expect(client.canWrite, isFalse);
      await expectLater(
        client.writeFile('.158', '/x', 'y'),
        throwsA(isA<AccessScopeException>()),
      );
      // Write was blocked client-side — no /tool call escaped.
      expect(adapter.requests, isEmpty);
    });

    test('search routes pg_search to the corpus primary (.158)', () async {
      final adapter = _RecordingAdapter({
        '/tool': {
          'ok': true,
          'result': {
            'hits': [
              {
                'node': '.41',
                'path': '/home/x/enroll.py',
                'score': 0.9,
                'snippet': 'the capauth enrollment bug',
                'doc_id': 'd1',
                'source': 'code',
              }
            ]
          },
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final client = DaemonAccessClient(
        dio: dio,
        tokenForCall: (n, t, a) async => 'tok',
        nodes: const {'.158': 'http://100.108.59.57:9386'},
      );

      final hits = await client.search('capauth enrollment', k: 5);
      expect(hits, hasLength(1));
      expect(hits.first.node, '.41');

      final req = adapter.requests.single;
      expect(req.uri.host, '100.108.59.57'); // pg_search → primary
      final sent = req.data as Map;
      expect(sent['tool'], 'pg_search');
      expect(sent['arguments'], {'query': 'capauth enrollment', 'k': 5});
    });
  });
}

/// Adapter that always raises an HTTP error with a given status + body.
class _ErrorAdapter implements HttpClientAdapter {
  _ErrorAdapter(this.status, this.body);
  final int status;
  final Map<String, Object?> body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}
