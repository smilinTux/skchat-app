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
