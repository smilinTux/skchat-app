import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/services/skcomms_client.dart';
import 'package:skchat/services/skcomms_sync.dart';

class MockSKCommsClient extends Mock implements SKCommsClient {}

/// BUG 1 — the offline banner must reflect TRUE daemon state. These drive the
/// real [SKCommsSyncNotifier]'s health check through an overridden client.
void main() {
  late MockSKCommsClient client;

  setUp(() {
    client = MockSKCommsClient();
    // Inbox poll is best-effort; keep it empty so it never flips state.
    when(() => client.getInbox()).thenAnswer((_) async => []);
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        skcommsClientProvider.overrideWithValue(client),
      ]);

  /// Poll until [predicate] holds or the budget elapses (the notifier checks
  /// the daemon from a deferred microtask on build).
  Future<DaemonState> settle(
    ProviderContainer c,
    bool Function(DaemonState) predicate,
  ) async {
    for (var i = 0; i < 50; i++) {
      final s = c.read(skcommsSyncProvider);
      if (predicate(s)) return s;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return c.read(skcommsSyncProvider);
  }

  test('200 health + valid status ⇒ DaemonStatus.online', () async {
    when(() => client.isAlive()).thenAnswer((_) async => true);
    when(() => client.getStatus())
        .thenAnswer((_) async => {'transport_ok': true});

    final c = makeContainer();
    final state =
        await settle(c, (s) => s.status == DaemonStatus.online);

    expect(state.status, DaemonStatus.online);
    expect(state.transportInfo?['transport_ok'], true);
    c.dispose();
  });

  test('genuinely-down daemon (isAlive false) ⇒ DaemonStatus.offline',
      () async {
    when(() => client.isAlive()).thenAnswer((_) async => false);
    // A down daemon also fails the inbox poll (it answers nothing); the poll
    // swallows the error and must not assert "online".
    when(() => client.getInbox()).thenThrow(Exception('down'));

    final c = makeContainer();
    final state =
        await settle(c, (s) => s.status == DaemonStatus.offline);

    expect(state.status, DaemonStatus.offline);
    c.dispose();
  });

  test('200 health but failing /api/v1/status still reports ONLINE', () async {
    // The decorative status fetch must NOT flip the UI offline (the false
    // "messages will queue" banner bug). Health is the source of truth.
    when(() => client.isAlive()).thenAnswer((_) async => true);
    when(() => client.getStatus()).thenThrow(Exception('status 500'));

    final c = makeContainer();
    final state =
        await settle(c, (s) => s.status == DaemonStatus.online);

    expect(state.status, DaemonStatus.online,
        reason: 'health 200 ⇒ online even if status throws');
    c.dispose();
  });

  test('a transient inbox-poll failure does NOT flip an online daemon offline',
      () async {
    when(() => client.isAlive()).thenAnswer((_) async => true);
    when(() => client.getStatus()).thenAnswer((_) async => {});
    // Inbox poll throws — the comment in _pollInbox says one poll failure must
    // not flip status.
    when(() => client.getInbox()).thenThrow(Exception('transient'));

    final c = makeContainer();
    await settle(c, (s) => s.status == DaemonStatus.online);
    // Give the inbox poll a chance to run and (wrongly) flip it.
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(c.read(skcommsSyncProvider).status, DaemonStatus.online);
    c.dispose();
  });
}
