import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:skchat/services/device_recovery_codec.dart';
import 'package:skchat/services/guest_identity.dart';
import 'package:skchat/services/guest_identity_io.dart';
import 'package:skchat/services/guest_key_store.dart';

class _MemStore implements GuestKeyStore {
  final Map<String, String> _m = {};
  @override
  Future<void> delete(String key) async => _m.remove(key);
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

ECPublicKey _pubFromSpki(Uint8List spki) {
  final point = spki.sublist(spki.length - 65); // 04||X32||Y32
  final domain = ECCurve_secp256r1();
  return ECPublicKey(domain.curve.decodePoint(point), domain);
}

BigInt _bi(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

void main() {
  test('NativeGuestIdentity exposes the recovery seam', () async {
    final id = NativeGuestIdentity(store: _MemStore());
    expect(id, isA<RecoverableIdentity>());
  });

  test('exportRecoveryPhrase yields 24 valid BIP39 words', () async {
    final id = NativeGuestIdentity(store: _MemStore());
    await id.ensure();
    final words = await (id as RecoverableIdentity).exportRecoveryPhrase();
    expect(words.length, 24);
    // Each word is in the vendored list and the whole thing re-decodes.
    final entropy = DeviceRecoveryCodec.wordsToEntropy(words);
    expect(entropy.length, 32);
  });

  test(
    'round-trip: export then restore reproduces the IDENTICAL key + fingerprint',
    () async {
      final id = NativeGuestIdentity(store: _MemStore());
      final original = await id.ensure();
      final words = await (id as RecoverableIdentity).exportRecoveryPhrase();

      // Fresh device (empty store): restore from the phrase.
      final fresh = NativeGuestIdentity(store: _MemStore());
      final restored =
          await (fresh as RecoverableIdentity).restoreFromRecoveryPhrase(words);

      expect(restored.publicKeyB64, original.publicKeyB64);
      expect(restored.fingerprint, original.fingerprint);
      expect(restored.degraded, isFalse);

      // Restore persisted: a new instance over the same store sees the key.
      expect(await fresh.hasCached(), isTrue);
    },
  );

  test('a restored key signs a payload that verifies against its pubkey',
      () async {
    final id = NativeGuestIdentity(store: _MemStore());
    await id.ensure();
    final words = await (id as RecoverableIdentity).exportRecoveryPhrase();

    final fresh = NativeGuestIdentity(store: _MemStore());
    final restored =
        await (fresh as RecoverableIdentity).restoreFromRecoveryPhrase(words);

    const payload = 'operator-enroll-challenge';
    final sigB64 = await fresh.sign(payload);
    final raw = base64.decode(sigB64);
    expect(raw.length, 64);
    final pub = _pubFromSpki(base64.decode(restored.publicKeyB64));
    final e =
        SHA256Digest().process(Uint8List.fromList(utf8.encode(payload)));
    final v = ECDSASigner()..init(false, PublicKeyParameter(pub));
    expect(
      v.verifySignature(e, ECSignature(_bi(raw.sublist(0, 32)), _bi(raw.sublist(32, 64)))),
      isTrue,
    );
  });

  test('restore rejects a checksum-invalid phrase', () async {
    final fresh = NativeGuestIdentity(store: _MemStore());
    // 24 'abandon' words: 253 zero bits + 11-bit last word 0 => checksum
    // must be 0b01100110, so all-abandon is a checksum failure.
    final bad = List<String>.filled(24, 'abandon');
    expect(
      () => (fresh as RecoverableIdentity).restoreFromRecoveryPhrase(bad),
      throwsA(isA<RecoveryPhraseException>()),
    );
  });

  test('restore rejects an out-of-range scalar d == 0 (all-zero entropy)',
      () async {
    // All-zero 256-bit entropy is a VALID BIP39 phrase (ends in "art") but
    // decodes to d == 0, which is not a valid P-256 private key.
    final zeroEntropy = Uint8List(32);
    final words = DeviceRecoveryCodec.entropyToWords(zeroEntropy);
    expect(words.last, 'art'); // sanity: it is checksum-valid
    final fresh = NativeGuestIdentity(store: _MemStore());
    expect(
      () => (fresh as RecoverableIdentity).restoreFromRecoveryPhrase(words),
      throwsA(isA<RecoveryPhraseException>()),
    );
  });

  test('restore rejects an out-of-range scalar d >= n (all-ff entropy)',
      () async {
    // All-ff 256-bit entropy is checksum-valid ("...vote") but d = 2^256-1,
    // which is >= the P-256 group order n, so it is not a valid key.
    final ff = Uint8List(32)..fillRange(0, 32, 0xff);
    final words = DeviceRecoveryCodec.entropyToWords(ff);
    expect(words.last, 'vote');
    final fresh = NativeGuestIdentity(store: _MemStore());
    expect(
      () => (fresh as RecoverableIdentity).restoreFromRecoveryPhrase(words),
      throwsA(isA<RecoveryPhraseException>()),
    );
  });

  test('a degraded (in-memory) identity cannot export a recovery phrase',
      () async {
    // Store that throws on everything -> ensure() returns a degraded key with
    // no persisted scalar. Exporting a phrase for a key that will not survive
    // a reload would be a dangerous lie, so it must refuse.
    final id = NativeGuestIdentity(store: _ThrowingStore());
    final kp = await id.ensure();
    expect(kp.degraded, isTrue);
    expect(
      () => (id as RecoverableIdentity).exportRecoveryPhrase(),
      throwsA(isA<RecoveryPhraseException>()),
    );
  });

  test('ensure() self-heals a stored priv/pub mismatch (trusts the private key)',
      () async {
    // A partial restore (new priv persisted, pub write failed) or any corruption
    // could leave the store advertising one identity while sign() uses another.
    // Build that exact state: identity A's real private scalar + identity B's
    // stale public key, then verify a fresh load heals to A's real pub.
    final storeA = _MemStore();
    final kpA = await NativeGuestIdentity(store: storeA).ensure();
    final storeB = _MemStore();
    final kpB = await NativeGuestIdentity(store: storeB).ensure();
    expect(kpA.publicKeyB64, isNot(equals(kpB.publicKeyB64)));

    // Corrupt storeA: keep A's priv, overwrite pub with B's (wrong) pub.
    storeA._m['skchat.guest.pub_spki'] = storeB._m['skchat.guest.pub_spki']!;

    final healed = await NativeGuestIdentity(store: storeA).ensure();
    expect(healed.publicKeyB64, kpA.publicKeyB64,
        reason: 'must derive the pub from the stored private scalar, '
            'never advertise the stale stored pub');
    expect(storeA._m['skchat.guest.pub_spki'], kpA.publicKeyB64,
        reason: 'the stale pub must be rewritten in the store');
  });
}

class _ThrowingStore implements GuestKeyStore {
  @override
  Future<void> delete(String key) async => throw StateError('no');
  @override
  Future<String?> read(String key) async => throw StateError('no');
  @override
  Future<void> write(String key, String value) async => throw StateError('no');
}
