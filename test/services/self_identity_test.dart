import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/self_identity.dart";

void main() {
  group("SelfIdentity", () {
    test("guest factory is red, not operator, carries no pgp", () {
      final s = SelfIdentity.guest(
        displayName: "Guest-Otter42",
        fingerprint: "0011223344556677",
      );
      expect(s.tier, SelfTrustTier.red);
      expect(s.isOperator, isFalse);
      expect(s.id, "0011223344556677");
      expect(s.pgpKeyId, "");
      expect(s.pgpKeySize, 0);
      expect(s.degraded, isFalse);
    });

    test("operator factory is green, operator, carries pgp", () {
      final s = SelfIdentity.operator__(
        displayName: "Lumina",
        fingerprint: "ABCDEF0123456789",
        pgpKeyId: "23456789",
        pgpKeySize: 4096,
      );
      expect(s.tier, SelfTrustTier.green);
      expect(s.isOperator, isTrue);
      expect(s.pgpKeyId, "23456789");
    });

    test("degraded flag propagates and equality holds", () {
      final a = SelfIdentity.guest(
        displayName: "x", fingerprint: "y", degraded: true);
      final b = SelfIdentity.guest(
        displayName: "x", fingerprint: "y", degraded: true);
      expect(a.degraded, isTrue);
      expect(a, equals(b));
      expect(a.copyWith(displayName: "z").displayName, "z");
    });
  });
}
