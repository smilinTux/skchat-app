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
      // Corrupt file: rename it aside so the prior key material is kept for
      // recovery instead of being silently overwritten by the next write.
      try {
        await f.rename('${f.path}.corrupt-$pid');
      } catch (_) {
        // Rename itself failed; fall back to the old behavior below.
      }
    }
    return {};
  }

  Future<void> _save(Map<String, String> data) async {
    await Directory(_dirPath).create(recursive: true);
    final tmp = File('${_file.path}.tmp-$pid');
    // Create the temp file and lock it down to owner-only BEFORE any secret
    // bytes are written into it. rename() preserves the mode, so the target
    // file is 0600 from the instant it holds the secret, never 0644 in
    // between. dart:io has no chmod, so this shells out on Linux/macOS.
    await tmp.create();
    if (Platform.isLinux || Platform.isMacOS) {
      final r = await Process.run('chmod', ['600', tmp.path]);
      if (r.exitCode != 0) {
        await tmp.delete();
        throw StateError('chmod failed on keystore temp file');
      }
    }
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(_file.path);
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
