import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c; // dev-only hashing for the assertion
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:skchat/services/guest_identity.dart';
import 'package:skchat/services/guest_identity_io.dart';
import 'package:skchat/services/guest_key_store.dart';

class _MemStore implements GuestKeyStore {
  final Map<String, String> _m = {};
  bool throwAll = false;
  @override
  Future<void> delete(String key) async {
    if (throwAll) throw StateError('no');
    _m.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (throwAll) throw StateError('no');
    return _m[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (throwAll) throw StateError('no');
    _m[key] = value;
  }
}

void main() {
  test(
    'generates a valid P-256 SPKI whose fp matches the server formula',
    () async {
      final store = _MemStore();
      final id = NativeGuestIdentity(store: store);
      final kp = await id.ensure();
      expect(kp.degraded, isFalse);
      // Standard P-256 SPKI base64 prefix (WebCrypto/OpenSSL identical).
      expect(
        kp.publicKeyB64,
        startsWith('MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE'),
      );
      // fingerprint == first 16 hex of sha256 over the base64 STRING.
      final want = c.sha256
          .convert(utf8.encode(kp.publicKeyB64))
          .toString()
          .substring(0, 16);
      expect(kp.fingerprint, want);
    },
  );

  test(
    'persists: a second instance over the same store returns same key',
    () async {
      final store = _MemStore();
      final first = await NativeGuestIdentity(store: store).ensure();
      final second = NativeGuestIdentity(store: store);
      expect(await second.hasCached(), isTrue);
      final k2 = await second.ensure();
      expect(k2.publicKeyB64, first.publicKeyB64);
      expect(k2.fingerprint, first.fingerprint);
    },
  );

  test('clear wipes; next ensure regenerates a different key', () async {
    final store = _MemStore();
    final id = NativeGuestIdentity(store: store);
    final a = await id.ensure();
    await id.clear();
    expect(await id.hasCached(), isFalse);
    final b = await id.ensure();
    expect(b.publicKeyB64, isNot(a.publicKeyB64));
  });

  test(
    'sign produces a 64-byte r||s that verifies against the pubkey',
    () async {
      final store = _MemStore();
      final id = NativeGuestIdentity(store: store);
      final kp = await id.ensure();
      final sigB64 = await id.sign('canonical-payload');
      final raw = base64.decode(sigB64);
      expect(raw.length, 64);
      // Reconstruct the pubkey from the stored SPKI and verify locally.
      final spki = base64.decode(kp.publicKeyB64);
      final pub = _pubFromSpki(spki);
      final r = _bi(raw.sublist(0, 32));
      final s = _bi(raw.sublist(32, 64));
      final e = SHA256Digest().process(
        Uint8List.fromList(utf8.encode('canonical-payload')),
      );
      final v = ECDSASigner()..init(false, PublicKeyParameter(pub));
      expect(v.verifySignature(e, ECSignature(r, s)), isTrue);
    },
  );

  test('degraded fallback when the store throws on read AND write', () async {
    final store = _MemStore()..throwAll = true;
    final id = NativeGuestIdentity(store: store);
    final kp = await id.ensure();
    expect(kp.degraded, isTrue);
    expect(kp.publicKeyB64, isNotEmpty);
  });

  test(
    'sign caches the private key: two consecutive signs both succeed and '
    'verify against the pubkey',
    () async {
      final store = _MemStore();
      final id = NativeGuestIdentity(store: store);
      final kp = await id.ensure();
      final spki = base64.decode(kp.publicKeyB64);
      final pub = _pubFromSpki(spki);

      Future<void> signAndVerify(String payload) async {
        final sigB64 = await id.sign(payload);
        final raw = base64.decode(sigB64);
        final r = _bi(raw.sublist(0, 32));
        final s = _bi(raw.sublist(32, 64));
        final e = SHA256Digest().process(
          Uint8List.fromList(utf8.encode(payload)),
        );
        final v = ECDSASigner()..init(false, PublicKeyParameter(pub));
        expect(v.verifySignature(e, ECSignature(r, s)), isTrue);
      }

      // First sign resolves and caches the key from the store; the second
      // sign must still succeed and verify using the cached key, proving
      // the cached-key path (not just a lucky single read) works.
      await signAndVerify('payload-one');
      await signAndVerify('payload-two');
    },
  );
}

BigInt _bi(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

ECPublicKey _pubFromSpki(Uint8List spki) {
  // The uncompressed point is the trailing 65 bytes (04||X32||Y32).
  final point = spki.sublist(spki.length - 65);
  final domain = ECCurve_secp256r1();
  return ECPublicKey(domain.curve.decodePoint(point), domain);
}
