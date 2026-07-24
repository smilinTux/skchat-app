import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/models/conversation.dart';

void main() {
  group('ConversationMember.fromJson', () {
    test('parses identity, name, and soul_fingerprint', () {
      final m = ConversationMember.fromJson({
        'identity_uri': 'capauth:lumina@skworld.io',
        'display_name': 'Lumina',
        'soul_fingerprint': '02BC0EB3CAD31DB691A753C70C5629AB893F9746',
      });
      expect(m.identityUri, 'capauth:lumina@skworld.io');
      expect(m.displayName, 'Lumina');
      expect(m.soulFingerprint, '02BC0EB3CAD31DB691A753C70C5629AB893F9746');
    });

    test('reads the fingerprint alias when soul_fingerprint absent', () {
      final m = ConversationMember.fromJson({
        'identity_uri': 'steward@skworld.io',
        'display_name': 'Steward',
        'fingerprint': '4E06A71935D1DF1FB9848112D8634AB3E7B55236',
      });
      expect(m.soulFingerprint, '4E06A71935D1DF1FB9848112D8634AB3E7B55236');
    });

    test('missing fields default to empty / null', () {
      final m = ConversationMember.fromJson({});
      expect(m.identityUri, '');
      expect(m.displayName, '');
      expect(m.soulFingerprint, isNull);
    });
  });

  group('Conversation.members', () {
    test('defaults to empty when no participants key', () {
      final c = Conversation.fromJson({
        'peer_id': 'steward@skworld.io',
        'display_name': 'Steward',
      });
      expect(c.members, isEmpty);
    });

    test('parses group participants into members', () {
      final c = Conversation.fromJson({
        'peer_id': 'g-1',
        'display_name': 'Penguins',
        'is_group': true,
        'member_count': 2,
        'participants': [
          {
            'identity_uri': 'capauth:lumina@skworld.io',
            'display_name': 'Lumina',
            'soul_fingerprint': 'AAAA1111',
          },
          {
            'identity_uri': 'steward@skworld.io',
            'display_name': 'Steward',
            'fingerprint': 'BBBB2222',
          },
        ],
      });
      expect(c.isGroup, isTrue);
      expect(c.members, hasLength(2));
      expect(c.members[0].displayName, 'Lumina');
      expect(c.members[0].soulFingerprint, 'AAAA1111');
      expect(c.members[1].soulFingerprint, 'BBBB2222');
    });

    test('copyWith preserves members', () {
      final c = Conversation.fromJson({
        'peer_id': 'g-1',
        'display_name': 'Penguins',
        'is_group': true,
        'participants': [
          {'identity_uri': 'a@x', 'display_name': 'A', 'soul_fingerprint': 'FP'},
        ],
      });
      final c2 = c.copyWith(unreadCount: 3);
      expect(c2.members, hasLength(1));
      expect(c2.members.first.soulFingerprint, 'FP');
    });
  });
}
