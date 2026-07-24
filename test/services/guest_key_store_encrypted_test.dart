import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/guest_identity.dart';
import 'package:skchat/services/guest_identity_io.dart';
import 'package:skchat/services/guest_key_store.dart';

/// A keyring stand-in that is always down, forcing NativeGuestIdentity onto the
/// file fallback (the real-world headless-Linux case this hardening targets).
class _DownKeyring implements GuestKeyStore {
  @override
  Future<void> delete(String key) => throw StateError('keyring down');
  @override
  Future<String?> read(String key) => throw StateError('keyring down');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('keyring down');
}

// A stable, known 32-byte scalar so tests can assert its base64 is NEVER
// present on disk in the encrypted form. This mirrors the real payload:
// NativeGuestIdentity stores base64(32-byte P-256 private scalar d).
final _scalarB64 = base64.encode(
  List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
);
const _priv = 'skchat.guest.priv';
const _pub = 'skchat.guest.pub_spki';

// A fixed machine-id override so the whole suite is hermetic (does not depend
// on /etc/machine-id being readable). The real code reads /etc/machine-id.
const _machineId = 'deadbeefdeadbeefdeadbeefdeadbeef';

EncryptedFileGuestKeyStore _store(String dir, {String machineId = _machineId}) =>
    EncryptedFileGuestKeyStore(dirPath: dir, machineIdOverride: machineId);

