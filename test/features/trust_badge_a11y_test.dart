import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';
import 'package:skchat/services/peer_trust_store.dart';
import 'package:skchat/services/self_identity.dart';

void main() {
  testWidgets('compact TrustBadge exposes a Semantics label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TrustBadge(tier: SelfTrustTier.red, compact: true),
      ),
    ));
    expect(find.bySemanticsLabel(RegExp('Untrusted')), findsOneWidget);
  });

  test('selfTierForPeer maps peer tiers to badge tiers', () {
    expect(selfTierForPeer(PeerTrustTier.red), SelfTrustTier.red);
    expect(selfTierForPeer(PeerTrustTier.amber), SelfTrustTier.amber);
  });
}
