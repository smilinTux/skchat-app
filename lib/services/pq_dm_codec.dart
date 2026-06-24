import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// PqDmCodec — Dart mirror of `skcomms/src/skcomms/pqdm.py` (PQC-MIGRATION Q5).
///
/// Byte-for-byte interoperable with the Python daemon's hybrid DM sealing so a
/// blob this codec seals can be opened by `pqdm.py` (and `ChatCrypto` / Q3) and
/// vice-versa. The hybrid KEM is `x25519-mlkem768` via [sk_pqc] (web = noble,
/// native = liboqs); the wrap is HKDF-SHA256 + AES-256-GCM, exactly as in
/// `pqdm.py`.
///
/// Wire contract (the interop gate — MUST NOT drift from pqdm.py):
///
/// ```
/// sealed = ct(1120) ‖ nonce(12) ‖ AES-256-GCM(body)          # body + 16B tag
/// token  = "pqdm1:" + "x25519-mlkem768:" + base64(sealed)    # stored in content
/// ss        = hybrid_encap(prekey_pub)                         # X25519 ‖ ML-KEM-768
/// wrap_key  = HKDF-SHA256(ss, salt=b"", info=_INFO_WRAP ‖ b"|" ‖ aad)
/// aad       = downgrade_lock_aad(suite, sender, recipient)     # canonical JSON
/// ```
///
/// The KEM ciphertext is the `pqkem` 1120-byte `X25519_eph_pub(32) ‖ ML-KEM-ct
/// (1088)` and the 32-byte shared secret is `HKDF(X25519_ss ‖ ML-KEM_ss,
/// info="sk_pqc/x25519-mlkem768/v1")` — identical on both sides because both use
/// the same `sk_pqc` combiner / pqkem default `info`.
class PqDmCodec {
  PqDmCodec({HybridKem? kem}) : _kem = kem ?? HybridKemImpl();

  final HybridKem _kem;

  // ── Interop constants (pinned to pqdm.py / pqkem.py / crypto.py) ───────────

  /// Hybrid KEM suite id (matches `pqdm.HYBRID_SUITE` / `pqkem.SUITE_ID`).
  static const String hybridSuite = 'x25519-mlkem768';

  /// Classical fallback suite id (matches `pqdm.CLASSICAL_SUITE`).
  static const String classicalSuite = 'x25519-pgp-wrap-v1';

  /// Wire scheme prefix for a hybrid-sealed token (matches
  /// `skcomms.crypto.PQDM_SCHEME`).
  static const String pqdmScheme = 'pqdm1:';

  /// HKDF domain-separation label for the wrap key (matches `pqdm._INFO_WRAP`).
  static final Uint8List _infoWrap =
      Uint8List.fromList(utf8.encode('skcomms/pqdm/wrap/v1'));

  static const int _ciphertextLen = 1120; // pqkem.CIPHERTEXT_LEN
  static const int _publicKeyLen = 1216; // pqkem.PUBLIC_KEY_LEN
  static const int _privateKeyLen = 2432; // pqkem.PRIVATE_KEY_LEN
  static const int _nonceLen = 12; // pqdm._WRAP_NONCE_LEN
  static const int _tagLen = 16; // pqdm._AESGCM_TAG_LEN
  static const int _sealedMinLen = _ciphertextLen + _nonceLen + _tagLen;

  // ── AAD (downgrade-lock) — mirrors pqdm.downgrade_lock_aad ─────────────────

  /// Canonical AEAD AAD binding the negotiated suite + parties into the
  /// transcript. MUST match `pqdm.downgrade_lock_aad` byte-for-byte:
  /// `json.dumps({...}, sort_keys=True, separators=(",", ":"))` UTF-8 + extra.
  static Uint8List downgradeLockAad(
    String negotiatedSuite, {
    String sender = '',
    String recipient = '',
    List<int>? extra,
  }) {
    // Python: sort_keys=True, separators=(",", ":"). Keys sorted:
    // negotiated_suite, recipient, sender, v.
    final head = '{'
        '"negotiated_suite":${_jsonStr(negotiatedSuite)},'
        '"recipient":${_jsonStr(recipient)},'
        '"sender":${_jsonStr(sender)},'
        '"v":1'
        '}';
    final headBytes = utf8.encode(head);
    if (extra == null || extra.isEmpty) {
      return Uint8List.fromList(headBytes);
    }
    return Uint8List.fromList([...headBytes, ...extra]);
  }

