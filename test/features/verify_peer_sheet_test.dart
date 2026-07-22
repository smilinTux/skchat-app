import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/features/identity/verify_peer_sheet.dart';
import 'package:skchat/services/peer_trust_store.dart';

/// In-memory [PeerTrustStore] fake, same shape as the one in
/// peer_trust_store_test.dart. peerTrustResolverProvider defaults to a
/// REAL Hive-backed store, and real dart:io File I/O awaited inside a
/// widget's build/provider chain deadlocks under the fake-async pump clock
/// `testWidgets` normally runs in (it never completes without
/// `tester.runAsync`). Overriding the resolver with this in-memory store
/// exercises the exact same TOFU/verify logic without touching a real box,
/// which is the seam [PeerTrustStore] exists for.
class _MemStore implements PeerTrustStore {
  Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => Map.of(_m);
  @override
  Future<void> save(Map<String, PeerTrustRecord> m) async => _m = Map.of(m);
}

void main() {
  // A couple of unrelated Hive-backed providers (daemon config, operator
  // session) are on selfIdentityProvider's dependency chain. Give Hive a
  // real (temp-dir) home so those best-effort loads succeed quietly instead
  // of throwing "Hive not initialized" into the test's zone.
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skchat_verify_peer_test');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    await Hive.deleteFromDisk();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('Mark verified promotes the peer to amber', (tester) async {
    final container = ProviderContainer(overrides: [
      peerTrustResolverProvider.overrideWithValue(
        PeerTrustResolver(_MemStore()),
      ),
    ]);
    addTearDown(container.dispose);
    // Seed a sight so a record exists.
    await container
        .read(peerTrustControllerProvider)
        .recordSight('bob', 'fpBOB');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Consumer(builder: (context, ref, _) {
              return ElevatedButton(
                onPressed: () => showVerifyPeerSheet(context, ref,
                    peerId: 'bob', peerName: 'Bob', peerFingerprint: 'fpBOB'),
                child: const Text('open'),
              );
            }),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Safety number'), findsOneWidget);
    await tester.tap(find.text('Mark verified'));
    await tester.pumpAndSettle();
    expect(
        await container.read(peerTrustResolverProvider).tierFor('bob', 'fpBOB'),
        PeerTrustTier.amber);
  });
}
