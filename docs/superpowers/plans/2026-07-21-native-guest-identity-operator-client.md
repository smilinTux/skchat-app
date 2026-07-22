# Native GuestIdentity keystore + neutral thick-client build: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the native (Linux desktop) `GuestIdentity` a real, persistent ECDSA P-256 keystore so the thick client can enroll as operator (green), and ship the build config neutral (no baked private-infra URL) while Chef's builds inject `.158` explicitly.

**Architecture:** A real `guest_identity_io.dart` (pointycastle keygen/sign, asn1lib SPKI DER) replaces the in-memory stub on native targets, persisting through an injectable `GuestKeyStore` seam (flutter_secure_storage → file fallback → in-memory degraded). Build config moves the baked host out of the code defaults into an opt-in `--dart-define-from-file`, with a first-run guard so an unconfigured neutral build routes to the server picker.

**Tech Stack:** Dart/Flutter, pointycastle 3.9.1 (ECDSA P-256), asn1lib 1.6.5 (SPKI DER), flutter_secure_storage 9, path_provider, dart:io; Python/pytest for the cross-language wire-compat fixture.

## Global Constraints

- **Curve/hash:** ECDSA **P-256** (`prime256v1` == `secp256r1`), **SHA-256**. No other curve.
- **Public key wire form:** `publicKeyB64` = `base64(DER SubjectPublicKeyInfo)`; a correct P-256 SPKI base64 always begins `MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE`.
- **Fingerprint:** `sha256(publicKeyB64_string_utf8)` → hex → first **16** chars. Identical to server `device_fingerprint` and `guest_identity_web.dart`.
- **Signature wire form:** 64-byte raw `r||s` (each 32-byte big-endian, left-zero-padded), base64. Message is SHA-256-**pre-hashed** before `ECDSASigner.generateSignature` (pointycastle does NOT hash internally).
- **No em/en dashes** in any code comment, commit message, or doc (repo/user rule).
- **Commit trailer (every commit):** `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **Line length** 80 cols in Dart to match the existing services.
- All work on branch `feat/native-guest-identity` (already created off `main`).
- Run Flutter with `export PATH=/home/cbrd21/flutter/bin:$PATH` first.
- **Crypto is pre-validated:** the exact pointycastle/asn1lib calls below were spiked and confirmed to (a) produce a server-`verify_device_signature`-True signature and (b) match the server fingerprint, including the reload-from-scalar path. Do not "improve" the crypto; reproduce it.

---

## File Structure

- Create `lib/services/guest_key_store.dart`: the `GuestKeyStore` seam + `SecureGuestKeyStore`, `FileGuestKeyStore`, `FallbackGuestKeyStore`.
- Create `lib/services/guest_identity_io.dart`: the real native `GuestIdentity` + `createGuestIdentity()`.
- Modify `lib/services/guest_identity.dart`: conditional import adds the io impl.
- Modify `lib/services/backend_config.dart`: neutral (empty) compile-time defaults.
- Create `config/lumina.json`: dart-define file with the `.158` hosts.
- Create `scripts/build-linux-lumina.sh`, `scripts/build-linux-neutral.sh`, `scripts/build-web-lumina.sh`.
- Create `test/services/guest_key_store_test.dart`, `test/services/guest_identity_io_test.dart`.
- Create `test/fixtures/emit_device_fixture.dart`: Dart entrypoint emitting a JSON fixture.
- Create `skchat` repo `tests/test_operator_auth_wire_compat.py`: feeds the fixture through the real server verify.

---

### Task 1: `GuestKeyStore` seam + file + fallback stores

**Files:**
- Create: `lib/services/guest_key_store.dart`
- Test: `test/services/guest_key_store_test.dart`

**Interfaces:**
- Produces:
  - `abstract class GuestKeyStore { Future<String?> read(String key); Future<void> write(String key, String value); Future<void> delete(String key); }`
  - `class SecureGuestKeyStore implements GuestKeyStore` (ctor `SecureGuestKeyStore(FlutterSecureStorage storage)`).
  - `class FileGuestKeyStore implements GuestKeyStore` (ctor `FileGuestKeyStore({String? dirPath})`, defaults to `$HOME/.skchat-app`).
  - `class FallbackGuestKeyStore implements GuestKeyStore` (ctor `FallbackGuestKeyStore(GuestKeyStore primary, GuestKeyStore secondary)`); each op tries primary, on throw tries secondary, and only rethrows if BOTH throw.

- [ ] **Step 1: Write failing tests**

```dart
// test/services/guest_key_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/guest_key_store.dart';

