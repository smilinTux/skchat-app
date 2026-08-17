// Coord card P1.3b (280348ef): SKCapstoneClient must send x-sk-capability
// (and a resolved x-sk-actor, never the hardcoded "skworld-app" string) on
// every mutating /api/change and /api/card call, mirroring skdashboard's
// authHeaders() in static/js/api.js. This is the last blocker on the
// SKAI_AUTHZ flip (card a5abe96e): once flipped, a client that omits
// x-sk-capability is denied by _capability_gate on the server.
//
// MUTATION TARGET: reverting any of mutateCard / queueAi / validateChange /
// scheduleChange / unscheduleChange / armChangeDeploy / pirDraft /
// verifyChange back to `Options(headers: const {'x-sk-actor':
// 'skworld-app'})` turns this file's "sends x-sk-capability" and
// "never sends the hardcoded actor" tests red.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/skcapstone_client.dart';

/// Records every request's method/path/headers so a test can assert on the
/// exact set the client attached, and answers GET /api/auth/capability with
/// a canned body while every other route gets a generic ok:true 200.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({this.capabilityBody});

  /// Body returned for GET /api/auth/capability. Null simulates the
  /// endpoint being unreachable (dashboard offline / not yet deployed).
  final Map<String, dynamic>? capabilityBody;

  final List<RequestOptions> requests = [];
  int capabilityFetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.endsWith('/api/auth/capability')) {
      capabilityFetchCount++;
      if (capabilityBody == null) {
        return ResponseBody.fromString('{"error":"unavailable"}', 503,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType]
            });
      }
      return ResponseBody.fromString(jsonEncode(capabilityBody), 200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    return ResponseBody.fromString(jsonEncode({'ok': true}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }
}

SKCapstoneClient _clientWith(_CapturingAdapter adapter) {
  final dashDio = Dio(BaseOptions(baseUrl: 'https://dash.test'))
    ..httpClientAdapter = adapter;
  return SKCapstoneClient(
    baseUrl: 'http://daemon.test',
    dashboardUrl: 'https://dash.test',
    dashDio: dashDio,
  );
}

RequestOptions _lastMutation(_CapturingAdapter adapter) => adapter.requests
    .lastWhere((r) => !r.path.endsWith('/api/auth/capability'));

void main() {
  group('SKCapstoneClient capability headers (P1.3b)', () {
    test('mutateCard sends both x-sk-actor and x-sk-capability when the '
        'seat has a configured capability', () async {
      final adapter = _CapturingAdapter(
          capabilityBody: {'capability': 'QTOK-abc', 'actor': 'chef'});
      final client = _clientWith(adapter);

      final ok = await client.mutateCard('card-1', 'move', {'column': 'doing'});

      expect(ok, isTrue);
      final req = _lastMutation(adapter);
      expect(req.headers['x-sk-actor'], 'chef');
      expect(req.headers['x-sk-capability'], 'QTOK-abc');
    });

    test('queueAi, validateChange, scheduleChange, unscheduleChange, '
        'armChangeDeploy, pirDraft and verifyChange all attach the same '
        'headers -- none hardcodes the actor', () async {
      final adapter = _CapturingAdapter(
          capabilityBody: {'capability': 'QTOK-xyz', 'actor': 'chef'});
      final client = _clientWith(adapter);

      await client.queueAi('card-2', instruction: 'do it');
      await client.validateChange('chg-1');
      await client.scheduleChange('chg-1', asap: true);
      await client.unscheduleChange('chg-1');
      await client.armChangeDeploy('chg-1');
      await client.pirDraft('chg-1');
      await client.verifyChange('chg-1', 'note');

      final mutations =
          adapter.requests.where((r) => !r.path.endsWith('/api/auth/capability'));
      expect(mutations, hasLength(7));
      for (final req in mutations) {
        expect(req.headers['x-sk-actor'], 'chef',
            reason: '${req.method} ${req.path} sent the wrong actor');
        expect(req.headers['x-sk-capability'], 'QTOK-xyz',
            reason: '${req.method} ${req.path} missing x-sk-capability');
        expect(req.headers['x-sk-actor'], isNot('skworld-app'));
      }
    });

    test('capability is fetched once and cached across multiple mutating '
        'calls', () async {
      final adapter = _CapturingAdapter(
          capabilityBody: {'capability': 'QTOK-once', 'actor': 'chef'});
      final client = _clientWith(adapter);

      await client.mutateCard('card-1', 'move', {'column': 'doing'});
      await client.mutateCard('card-1', 'assign', {'owner': 'chef'});
      await client.queueAi('card-1', instruction: 'go');

      expect(adapter.capabilityFetchCount, 1);
    });

    test('omits x-sk-capability when the seat has none configured, but '
        'still sends the resolved actor', () async {
      final adapter =
          _CapturingAdapter(capabilityBody: {'capability': null, 'actor': 'chef'});
      final client = _clientWith(adapter);

      await client.mutateCard('card-1', 'move', {'column': 'doing'});

      final req = _lastMutation(adapter);
      expect(req.headers['x-sk-actor'], 'chef');
      expect(req.headers.containsKey('x-sk-capability'), isFalse);
    });

    test('a capability-fetch failure degrades to "unattributed", never a '
        'hardcoded actor string', () async {
      final adapter = _CapturingAdapter(capabilityBody: null);
      final client = _clientWith(adapter);

      final ok = await client.mutateCard('card-1', 'move', {'column': 'doing'});

      expect(ok, isTrue);
      final req = _lastMutation(adapter);
      expect(req.headers['x-sk-actor'], 'unattributed');
      expect(req.headers['x-sk-actor'], isNot('skworld-app'));
      expect(req.headers.containsKey('x-sk-capability'), isFalse);
    });

    test('a missing actor field in the capability response also degrades '
        'to "unattributed"', () async {
      final adapter = _CapturingAdapter(capabilityBody: const {});
      final client = _clientWith(adapter);

      await client.mutateCard('card-1', 'move', {'column': 'doing'});

      final req = _lastMutation(adapter);
      expect(req.headers['x-sk-actor'], 'unattributed');
    });
  });
}
