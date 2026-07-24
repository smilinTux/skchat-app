import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/call_api_client.dart';

/// Minimal in-memory Dio adapter: maps "METHOD path" -> (status, json).
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.routes);
  final Map<String, (int, Object)> routes;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? _, Future<void>? __) async {
    final key = '${options.method} ${options.path}';
    final entry = routes[key];
    if (entry == null) return ResponseBody.fromString('{}', 404);
    return ResponseBody.fromString(_json(entry.$2), entry.$1,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
  static String _json(Object o) => o is String ? o : _encode(o);
  static String _encode(Object o) => o.toString();
}

Dio _dioWith(Map<String, (int, Object)> routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://webui.test'));
  dio.httpClientAdapter = _StubAdapter(routes);
  return dio;
}

void main() {
  group('CallApiClient', () {
    test('startCall posts /call/start and parses the room+token', () async {
      final dio = _dioWith({
        'POST https://webui.test/call/start':
            (200, '{"room":"call-abc","token":"tok1","livekit_url":"wss://sfu","peer_fqid":"steward@skworld.io","identity":"chef@skworld.io"}'),
      });
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      final r = await api.startCall('steward@skworld.io');
      expect(r.room, 'call-abc');
      expect(r.token, 'tok1');
      expect(r.livekitUrl, 'wss://sfu');
      expect(r.peerFqid, 'steward@skworld.io');
    });

    test('answerCall posts /call/answer and parses the same shape', () async {
      final dio = _dioWith({
        'POST https://webui.test/call/answer':
            (200, '{"room":"call-abc","token":"tok2","livekit_url":"wss://sfu","peer_fqid":"steward@skworld.io","identity":"chef@skworld.io"}'),
      });
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      final r = await api.answerCall('steward@skworld.io');
      expect(r.room, 'call-abc');
      expect(r.token, 'tok2');
    });

    test('pollIncoming parses the invites array', () async {
      final dio = _dioWith({
        'GET https://webui.test/call/incoming':
            (200, '{"invites":[{"from_fqid":"steward@skworld.io","room":"call-abc","livekit_url":"wss://sfu","topic":"","ts":123,"nonce":"n1"}]}'),
      });
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      final invites = await api.pollIncoming();
      expect(invites, hasLength(1));
      expect(invites.first.fromFqid, 'steward@skworld.io');
      expect(invites.first.room, 'call-abc');
      expect(invites.first.nonce, 'n1');
    });

    test('pollIncoming returns empty on a missing invites key', () async {
      final dio = _dioWith({'GET https://webui.test/call/incoming': (200, '{}')});
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      expect(await api.pollIncoming(), isEmpty);
    });
  });
}