class _ThrowingStore implements GuestKeyStore {
  @override
  Future<void> delete(String key) => throw StateError('no');
  @override
  Future<String?> read(String key) => throw StateError('no');
  @override
  Future<void> write(String key, String value) => throw StateError('no');
}

void main() {
  test('FileGuestKeyStore persists across instances (atomic, 0600)', () async {
    final dir = await Directory.systemTemp.createTemp('gks');
    final a = FileGuestKeyStore(dirPath: dir.path);
    await a.write('k', 'v1');
    expect(await a.read('k'), 'v1');
    // A brand new instance reads the same file back.
    final b = FileGuestKeyStore(dirPath: dir.path);
    expect(await b.read('k'), 'v1');
    // Missing key is null, not a throw.
    expect(await b.read('absent'), isNull);
    // File perms are owner-only.
    final f = File('${dir.path}/guest_identity.json');
    final mode = (await f.stat()).mode & 0x1FF; // low 9 perm bits
    expect(mode, 0x180); // 0600
    await a.delete('k');
    expect(await b.read('k'), isNull);
  });

  test('FallbackGuestKeyStore uses secondary when primary throws', () async {
    final dir = await Directory.systemTemp.createTemp('gks2');
    final store = FallbackGuestKeyStore(_ThrowingStore(),
        FileGuestKeyStore(dirPath: dir.path));
    await store.write('k', 'v');       // primary throws -> file persists it
    expect(await store.read('k'), 'v'); // primary throws -> file returns it
  });

  test('FallbackGuestKeyStore rethrows only when BOTH throw', () async {
    final store = FallbackGuestKeyStore(_ThrowingStore(), _ThrowingStore());
    expect(() => store.write('k', 'v'), throwsA(isA<Object>()));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/guest_key_store_test.dart`
Expected: FAIL (`guest_key_store.dart` / classes not found).

- [ ] **Step 3: Implement**

```dart
// lib/services/guest_key_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A minimal string key-value seam for the native device key material, so the
/// GuestIdentity impl can be tested with an in-memory fake and can fall back
/// between backends without knowing which one is live.
abstract class GuestKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Wraps the OS keyring (libsecret / gnome-keyring on Linux) via
/// flutter_secure_storage. Reads/writes touch a platform channel, so this is
/// never used directly under `flutter test` (tests inject a fake).
class SecureGuestKeyStore implements GuestKeyStore {
  const SecureGuestKeyStore(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A file-backed store at `$HOME/.skchat-app/guest_identity.json`, `0600`,
/// written atomically (temp + rename). Persists on any Linux box even with no
/// Secret Service running, so an operator device stays enrolled across
/// restarts.
class FileGuestKeyStore implements GuestKeyStore {
  FileGuestKeyStore({String? dirPath})
      : _dirPath = dirPath ??
            '${Platform.environment['HOME'] ?? '.'}/.skchat-app';

  final String _dirPath;

  File get _file => File('$_dirPath/guest_identity.json');

  Future<Map<String, String>> _load() async {
    final f = _file;
    if (!await f.exists()) return {};
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // Corrupt file: treat as empty; a fresh write will replace it.
    }
    return {};
  }

  Future<void> _save(Map<String, String> data) async {
    await Directory(_dirPath).create(recursive: true);
    final tmp = File('${_file.path}.tmp-$pid');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(_file.path);
    // dart:io has no chmod; enforce owner-only perms on Linux.
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['600', _file.path]);
    }
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) async {
    final data = await _load();
    data[key] = value;
    await _save(data);
  }

  @override
  Future<void> delete(String key) async {
    final data = await _load();
    data.remove(key);
    await _save(data);
  }
}

/// Tries [primary] first; on ANY throw, delegates to [secondary]. Only
/// rethrows when BOTH backends throw, which the caller treats as "storage
/// unavailable -> degraded, in-memory identity".
class FallbackGuestKeyStore implements GuestKeyStore {
  const FallbackGuestKeyStore(this._primary, this._secondary);
  final GuestKeyStore _primary;
  final GuestKeyStore _secondary;

  Future<T> _either<T>(
      Future<T> Function(GuestKeyStore) op) async {
    try {
      return await op(_primary);
    } catch (_) {
      return await op(_secondary);
    }
  }

  @override
  Future<String?> read(String key) => _either((s) => s.read(key));
  @override
  Future<void> write(String key, String value) =>
      _either((s) => s.write(key, value));
  @override
  Future<void> delete(String key) => _either((s) => s.delete(key));
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/guest_key_store_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/guest_key_store.dart test/services/guest_key_store_test.dart
git commit -m "feat(identity): native GuestKeyStore seam (secure + file + fallback)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: `guest_identity_io.dart` (keygen, SPKI, fingerprint, sign)

**Files:**
- Create: `lib/services/guest_identity_io.dart`
- Test: `test/services/guest_identity_io_test.dart`

**Interfaces:**
- Consumes: `GuestKeyStore` (Task 1); `GuestIdentity` / `GuestKeypair` (`lib/services/guest_identity.dart`).
- Produces:
  - `GuestIdentity createGuestIdentity()` (default store = the fallback chain).
  - `class NativeGuestIdentity implements GuestIdentity` with a testing ctor `NativeGuestIdentity({GuestKeyStore? store})`.
  - Storage keys `'skchat.guest.priv'` (base64 of the 32-byte scalar d) and `'skchat.guest.pub_spki'` (the `publicKeyB64`).

- [ ] **Step 1: Write failing tests**

```dart
// test/services/guest_identity_io_test.dart
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
  test('generates a valid P-256 SPKI whose fp matches the server formula',
      () async {
    final store = _MemStore();
    final id = NativeGuestIdentity(store: store);
    final kp = await id.ensure();
    expect(kp.degraded, isFalse);
    // Standard P-256 SPKI base64 prefix (WebCrypto/OpenSSL identical).
    expect(kp.publicKeyB64,
        startsWith('MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE'));
    // fingerprint == first 16 hex of sha256 over the base64 STRING.
    final want = c.sha256
        .convert(utf8.encode(kp.publicKeyB64))
        .toString()
        .substring(0, 16);
    expect(kp.fingerprint, want);
  });

  test('persists: a second instance over the same store returns same key',
      () async {
    final store = _MemStore();
    final first = await NativeGuestIdentity(store: store).ensure();
    final second = NativeGuestIdentity(store: store);
    expect(await second.hasCached(), isTrue);
    final k2 = await second.ensure();
    expect(k2.publicKeyB64, first.publicKeyB64);
    expect(k2.fingerprint, first.fingerprint);
  });

  test('clear wipes; next ensure regenerates a different key', () async {
    final store = _MemStore();
    final id = NativeGuestIdentity(store: store);
    final a = await id.ensure();
    await id.clear();
    expect(await id.hasCached(), isFalse);
    final b = await id.ensure();
    expect(b.publicKeyB64, isNot(a.publicKeyB64));
  });

  test('sign produces a 64-byte r||s that verifies against the pubkey',
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
    final e =
        SHA256Digest().process(Uint8List.fromList(utf8.encode('canonical-payload')));
    final v = ECDSASigner()..init(false, PublicKeyParameter(pub));
    expect(v.verifySignature(e, ECSignature(r, s)), isTrue);
  });

  test('degraded fallback when the store throws on read AND write', () async {
    final store = _MemStore()..throwAll = true;
    final id = NativeGuestIdentity(store: store);
    final kp = await id.ensure();
    expect(kp.degraded, isTrue);
    expect(kp.publicKeyB64, isNotEmpty);
  });
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
```

Note: add `crypto` to `dev_dependencies` if not present (`flutter pub add --dev crypto`). It is only used by this test's assertion.

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/guest_identity_io_test.dart`
Expected: FAIL (`guest_identity_io.dart` / `NativeGuestIdentity` not found).

- [ ] **Step 3: Implement**

```dart
// lib/services/guest_identity_io.dart
//
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

import 'guest_identity.dart';
import 'guest_key_store.dart';

const _kPrivKey = 'skchat.guest.priv';      // base64(32-byte scalar d)
const _kPubKey = 'skchat.guest.pub_spki';   // publicKeyB64 (DER SPKI base64)

GuestIdentity createGuestIdentity() => NativeGuestIdentity();

class NativeGuestIdentity implements GuestIdentity {
  NativeGuestIdentity({GuestKeyStore? store})
      : _store = store ??
            const FallbackGuestKeyStore(
              SecureGuestKeyStore(FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true),
              )),
              FileGuestKeyStore(),
            );

  final GuestKeyStore _store;
  GuestKeypair? _cached;
  ECPrivateKey? _degradedPriv; // only set on the degraded path

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
        return _cached = GuestKeypair(
            publicKeyB64: pubB64, fingerprint: _fingerprint(pubB64));
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
          degraded: true);
    }
  }

  @override
  Future<String> sign(String data) async {
    await ensure();
    final priv = _degradedPriv ?? await _loadPriv();
    final e = SHA256Digest()
        .process(Uint8List.fromList(utf8.encode(data)));
    final signer = ECDSASigner()
      ..init(true,
          ParametersWithRandom(PrivateKeyParameter(priv), _secureRandom()));
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
    try {
      await _store.delete(_kPrivKey);
      await _store.delete(_kPubKey);
    } catch (_) {
      // Nothing persisted (degraded), nothing to clear.
    }
  }

  // ── crypto helpers ─────────────────────────────────────────────────────
  AsymmetricKeyPair<PublicKey, PrivateKey> _generate() {
    final g = ECKeyGenerator()
      ..init(ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()), _secureRandom()));
    return g.generateKeyPair();
  }

  Future<ECPrivateKey> _loadPriv() async {
    final d = _fromBytes(base64.decode((await _store.read(_kPrivKey))!));
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
    final h = SHA256Digest()
        .process(Uint8List.fromList(utf8.encode(spkiB64)));
    return h
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 16);
  }

  SecureRandom _secureRandom() {
    final fr = FortunaRandom();
    final r = Random.secure();
    fr.seed(KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)))));
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/guest_identity_io_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/guest_identity_io.dart test/services/guest_identity_io_test.dart pubspec.yaml pubspec.lock
git commit -m "feat(identity): real native ECDSA P-256 GuestIdentity

