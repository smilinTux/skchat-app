import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/guest_ring.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat_ui/skchat_ui.dart';

/// Seeds chatsProvider with a fixed list (no daemon), mirroring the pattern in
/// space_share_sheet_test.
class FakeChatsNotifier extends ChatsNotifier {
  FakeChatsNotifier(this._seed);
  final List<Conversation> _seed;
  @override
  List<Conversation> build() => _seed;
}

Conversation _c({
  required String peerId,
  bool isGuestDm = true,
  bool ringing = true,
  double? ringTs = 1000,
  String? alias,
  String guestName = 'Mallory',
  String? status,
}) =>
    Conversation(
      peerId: peerId,
      displayName: 'raw-group-name',
      lastMessage: '',
      lastMessageTime: DateTime(2026, 8, 7),
      isGroup: true,
      isGuestDm: isGuestDm,
      guestName: guestName,
      guestAlias: alias,
      guestStatus: status,
      ringing: ringing,
      ringTs: ringTs,
    );

ProviderContainer _container(List<Conversation> convos) {
  final c = ProviderContainer(
    overrides: [chatsProvider.overrideWith(() => FakeChatsNotifier(convos))],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('a ringing guest DM surfaces as the active ring', () {
    final c = _container([
      _c(peerId: 'lumina', isGuestDm: false),
      _c(peerId: 'g-ring', alias: 'Alex'),
    ]);
    expect(c.read(guestRingProvider)?.peerId, 'g-ring');
  });

  test('dismiss dedupes by ring_ts so it does not re-surface', () {
    final c = _container([_c(peerId: 'g-ring')]);
    final ringing = c.read(guestRingProvider);
    expect(ringing, isNotNull);
    c.read(guestRingProvider.notifier).dismiss(ringing!);
    expect(c.read(guestRingProvider), isNull);
  });

  test('a NEW ring_ts on the same guest re-rings after a prior dismiss', () {
    // First ring dismissed...
    final c1 = _container([_c(peerId: 'g-ring', ringTs: 1000)]);
    final r1 = c1.read(guestRingProvider)!;
    c1.read(guestRingProvider.notifier).dismiss(r1);
    expect(c1.read(guestRingProvider), isNull);
    // ...a fresh ring (new ts) on the same peer is a different key -> rings.
    final c2 = _container([_c(peerId: 'g-ring', ringTs: 2000)]);
    expect(c2.read(guestRingProvider)?.ringTs, 2000);
  });

  test('a revoked contact never rings', () {
    final c = _container([_c(peerId: 'g-ring', status: 'revoked')]);
    expect(c.read(guestRingProvider), isNull);
  });

  test('a non-ringing guest DM does not surface', () {
    final c = _container([_c(peerId: 'g-ring', ringing: false)]);
    expect(c.read(guestRingProvider), isNull);
  });

  testWidgets('banner shows the alias-wins identity + Answer/Dismiss',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider
              .overrideWith(() => FakeChatsNotifier([_c(peerId: 'g-ring', alias: 'Alex from expo')])),
        ],
        child: const MaterialApp(home: Scaffold(body: GuestRingBanner())),
      ),
    );
    await tester.pump();

    expect(find.text('Incoming call from Alex from expo'), findsOneWidget);
    expect(find.byKey(const Key('guest-ring-answer')), findsOneWidget);

    await tester.tap(find.byKey(const Key('guest-ring-dismiss')));
    await tester.pump();
    expect(find.textContaining('Incoming call'), findsNothing);
  });

  testWidgets('an un-aliased guest rings as guest: <name> (anti-spoof)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider
              .overrideWith(() => FakeChatsNotifier([_c(peerId: 'g-ring', guestName: 'Chef')])),
        ],
        child: const MaterialApp(home: Scaffold(body: GuestRingBanner())),
      ),
    );
    await tester.pump();
    expect(find.text('Incoming call from guest: Chef'), findsOneWidget);
  });
}
