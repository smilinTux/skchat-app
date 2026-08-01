import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/conversation/message_dedup.dart';
import 'package:skchat/models/chat_message.dart';

ChatMessage m(
  String id,
  String content, {
  required bool out,
  DateTime? ts,
  bool locked = false,
}) =>
    ChatMessage(
      id: id,
      peerId: 'lumina',
      content: content,
      timestamp: ts ?? DateTime(2026, 1, 1, 12),
      isOutbound: out,
      pqLocked: locked,
    );

void main() {
  test(
    'optimistic + history copy of same outbound message collapse to one outbound',
    () {
      // The optimistic (client temp id + local now) and the daemon `history` copy
      // (server id + UTC) of the SAME send are the same instant, so their absolute
      // difference is only the send-to-persist latency (a second or two). They
      // must still reconcile to a single outbound bubble.
      final result = dedupForDisplay([
        m(
          '1718400000000',
          'hello lumina',
          out: true,
          ts: DateTime.utc(2026, 1, 1, 12, 0, 0),
        ),
        m(
          'chef@skworld.io_1718400000111',
          'hello lumina',
          out: true,
          ts: DateTime.utc(2026, 1, 1, 12, 0, 1),
        ),
      ]);
      expect(result.length, 1);
      expect(result.first.isOutbound, isTrue);
    },
  );

  test('identical text sent far apart in time stays as TWO distinct bubbles', () {
    // Regression: Chef re-tests with the same word ("hello5") weeks apart. The
    // just-sent copy must NOT collapse into the days-old copy of the same text —
    // that erased the newest message from the thread while the conversation-list
    // overview (updated directly) still showed it. Two real messages -> two
    // bubbles, both outbound.
    final result = dedupForDisplay([
      m('old', 'hello5', out: true, ts: DateTime.utc(2026, 7, 5, 13, 52)),
      m('new', 'hello5', out: true, ts: DateTime.utc(2026, 7, 31, 20, 44)),
    ]);
    expect(result.length, 2, reason: 'a 26-day-apart re-send is a new message');
    expect(result.every((x) => x.isOutbound), isTrue);
  });

  test('same content just outside the reconcile window is not collapsed', () {
    // A genuine re-send minutes later is a distinct message, not the
    // optimistic/server pair of one send (which is seconds apart).
    final result = dedupForDisplay([
      m('a', 'ok', out: true, ts: DateTime.utc(2026, 1, 1, 12, 0, 0)),
      m('b', 'ok', out: true, ts: DateTime.utc(2026, 1, 1, 12, 5, 0)),
    ]);
    expect(result.length, 2);
  });

  test(
    'operator message wrongly rendered inbound collapses, keeping outbound',
    () {
      final result = dedupForDisplay([
        m('a', 'on the right please', out: false), // legacy green inbound copy
        m('b', 'on the right please', out: true), // correct outbound
      ]);
      expect(result.length, 1);
      expect(result.first.isOutbound, isTrue, reason: 'outbound copy must win');
    },
  );

  test(
    'duplicate agent reply (two ids, same text) collapses to one inbound',
    () {
      final result = dedupForDisplay([
        m('lumina_1', 'Got it, single bubble.', out: false),
        m('lumina_2', 'Got it, single bubble.', out: false),
      ]);
      expect(result.length, 1);
      expect(result.first.isOutbound, isFalse);
    },
  );

  test(
    'CARD E: two distinct LOCKED replies (same placeholder) both render',
    () {
      // On the web/PWA leg, a hybrid-sealed reply this device can't open renders
      // as a locked placeholder with IDENTICAL text for every such reply. They
      // MUST NOT collapse (they are distinct replies from Lumina); otherwise she
      // looks silent even though she replied N times.
      const locked = "🔐 Encrypted message (can't be opened on this device)";
      final result = dedupForDisplay([
        m('r1', locked, out: false, ts: DateTime.utc(2026, 1, 1, 12, 0, 0),
            locked: true),
        m('r2', locked, out: false, ts: DateTime.utc(2026, 1, 1, 12, 0, 5),
            locked: true),
      ]);
      expect(result.length, 2, reason: 'two distinct sealed replies, by id');
    },
  );

  test('CARD E: the same locked reply id still folds (idempotent re-poll)', () {
    const locked = "🔐 Encrypted message (can't be opened on this device)";
    final result = dedupForDisplay([
      m('r1', locked, out: false, locked: true),
      m('r1', locked, out: false, locked: true),
    ]);
    expect(result.length, 1, reason: 'same id → one bubble');
  });

  test('distinct replies are preserved', () {
    final result = dedupForDisplay([
      m('1', 'hi there', out: false),
      m('2', 'how can I help?', out: false),
      m('3', 'hi there', out: true), // operator also said "hi there"
    ]);
    // The two inbound distinct texts stay; the outbound "hi there" collapses
    // with the inbound "hi there" (content match) and outbound wins.
    expect(result.map((x) => x.content).toList(), [
      'hi there',
      'how can I help?',
    ]);
    expect(result.first.isOutbound, isTrue);
  });
}