Persistent P-256 device key (pointycastle + asn1lib SPKI DER) mirroring the
web impl contract, with graceful degraded fallback. Wire-compatible with the
server operator_auth (P1363 r||s over DER SPKI).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Wire the platform seam to the io impl

**Files:**
- Modify: `lib/services/guest_identity.dart:10-11` (the conditional import) and `:52-53` (factory).
- Test: `test/services/guest_identity_seam_test.dart`

**Interfaces:**
- Consumes: `createGuestIdentity()` from Task 2.
- Produces: on the Dart VM / native, `createGuestIdentity()` returns a `NativeGuestIdentity`.

- [ ] **Step 1: Write failing test**

```dart
// test/services/guest_identity_seam_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/guest_identity.dart';
import 'package:skchat/services/guest_identity_io.dart';

void main() {
  test('native factory yields the real NativeGuestIdentity, not the stub', () {
    expect(createGuestIdentity(), isA<NativeGuestIdentity>());
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/guest_identity_seam_test.dart`
Expected: FAIL (factory still returns the stub `_StubGuestIdentity`).

- [ ] **Step 3: Implement**

Change the conditional import in `lib/services/guest_identity.dart`:

```dart
import 'guest_identity_stub.dart'
    if (dart.library.io) 'guest_identity_io.dart'
    if (dart.library.html) 'guest_identity_web.dart' as impl;
```

