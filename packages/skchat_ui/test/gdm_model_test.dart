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

  group('GuestRinger (G7)', () {
    Conversation parse(Map<String, dynamic> extra) =>
        Conversation.fromJson(<String, dynamic>{
          'peer_id': 'g1',
          'display_name': 'Ops room',
          'last_message': '',
          'mode': 'gdm',
          ...extra,
        });

    test('a quiet room names nobody', () {
      expect(parse({}).ringers, isEmpty);
      expect(parse({}).ringingCaller, isNull);
    });

    test('the caller is named alias-wins, newest first', () {
      final c = parse({
        'ringing': true,
        'ring_ts': 200.0,
        'ringers': [
          {'guest_id': 'g:bob', 'guest_name': 'Bob', 'guest_alias': 'Work Bob', 'ring_ts': 200.0},
          {'guest_id': 'g:alice', 'guest_name': 'Alice', 'ring_ts': 100.0},
        ],
      });
      expect(c.ringers.length, 2);
      expect(c.ringingCaller!.title, 'Work Bob');
      expect(c.ringingCaller!.isUntrustedName, isFalse);
      expect(c.ringers[1].title, 'guest: Alice');
      expect(c.ringers[1].isUntrustedName, isTrue);
    });

    test('an unnamed ring is never given the room name as a person', () {
      final c = parse({'ringing': true, 'ring_ts': 5.0});
      expect(c.ringing, isTrue);
      expect(c.ringingCaller, isNull);
    });

    group('whole-room expiry', () {
      double _epoch(Duration offset) =>
          DateTime.now().add(offset).millisecondsSinceEpoch / 1000;

      test('a room with no schedule reports no expiry', () {
        final c = parse({'mode': 'gdm'});
        expect(c.expiresAt, isNull);
        expect(c.hasGroupExpiry, isFalse);
        expect(c.hasExpired, isFalse);
      });

      test('a future schedule is set but has not run out', () {
        final c = parse({'mode': 'gdm', 'expires_at': _epoch(const Duration(days: 2))});
        expect(c.hasGroupExpiry, isTrue);
        expect(c.hasExpired, isFalse);
      });

      test('a past schedule reads as expired, not as a live countdown', () {
        final c = parse({'mode': 'gdm', 'expires_at': _epoch(const Duration(days: -1))});
        expect(c.hasGroupExpiry, isTrue);
        expect(c.hasExpired, isTrue);
      });

      test('clearExpiry actually clears it (a null copyWith arg cannot)', () {
        final c = parse({'mode': 'gdm', 'expires_at': _epoch(const Duration(days: 1))});
        expect(c.copyWith(expiresAt: null).expiresAt, isNotNull);
        expect(c.copyWith(clearExpiry: true).expiresAt, isNull);
        expect(c.copyWith(clearExpiry: true).hasGroupExpiry, isFalse);
      });
    });
  });
}
