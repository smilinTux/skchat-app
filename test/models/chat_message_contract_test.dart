import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/models/chat_message.dart';

void main() {
  group('typed-message contract parsing', () {
    test('fromJson reads the full contract shape', () {
      final m = ChatMessage.fromJson({
        'id': 'm-1',
        'conversation_id': 'lumina',
        'sender': 'capauth:chef@skworld.io',
        'content_type': 'application/skchat.location+json',
        'body': 'pin at 40.7,-74.0',
        'rich': {'geo': '40.7,-74.0'},
        'ts': '2026-06-23T12:00:00Z',
        'reply_to_id': 'm-0',
        'thread_id': 'thr-7',
        'edited_at': '2026-06-23T12:05:00Z',
        'edit_history': ['old body'],
        'reactions': {
          '❤️': ['chef', 'lumina'],
          '🔥': ['chef'],
        },
        'receipts': {
          'delivered': ['lumina'],
          'read': ['lumina'],
        },
      });

      expect(m.id, 'm-1');
      expect(m.conversationId, 'lumina');
      expect(m.contentType, 'application/skchat.location+json');
      expect(m.content, 'pin at 40.7,-74.0');
      expect(m.rich?['geo'], '40.7,-74.0');
      expect(m.replyToId, 'm-0');
      expect(m.threadId, 'thr-7');
      expect(m.hasThread, isTrue);
      expect(m.isEdited, isTrue);
      expect(m.editHistory, ['old body']);
      expect(m.reactions['❤️'], 2);
      expect(m.reactions['🔥'], 1);
      expect(m.receiptsDelivered, ['lumina']);
      expect(m.receiptsRead, ['lumina']);
    });

    test('fromJson tolerates the legacy {emoji: count} reactions shape', () {
      final m = ChatMessage.fromJson({
        'id': 'm-2',
        'body': 'legacy',
        'reactions': {'👍': 3},
      });
      expect(m.reactions['👍'], 3);
    });

    test('content_type defaults to text when absent', () {
      final m = ChatMessage.fromJson({'id': 'm-3', 'body': 'plain'});
      expect(m.contentType, 'text');
      expect(m.isEdited, isFalse);
      expect(m.hasThread, isFalse);
    });

    test('toJson round-trips the contract fields', () {
      final m = ChatMessage(
        id: 'm-4',
        peerId: 'lumina',
        content: 'hello',
        timestamp: DateTime.utc(2026, 6, 23, 12),
        isOutbound: true,
        contentType: 'markdown',
        replyToId: 'm-3',
        threadId: 'thr-1',
        reactionSenders: {
          '🎉': ['me'],
        },
        receiptsRead: ['lumina'],
      );
      final j = m.toJson();
      expect(j['content_type'], 'markdown');
      expect(j['body'], 'hello');
      expect(j['reply_to_id'], 'm-3');
      expect(j['thread_id'], 'thr-1');
      expect((j['reactions'] as Map)['🎉'], ['me']);
      expect((j['receipts'] as Map)['read'], ['lumina']);

      final back = ChatMessage.fromJson(j);
      expect(back.contentType, 'markdown');
      expect(back.reactions['🎉'], 1);
      expect(back.receiptsRead, ['lumina']);
    });
  });

  group('denormalized quoted-reply snippet (card 55a028c4)', () {
    test('toJson/fromJson round-trip WITH the quoted-snippet fields', () {
      final m = ChatMessage(
        id: 'reply-1',
        peerId: 'lumina',
        content: 'agreed, ship it',
        timestamp: DateTime.utc(2026, 7, 18, 9),
        isOutbound: true,
        replyToId: 'orig-1',
        quotedText: 'should we deploy tonight?',
        quotedSender: 'Them',
        quotedId: 'orig-1',
      );

      final j = m.toJson();
      expect(j['quoted_text'], 'should we deploy tonight?');
      expect(j['quoted_sender'], 'Them');
      expect(j['quoted_id'], 'orig-1');

      final back = ChatMessage.fromJson(j);
      expect(back.quotedText, 'should we deploy tonight?');
      expect(back.quotedSender, 'Them');
      expect(back.quotedId, 'orig-1');
    });

    test('toJson/fromJson round-trip WITHOUT the quoted-snippet fields (legacy)',
        () {
      final m = ChatMessage(
        id: 'reply-legacy',
        peerId: 'lumina',
        content: 'plain reply',
        timestamp: DateTime.utc(2026, 7, 18, 9),
        isOutbound: true,
        replyToId: 'orig-1',
      );

      final j = m.toJson();
      // Emitted as null (backward compatible), and a legacy JSON that omits the
      // keys entirely hydrates back to null without error.
      expect(j['quoted_text'], isNull);
      expect(j.containsKey('quoted_text'), isTrue);

      final legacyJson = {
        'id': 'reply-legacy',
        'body': 'plain reply',
        'reply_to_id': 'orig-1',
      };
      final back = ChatMessage.fromJson(legacyJson);
      expect(back.quotedText, isNull);
      expect(back.quotedSender, isNull);
      expect(back.quotedId, isNull);
      expect(back.replyToId, 'orig-1');
    });

    test('copyWith carries the quoted-snippet fields', () {
      final base = ChatMessage(
        id: 'r',
        peerId: 'p',
        content: 'x',
        timestamp: DateTime.utc(2026),
        isOutbound: true,
      );
      final quoted = base.copyWith(
        quotedText: 'snippet',
        quotedSender: 'You',
        quotedId: 'orig-9',
      );
      expect(quoted.quotedText, 'snippet');
      expect(quoted.quotedSender, 'You');
      expect(quoted.quotedId, 'orig-9');
      // Unset copyWith preserves them.
      final same = quoted.copyWith(content: 'y');
      expect(same.quotedText, 'snippet');
      expect(same.quotedId, 'orig-9');
    });
  });

  group('reaction helpers', () {
    test('reactedBy reflects per-sender membership', () {
      final m = ChatMessage(
        id: 'm',
        peerId: 'p',
        content: 'x',
        timestamp: DateTime(2026),
        isOutbound: false,
        reactionSenders: {
          '❤️': ['me', 'lumina'],
        },
      );
      expect(m.reactedBy('❤️', 'me'), isTrue);
      expect(m.reactedBy('❤️', 'jarvis'), isFalse);
      expect(m.reactedBy('🔥', 'me'), isFalse);
    });
  });
}