Leave `GuestIdentity createGuestIdentity() => impl.createGuestIdentity();` unchanged. Update the library doc comment's "On non-web targets the stub keeps an in-memory keypair" line to note the native impl is now a real persistent keystore (stub remains only as the no-io/no-html compile fallback).

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/`
Expected: PASS (all identity tests, including the existing operator_session tests, still green).

- [ ] **Step 5: Commit**

```bash
git add lib/services/guest_identity.dart test/services/guest_identity_seam_test.dart
git commit -m "feat(identity): route native targets to the real GuestIdentity

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Cross-language wire-compat fixture (Dart emitter + pytest)

**Files:**
- Create: `test/fixtures/emit_device_fixture.dart` (skchat-app)
- Create: `tests/test_operator_auth_wire_compat.py` (skchat repo, `~/clawd/skcapstone-repos/skchat`)

**Interfaces:**
- Consumes: `NativeGuestIdentity` (Task 2), an in-memory `GuestKeyStore`.
- Produces: a JSON line `{pubkey_b64, fingerprint, payload, sig_b64}` on stdout that the server's real `verify_device_signature` accepts.

- [ ] **Step 1: Write the Dart emitter**

```dart
// test/fixtures/emit_device_fixture.dart
// Emits one JSON fixture line for the Python wire-compat test. Run:
//   dart run test/fixtures/emit_device_fixture.dart
import 'dart:convert';
import 'package:skchat/services/guest_identity_io.dart';
import 'package:skchat/services/guest_key_store.dart';

class _Mem implements GuestKeyStore {
  final Map<String, String> _m = {};
  @override
  Future<void> delete(String k) async => _m.remove(k);
  @override
  Future<String?> read(String k) async => _m[k];
  @override
  Future<void> write(String k, String v) async => _m[k] = v;
}

Future<void> main() async {
  final id = NativeGuestIdentity(store: _Mem());
  final kp = await id.ensure();
  const payload = '{"device_fp":"x","nonce":"wire-compat-nonce"}';
  final sig = await id.sign(payload);
  // ignore: avoid_print
  print(jsonEncode({
    'pubkey_b64': kp.publicKeyB64,
    'fingerprint': kp.fingerprint,
    'payload': payload,
    'sig_b64': sig,
  }));
}
```

