/// Guest identity, a persisted asymmetric keypair so the SAME shareable link
/// maps to the SAME guest on a return visit.
///
/// Platform seam: on web the real implementation lives in
/// [guest_identity_web.dart] (uses `window.crypto.subtle` ECDSA P-256 +
/// `window.localStorage`). On native targets the real implementation lives in
/// [guest_identity_io.dart] (`NativeGuestIdentity`, a persistent on-disk
/// keystore). The stub remains only as the compile-time fallback for a
/// target that has neither `dart:io` nor `dart:html`, and backs unit tests
/// that use a [FakeGuestIdentity] instead of the real factory.
library;

import 'guest_identity_stub.dart'
    if (dart.library.io) 'guest_identity_io.dart'
    if (dart.library.html) 'guest_identity_web.dart'
    as impl;

/// A guest's locally-held identity material.
class GuestKeypair {
  const GuestKeypair({
    required this.publicKeyB64,
    required this.fingerprint,
    this.degraded = false,
  });

  /// Base64 SPKI export of the public key, sent to the server at join time.
  /// The server fingerprints this to derive the stable `guest:<name>#<fp>` id.
  final String publicKeyB64;

  /// Local convenience fingerprint (first 16 hex of SHA-256 over the SPKI).
  /// Mirrors the server's derivation so the UI can show the same short id.
  final String fingerprint;

  /// True when this keypair could not be read from or written to persistent
  /// storage (for example a privacy browser blocking localStorage/WebCrypto)
  /// and is instead a unique in-memory fallback that will NOT survive a
  /// reload. The UI can use this to warn the user.
  final bool degraded;
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

/// The platform [GuestIdentity]: real WebCrypto on web, a real persistent
/// keystore on native, and the in-memory stub only when neither is compiled.
GuestIdentity createGuestIdentity() => impl.createGuestIdentity();
