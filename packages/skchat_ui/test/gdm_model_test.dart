import 'package:flutter_test/flutter_test.dart';
import 'package:skchat_ui/skchat_ui.dart';

/// guest-dm G6: the model half of gdm rendering. One anti-spoof rule
/// (`guestDisplayTitle`) shared by the DM row title, the roster, and message
/// attribution - so no surface can drift into rendering a spoofable name.
void main() {
  group('guestDisplayTitle', () {
    test('operator alias wins and renders like a real contact', () {
      expect(guestDisplayTitle('Bestie', 'Chef'), 'Bestie');
    });

    test('no alias falls back to the prefixed self-name', () {
      expect(guestDisplayTitle(null, 'Alice'), 'guest: Alice');
      expect(guestDisplayTitle('   ', 'Alice'), 'guest: Alice');
    });

    test('a guest cannot pass as a real contact by naming themselves', () {
      expect(guestDisplayTitle(null, 'Chef'), 'guest: Chef');
    });

    test('a nameless guest still gets a title', () {
      expect(guestDisplayTitle(null, null), 'guest: guest');
      expect(guestDisplayTitle(null, '  '), 'guest: guest');
    });
  });

  group('Conversation gdm', () {
    Conversation parse(Map<String, dynamic> extra) =>
        Conversation.fromJson(<String, dynamic>{
          'peer_id': 'g1',
          'display_name': 'Ops room',
          'last_message': 'hi',
          'is_group': true,
          'member_count': 3,
          ...extra,
        });

    test('mode=gdm keeps the conversation under the Guests filter', () {
      final c = parse({'mode': 'gdm'});
      expect(c.isGdm, isTrue);
      // The server drops the flat guest_dm badge on promotion; untrusted people
      // are still in the room, so every guest surface must keep catching it.
      expect(c.isGuestDm, isTrue);
    });

    test('a gdm titles by its own operator-set group name', () {
      final c = parse({'mode': 'gdm'});
      expect(c.guestTitle, 'Ops room');
      expect(c.isUntrustedTitle, isFalse);
    });

    test('a 1:1 guest DM still titles by the alias-wins rule', () {
      final c = parse({'guest_dm': true, 'guest_name': 'Alice'});
      expect(c.isGdm, isFalse);
      expect(c.guestTitle, 'guest: Alice');
      expect(c.isUntrustedTitle, isTrue);

      final aliased = parse({
        'guest_dm': true,
        'guest_name': 'Alice',
        'guest_alias': 'Bestie',
      });
      expect(aliased.guestTitle, 'Bestie');
      expect(aliased.isUntrustedTitle, isFalse);
    });

    test('an ordinary group is untouched', () {
      final c = parse({});
      expect(c.isGdm, isFalse);
      expect(c.isGuestDm, isFalse);
    });
  });

  group('ConversationMember guest fields (G4 payload)', () {
    ConversationMember parse(Map<String, dynamic> extra) =>
        ConversationMember.fromJson(<String, dynamic>{
          'identity_uri': 'guest:alice#fp',
          'display_name': 'Alice',
          ...extra,
        });

    test('a trusted member keeps its real name and no guest styling', () {
      final m = parse({});
      expect(m.isGuest, isFalse);
      expect(m.title, 'Alice');
      expect(m.isUntrustedName, isFalse);
      expect(m.isRevoked, isFalse);
    });

    test('alias-wins applies PER MEMBER', () {
      final m = parse({
        'guest': true,
        'guest_name': 'Alice',
        'guest_alias': 'Bestie',
      });
      expect(m.title, 'Bestie');
      expect(m.isUntrustedName, isFalse);
    });

    test('an unaliased guest member is untrusted and prefixed', () {
      final m = parse({'guest': true, 'guest_name': 'Chef'});
      expect(m.title, 'guest: Chef');
      expect(m.isUntrustedName, isTrue);
    });

    test('a guest with no guest_name falls back to the roster name', () {
      final m = parse({'guest': true});
      expect(m.title, 'guest: Alice');
    });

    test('revoked at either level marks the member revoked', () {
      expect(parse({'guest': true, 'guest_status': 'revoked'}).isRevoked, isTrue);
      expect(
        parse({'guest': true, 'membership_status': 'revoked'}).isRevoked,
        isTrue,
      );
      expect(
        parse({
          'guest': true,
          'guest_status': 'active',
          'membership_status': 'active',
        }).isRevoked,
        isFalse,
      );
    });
  });
}
