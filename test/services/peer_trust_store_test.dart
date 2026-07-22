import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/peer_trust_store.dart';

class _MemStore implements PeerTrustStore {
  Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => Map.of(_m);
  @override
  Future<void> save(Map<String, PeerTrustRecord> m) async => _m = Map.of(m);
}

PeerTrustResolver _resolver([_MemStore? s]) =>
    PeerTrustResolver(s ?? _MemStore(), now: () => DateTime(2026, 7, 22));

void main() {
  test('first sight records red (TOFU), unverified', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.red);
  });

  test('no fingerprint resolves unverifiable', () async {
    final r = _resolver();
    expect(await r.tierFor('ghost', null), PeerTrustTier.unverifiable);
  });

  test('fingerprint equal to peerId (fallback) resolves unverifiable',
      () async {
    final r = _resolver();
    expect(await r.tierFor('bob', 'bob'), PeerTrustTier.unverifiable);
  });

  test('a real fingerprint (!= peerId) first sight resolves red', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.red);
  });

  test('markVerified promotes to amber for the current fingerprint', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp1');
    await r.markVerified('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.amber);
  });

  test(
      'a VERIFIED peer whose real fingerprint changes reverts to red '
      'and flags a key change', () async {
    final s = _MemStore();
    final r = _resolver(s);
    await r.recordSight('bob', 'fp1');
    await r.markVerified('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.amber);
    final changed = await r.recordSight('bob', 'fp2'); // key rotated
    expect(changed, isTrue);
    expect(await r.isKeyChanged('bob', 'fp2'), isTrue);
    expect(await r.tierFor('bob', 'fp2'), PeerTrustTier.red);
  });

  test(
      'an UNVERIFIED peer whose fingerprint changes stays red silently '
      '(no false alarm)', () async {
    final s = _MemStore();
    final r = _resolver(s);
    await r.recordSight('bob', 'fp1'); // unverified
    final changed = await r.recordSight('bob', 'fp2'); // still unverified
    expect(changed, isFalse);
    expect(await r.isKeyChanged('bob', 'fp2'), isFalse);
    expect(await r.tierFor('bob', 'fp2'), PeerTrustTier.red);
  });

  test('cannot verify against a stale fingerprint', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp2');
    await r.markVerified('bob', 'fp1'); // stale, ignored
    expect(await r.tierFor('bob', 'fp2'), PeerTrustTier.red);
  });

  test('records persist through the store (round-trip)', () async {
    final s = _MemStore();
    await _resolver(s).markVerifyFlow('bob', 'fp1'); // helper: record+verify
    final r2 = _resolver(s);
    expect(await r2.tierFor('bob', 'fp1'), PeerTrustTier.amber);
  });

  test(
      'recordSight with a null/empty/peerId-fallback fp is a no-op and '
      'does not clobber an existing real-key verified record', () async {
    final s = _MemStore();
    final r = _resolver(s);
    await r.recordSight('bob', 'fpReal');
    await r.markVerified('bob', 'fpReal');
    expect(await r.tierFor('bob', 'fpReal'), PeerTrustTier.amber);

    final changedByFallback = await r.recordSight('bob', 'bob'); // fp == peerId
    expect(changedByFallback, isFalse);
    expect(await r.tierFor('bob', 'fpReal'), PeerTrustTier.amber);
    expect(await r.isKeyChanged('bob', 'fpReal'), isFalse);

    final changedByNull = await r.recordSight('bob', null);
    expect(changedByNull, isFalse);
    expect(await r.tierFor('bob', 'fpReal'), PeerTrustTier.amber);
    expect(await r.isKeyChanged('bob', 'fpReal'), isFalse);
  });
}
