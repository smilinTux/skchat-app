import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/conversation/widgets/quoted_reply.dart';
import 'package:skchat/models/chat_message.dart';
import 'package:skchat/services/pq_conversation_service.dart';

/// Regression tests for coord card 5ac65af5 (HIGH): a reply's quoted "Original
/// message" preview must show the SAME decrypted plaintext the main bubble
/// shows for any OPENABLE replied-to message, and a graceful muted placeholder
/// (never ciphertext, never the raw internal locked string) for a genuinely
/// unopenable one.
///
/// The conversation provider already stores the DECRYPTED plaintext in
/// [ChatMessage.content] (and marks unopenable copies [ChatMessage.pqLocked]);
/// these tests pin that QuotedReply renders from that resolved state instead of
/// re-deriving a sealed value from raw content.
ChatMessage _msg(
  String content, {
  bool locked = false,
  bool outbound = false,
  String? senderName = 'Lumina',
}) =>
    ChatMessage(
      id: 'orig-1',
      peerId: 'lumina@chef.skworld',
      content: content,
      timestamp: DateTime(2026, 7, 25, 9, 0),
      isOutbound: outbound,
      pqLocked: locked,
      senderName: senderName,
    );

Future<List<String>> _pumpPreview(
  WidgetTester tester,
  ChatMessage? original, {
  String? quotedText,
  String? quotedSender,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: QuotedReply(
        original: original,
        quotedText: quotedText,
        quotedSender: quotedSender,
        accent: Colors.blue,
      ),
    ),
  ));
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? '')
      .toList();
}

void main() {
  group('QuotedReply preview (card 5ac65af5)', () {
    testWidgets(
        'reply-to an OWN-OUTBOUND message shows its plaintext, not a lock',
        (tester) async {
      final texts =
          await _pumpPreview(tester, _msg('my earlier note', outbound: true));

      expect(texts, contains('You'));
      expect(texts, contains('my earlier note'));
      // Never the sealed placeholder for an openable original.
      expect(texts, isNot(contains(QuotedReply.sealedPreviewText)));
      expect(
          texts.any((t) => t.contains('Encrypted message')), isFalse);
    });

    testWidgets(
        'reply-to a PEER hybrid-sealed but OPENABLE message shows its plaintext',
        (tester) async {
      // The provider decrypted Lumina\'s hybrid DM: content is the plaintext,
      // pqLocked is false. The quote must show that plaintext, matching the
      // main bubble.
      final texts = await _pumpPreview(
          tester, _msg('decrypted from lumina', outbound: false));

      expect(texts, contains('Lumina'));
      expect(texts, contains('decrypted from lumina'));
      expect(texts, isNot(contains(QuotedReply.sealedPreviewText)));
    });

    testWidgets(
        'reply-to a genuinely-unopenable (pqLocked) message shows a graceful placeholder',
        (tester) async {
      final texts = await _pumpPreview(
        tester,
        _msg(PqConversationService.lockedCantOpenText, locked: true),
      );

      // Graceful muted placeholder, NOT the raw internal "can\'t be opened on
      // this device" string, and NOT blank.
      expect(texts, contains(QuotedReply.sealedPreviewText));
      expect(
        texts.any((t) => t.contains("can't be opened on this device")),
        isFalse,
      );
    });

    testWidgets(
        'a RAW pqdm1: token that reaches the quote un-resolved never renders as ciphertext',
        (tester) async {
      const rawToken = 'pqdm1:x25519-mlkem768:AAAAsealedbytes';
      final texts = await _pumpPreview(tester, _msg(rawToken));

      // Defensive guard: the sealed placeholder, never the raw token.
      expect(texts, contains(QuotedReply.sealedPreviewText));
      expect(texts.any((t) => t.contains('pqdm1:')), isFalse);
    });

    testWidgets('an out-of-window original still shows the muted fallback',
        (tester) async {
      final texts = await _pumpPreview(tester, null);
      expect(texts, contains('Original message'));
    });
  });

  group('embedded quoted snippet (cross-device fix, card 55a028c4)', () {
    testWidgets(
        'an embedded snippet renders WITHOUT the original in the loaded window',
        (tester) async {
      // The viewing device never decrypted the original (original == null:
      // out-of-window). The reply carries the snippet captured at compose time,
      // so the quote still renders that text + sender, not the placeholder.
      final texts = await _pumpPreview(
        tester,
        null,
        quotedText: 'should we deploy tonight?',
        quotedSender: 'Them',
      );

      expect(texts, contains('Them'));
      expect(texts, contains('should we deploy tonight?'));
      expect(texts, isNot(contains('Original message')));
      expect(texts, isNot(contains(QuotedReply.sealedPreviewText)));
    });

    testWidgets(
        'an embedded snippet wins even when the original is a sealed placeholder',
        (tester) async {
      // Original present but pqLocked (this device could not open it). Without
      // the snippet this shows the sealed placeholder; the embedded snippet
      // (captured where it WAS decrypted) takes precedence.
      final texts = await _pumpPreview(
        tester,
        _msg(PqConversationService.lockedCantOpenText, locked: true),
        quotedText: 'the decrypted original',
        quotedSender: 'Them',
      );

      expect(texts, contains('the decrypted original'));
      expect(texts, isNot(contains(QuotedReply.sealedPreviewText)));
    });

    testWidgets('a legacy reply (no snippet) falls back to local resolution',
        (tester) async {
      final texts = await _pumpPreview(
        tester,
        _msg('resolved locally', outbound: true),
        quotedText: null,
      );
      expect(texts, contains('You'));
      expect(texts, contains('resolved locally'));
    });

    testWidgets('an empty/blank snippet falls back to placeholder',
        (tester) async {
      final texts = await _pumpPreview(
        tester,
        null,
        quotedText: '   ',
      );
      // Blank snippet is ignored; with no in-window original -> muted fallback.
      expect(texts, contains('Original message'));
    });
  });

  group('QuotedReply.snippetFor (compose-time capture)', () {
    test('returns a trimmed plaintext snippet for an openable original', () {
      expect(
        QuotedReply.snippetFor(_msg('  hello there  ', outbound: true)),
        'hello there',
      );
    });

    test('truncates to snippetMaxChars', () {
      final long = 'a' * 300;
      final snip = QuotedReply.snippetFor(_msg(long));
      expect(snip!.length, QuotedReply.snippetMaxChars);
    });

    test('returns null for a pqLocked original (never captures placeholder)',
        () {
      expect(
        QuotedReply.snippetFor(
          _msg(PqConversationService.lockedCantOpenText, locked: true),
        ),
        isNull,
      );
    });

    test('returns null for a raw pqdm1: / pqdm2: token', () {
      expect(
        QuotedReply.snippetFor(_msg('pqdm1:x25519-mlkem768:AAAAsealed')),
        isNull,
      );
      expect(
        QuotedReply.snippetFor(_msg('pqdm2:header.slots.ct')),
        isNull,
      );
    });

    test('senderLabelFor labels You/name correctly', () {
      expect(QuotedReply.senderLabelFor(_msg('x', outbound: true)), 'You');
      expect(
        QuotedReply.senderLabelFor(_msg('x', senderName: 'Lumina')),
        'Lumina',
      );
      expect(QuotedReply.senderLabelFor(_msg('x', senderName: null)), 'Them');
    });
  });
}