- [ ] **Step 2: Write the pytest that consumes it**

```python
# ~/clawd/skcapstone-repos/skchat/tests/test_operator_auth_wire_compat.py
"""Proves the native Flutter GuestIdentity signs something the server accepts.

Runs the Dart fixture emitter in the skchat-app repo, then feeds its output
through the SAME verify path the operator-auth routes use. If this passes, the
thick client's enrollment/handshake signatures will verify server-side.
"""
import json
import os
import shutil
import subprocess

import pytest

from skchat.operator_auth import device_fingerprint, verify_device_signature

APP_DIR = os.path.expanduser("~/clawd/skcapstone-repos/skchat-app")
FLUTTER_BIN = "/home/cbrd21/flutter/bin"


@pytest.mark.skipif(
    not shutil.which("dart", path=FLUTTER_BIN + os.pathsep + os.environ.get("PATH", "")),
    reason="dart SDK not available",
)
def test_native_guest_identity_signature_verifies_server_side():
    env = dict(os.environ, PATH=FLUTTER_BIN + os.pathsep + os.environ.get("PATH", ""))
    out = subprocess.check_output(
        ["dart", "run", "test/fixtures/emit_device_fixture.dart"],
        cwd=APP_DIR, env=env, text=True,
    )
    fx = json.loads(out.strip().splitlines()[-1])
    assert verify_device_signature(
        device_pubkey_b64=fx["pubkey_b64"],
        payload=fx["payload"].encode(),
        sig_b64=fx["sig_b64"],
    ) is True
    assert device_fingerprint(fx["pubkey_b64"]) == fx["fingerprint"]
```

- [ ] **Step 3: Run it**

Run: `cd ~ && ~/.skenv/bin/python -m pytest ~/clawd/skcapstone-repos/skchat/tests/test_operator_auth_wire_compat.py -v`
Expected: PASS (server verify True, fingerprints equal). (Pre-validated by spike; this locks it as a regression test.)

- [ ] **Step 4: Commit (two repos)**

