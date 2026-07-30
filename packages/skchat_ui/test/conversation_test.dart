import 'package:flutter_test/flutter_test.dart';
import 'package:skchat_ui/skchat_ui.dart';

final _t = DateTime.parse('2026-07-30T00:00:00.000Z');

void main() {
  test('Conversation round-trips through JSON', () {
    final conv = Conversation(
      peerId: 'lumina',
      displayName: 'Lumina',
      lastMessage: 'hello',
      lastMessageTime: _t,
      isGroup: false,
      unreadCount: 4,
      isAgent: true,
    );
    final restored = Conversation.fromJson(conv.toJsonForTest());
    expect(restored.peerId, 'lumina');
    expect(restored.displayName, 'Lumina');
    expect(restored.lastMessage, 'hello');
    expect(restored.unreadCount, 4);
    expect(restored.isAgent, isTrue);
  });

  test('resolvedSoulColor derives from fingerprint when no explicit color', () {
    final conv = Conversation(
      peerId: 'p1',
      displayName: 'Peer One',
      lastMessage: 'hi',
      lastMessageTime: _t,
      soulFingerprint: 'abc123',
    );
    // Deterministic derivation from SovereignColors.fromFingerprint.
    expect(conv.resolvedSoulColor, SovereignColors.fromFingerprint('abc123'));
  });

  test('resolvedInitials falls back to first letter for a single-word name', () {
    final conv = Conversation(
      peerId: 'p1',
      displayName: 'Lumina',
      lastMessage: '',
      lastMessageTime: _t,
    );
    expect(conv.resolvedInitials, 'L');
  });

  test('displayTextFor drops transport/control envelopes, keeps plain text', () {
    expect(displayTextFor('  hello  '), 'hello');
    expect(displayTextFor('Chat context (recent): x'), isNull);
    expect(displayTextFor('__REACT__:{"emoji":"thumbsup"}'), isNull);
    expect(displayTextFor(''), isNull);
  });

  test('normalizePeerKey collapses schemes and domains to the local part', () {
    expect(normalizePeerKey('did:capauth:lumina@skworld.io'), 'lumina');
    expect(normalizePeerKey('Lumina'), 'lumina');
    expect(normalizePeerKey('lumina@skworld.io'), 'lumina');
  });
}

/// The Conversation model carries `fromJson` but no `toJson`, so this test
/// serializes the fields it round-trips itself (with a non-null timestamp).
extension on Conversation {
  Map<String, dynamic> toJsonForTest() => {
        'peer_id': peerId,
        'display_name': displayName,
        'last_message': lastMessage,
        'last_message_time': lastMessageTime.toIso8601String(),
        'unread_count': unreadCount,
        'is_agent': isAgent,
        'is_group': isGroup,
      };
}
