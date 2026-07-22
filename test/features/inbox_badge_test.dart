import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/widgets/conversation_tile.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/peer_trust_store.dart';

/// In-memory [PeerTrustStore] so tests seed/read trust state without
/// touching real Hive I/O.
class _FakeTrustStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _records = {};

  @override
  Future<Map<String, PeerTrustRecord>> load() async => Map.of(_records);

  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    _records
      ..clear()
      ..addAll(records);
  }
}

Conversation _conversation({
  required String peerId,
  required String displayName,
  String? soulFingerprint,
  bool isGroup = false,
}) {
  return Conversation(
    peerId: peerId,
    displayName: displayName,
    lastMessage: 'hey',
    lastMessageTime: DateTime.now(),
    soulFingerprint: soulFingerprint,
    isGroup: isGroup,
  );
}

ProviderContainer _containerWithFakeStore() {
  final store = _FakeTrustStore();
  return ProviderContainer(overrides: [
    peerTrustResolverProvider.overrideWithValue(PeerTrustResolver(store)),
  ]);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Conversation conversation,
) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: ConversationTile(
          conversation: conversation,
          onTap: () {},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('1:1 row with a verified peer shows an amber trust badge',
      (tester) async {
    final container = _containerWithFakeStore();
    addTearDown(container.dispose);
    // Seed the peer as amber (verified) via TOFU + markVerified.
    await container
        .read(peerTrustControllerProvider)
        .recordSight('bob', 'fpBOB');
    await container
        .read(peerTrustControllerProvider)
        .markVerified('bob', 'fpBOB');

    await _pump(
      tester,
      container,
      _conversation(
          peerId: 'bob', displayName: 'Bob', soulFingerprint: 'fpBOB'),
    );

    expect(find.bySemanticsLabel(RegExp('Provisional')), findsOneWidget);
  });

  testWidgets('group conversation renders no trust badge', (tester) async {
    final container = _containerWithFakeStore();
    addTearDown(container.dispose);

    await _pump(
      tester,
      container,
      _conversation(
        peerId: 'group-1',
        displayName: 'Squad',
        soulFingerprint: 'fpGROUP',
        isGroup: true,
      ),
    );

    expect(find.bySemanticsLabel(RegExp('Provisional')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Untrusted')), findsNothing);
  });

  testWidgets('1:1 row with no fingerprint renders no trust badge',
      (tester) async {
    final container = _containerWithFakeStore();
    addTearDown(container.dispose);

    await _pump(
      tester,
      container,
      _conversation(peerId: 'carol', displayName: 'Carol'),
    );

    expect(find.bySemanticsLabel(RegExp('Provisional')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Untrusted')), findsNothing);
  });

  testWidgets(
      '1:1 row whose fingerprint equals its peerId (unverifiable, no real '
      'key) renders no trust badge', (tester) async {
    final container = _containerWithFakeStore();
    addTearDown(container.dispose);

    await _pump(
      tester,
      container,
      // The chats_provider fallback echoes peerId back as the fingerprint
      // when there is no real capauth key; that must resolve to
      // `unverifiable`, not `red`, and show no badge.
      _conversation(
          peerId: 'dave', displayName: 'Dave', soulFingerprint: 'dave'),
    );

    expect(find.bySemanticsLabel(RegExp('Provisional')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Untrusted')), findsNothing);
  });
}