```bash
# skchat-app
git add test/fixtures/emit_device_fixture.dart
git commit -m "test(identity): emit device-key fixture for server wire-compat

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
# skchat
cd ~/clawd/skcapstone-repos/skchat
git checkout -b feat/native-guest-identity-wirecompat
git add tests/test_operator_auth_wire_compat.py
git commit -m "test(operator-auth): verify native Flutter device signatures

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Neutral build config + first-run guard

**Files:**
- Modify: `lib/services/backend_config.dart:24-27` (and any sibling host default in `lib/services/daemon_config.dart`).
- Create: `config/lumina.json`
- Modify/verify: onboarding entry so an empty `skchatWebuiUrl` routes to the server picker (discover exact site in `lib/features/onboarding/` + app router).
- Test: `test/services/backend_config_test.dart` (extend the existing file).

**Interfaces:**
- Consumes: `BackendConfigNotifier`, `kBackendPresets` (existing).
- Produces: neutral compile-time defaults; `config/lumina.json` injecting the `.158` hosts at build time.

- [ ] **Step 1: Write failing test**

```dart
// add to test/services/backend_config_test.dart
test('neutral build ships an empty skchat web-ui default (no baked host)', () {
  expect(kDefaultSkchatWebuiUrl, isEmpty);
});
test('a lumina preset still points at .158 (opt-in, not the default)', () {
  final lumina = kBackendPresets.firstWhere((p) => p.id == 'lumina');
  expect(lumina.config.skchatWebuiUrl, contains('noroc2027'));
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/backend_config_test.dart`
Expected: FAIL (default is currently `https://noroc2027...`).

- [ ] **Step 3: Implement**

In `lib/services/backend_config.dart`, flip the compile-time defaults to empty (keep the `String.fromEnvironment` names so builds can inject):

```dart
const kDefaultSkchatWebuiUrl = String.fromEnvironment(
  'SKCHAT_WEBUI_URL',
  defaultValue: '',
);
```

Do the same for `kDefaultLivekitUrl`, `kDefaultLivekitWebuiUrl`, `kDefaultSkcapstoneUrl`, `kDefaultSkcapstoneDashboardUrl` (empty defaults), and mirror any host default in `daemon_config.dart` (check `kDefaultDaemonUrl`). Leave the `kBackendPresets` `lumina`/`jarvis` entries unchanged (they carry the real hosts, now opt-in via the picker).

Create `config/lumina.json`:

```json
{
  "SKCHAT_WEBUI_URL": "https://noroc2027.tail204f0c.ts.net",
  "LIVEKIT_WEBUI_URL": "https://noroc2027.tail204f0c.ts.net",
  "LIVEKIT_URL": "wss://noroc2027.tail204f0c.ts.net:8443",
  "SKCAPSTONE_URL": "http://noroc2027.tail204f0c.ts.net:7777",
  "SKCAPSTONE_DASHBOARD_URL": "http://noroc2027.tail204f0c.ts.net:7778",
  "SKBLOOM_URL": "http://noroc2027.tail204f0c.ts.net:8774"
}
```

First-run guard: inspect the app router / home shell (grep for where `backendConfigProvider` / `daemonUrlProvider` is first consumed and where `OnboardingScreen` is shown). If a fresh install with an empty `skchatWebuiUrl` does NOT already land on onboarding/the server picker, add a redirect: when `backendConfigProvider.skchatWebuiUrl.isEmpty`, route to `OnboardingScreen` (or the Profile instance picker) before any gated client is constructed. Confirm no client throws on an empty base URL (dio with `baseUrl: ''` must not be reached; the guard prevents it).

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/backend_config_test.dart && flutter analyze`
Expected: PASS + no analyzer errors.

- [ ] **Step 5: Commit**

```bash
git add lib/services/backend_config.dart lib/services/daemon_config.dart \
        config/lumina.json test/services/backend_config_test.dart \
        lib/features/onboarding lib/app*  # whatever the guard touched
git commit -m "feat(build): neutral defaults; inject .158 via config/lumina.json

Code no longer hard-codes the private noroc2027 host; Chef's builds inject it
with --dart-define-from-file. Empty-host first run routes to the server picker.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: Build scripts (web must inject lumina; linux operator + neutral)

**Files:**
- Create: `scripts/build-web-lumina.sh`, `scripts/build-linux-lumina.sh`, `scripts/build-linux-neutral.sh`
- Modify: `HANDOFF-*` / any deploy doc that documents the web build recipe (add the `--dart-define-from-file` flag).

**Interfaces:** none (shell). The web script MUST inject `config/lumina.json` or the deployed web app loses its host (regression from Task 5's empty default).

- [ ] **Step 1: Write the scripts**

```bash
# scripts/build-web-lumina.sh
#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
flutter build web --release --base-href /app/ --pwa-strategy=none \
  --dart-define-from-file=config/lumina.json
echo "built web (lumina). rsync into skchat/src/skchat/static/app/ then restart skchat-webui@lumina"
```

```bash
# scripts/build-linux-lumina.sh
#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
flutter build linux --release --dart-define-from-file=config/lumina.json
echo "built build/linux/x64/release/bundle (operator build -> .158)"
```

```bash
# scripts/build-linux-neutral.sh
#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
flutter build linux --release
echo "built build/linux/x64/release/bundle (neutral: user picks server at first run)"
```

- [ ] **Step 2: Make executable + smoke the web build**

```bash
chmod +x scripts/build-web-lumina.sh scripts/build-linux-lumina.sh scripts/build-linux-neutral.sh
export PATH=/home/cbrd21/flutter/bin:$PATH && bash scripts/build-web-lumina.sh
```
Expected: web build succeeds; `build/web/main.dart.js` contains `noroc2027` (the injected host baked in). Verify: `grep -c noroc2027 build/web/main.dart.js` > 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-web-lumina.sh scripts/build-linux-lumina.sh scripts/build-linux-neutral.sh
git commit -m "build: web(inject lumina) + linux operator/neutral build scripts

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Operator linux build + native media/enrollment smoke (verification)

**Files:** none (verification task; findings recorded in the PR/handoff).

**Interfaces:** exercises Tasks 1-6 as a whole on Chef's Linux box.

- [ ] **Step 1: Build the operator linux client**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && bash scripts/build-linux-lumina.sh`
Expected: succeeds; confirm the vendored flutter-webrtc fork (`ref a7db44d9…` in pubspec `dependency_overrides`) is the one resolved (`grep -A3 flutter_webrtc pubspec.lock | grep a7db44d9`).

- [ ] **Step 2: Run + enroll**

Launch `build/linux/x64/release/bundle/skchat`. Over the tailnet the server trusts loopback/tailnet without the operator token, so open enrollment (or if `SKCHAT_GUEST_OPERATOR_TOKEN` is required by the webui env, use the operator-token path in settings). Enroll this device.

Expected: the M1 self-identity surface shows the **operator/green** tier (not guest/red); `~/.skchat-app/guest_identity.json` exists with `0600` perms (or the key is in the keyring); a gated call (e.g. `GET /api/v1/conversations`) succeeds (200, not 401).

- [ ] **Step 3: Media parity**

Confirm camera publish, screen-share, system-audio (LoopbackCapturer), and the camera-stop-unpublish behavior work natively (join a Space, share, stop, confirm the far side clears).

- [ ] **Step 4: Record results**

Append a short PASS/FAIL note (identity tier, enrollment, media) to the PR description. If any step fails, open a systematic-debugging session rather than patching blind.

- [ ] **Step 5: Finalize**

Use `superpowers:finishing-a-development-branch` to decide merge/PR for both repos (`skchat-app` `feat/native-guest-identity`, `skchat` `feat/native-guest-identity-wirecompat`). Bump `pubspec.yaml` version (still `1.3.2+9`; the M1 + this native work warrant a bump, e.g. `1.4.0+10`).

---

## Self-Review

**Spec coverage:**
- Crypto contract (SPKI, fingerprint, P1363 sig) → Tasks 2, 4 (validated end-to-end via spike + pytest). ✓
- Persistence: secure + file fallback + degraded → Tasks 1, 2. ✓
- Platform seam wiring → Task 3. ✓
- Neutral build + first-run guard → Task 5. ✓
- Build scripts (web inject / linux operator / neutral) → Task 6. ✓
- Operator build + media parity smoke → Task 7. ✓
- Out-of-scope items (M1b badges, call gate, recovery phrase, CI) correctly excluded. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; the one discovery point (first-run guard site in Task 5) is bounded with an explicit grep + fallback action, not a vague "handle it". ✓

**Type consistency:** `GuestKeyStore.{read,write,delete}` identical across Tasks 1-4; `NativeGuestIdentity({GuestKeyStore? store})` ctor consistent; storage keys `skchat.guest.priv` / `skchat.guest.pub_spki` consistent between impl (Task 2) and tests (Tasks 2, 4); `publicKeyB64`/`fingerprint`/`degraded` match the existing `GuestKeypair`. ✓
