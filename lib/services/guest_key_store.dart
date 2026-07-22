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
