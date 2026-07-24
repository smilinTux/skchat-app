// Real native GuestIdentity: a persistent ECDSA P-256 device key that mirrors
// guest_identity_web.dart's contract so the thick (Linux desktop) client can
// enroll as operator. Crypto (keygen/SPKI/sign) is byte-compatible with the
// server's operator_auth.verify_device_signature (P1363 r||s over a DER SPKI
// pubkey), validated by the cross-language fixture test.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'device_recovery_codec.dart';
import 'guest_identity.dart';
import 'guest_key_store.dart';

const _kPrivKey = 'skchat.guest.priv'; // base64(32-byte scalar d)
const _kPubKey = 'skchat.guest.pub_spki'; // publicKeyB64 (DER SPKI base64)

GuestIdentity createGuestIdentity() => NativeGuestIdentity();

class NativeGuestIdentity implements GuestIdentity, RecoverableIdentity {
  NativeGuestIdentity({GuestKeyStore? store})
    : _store =
          store ??
          FallbackGuestKeyStore(
            const SecureGuestKeyStore(
              FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true),
              ),
            ),
            // When the OS keyring is unavailable, fall back to an AES-256-GCM
            // encrypted-at-rest file store (machine-bound key) instead of the
            // legacy plaintext FileGuestKeyStore, so the private scalar is not
            // left in the clear on disk. Legacy plaintext files are read and
            // migrated transparently.
            EncryptedFileGuestKeyStore(),
          );

  final GuestKeyStore _store;
  GuestKeypair? _cached;
  ECPrivateKey? _degradedPriv; // only set on the degraded path
  ECPrivateKey? _priv; // cached scalar for the persisted (non-degraded) path

  @override
  Future<bool> hasCached() async {
    if (_cached != null) return true;
    try {
      return await _store.read(_kPrivKey) != null &&
          await _store.read(_kPubKey) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<GuestKeypair> ensure() async {
    if (_cached != null) return _cached!;
    try {
      final pubB64 = await _store.read(_kPubKey);
      final privB64 = await _store.read(_kPrivKey);
      if (pubB64 != null && privB64 != null) {
        // Self-heal a private/public MISMATCH: the priv and pub are two separate
        // store writes (enrollment and restore), so a partial write (priv
        // persisted, pub write failed) could leave a stale pub that silently
        // advertises one identity while sign() uses another. The private scalar
        // is the source of truth: derive Q = d·G from it and, on mismatch,
        // rewrite the correct pub. Runs once (then _cached short-circuits).
        try {
          final d = _fromBytes(base64.decode(privB64));
          final domain = ECCurve_secp256r1();
          if (d >= BigInt.one && d < domain.n) {
            final derivedPub =
                base64.encode(_spkiDer(ECPublicKey(domain.G * d, domain)));
            if (derivedPub != pubB64) {
              await _store.write(_kPubKey, derivedPub);
              _priv = ECPrivateKey(d, domain);
              return _cached = GuestKeypair(
                publicKeyB64: derivedPub,
                fingerprint: _fingerprint(derivedPub),
              );
            }
          }
        } catch (_) {
          // Malformed stored priv: fall through to trusting the stored pub
          // (sign() will surface any real key problem).
        }
        return _cached = GuestKeypair(
          publicKeyB64: pubB64,
          fingerprint: _fingerprint(pubB64),
        );
      }

      final pair = _generate();
      final pub = pair.publicKey as ECPublicKey;
      final priv = pair.privateKey as ECPrivateKey;
      final spkiB64 = base64.encode(_spkiDer(pub));
      final fp = _fingerprint(spkiB64);

      // Persist only after SPKI + fingerprint succeed, so a failure here never
      // leaves a half-written key while returning a different one.
      await _store.write(_kPrivKey, base64.encode(_bytes32(priv.d!)));
      await _store.write(_kPubKey, spkiB64);

      _priv = priv;
      return _cached = GuestKeypair(publicKeyB64: spkiB64, fingerprint: fp);
    } catch (_) {
      // Storage unavailable (no Secret Service AND file write blocked). Return
      // a real, unique in-memory keypair flagged degraded: the user still gets
      // a distinct id and can sign this session, warned it will not persist.
      final pair = _generate();
      final pub = pair.publicKey as ECPublicKey;
      _degradedPriv = pair.privateKey as ECPrivateKey;
      final spkiB64 = base64.encode(_spkiDer(pub));
      return _cached = GuestKeypair(
        publicKeyB64: spkiB64,
        fingerprint: _fingerprint(spkiB64),
        degraded: true,
      );
    }
  }

  @override
  Future<String> sign(String data) async {
    await ensure();
    // Prefer the in-memory scalar (degraded, then already-cached) so a
    // resolved key is never re-read from the store on every call; cache the
    // store-loaded key the first time so subsequent signs stay in-memory.
    final priv = _degradedPriv ?? _priv ?? (_priv = await _loadPriv());
    final e = SHA256Digest().process(Uint8List.fromList(utf8.encode(data)));
    final signer = ECDSASigner()
      ..init(
        true,
        ParametersWithRandom(PrivateKeyParameter(priv), _secureRandom()),
      );
    final sig = signer.generateSignature(e) as ECSignature;
    final raw = Uint8List(64)
      ..setRange(0, 32, _bytes32(sig.r))
      ..setRange(32, 64, _bytes32(sig.s));
    return base64.encode(raw);
  }

  @override
  Future<void> clear() async {
    _cached = null;
    _degradedPriv = null;
    _priv = null;
    try {
      await _store.delete(_kPrivKey);
      await _store.delete(_kPubKey);
    } catch (_) {
      // Nothing persisted (degraded), nothing to clear.
    }
  }

  // ── recovery phrase (RecoverableIdentity) ──────────────────────────────
  @override
  Future<List<String>> exportRecoveryPhrase() async {
    await ensure();
    // Only a DURABLE key can be truthfully "backed up". A degraded, in-memory
    // key (storage unavailable) has nothing persisted, and its scalar dies on
    // reload, so refuse rather than hand out a phrase that restores nothing
    // useful. Read the persisted scalar bytes so the phrase encodes exactly
    // what is on disk (32-byte big-endian d), not a re-derived copy.
    String? raw;
    try {
      raw = await _store.read(_kPrivKey);
    } catch (_) {
      raw = null;
    }
    if (raw == null || _degradedPriv != null) {
      throw const RecoveryPhraseException(
        'This identity is temporary and cannot be backed up. Enroll on a '
        'device with working secure storage first.',
      );
    }
    final scalar = base64.decode(raw);
    if (scalar.length != 32) {
      throw const RecoveryPhraseException(
        'stored device key is malformed (expected a 32-byte scalar)',
      );
    }
    return DeviceRecoveryCodec.entropyToWords(Uint8List.fromList(scalar));
  }

  @override
  Future<GuestKeypair> restoreFromRecoveryPhrase(List<String> words) async {
    // Tolerate casing / stray spaces on individual entries; the codec itself
    // validates the BIP39 checksum, word membership, and 24-word length.
    final cleaned = words.map((w) => w.trim().toLowerCase()).toList();
    final entropy = DeviceRecoveryCodec.wordsToEntropy(cleaned);

    final d = _fromBytes(entropy);
    final domain = ECCurve_secp256r1();
    final n = domain.n;
    // A checksum-valid phrase can still decode to a scalar outside the valid
    // P-256 private-key range [1, n). Reject those: d == 0 has no inverse and
    // d >= n is not a group element, either would corrupt signing.
    if (d < BigInt.one || d >= n) {
      throw const RecoveryPhraseException(
        'This recovery phrase does not encode a valid device key. Re-check '
        'the words (a typo can pass the checksum yet be out of range).',
      );
    }

    final priv = ECPrivateKey(d, domain);
    final q = domain.G * d; // public point Q = d·G
    final pub = ECPublicKey(q, domain);
    final spkiB64 = base64.encode(_spkiDer(pub));
    final fp = _fingerprint(spkiB64);

    // Persist the reconstructed key (same layout ensure() writes), then adopt
    // it in-memory so subsequent sign()/ensure() use the restored identity.
    await _store.write(_kPrivKey, base64.encode(_bytes32(d)));
    await _store.write(_kPubKey, spkiB64);
    _priv = priv;
    _degradedPriv = null;
    return _cached = GuestKeypair(publicKeyB64: spkiB64, fingerprint: fp);
  }

  // ── crypto helpers ─────────────────────────────────────────────────────
  AsymmetricKeyPair<PublicKey, PrivateKey> _generate() {
    final g = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()),
          _secureRandom(),
        ),
      );
    return g.generateKeyPair();
  }

  Future<ECPrivateKey> _loadPriv() async {
    final raw = await _store.read(_kPrivKey);
    if (raw == null) {
      throw StateError('device private key missing from keystore');
    }
    final d = _fromBytes(base64.decode(raw));
    return ECPrivateKey(d, ECCurve_secp256r1());
  }

  Uint8List _spkiDer(ECPublicKey pub) {
    final point = pub.Q!.getEncoded(false); // 04||X||Y uncompressed
    final algo = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.10045.2.1'))
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.10045.3.1.7'));
    final spki = ASN1Sequence()
      ..add(algo)
      ..add(ASN1BitString(Uint8List.fromList(point)));
    return spki.encodedBytes;
  }

  String _fingerprint(String spkiB64) {
    final h = SHA256Digest().process(Uint8List.fromList(utf8.encode(spkiB64)));
    return h
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 16);
  }

  SecureRandom _secureRandom() {
    final fr = FortunaRandom();
    final r = Random.secure();
    fr.seed(
      KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256))),
      ),
    );
    return fr;
  }

  Uint8List _bytes32(BigInt v) {
    var s = v.toRadixString(16);
    if (s.length.isOdd) s = '0$s';
    final by = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      by.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    final out = Uint8List(32);
    out.setRange(32 - by.length, 32, by);
    return out;
  }

  BigInt _fromBytes(List<int> b) {
    var r = BigInt.zero;
    for (final x in b) {
      r = (r << 8) | BigInt.from(x);
    }
    return r;
  }
}
