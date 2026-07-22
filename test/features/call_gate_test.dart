import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_gate.dart';
import 'package:skchat/services/peer_trust_store.dart';

void main() {
  group('canCall', () {
    test('blocks a red (unverified/TOFU/key-changed) peer', () {
      expect(canCall(PeerTrustTier.red), isFalse);
    });

    test('allows an amber (verified) peer', () {
      expect(canCall(PeerTrustTier.amber), isTrue);
    });
  });
}
