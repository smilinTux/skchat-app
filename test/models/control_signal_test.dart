import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/chat_text.dart';
import 'package:skchat/models/control_signal.dart';
import 'package:skchat/services/skcomms_client.dart';

/// Canned-response adapter — resolves each request by path and records the last
/// request so the encoded sentinel body can be asserted. Mirrors the pattern in
/// skcomms_upload_test.dart.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
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
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
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
  group('ReactionSignal encode/parse', () {
    test('round-trips an add through encode → parse', () {
      const sig = ReactionSignal(targetId: 'm-1', emoji: '❤️');
      final encoded = sig.encode();
      expect(encoded.startsWith(ReactionSignal.prefix), isTrue);

      final parsed = ReactionSignal.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.targetId, 'm-1');
      expect(parsed.emoji, '❤️');
      expect(parsed.action, 'add');
      expect(parsed.isAdd, isTrue);
    });

    test('round-trips a remove', () {
      const sig = ReactionSignal(targetId: 'm-2', emoji: '🔥', action: 'remove');
      final parsed = ReactionSignal.parse(sig.encode());
      expect(parsed, isNotNull);
      expect(parsed!.action, 'remove');
      expect(parsed.isAdd, isFalse);
    });

    test('returns null for non-reaction bodies', () {
      expect(ReactionSignal.parse('just text'), isNull);
      expect(ReactionSignal.parse(null), isNull);
      expect(ReactionSignal.parse('__REACT__:not-json'), isNull);
      // Missing target_id / emoji is invalid.
      expect(ReactionSignal.parse('__REACT__:{"emoji":"x"}'), isNull);
      expect(ReactionSignal.parse('__REACT__:{"target_id":"m"}'), isNull);
    });

    test('unknown action defaults to add', () {
      final parsed =
          ReactionSignal.parse('__REACT__:{"target_id":"m","emoji":"👍","action":"weird"}');
      expect(parsed, isNotNull);
      expect(parsed!.action, 'add');
    });
  });

  group('TypingSignal encode/parse', () {
    test('round-trips start and stop', () {
      expect(TypingSignal.parse(const TypingSignal().encode())!.isStart, isTrue);
      expect(
        TypingSignal.parse(const TypingSignal(state: 'stop').encode())!.isStart,
        isFalse,
      );
    });

    test('returns null for non-typing bodies', () {
      expect(TypingSignal.parse('hello'), isNull);
      expect(TypingSignal.parse(null), isNull);
      expect(TypingSignal.parse('__TYPING__:nope'), isNull);
    });

    test('unknown state defaults to start', () {
      expect(TypingSignal.parse('__TYPING__:{"state":"???"}')!.isStart, isTrue);
    });
  });

  group('displayTextFor drops control sentinels', () {
    test('reaction and typing sentinels never render as chat text', () {
      expect(
        displayTextFor(const ReactionSignal(targetId: 'm', emoji: '❤️').encode()),
        isNull,
      );
      expect(displayTextFor(const TypingSignal().encode()), isNull);
      expect(displayTextFor(const TypingSignal(state: 'stop').encode()), isNull);
    });

    test('ordinary text still displays', () {
      expect(displayTextFor('hello there'), 'hello there');
    });
  });

  group('send path — encoded sentinel reaches POST /api/v1/send', () {
    late _CannedAdapter adapter;
    late SKCommsClient client;

    setUp(() {
      adapter = _CannedAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      client = SKCommsClient(baseUrl: 'http://test.local:9384', dio: dio);
    });

    test('reaction sentinel is sent as the message body', () async {
      adapter.routes['/api/v1/send'] = {
        'delivered': true,
        'envelope_id': 'e-1',
      };

      final body = const ReactionSignal(targetId: 'm-9', emoji: '🔥').encode();
      final result = await client.sendMessage(recipient: 'lumina', message: body);

      expect(result.delivered, isTrue);
      final req = adapter.lastRequest;
      expect(req, isNotNull);
      expect(req!.method, 'POST');
      expect(req.path, '/api/v1/send');
      final sent = req.data as Map<String, dynamic>;
      expect(sent['recipient'], 'lumina');
      // The body carried over the wire is the reaction sentinel verbatim, so
      // the receiver can parse it back out.
      expect(sent['message'], body);
      final reparsed = ReactionSignal.parse(sent['message'] as String);
      expect(reparsed, isNotNull);
      expect(reparsed!.targetId, 'm-9');
      expect(reparsed.emoji, '🔥');
    });

    test('typing sentinel is sent as the message body', () async {
      adapter.routes['/api/v1/send'] = {
        'delivered': true,
        'envelope_id': 'e-2',
      };

      final body = const TypingSignal().encode();
      await client.sendMessage(recipient: 'opus', message: body);

      final sent = adapter.lastRequest!.data as Map<String, dynamic>;
      expect(TypingSignal.parse(sent['message'] as String)!.isStart, isTrue);
    });
  });

  group('EditSignal + ReceiptSignal (typed-contract additions)', () {
    test('ReactionSignal carries an optional sender', () {
      final parsed = ReactionSignal.parse(
        const ReactionSignal(targetId: 'm', emoji: '👍', sender: 'chef')
            .encode(),
      );
      expect(parsed!.sender, 'chef');
    });

    test('EditSignal round-trips', () {
      final wire = const EditSignal(targetId: 'm-2', body: 'new text').encode();
      expect(wire.startsWith(EditSignal.prefix), isTrue);
      final back = EditSignal.parse(wire)!;
      expect(back.targetId, 'm-2');
      expect(back.body, 'new text');
      expect(EditSignal.parse('plain'), isNull);
    });

    test('ReceiptSignal round-trips and rejects a bad kind', () {
      final wire =
          const ReceiptSignal(targetId: 'm-3', kind: 'read', sender: 'lumina')
              .encode();
      expect(wire.startsWith(ReceiptSignal.prefix), isTrue);
      final back = ReceiptSignal.parse(wire)!;
      expect(back.kind, 'read');
      expect(back.sender, 'lumina');
      expect(
        ReceiptSignal.parse('__RECEIPT__:{"target_id":"x","kind":"bogus"}'),
        isNull,
      );
    });

    test('displayTextFor drops edit + receipt sentinels', () {
      expect(
        displayTextFor(const EditSignal(targetId: 'm', body: 'x').encode()),
        isNull,
      );
      expect(
        displayTextFor(
          const ReceiptSignal(targetId: 'm', kind: 'read').encode(),
        ),
        isNull,
      );
    });
  });

  group('typed-contract HTTP endpoints', () {
    late _CannedAdapter adapter;
    late SKCommsClient client;

    setUp(() {
      adapter = _CannedAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      client = SKCommsClient(baseUrl: 'http://test.local:9384', dio: dio);
    });

    test('react posts conversation_id/message_id/emoji/op', () async {
      adapter.routes['/api/v1/react'] = {'ok': true};
      final ok = await client.react(
        conversationId: 'lumina',
        messageId: 'm-1',
        emoji: '🔥',
        op: 'add',
      );
      expect(ok, isTrue);
      final sent = adapter.lastRequest!.data as Map<String, dynamic>;
      expect(adapter.lastRequest!.path, '/api/v1/react');
      expect(sent['conversation_id'], 'lumina');
      expect(sent['message_id'], 'm-1');
      expect(sent['emoji'], '🔥');
      expect(sent['op'], 'add');
    });

    test('edit posts message_id/body', () async {
      adapter.routes['/api/v1/edit'] = {'ok': true};
      final ok = await client.edit(messageId: 'm-2', body: 'fixed');
      expect(ok, isTrue);
      final sent = adapter.lastRequest!.data as Map<String, dynamic>;
      expect(adapter.lastRequest!.path, '/api/v1/edit');
      expect(sent['message_id'], 'm-2');
      expect(sent['body'], 'fixed');
    });

    test('receipt posts conversation_id/message_id/kind', () async {
      adapter.routes['/api/v1/receipt'] = {'ok': true};
      final ok = await client.receipt(
        conversationId: 'lumina',
        messageId: 'm-3',
        kind: 'read',
      );
      expect(ok, isTrue);
      final sent = adapter.lastRequest!.data as Map<String, dynamic>;
      expect(adapter.lastRequest!.path, '/api/v1/receipt');
      expect(sent['kind'], 'read');
    });

    test('send carries reply_to_id and thread_id', () async {
      adapter.routes['/api/v1/send'] = {
        'delivered': true,
        'envelope_id': 'e-9',
      };
      await client.sendMessage(
        recipient: 'lumina',
        message: 'a reply',
        inReplyTo: 'm-0',
        threadId: 'thr-1',
      );
      final sent = adapter.lastRequest!.data as Map<String, dynamic>;
      expect(sent['reply_to_id'], 'm-0');
      expect(sent['thread_id'], 'thr-1');
    });
  });
}
