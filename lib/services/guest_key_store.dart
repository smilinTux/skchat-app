import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'guest_keystore_crypto.dart';

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

/// Raw atomic 0600-file backing shared by the plaintext and encrypted file
/// stores. Handles directory creation, owner-only permissions, atomic
/// temp+rename, and preserving an unreadable file as a `.corrupt-<pid>`
/// sidecar instead of destroying it.
class _KeystoreFileIo {
  const _KeystoreFileIo(this.path);
  final String path;

  File get _file => File(path);

  /// Read the raw file contents, or null if the file does not exist.
  Future<String?> read() async {
    final f = _file;
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  /// Atomically write [contents], locking the file to 0600 BEFORE any bytes
  /// are written into it. rename() preserves the mode, so the target file is
  /// 0600 from the instant it holds the secret, never 0644 in between. dart:io
  /// has no chmod, so this shells out on Linux/macOS.
  Future<void> write(String contents) async {
    await _file.parent.create(recursive: true);
    final tmp = File('$path.tmp-$pid');
    await tmp.create();
    if (Platform.isLinux || Platform.isMacOS) {
      final r = await Process.run('chmod', ['600', tmp.path]);
      if (r.exitCode != 0) {
        await tmp.delete();
        throw StateError('chmod failed on keystore temp file');
      }
    }
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(path);
  }

  /// Preserve an unreadable (corrupt or undecryptable) file under a
  /// `.corrupt-<pid>` sidecar so prior key material survives for recovery
  /// instead of being silently overwritten by the next write. Best-effort.
  Future<void> sidecarCorrupt() async {
    try {
      await _file.rename('$path.corrupt-$pid');
    } catch (_) {
      // Rename itself failed; the caller still treats the file as absent.
    }
  }
}

/// A file-backed store at `$HOME/.skchat-app/guest_identity.json`, `0600`,
/// written atomically (temp + rename). Persists on any Linux box even with no
/// Secret Service running, so an operator device stays enrolled across
/// restarts.
///
/// NOTE: this store writes values in PLAINTEXT. Prefer
/// [EncryptedFileGuestKeyStore] for the device-key fallback so the private
/// scalar is not left in the clear on disk. This class is retained for the
/// atomic-file primitives and as the legacy on-disk format that the encrypted
/// store transparently reads and migrates.
class FileGuestKeyStore implements GuestKeyStore {
  FileGuestKeyStore({String? dirPath})
      : _io = _KeystoreFileIo('${_resolveDir(dirPath)}/guest_identity.json');

  final _KeystoreFileIo _io;

  static String _resolveDir(String? dirPath) =>
      dirPath ?? '${Platform.environment['HOME'] ?? '.'}/.skchat-app';

  Future<Map<String, String>> _load() async {
    final raw = await _io.read();
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // Corrupt file: rename it aside so the prior key material is kept for
      // recovery instead of being silently overwritten by the next write.
      await _io.sidecarCorrupt();
    }
    return {};
  }

  Future<void> _save(Map<String, String> data) => _io.write(jsonEncode(data));

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

/// A file-backed store whose payload is encrypted at rest with AES-256-GCM.
///
/// Used ONLY as the file fallback for the native device key when the OS
/// keyring is unavailable. The wrapping key is derived (HKDF-SHA256) from a
/// stable per-machine secret (`/etc/machine-id`) mixed with a per-install
/// random salt kept in a SEPARATE 0600 file (`guest_identity.salt`), so the
/// key is NOT derivable from `guest_identity.json` alone. See
/// [MachineBoundKeystoreCipher] for the full threat model: this is
/// REDUCED-ASSURANCE (a same-UID attacker who reads both files plus
/// `/etc/machine-id` can still decrypt); it defeats casual exfiltration
/// (backups, home-dir sync, a copied `guest_identity.json`), not a privileged
/// local attacker.
///
/// On-disk format is a versioned JSON envelope (magic field
/// [kKeystoreMagicField]). A legacy PLAINTEXT `guest_identity.json` (the old
/// [FileGuestKeyStore] format) is detected by the absence of that field, read
/// transparently, and migrated to the encrypted envelope on the next write.
class EncryptedFileGuestKeyStore implements GuestKeyStore {
  EncryptedFileGuestKeyStore({
    String? dirPath,
    String? machineIdOverride,
    List<String>? machineIdPaths,
  })  : _io = _KeystoreFileIo(
            '${FileGuestKeyStore._resolveDir(dirPath)}/guest_identity.json'),
        _cipher = MachineBoundKeystoreCipher(
          saltPath:
              '${FileGuestKeyStore._resolveDir(dirPath)}/guest_identity.salt',
          machineIdOverride: machineIdOverride,
          machineIdPaths: machineIdPaths,
        );

  final _KeystoreFileIo _io;
  final MachineBoundKeystoreCipher _cipher;

  Future<Map<String, String>> _load() async {
    final raw = await _io.read();
    if (raw == null) return {};

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Not even JSON: preserve and treat as absent.
      await _io.sidecarCorrupt();
      return {};
    }

    if (MachineBoundKeystoreCipher.isEnvelope(decoded)) {
      try {
        final plaintext = await _cipher.open(decoded as Map);
        final inner = jsonDecode(plaintext);
        if (inner is Map) {
          return inner.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {
        // Undecryptable: missing/wrong salt, wrong machine-id, or a tampered
        // ciphertext (GCM tag failure). Fail SAFE: never return partial or
        // garbage bytes. Preserve the ciphertext as a sidecar and report the
        // key as absent so the caller can regenerate rather than trust junk.
      }
      await _io.sidecarCorrupt();
      return {};
    }

    // Legacy plaintext map (old FileGuestKeyStore format): read it as-is. The
    // next write re-serializes through _save(), migrating it to the envelope.
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    await _io.sidecarCorrupt();
    return {};
  }

  Future<void> _save(Map<String, String> data) async {
    final envelope = await _cipher.seal(jsonEncode(data));
    await _io.write(envelope);
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
///
/// [read] additionally falls back when the primary is reachable but simply
/// has no value for the key: a key written to the secondary while the
/// primary was down must still be found once the primary comes back empty,
/// so a caller never regenerates and orphans the persisted identity.
///
/// [delete] is best-effort on BOTH backends independently, so "forget me"
/// truly clears the key wherever it lives instead of leaving a copy that
/// gets resurrected on the next read.
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
  Future<String?> read(String key) async {
    String? primaryValue;
    try {
      primaryValue = await _primary.read(key);
    } catch (_) {
      // Primary is down: the secondary is the only source of truth.
      return await _secondary.read(key);
    }
    if (primaryValue != null) return primaryValue;
    // Primary is reachable but empty: check the secondary before giving
    // up, in case the key was persisted there during a primary outage.
    try {
      return await _secondary.read(key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _either((s) => s.write(key, value));

  @override
  Future<void> delete(String key) async {
    Object? primaryError;
    Object? secondaryError;
    try {
      await _primary.delete(key);
    } catch (e) {
      primaryError = e;
    }
    try {
      await _secondary.delete(key);
    } catch (e) {
      secondaryError = e;
    }
    if (primaryError != null && secondaryError != null) {
      throw primaryError;
    }
  }
}
