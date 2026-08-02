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

Future<List<String>> _pumpPreview(WidgetTester tester, ChatMessage? original) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: QuotedReply(original: original, accent: Colors.blue),
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
}
