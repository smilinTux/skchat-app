/// Guest identity, an ephemeral WebCrypto keypair persisted in localStorage so
/// the SAME shareable link maps to the SAME guest on a return visit.
///
/// Platform seam: the real implementation lives in [guest_identity_web.dart]
/// (uses `window.crypto.subtle` ECDSA P-256 + `window.localStorage`). On
/// non-web targets the stub keeps an in-memory keypair so the app still
/// compiles and unit tests can run with a [FakeGuestIdentity].
library;

import 'guest_identity_stub.dart'
    if (dart.library.html) 'guest_identity_web.dart' as impl;

/// A guest's locally-held identity material.
class GuestKeypair {
  const GuestKeypair({required this.publicKeyB64, required this.fingerprint});

  /// Base64 SPKI export of the public key, sent to the server at join time.
  /// The server fingerprints this to derive the stable `guest:<name>#<fp>` id.
  final String publicKeyB64;

  /// Local convenience fingerprint (first 16 hex of SHA-256 over the SPKI).
  /// Mirrors the server's derivation so the UI can show the same short id.
  final String fingerprint;
}

/// Generates / persists the guest keypair and signs messages with it.
abstract class GuestIdentity {
  /// Load the persisted keypair, generating + persisting one on first use.
  /// Returns the public key material the join call needs.
  Future<GuestKeypair> ensure();

  /// True if a keypair is already cached (returning guest -> can auto-join).
  Future<bool> hasCached();

  /// Sign [data] (the canonical message string) -> base64 detached signature.
  Future<String> sign(String data);

  /// Wipe the cached keypair (e.g. "forget me" / link revoked).
  Future<void> clear();
}

/// The platform [GuestIdentity] (real WebCrypto on web, in-memory stub else).
GuestIdentity createGuestIdentity() => impl.createGuestIdentity();