  /// JSON-encode a string exactly like Python's `json.dumps` (compact) — used
  /// for the AAD so the bytes are identical across impls. `dart:convert`'s
  /// `jsonEncode` of a String produces the same escaping for the inputs we use
  /// (identity URIs / suite ids: ASCII, no control chars).
  static String _jsonStr(String s) => jsonEncode(s);

  // ── Wrap-key derivation — mirrors pqdm._wrap_key ──────────────────────────

  /// `HKDF-SHA256(shared, salt=b"", info=_INFO_WRAP ‖ b"|" ‖ aad, L=32)`.
  Future<Uint8List> _wrapKey(Uint8List shared, Uint8List aad) async {
    final info = Uint8List(_infoWrap.length + 1 + aad.length)
      ..setAll(0, _infoWrap)
      ..[_infoWrap.length] = 0x7c /* '|' */
      ..setAll(_infoWrap.length + 1, aad);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: Uint8List(0), // salt=b"" (cryptography calls the HKDF salt `nonce`)
      info: info,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  // ── Seal — mirrors pqdm.seal + crypto.encrypt_payload_hybrid token wrap ────

  /// Hybrid-seal [plaintext] to the recipient's 1216-byte [hybridPublicKey] and
  /// return the `pqdm1:x25519-mlkem768:<base64>` token (what goes in `content`).
  ///
  /// Encapsulates to the prekey, derives the AES-256 wrap key, AES-256-GCM-seals
  /// the body with the downgrade-lock AAD, and emits `ct ‖ nonce ‖ aesgcm(body)`.
  Future<String> sealToken(
    Uint8List plaintext,
    Uint8List hybridPublicKey, {
    String sender = '',
    String recipient = '',
    Uint8List? nonceOverride, // tests only — pin the nonce for vectors
  }) async {
    if (hybridPublicKey.length != _publicKeyLen) {
      throw SkPqcError(
        'hybrid public key must be $_publicKeyLen bytes, '
        'got ${hybridPublicKey.length}',
      );
    }
    final sealed = await sealRaw(
      plaintext,
      hybridPublicKey,
      sender: sender,
      recipient: recipient,
      nonceOverride: nonceOverride,
    );
    return '$pqdmScheme$hybridSuite:${base64.encode(sealed)}';
  }

  /// Raw sealed blob `ct(1120) ‖ nonce(12) ‖ aesgcm(body)` (pre-token), so tests
  /// can compare against the Python `pqdm.seal` output directly.
  Future<Uint8List> sealRaw(
    Uint8List plaintext,
    Uint8List hybridPublicKey, {
    String sender = '',
    String recipient = '',
    Uint8List? nonceOverride,
  }) async {
    final aad = downgradeLockAad(
      hybridSuite,
      sender: sender,
      recipient: recipient,
    );
    final enc = await _kem.encapsulate(hybridPublicKey);
    if (enc.ciphertext.length != _ciphertextLen) {
      throw SkPqcError(
        'KEM ciphertext must be $_ciphertextLen bytes, '
        'got ${enc.ciphertext.length}',
      );
    }
    final wrapKey = await _wrapKey(enc.sharedSecret, aad);
    final nonce = nonceOverride ?? _randomNonce();
    if (nonce.length != _nonceLen) {
      throw SkPqcError('nonce must be $_nonceLen bytes, got ${nonce.length}');
    }
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(
      plaintext,
      secretKey: SecretKey(wrapKey),
      nonce: nonce,
      aad: aad,
    );
    // cryptography returns cipherText + a separate MAC; pqdm.py / pyca appends
    // the 16-byte tag to the ciphertext. Reassemble: ct ‖ nonce ‖ (body ‖ tag).
    final body = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    final out = Uint8List(enc.ciphertext.length + nonce.length + body.length)
      ..setAll(0, enc.ciphertext)
      ..setAll(enc.ciphertext.length, nonce)
      ..setAll(enc.ciphertext.length + nonce.length, body);
    return out;
  }

  // ── Open — mirrors pqdm.open_sealed + crypto.decrypt_payload_hybrid ────────

  /// Detect whether [content] carries a hybrid-sealed token.
  static bool isHybridToken(String content) => content.startsWith(pqdmScheme);

  /// Open a `pqdm1:`-prefixed token with this device's [hybridPrivateKey] and
  /// return the plaintext. The expected suite is read from the token, so a
  /// stripped/downgraded blob fails to authenticate (downgrade-lock).
  ///
  /// Throws [DowngradeDetected] on AEAD failure (wrong key / tamper / suite
  /// mismatch), [SkPqcError] on malformed input.
  Future<Uint8List> openToken(
    String token,
    Uint8List hybridPrivateKey, {
    String sender = '',
    String recipient = '',
  }) async {
    if (!token.startsWith(pqdmScheme)) {
      throw const SkPqcError('not a hybrid-sealed (pqdm1:) token');
    }
    final rest = token.substring(pqdmScheme.length);
    final colon = rest.indexOf(':');
    if (colon < 0) {
      throw const SkPqcError('malformed pqdm token (missing suite separator)');
    }
    final suite = rest.substring(0, colon);
    final b64 = rest.substring(colon + 1);
    final Uint8List sealed;
    try {
      sealed = base64.decode(b64);
    } catch (e) {
      throw SkPqcError('pqdm token base64 invalid: $e');
    }
    return openRaw(
      sealed,
      hybridPrivateKey,
      sender: sender,
      recipient: recipient,
      expectedSuite: suite,
    );
  }

  /// Open a raw `ct ‖ nonce ‖ aesgcm(body)` blob (no token prefix).
  Future<Uint8List> openRaw(
    Uint8List sealed,
    Uint8List hybridPrivateKey, {
    String sender = '',
    String recipient = '',
    String expectedSuite = hybridSuite,
  }) async {
    if (sealed.length < _sealedMinLen) {
      throw SkPqcError(
        'sealed blob must be >= $_sealedMinLen bytes, got ${sealed.length}',
      );
    }
    if (hybridPrivateKey.length != _privateKeyLen) {
      throw SkPqcError(
        'hybrid private key must be $_privateKeyLen bytes, '
        'got ${hybridPrivateKey.length}',
      );
    }
    final ct = Uint8List.sublistView(sealed, 0, _ciphertextLen);
    final nonce =
        Uint8List.sublistView(sealed, _ciphertextLen, _ciphertextLen + _nonceLen);
    final body = Uint8List.sublistView(sealed, _ciphertextLen + _nonceLen);

    final aad = downgradeLockAad(
      expectedSuite,
      sender: sender,
      recipient: recipient,
    );
    final shared = await _kem.decapsulate(ct, hybridPrivateKey);
    final wrapKey = await _wrapKey(shared, aad);

    // Split body into cipherText ‖ 16-byte tag for `cryptography`.
    if (body.length < _tagLen) {
      throw const SkPqcError('sealed body shorter than the GCM tag');
    }
    final cipherText = Uint8List.sublistView(body, 0, body.length - _tagLen);
    final mac = Mac(Uint8List.sublistView(body, body.length - _tagLen));
    final aes = AesGcm.with256bits();
    try {
      final clear = await aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: SecretKey(wrapKey),
        aad: aad,
      );
      return Uint8List.fromList(clear);
    } catch (e) {
      throw DowngradeDetected(
        'hybrid-sealed open failed — wrong key, tampered ciphertext, or a '
        'suite-downgrade attempt (AAD bound suite=$expectedSuite): $e',
      );
    }
  }

  // ── Negotiation helper — mirrors pqdm.negotiate_suite ─────────────────────

  /// The suite both sides agree on: hybrid only when the local side supports it
  /// AND the peer advertises a hybrid prekey; else the classical suite.
  static String negotiateSuite({
    required bool localSupportsHybrid,
    required bool peerIsHybrid,
  }) {
    if (localSupportsHybrid && peerIsHybrid) return hybridSuite;
    return classicalSuite;
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  Uint8List _randomNonce() {
    final r = SecretKeyData.random(length: _nonceLen);
    return Uint8List.fromList(r.bytes);
  }
}

/// Raised when a hybrid-sealed open fails (wrong key, tamper, or a suite
/// downgrade). Mirrors `skcomms.pqdm.DowngradeDetected`.
class DowngradeDetected implements Exception {
  const DowngradeDetected(this.message);
  final String message;
  @override
  String toString() => 'DowngradeDetected: $message';
}
