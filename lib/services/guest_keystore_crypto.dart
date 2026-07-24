// Machine-bound authenticated encryption for the FILE-fallback keystore.
//
// THREAT MODEL (read this before touching the crypto):
// The file-fallback keystore (`FileGuestKeyStore`) is only used when the OS
// keyring (Secret Service / libsecret) is unavailable, which is common on
// headless/minimal Linux, the thick-client target. Historically it wrote
// `base64(d)` (the raw ECDSA P-256 private scalar) as PLAINTEXT to
// `~/.skchat-app/guest_identity.json`. That means a filesystem backup, a
// home-dir sync (Syncthing/Dropbox), or a casually copied JSON file carried
// the operator's full private identity off the device.
//
// This layer wraps the payload with AES-256-GCM. The wrapping key is derived
// (HKDF-SHA256) from TWO inputs that must BOTH be present to decrypt:
//   1. a STABLE per-machine secret: `/etc/machine-id` (fallback
//      `~/.config/machine-id`). This lives OUTSIDE the home directory, so a
//      home-dir backup / sync does NOT carry it.
//   2. a per-install random salt persisted in a SEPARATE 0600 file next to
//      the keystore (`guest_identity.salt`). It is NOT stored in the
//      ciphertext envelope, so the envelope alone is not decryptable.
//
// This is REDUCED ASSURANCE by design. A same-UID attacker who can read BOTH
// `guest_identity.salt` AND `/etc/machine-id` can still derive the key and
// decrypt. The point is to defeat CASUAL exfiltration (a stray backup, a
// synced home dir, a copied `guest_identity.json`), NOT a privileged local
// attacker who already has arbitrary read of the user's files. The real OS
// keyring, when present, is always preferred and this layer is never used.
//
// The wrapping key and plaintext are NEVER logged.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Magic/version key present ONLY in the encrypted envelope. Its presence is
/// how the reader distinguishes an encrypted file from a legacy plaintext map
/// (detected by tag, never by guessing at the bytes).
const String kKeystoreMagicField = 'skchat_keystore_version';
const int kKeystoreVersion = 1;
const String _kInfo = 'skchat-guest-keystore-v1';
const int _kNonceLen = 12; // AES-GCM standard nonce
const int _kSaltLen = 32;
const int _kKeyLen = 32; // AES-256
const int _kMacBits = 128;

/// Raised when the per-install salt file is required for decryption but is
/// absent. The caller treats this as "undecryptable" and fails safe (it does
/// NOT fabricate a fresh salt, which would only guarantee a wrong key).
class KeystoreSaltMissing implements Exception {
  const KeystoreSaltMissing();
  @override
  String toString() => 'keystore salt file is missing';
}

/// Derives the AES wrapping key and seals/opens the keystore envelope.
///
/// Machine-id resolution order: [machineIdOverride] (test hook) -> the first
/// existing path in [machineIdPaths] (default `/etc/machine-id` then
/// `~/.config/machine-id`). Throws [StateError] if none is available, so the
/// caller can degrade rather than silently encrypt with an empty secret.
class MachineBoundKeystoreCipher {
  MachineBoundKeystoreCipher({
    required this.saltPath,
    String? machineIdOverride,
    List<String>? machineIdPaths,
  })  : _machineIdOverride = machineIdOverride,
        _machineIdPaths = machineIdPaths ??
            <String>[
              '/etc/machine-id',
              '${Platform.environment['HOME'] ?? '.'}/.config/machine-id',
            ];

  /// Path of the SEPARATE 0600 salt file (kept out of the envelope).
  final String saltPath;
  final String? _machineIdOverride;
  final List<String> _machineIdPaths;

