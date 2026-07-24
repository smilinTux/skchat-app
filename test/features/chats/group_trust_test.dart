import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/group_trust.dart';
import 'package:skchat/services/peer_trust_store.dart';

void main() {
  group('foldGroupTier', () {
    test('no keyed members -> null (no badge)', () {
      expect(foldGroupTier([]), isNull);
      expect(foldGroupTier([null, null]), isNull);
      expect(
        foldGroupTier([PeerTrustTier.unverifiable, PeerTrustTier.unverifiable]),
        isNull,
      );
    });

    test('any keyed-but-unverified member -> red', () {
      expect(
        foldGroupTier([PeerTrustTier.amber, PeerTrustTier.red]),
        PeerTrustTier.red,
      );
      expect(
        foldGroupTier([PeerTrustTier.unverifiable, PeerTrustTier.red]),
        PeerTrustTier.red,
      );
    });

    test('all keyed members verified -> amber', () {
      expect(
        foldGroupTier([PeerTrustTier.amber, PeerTrustTier.amber]),
        PeerTrustTier.amber,
      );
      expect(
        foldGroupTier([PeerTrustTier.unverifiable, PeerTrustTier.amber]),
        PeerTrustTier.amber,
      );
    });

    test('a still-loading (null) tier does not force a badge on its own', () {
      expect(foldGroupTier([null, PeerTrustTier.unverifiable]), isNull);
      expect(foldGroupTier([null, PeerTrustTier.amber]), PeerTrustTier.amber);
    });
  });
}
