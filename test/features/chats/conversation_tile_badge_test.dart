import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/widgets/conversation_tile.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/peer_trust_store.dart';

/// In-memory trust store so the tier resolver is Hive-free (widget-test fake
/// async never completes real Hive file I/O, which would leave the tier
/// provider stuck AsyncLoading and mask the real render behaviour).
class _MemStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _m;
  _MemStore([Map<String, PeerTrustRecord>? seed]) : _m = seed ?? {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => _m;
  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    _m
      ..clear()
      ..addAll(records);
  }
}

/// Reproduces the reported bug: a 1:1 conversation whose peer carries a REAL
/// capauth fingerprint must render a trust badge (red = untrusted-but-keyed) in
/// the inbox tile. The live app receives real fingerprints for every agent peer
/// (verified against the webui /api/v1/conversations payload) yet shows no dot,
/// so the failure is in the render path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a real-key 1:1 peer renders a trust badge (red)', (tester) async {
    final convo = Conversation(
      peerId: 'steward@skworld.io',
      displayName: 'Steward',
      lastMessage: '[system message]',
      lastMessageTime: DateTime(2026, 7, 22, 12),
      // The exact real capauth fingerprint the live webui serves for steward.
      soulFingerprint: '4E06A71935D1DF1FB9848112D8634AB3E7B55236',
      isGroup: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerTrustResolverProvider.overrideWithValue(
            PeerTrustResolver(_MemStore()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ConversationTile(conversation: convo, onTap: () {}),
          ),
        ),
      ),
    );
    // Let the async peerTrustTierProvider resolve (real Hive file I/O →
    // tierFor → red). runAsync lets the real Future complete; then pump to
    // flush the Riverpod-triggered rebuild.
    await tester.pumpAndSettle();

    expect(find.byType(TrustBadge), findsOneWidget,
        reason: 'a keyed, unverified peer must show the red trust dot');
  });

  testWidgets('a keyless peer (fingerprint == peerId) shows NO badge',
      (tester) async {
    final convo = Conversation(
      peerId: 'opus',
      displayName: 'opus',
      lastMessage: 'hi',
      lastMessageTime: DateTime(2026, 7, 22, 12),
      soulFingerprint: 'opus', // peerId fallback → not a real key
      isGroup: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peerTrustResolverProvider.overrideWithValue(
            PeerTrustResolver(_MemStore()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ConversationTile(conversation: convo, onTap: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TrustBadge), findsNothing,
        reason: 'an unverifiable/keyless peer must not show a badge');
  });
}
