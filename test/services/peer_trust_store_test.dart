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

  test('no fingerprint resolves red', () async {
    final r = _resolver();
    expect(await r.tierFor('ghost', null), PeerTrustTier.red);
  });

  test('markVerified promotes to amber for the current fingerprint', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp1');
    await r.markVerified('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.amber);
  });

  test('a changed fingerprint reverts to red + flags key change', () async {
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
}
