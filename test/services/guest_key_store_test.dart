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

/// In-memory fake backed by a plain map, so tests can seed/inspect state
/// directly without touching the filesystem.
class _MapStore implements GuestKeyStore {
  _MapStore([Map<String, String>? seed]) : data = seed ?? {};
  final Map<String, String> data;

  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
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

  test('FileGuestKeyStore write leaves no world-readable window (0600, '
      'no leftover temp file)', () async {
    final dir = await Directory.systemTemp.createTemp('gks-perm');
    final store = FileGuestKeyStore(dirPath: dir.path);
    await store.write('secret', 'top-secret-value');
    // The final file is owner-only from the moment it holds the secret.
    final f = File('${dir.path}/guest_identity.json');
    final mode = (await f.stat()).mode & 0x1FF;
    expect(mode, 0x180); // 0600
    // The temp file used to stage the write is gone (renamed onto the
    // target), so no `.tmp-*` artifact is left lying around.
    final leftovers = await dir
        .list()
        .where((e) => e.path.contains('.tmp-'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('corrupt keystore file is preserved as a .corrupt-* sidecar, not '
      'silently overwritten', () async {
    final dir = await Directory.systemTemp.createTemp('gks-corrupt');
    final target = File('${dir.path}/guest_identity.json');
    await target.create(recursive: true);
    await target.writeAsString('not valid json {{{');

    final store = FileGuestKeyStore(dirPath: dir.path);
    // The corrupt file is not a throw; it reads as if the key were absent.
    expect(await store.read('k'), isNull);
    // The original bytes are preserved under a .corrupt-<pid> sidecar rather
    // than being destroyed, so prior key material survives for recovery.
    final siblings = await dir.list().toList();
    final corruptSidecars =
        siblings.where((e) => e.path.contains('.corrupt-')).toList();
    expect(corruptSidecars, isNotEmpty);
    expect(await target.exists(), isFalse);
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

  test('read falls back to secondary when primary is reachable but empty',
      () async {
    // Primary (keyring) is up but has no value for this key; secondary
    // (file) still holds it from a session where the primary was down.
    final primary = _MapStore();
    final secondary = _MapStore({'k': 'from-secondary'});
    final store = FallbackGuestKeyStore(primary, secondary);
    expect(await store.read('k'), 'from-secondary');
  });

  test('read prefers primary value over secondary when both have it',
      () async {
    final primary = _MapStore({'k': 'from-primary'});
    final secondary = _MapStore({'k': 'from-secondary'});
    final store = FallbackGuestKeyStore(primary, secondary);
    expect(await store.read('k'), 'from-primary');
  });

  test('delete removes the key from BOTH backends', () async {
    final primary = _MapStore({'k': 'v'});
    final secondary = _MapStore({'k': 'v'});
    final store = FallbackGuestKeyStore(primary, secondary);
    await store.delete('k');
    expect(primary.data.containsKey('k'), isFalse);
    expect(secondary.data.containsKey('k'), isFalse);
  });

  test('delete rethrows only when BOTH throw', () async {
    final store = FallbackGuestKeyStore(_ThrowingStore(), _ThrowingStore());
    expect(() => store.delete('k'), throwsA(isA<Object>()));
  });
}