void main() {
  test('round-trip: writes and reads back the identical scalar', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-rt')).path;
    final a = _store(dir);
    await a.write(_priv, _scalarB64);
    await a.write(_pub, 'PUBLIC-SPKI-B64');
    expect(await a.read(_priv), _scalarB64);
    expect(await a.read(_pub), 'PUBLIC-SPKI-B64');
    // A fresh instance over the same dir reads the same values back.
    final b = _store(dir);
    expect(await b.read(_priv), _scalarB64);
    expect(await b.read(_pub), 'PUBLIC-SPKI-B64');
    expect(await b.read('absent'), isNull);
  });

  test('the raw scalar bytes are ABSENT from the on-disk file (encrypted)',
      () async {
    final dir = (await Directory.systemTemp.createTemp('eks-secret')).path;
    await _store(dir).write(_priv, _scalarB64);

    final onDisk = await File('$dir/guest_identity.json').readAsString();
    // The plaintext base64 scalar must not appear anywhere in the file.
    expect(onDisk.contains(_scalarB64), isFalse,
        reason: 'private scalar leaked in plaintext');
    // The raw scalar bytes themselves must not appear either.
    final rawScalar = base64.decode(_scalarB64);
    final fileBytes = await File('$dir/guest_identity.json').readAsBytes();
    expect(_containsSubsequence(fileBytes, rawScalar), isFalse,
        reason: 'raw scalar bytes leaked');
    // The file is a versioned envelope, and it does NOT carry the salt
    // (the wrapping key must not be derivable from this file alone).
    final env = jsonDecode(onDisk) as Map<String, dynamic>;
    expect(env['skchat_keystore_version'], 1);
    expect(env.containsKey('salt'), isFalse);
    expect(env['ct'], isA<String>());
    expect(env['nonce'], isA<String>());
  });

  test('on-disk file and salt file are both 0600', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-perm')).path;
    await _store(dir).write(_priv, _scalarB64);
    final fMode =
        (await File('$dir/guest_identity.json').stat()).mode & 0x1FF;
    expect(fMode, 0x180); // 0600
    final saltFile = File('$dir/guest_identity.salt');
    expect(await saltFile.exists(), isTrue);
    final sMode = (await saltFile.stat()).mode & 0x1FF;
    expect(sMode, 0x180); // 0600
  });

  test('migration: reads an OLD plaintext file, then re-encrypts on next write',
      () async {
    final dir = (await Directory.systemTemp.createTemp('eks-mig')).path;
    // Seed the legacy plaintext format: a raw JSON map of key->value, exactly
    // what the old FileGuestKeyStore wrote.
    final legacy = File('$dir/guest_identity.json');
    await legacy.create(recursive: true);
    await legacy.writeAsString(jsonEncode({_priv: _scalarB64}));

    final store = _store(dir);
    // Transparent read of the legacy plaintext.
    expect(await store.read(_priv), _scalarB64);

    // Any write migrates the file to the encrypted envelope.
    await store.write(_pub, 'PUBLIC-SPKI-B64');
    final onDisk = await legacy.readAsString();
    final env = jsonDecode(onDisk) as Map<String, dynamic>;
    expect(env['skchat_keystore_version'], 1,
        reason: 'file was not migrated to the encrypted format');
    expect(onDisk.contains(_scalarB64), isFalse,
        reason: 'scalar still in plaintext after migration');
    // Both keys survive migration and read back correctly.
    final reader = _store(dir);
    expect(await reader.read(_priv), _scalarB64);
    expect(await reader.read(_pub), 'PUBLIC-SPKI-B64');
  });

  test('missing salt file -> read fails safe (no value, no garbage)', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-nosalt')).path;
    await _store(dir).write(_priv, _scalarB64);
    // Remove the salt: the wrapping key can no longer be derived.
    await File('$dir/guest_identity.salt').delete();

    final reader = _store(dir);
    final got = await reader.read(_priv);
    // Must NOT return the value and must NOT return corrupted/garbage bytes.
    expect(got, isNull);
    // The undecryptable ciphertext is preserved as a sidecar, not silently
    // destroyed, and the live file no longer trips the reader repeatedly.
    final siblings = await Directory(dir).list().toList();
    expect(
      siblings.where((e) => e.path.contains('.corrupt-')).isNotEmpty,
      isTrue,
      reason: 'undecryptable file should be preserved as a .corrupt sidecar',
    );
  });

  test('wrong salt -> read fails safe (GCM tag rejects it)', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-badsalt')).path;
    await _store(dir).write(_priv, _scalarB64);
    // Corrupt the salt with different bytes.
    await File('$dir/guest_identity.salt')
        .writeAsString(base64.encode(List<int>.filled(32, 9)));
    expect(await _store(dir).read(_priv), isNull);
  });

  test('different machine-id cannot decrypt (key is machine-bound)', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-machine')).path;
    await _store(dir, machineId: _machineId).write(_priv, _scalarB64);
    // Same salt file, different machine-id -> HKDF yields a different key ->
    // GCM tag fails -> no value returned.
    final other = _store(dir, machineId: 'ffffffffffffffffffffffffffffffff');
    expect(await other.read(_priv), isNull);
  });

  test('nonce is randomized per write (no fixed-nonce GCM reuse)', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-nonce')).path;
    final s = _store(dir);
    await s.write(_priv, _scalarB64);
    final n1 = (jsonDecode(await File('$dir/guest_identity.json').readAsString())
        as Map)['nonce'];
    await s.write(_pub, 'x');
    final n2 = (jsonDecode(await File('$dir/guest_identity.json').readAsString())
        as Map)['nonce'];
    expect(n1, isNot(n2));
  });

  test('delete removes a key; empty store reads null', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-del')).path;
    final s = _store(dir);
    await s.write(_priv, _scalarB64);
    await s.delete(_priv);
    expect(await _store(dir).read(_priv), isNull);
  });

  test('corrupt (truncated) envelope -> null + sidecar, not a throw', () async {
    final dir = (await Directory.systemTemp.createTemp('eks-trunc')).path;
    await _store(dir).write(_priv, _scalarB64);
    // Truncate the ciphertext so GCM cannot authenticate it.
    final f = File('$dir/guest_identity.json');
    final env = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    env['ct'] = (env['ct'] as String).substring(0, 8);
    await f.writeAsString(jsonEncode(env));
    expect(await _store(dir).read(_priv), isNull);
    final siblings = await Directory(dir).list().toList();
    expect(siblings.where((e) => e.path.contains('.corrupt-')).isNotEmpty,
        isTrue);
  });

  group('NativeGuestIdentity over the encrypted file fallback', () {
    // Wire the identity exactly like production would when the keyring is
    // unavailable: keyring primary throws, encrypted file store is secondary.
    GuestKeyStore fallback(String dir) => FallbackGuestKeyStore(
          _DownKeyring(),
          _store(dir),
        );

    test('ensure() persists a durable key; nothing leaks in plaintext',
        () async {
      final dir = (await Directory.systemTemp.createTemp('eks-id')).path;
      final id = NativeGuestIdentity(store: fallback(dir));
      final kp = await id.ensure();
      expect(kp.degraded, isFalse); // durable, not the in-memory fallback
      expect(kp.publicKeyB64, startsWith('MFkwEwYHKoZIzj0'));

      // On-disk file is the encrypted envelope; the private scalar the store
      // holds must not appear anywhere in it.
      final onDisk = await File('$dir/guest_identity.json').readAsString();
      final env = jsonDecode(onDisk) as Map<String, dynamic>;
      expect(env['skchat_keystore_version'], 1);
      final storedPriv = await _store(dir).read('skchat.guest.priv');
      expect(storedPriv, isNotNull);
      expect(onDisk.contains(storedPriv!), isFalse);
    });

    test('a second instance over the same dir returns the SAME key', () async {
      final dir = (await Directory.systemTemp.createTemp('eks-id2')).path;
      final first = await NativeGuestIdentity(store: fallback(dir)).ensure();
      final second = NativeGuestIdentity(store: fallback(dir));
      expect(await second.hasCached(), isTrue);
      final k2 = await second.ensure();
      expect(k2.publicKeyB64, first.publicKeyB64);
      expect(k2.fingerprint, first.fingerprint);
    });

    test('sign() works and recovery phrase exports + restores', () async {
      final dir = (await Directory.systemTemp.createTemp('eks-id3')).path;
      final id = NativeGuestIdentity(store: fallback(dir));
      await id.ensure();
      final sig = await id.sign('canonical-payload');
      expect(base64.decode(sig).length, 64);

      // A durable encrypted-file key can be backed up and restored identically.
      final words = await id.exportRecoveryPhrase();
      expect(words.length, 24);
      final restored = await NativeGuestIdentity(store: fallback(dir))
          .restoreFromRecoveryPhrase(words);
      expect(restored.publicKeyB64, (await id.ensure()).publicKeyB64);
    });
  });
}

/// True if [needle] appears as a contiguous subsequence of [hay].
bool _containsSubsequence(List<int> hay, List<int> needle) {
  if (needle.isEmpty || needle.length > hay.length) return false;
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
