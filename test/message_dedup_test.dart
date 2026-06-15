import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/conversation/message_dedup.dart';
import 'package:skchat/models/chat_message.dart';

ChatMessage m(String id, String content, {required bool out, DateTime? ts}) =>
    ChatMessage(
      id: id,
      peerId: 'lumina',
      content: content,
      timestamp: ts ?? DateTime(2026, 1, 1, 12),
      isOutbound: out,
    );

void main() {
  test('optimistic + history copy of same outbound message collapse to one outbound', () {
    // Optimistic: client temp id + local time. History: server id + UTC time.
    final result = dedupForDisplay([
      m('1718400000000', 'hello lumina', out: true, ts: DateTime(2026, 1, 1, 8)),
      m('chef@skworld.io_1718400000111', 'hello lumina', out: true, ts: DateTime.utc(2026, 1, 1, 12)),
    ]);
    expect(result.length, 1);
    expect(result.first.isOutbound, isTrue);
  });

  test('operator message wrongly rendered inbound collapses, keeping outbound', () {
    final result = dedupForDisplay([
      m('a', 'on the right please', out: false), // legacy green inbound copy
      m('b', 'on the right please', out: true), // correct outbound
    ]);
    expect(result.length, 1);
    expect(result.first.isOutbound, isTrue, reason: 'outbound copy must win');
  });

  test('duplicate agent reply (two ids, same text) collapses to one inbound', () {
    final result = dedupForDisplay([
      m('lumina_1', 'Got it, single bubble.', out: false),
      m('lumina_2', 'Got it, single bubble.', out: false),
    ]);
    expect(result.length, 1);
    expect(result.first.isOutbound, isFalse);
  });

  test('distinct replies are preserved', () {
    final result = dedupForDisplay([
      m('1', 'hi there', out: false),
      m('2', 'how can I help?', out: false),
      m('3', 'hi there', out: true), // operator also said "hi there"
    ]);
    // The two inbound distinct texts stay; the outbound "hi there" collapses
    // with the inbound "hi there" (content match) and outbound wins.
    expect(result.map((x) => x.content).toList(), ['hi there', 'how can I help?']);
    expect(result.first.isOutbound, isTrue);
  });
}
