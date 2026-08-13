import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/guest/guest_link.dart';

/// The bug these pin: skchat has minted `/app/#/g/<token>&k=<secret>` since
/// 2026-07-15 (signed invites, server-side only). GoRouter captures the whole
/// `<token>&k=<secret>` as `:token`, so the app sent the JWT with `&k=...`
/// glued on. Every preview and join then failed signature verification, and
/// the server's deliberately generic "invalid or expired invite" surfaced to
/// the guest as "expired" - which points at TTLs instead of at the link.
void main() {
  // A JWT shape close enough to the real thing to catch naive splitting: real
  // tokens carry '.', '-' and '_', and the payload can be ~1.7kB.
  const jwt = 'FAKEhdr-aaa.FAKEpayload-bbb_ccc-ddd.FAKEsig-eee_fff-ggg';
  // Synthetic on purpose: never paste a value from a real mint into a test.
  const secret = 'FAKE-fragment-secret-for-tests-0000000000';

  group('GuestLink.parse', () {
    test('a signed-invite link yields the bare JWT, not the JWT plus &k', () {
      final link = GuestLink.parse('$jwt&k=$secret');

      // The whole bug in one assertion: the token must not carry the suffix.
      expect(link.token, jwt);
      expect(link.token.contains('&'), isFalse);
      expect(link.fragmentSecret, secret);
    });

    test('a classic link with no fragment secret is unchanged', () {
      final link = GuestLink.parse(jwt);
      expect(link.token, jwt);
      expect(link.fragmentSecret, isNull);
    });

    test('a JWT is never truncated at its own punctuation', () {
      // Guards against splitting on '.', '-' or '_' instead of '&'.
      expect(GuestLink.parse(jwt).token, jwt);
      expect(GuestLink.parse('$jwt&k=$secret').token.split('.').length, 3);
    });

    test('an empty or whitespace token stays empty so the router can reject it', () {
      expect(GuestLink.parse('').isEmpty, isTrue);
      expect(GuestLink.parse('   ').isEmpty, isTrue);
    });

    group('degrades toward letting the guest IN', () {
      // Over-trimming locks a guest out; ignoring an unknown parameter does
      // not. These pin that bias deliberately.

      test('a stray trailing & still yields a usable token', () {
        final link = GuestLink.parse('$jwt&');
        expect(link.token, jwt);
        expect(link.fragmentSecret, isNull);
      });

      test('an empty k= is treated as absent, not as an empty secret', () {
        final link = GuestLink.parse('$jwt&k=');
        expect(link.token, jwt);
        expect(link.fragmentSecret, isNull);
      });

      test('unknown extra params do not corrupt the token', () {
        final link = GuestLink.parse('$jwt&a=1&k=$secret&z=9');
        expect(link.token, jwt);
        expect(link.fragmentSecret, secret);
      });

      test('k in a later position is still found', () {
        final link = GuestLink.parse('$jwt&other=x&k=$secret');
        expect(link.fragmentSecret, secret);
      });
    });
  });
}
