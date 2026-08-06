import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/skcomms_client.dart';

/// Canned-response adapter resolving by path, with a configurable status code
/// and the ability to simulate a transport failure (throws). Records the last
/// request so the send body can be asserted.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter();

  final Map<String, Object?> routes = {};
  final Map<String, int> statusCodes = {};
  final Set<String> failPaths = {};
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    final path = options.uri.path;
    if (failPaths.contains(path) || failPaths.contains(Uri.decodeFull(path))) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'simulated transport failure',
      );
    }
    // Match by the request path, tolerating percent-encoding (the client
    // url-encodes peer fqids, so `@` arrives as `%40`).
    final decoded = Uri.decodeFull(path);
    final body =
        routes[path] ?? routes[decoded] ?? routes[options.path] ?? {};
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      statusCodes[path] ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

SKCommsClient _client(_CannedAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return SKCommsClient(baseUrl: 'http://test.local:9384', dio: dio);
}

void main() {
  // ── BUG 1 — daemon-state truth ────────────────────────────────────────────
  group('daemon-state truth (isAlive + getStatus)', () {
    test('200 /health ⇒ isAlive true', () async {
      final a = _CannedAdapter();
      a.routes['/health'] = {'status': 'ok'};
      expect(await _client(a).isAlive(), isTrue);
    });

    test('genuinely-down daemon ⇒ isAlive false', () async {
      final a = _CannedAdapter()..failPaths.add('/health');
      expect(await _client(a).isAlive(), isFalse);
    });

    test('5xx /health ⇒ isAlive false (not a 2xx/3xx)', () async {
      final a = _CannedAdapter();
      a.routes['/health'] = {'status': 'err'};
      a.statusCodes['/health'] = 503;
      expect(await _client(a).isAlive(), isFalse);
    });

    test('getStatus returns the {agents:[...]} contract shape as a map',
        () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/status'] = {
        'agents': [
          {'name': 'lumina'},
        ],
        'transport_ok': true,
      };
      final status = await _client(a).getStatus();
      expect(status['transport_ok'], true);
      expect(status['agents'], isA<List>());
    });

    test('getStatus does NOT throw on a non-map 200 body (no false offline)',
        () async {
      // A proxy returning a bare JSON array/scalar must not blow up the cast
      // and flip the UI offline — we coerce to an empty map instead.
      final a = _CannedAdapter();
      a.routes['/api/v1/status'] = <dynamic>[1, 2, 3];
      final status = await _client(a).getStatus();
      expect(status, isEmpty);
    });
  });

  // ── BUG 3 — send contract reply parsing ───────────────────────────────────
  group('sendMessage parses the {ok, reply, message} contract', () {
    test('surfaces echoed user message AND the agent reply', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/send'] = {
        'ok': true,
        'message': {
          'id': 'u-1',
          'sender': 'chef@skworld.io',
          'body': 'hi Lumina',
          'ts': '2026-06-20T10:00:00Z',
        },
        'reply': {
          'id': 'l-1',
          'sender': 'lumina@chef.skworld',
          'body': "Received. I'm here.",
          'ts': '2026-06-20T10:00:18Z',
        },
      };

      final r = await _client(a).sendMessage(
        recipient: 'lumina@chef.skworld',
        message: 'hi Lumina',
      );

      expect(r.delivered, isTrue);
      expect(r.echoedMessage?['id'], 'u-1');
      expect(r.reply?['id'], 'l-1');
      expect(r.reply?['body'], "Received. I'm here.");
      expect(r.envelopeId, 'u-1');
    });

    test('send body carries both peer_id (contract) and recipient (legacy)',
        () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/send'] = {'ok': true};
      await _client(a).sendMessage(
        recipient: 'lumina@chef.skworld',
        message: 'hello',
      );
      final sent = a.lastRequest!.data as Map;
      expect(sent['peer_id'], 'lumina@chef.skworld');
      expect(sent['recipient'], 'lumina@chef.skworld');
      expect(sent['content'], 'hello');
    });

    test('tolerates the legacy {delivered, envelope_id} daemon shape',
        () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/send'] = {
        'delivered': true,
        'envelope_id': 'env-9',
        'transport_used': 'syncthing',
      };
      final r = await _client(a).sendMessage(
        recipient: 'lumina',
        message: 'x',
      );
      expect(r.delivered, isTrue);
      expect(r.envelopeId, 'env-9');
      expect(r.reply, isNull);
      expect(r.echoedMessage, isNull);
    });
  });

  // ── BUG 2 — history fetch parsing ─────────────────────────────────────────
  group('getConversationFull parses history (both wire shapes)', () {
    test('reads a bare array of contract messages', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/conversations/lumina@chef.skworld'] = [
        {'id': 'm1', 'sender': 'lumina@chef.skworld', 'body': 'hey'},
        {'id': 'm2', 'sender': 'chef@skworld.io', 'body': 'hi'},
      ];
      final msgs =
          await _client(a).getConversationFull('lumina@chef.skworld');
      expect(msgs.length, 2);
      expect(msgs.first['id'], 'm1');
    });

    test('reads a {messages:[...]} wrapper', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/conversations/lumina@chef.skworld'] = {
        'messages': [
          {'id': 'm1', 'sender': 'lumina@chef.skworld', 'body': 'hey'},
        ],
      };
      final msgs =
          await _client(a).getConversationFull('lumina@chef.skworld');
      expect(msgs.length, 1);
      expect(msgs.first['body'], 'hey');
    });

    test('returns empty (not throw) when the endpoint fails', () async {
      final a = _CannedAdapter()
        ..failPaths.add('/api/v1/conversations/lumina@chef.skworld');
      final msgs =
          await _client(a).getConversationFull('lumina@chef.skworld');
      expect(msgs, isEmpty);
    });
  });

  // ── Cross-device reply-quote wire threading (card 5a19f848) ────────────────
  group('sendMessage threads the quoted snippet into the POST body', () {
    test('carries quoted_text/quoted_sender/quoted_id when provided', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/send'] = {'ok': true};
      await _client(a).sendMessage(
        recipient: 'lumina@chef.skworld',
        message: 'sounds good',
        inReplyTo: 'orig-1',
        quotedText: 'here is the original plan',
        quotedSender: 'Lumina',
        quotedId: 'orig-1',
      );
      final sent = a.lastRequest!.data as Map;
      expect(sent['reply_to_id'], 'orig-1');
      expect(sent['quoted_text'], 'here is the original plan');
      expect(sent['quoted_sender'], 'Lumina');
      expect(sent['quoted_id'], 'orig-1');
    });

    test('omits the quoted_* keys entirely when not provided', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/send'] = {'ok': true};
      await _client(a).sendMessage(
        recipient: 'lumina@chef.skworld',
        message: 'plain message',
      );
      final sent = a.lastRequest!.data as Map;
      // Null-aware map entries drop the key rather than sending a null value,
      // so a non-reply send never ships empty quoted fields.
      expect(sent.containsKey('quoted_text'), isFalse);
      expect(sent.containsKey('quoted_sender'), isFalse);
      expect(sent.containsKey('quoted_id'), isFalse);
    });
  });
}
