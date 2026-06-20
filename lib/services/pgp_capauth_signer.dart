import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/crypto/pgp_bridge.dart";
import "identity_service.dart";
import "join_service.dart" show SovereignSigner;

/// [SovereignSigner] backed by the app's local PGP identity.
///
/// Reuses the same key material as the CapAuth login flow (loaded by
/// [IdentityService] from secure storage) and the same RSA/SHA-256 signing
/// primitive ([PgpBridge.signAsync]) the app already uses for capauth
/// challenge-response. The private key never leaves the device.
class PgpCapAuthSigner implements SovereignSigner {
  const PgpCapAuthSigner(this._keyPair);

  final PgpKeyPair _keyPair;

  /// The fingerprint (used as the sovereign `identity` in the claim).
  String get identity => _keyPair.fingerprint;

  @override
  Future<String> sign(String claim) =>
      PgpBridge.signAsync(claim, _keyPair.privateKeyPem);
}

/// Resolves a [PgpCapAuthSigner] from the loaded identity keypair, or null when
/// no key has been provisioned yet (user must complete QR login / onboarding).
final sovereignSignerProvider = FutureProvider<PgpCapAuthSigner?>((ref) async {
  final keyPair = await ref.watch(identityKeyPairProvider.future);
  if (keyPair == null) return null;
  return PgpCapAuthSigner(keyPair);
});
