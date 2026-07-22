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