  /// Encrypt [plaintext] into a self-describing JSON envelope string. Creates
  /// the salt file on first use. The salt is NOT included in the envelope.
  Future<String> seal(String plaintext) async {
    final key = await _wrappingKey(createSaltIfMissing: true);
    final nonce = _randomBytes(_kNonceLen);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), _kMacBits, nonce, Uint8List(0)),
      );
    final ct = gcm.process(Uint8List.fromList(utf8.encode(plaintext)));
    return jsonEncode(<String, dynamic>{
      kKeystoreMagicField: kKeystoreVersion,
      'alg': 'AES-256-GCM',
      'kdf': 'HKDF-SHA256',
      'nonce': base64.encode(nonce),
      'ct': base64.encode(ct),
    });
  }

  /// True when [decoded] is an encrypted envelope (has the magic version tag)
  /// as opposed to a legacy plaintext key/value map.
  static bool isEnvelope(Object? decoded) =>
      decoded is Map && decoded.containsKey(kKeystoreMagicField);

  /// Decrypt an envelope map back to its plaintext string. Throws on ANY
  /// failure: missing salt ([KeystoreSaltMissing]), malformed envelope
  /// ([FormatException]/[ArgumentError]), or a failed GCM tag
  /// ([InvalidCipherTextException]). It NEVER returns partial/garbage output,
  /// so the caller can safely treat any throw as "unreadable, fail safe".
  Future<String> open(Map<dynamic, dynamic> env) async {
    final nonceB64 = env['nonce'];
    final ctB64 = env['ct'];
    if (nonceB64 is! String || ctB64 is! String) {
      throw const FormatException('keystore envelope missing nonce/ct');
    }
    final nonce = base64.decode(nonceB64);
    final ct = base64.decode(ctB64);
    // Salt MUST already exist for a decrypt; never fabricate one.
    final key = await _wrappingKey(createSaltIfMissing: false);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(key), _kMacBits, nonce, Uint8List(0)),
      );
    // Throws InvalidCipherTextException if the tag does not verify (wrong
    // machine-id, wrong salt, or tampered ciphertext).
    final pt = gcm.process(ct);
    return utf8.decode(pt);
  }

  // ── key derivation ─────────────────────────────────────────────────────
  Future<Uint8List> _wrappingKey({required bool createSaltIfMissing}) async {
    final ikm = _machineIdBytes();
    final salt = await _salt(createIfMissing: createSaltIfMissing);
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        ikm,
        _kKeyLen,
        salt,
        Uint8List.fromList(utf8.encode(_kInfo)),
      ));
    // HKDF ignores the process() input; keying material comes from params.
    return hkdf.process(Uint8List(0));
  }

  Uint8List _machineIdBytes() {
    final id = _machineIdString();
    if (id.isEmpty) {
      throw StateError(
        'no machine-id available to bind the keystore key '
        '(checked ${_machineIdPaths.join(", ")})',
      );
    }
    return Uint8List.fromList(utf8.encode(id));
  }

  String _machineIdString() {
    final override = _machineIdOverride;
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    for (final p in _machineIdPaths) {
      final f = File(p);
      if (f.existsSync()) {
        final v = f.readAsStringSync().trim();
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

  Future<Uint8List> _salt({required bool createIfMissing}) async {
    final f = File(saltPath);
    if (await f.exists()) {
      final raw = (await f.readAsString()).trim();
      final decoded = base64.decode(raw);
      if (decoded.length != _kSaltLen) {
        throw const FormatException('keystore salt has an unexpected length');
      }
      return Uint8List.fromList(decoded);
    }
    if (!createIfMissing) throw const KeystoreSaltMissing();
    final salt = _randomBytes(_kSaltLen);
    await _writeOwnerOnly(f, base64.encode(salt));
    return salt;
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  /// Write [contents] to [f] with 0600 perms from the moment it holds bytes
  /// (temp + chmod-before-write + rename), mirroring the keystore file's own
  /// atomic write so the salt is never briefly world-readable.
  Future<void> _writeOwnerOnly(File f, String contents) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp-$pid');
    await tmp.create();
    if (Platform.isLinux || Platform.isMacOS) {
      final r = await Process.run('chmod', ['600', tmp.path]);
      if (r.exitCode != 0) {
        await tmp.delete();
        throw StateError('chmod failed on keystore salt temp file');
      }
    }
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(f.path);
  }
}
