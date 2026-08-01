import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/data/conversation_repository.dart';
import 'package:skchat/data/message_repository.dart';
import 'package:skchat/features/conversation/conversation_provider.dart';
import 'package:skchat/models/chat_message.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/daemon_service.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_prekey_service.dart';
import 'package:skchat/services/skcomms_client.dart';
import 'package:skchat/services/skcomms_sync.dart';

class MockMessageRepository extends Mock implements MessageRepository {}

/// A prekey service that never holds a PQ key, models the web/PWA leg (or a
/// device that is NOT the one Lumina sealed her reply to). Every incoming
/// `pqdm1:` token then fails to open → renders as a LOCKED placeholder.
class _NoKeyPrekeyService implements PqPrekeyService {
  @override
  Future<bool> ensureKeyPair() async => false;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockConversationRepository extends Mock
    implements ConversationRepository {}

class MockSKCommsClient extends Mock implements SKCommsClient {}

class MockDaemonService extends Mock implements DaemonService {}

/// A no-op sync notifier so folding inbound messages (which fire best-effort
/// read receipts via [skcommsSyncProvider]) does NOT spin up the real notifier
/// and its polling timers, which would outlive the test container.
class FakeSyncNotifier extends SKCommsSyncNotifier {
  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.online);

  @override
  Future<void> sendReceipt({
    required String peerId,
    required String targetMessageId,
    required String kind,
    String? me,
  }) async {}
}

/// The operator's identity and Lumina's fqid as the live backend keys them.
const _me = 'chef@skworld.io';
const _peer = 'lumina@chef.skworld';

void main() {
  late MockMessageRepository msgRepo;
  late MockConversationRepository convoRepo;
  late MockSKCommsClient client;
  late MockDaemonService daemon;

  setUpAll(() {
    // The pq-prekey provider chain reached through ConversationNotifier opens
    // Hive boxes (daemonUrlProvider persistence); on the test VM Hive has no
    // default path, so seed it with a throwaway temp dir or provider creation
    // throws HiveError.
    Hive.init(Directory.systemTemp.createTempSync('skchat_test_hive').path);
    registerFallbackValue(ChatMessage(
      id: '',
      peerId: '',
      content: '',
      timestamp: DateTime(2026),
      isOutbound: false,
    ));
    registerFallbackValue(Conversation(
      peerId: '',
      displayName: '',
      lastMessage: '',
      lastMessageTime: DateTime(2026),
    ));
  });

  setUp(() {
    msgRepo = MockMessageRepository();
    convoRepo = MockConversationRepository();
    client = MockSKCommsClient();
    daemon = MockDaemonService();

    // Repo no-ops.
    when(() => msgRepo.getMessages(any())).thenAnswer((_) async => []);
    when(() => msgRepo.saveMessage(any())).thenAnswer((_) async {});
    when(() => convoRepo.getAll()).thenAnswer((_) async => []);
    when(() => convoRepo.save(any())).thenAnswer((_) async {});

    // Daemon: web-like — no local CLI (history & send return empty/failure so
    // the HTTP contract path is exercised, exactly like the browser build).
    when(() => daemon.localIdentity).thenReturn(_me);
    when(() => daemon.getConversation(any(), limit: any(named: 'limit')))
        .thenAnswer((_) async => <SkchatCliMessage>[]);
    when(() => daemon.sendMessage(
          recipient: any(named: 'recipient'),
          content: any(named: 'content'),
          threadId: any(named: 'threadId'),
          replyTo: any(named: 'replyTo'),
        )).thenAnswer(
        (_) async => const DaemonSendResult(success: false, error: 'web'));

    // Default: receipts/typing best-effort calls don't matter for these tests.
    when(() => client.receipt(
          conversationId: any(named: 'conversationId'),
          messageId: any(named: 'messageId'),
          kind: any(named: 'kind'),
        )).thenAnswer((_) async => true);

    // chatsProvider (read by addMessage → updateConversation) builds the real
    // ChatsNotifier, which polls these on load. Stub them empty so the build
    // settles deterministically.
    when(() => client.getConversations()).thenAnswer((_) async => []);
    when(() => client.getPeers()).thenAnswer((_) async => []);
  });

  ProviderContainer makeContainer({bool noPqKey = false}) =>
      ProviderContainer(overrides: [
        messageRepositoryProvider.overrideWithValue(msgRepo),
        conversationRepositoryProvider.overrideWithValue(convoRepo),
        skcommsClientProvider.overrideWithValue(client),
        daemonServiceProvider.overrideWithValue(daemon),
        skcommsSyncProvider.overrideWith(FakeSyncNotifier.new),
        if (noPqKey)
          pqConversationServiceProvider.overrideWithValue(
            PqConversationService(
              prekeys: _NoKeyPrekeyService(),
              localShort: 'chef',
            ),
          ),
      ]);

  // ── BUG 2 — history loads on open with the correct (fqid) peer key ─────────
  group('history loads on open', () {
    test('requests the SAME fqid peer key the backend stores under', () async {
      when(() => client.isAlive()).thenAnswer((_) async => true);
      when(() => client.getConversationFull(any()))
          .thenAnswer((_) async => []);

      final container = makeContainer();
      // Open the conversation with the fqid (what the chats list passes).
      container.read(conversationProvider(_peer));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // It must fetch history for the EXACT fqid, not the short 'lumina'.
      verify(() => client.getConversationFull(_peer)).called(greaterThan(0));
      verifyNever(() => client.getConversationFull('lumina'));

      container.dispose();
    });

    test('renders Lumina\'s prior messages returned by the daemon', () async {
      when(() => client.isAlive()).thenAnswer((_) async => true);
      when(() => client.getConversationFull(_peer)).thenAnswer((_) async => [
            {
              'id': 'h1',
              'sender': _peer,
              'body': "Received. I'm here.",
              'ts': '2026-06-20T09:00:00Z',
            },
            {
              'id': 'h2',
              'sender': _me,
              'body': 'hey Lumina',
              'ts': '2026-06-20T09:01:00Z',
            },
          ]);

      final container = makeContainer();
      container.read(conversationProvider(_peer));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final msgs = container.read(conversationProvider(_peer));
      expect(msgs.length, 2);
      // Lumina's message is inbound; the operator's is outbound.
      final lumi = msgs.firstWhere((m) => m.id == 'h1');
      final mine = msgs.firstWhere((m) => m.id == 'h2');
      expect(lumi.isOutbound, isFalse);
      expect(lumi.content, "Received. I'm here.");
      expect(mine.isOutbound, isTrue);

      container.dispose();
    });
  });

  // ── BUG 3 — reply renders after send (empty history → send → 2 bubbles) ───
  group('send appends user message AND reply', () {
    test('ingestSendResponse adds both bubbles to an empty thread', () async {
      when(() => client.isAlive()).thenAnswer((_) async => true);
      when(() => client.getConversationFull(_peer))
          .thenAnswer((_) async => []);

      final container = makeContainer();
      final notifier = container.read(conversationProvider(_peer).notifier);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Empty thread to start.
      expect(container.read(conversationProvider(_peer)), isEmpty);

      // The /api/v1/send 200 response, folded in after a send.
      await notifier.ingestSendResponse(
        _peer,
        echoedMessage: {
          'id': 'u-1',
          'sender': _me,
          'body': 'hi Lumina',
          'ts': '2026-06-20T10:00:00Z',
        },
        reply: {
          'id': 'l-1',
          'sender': _peer,
          'body': "Received. I'm here.",
          'ts': '2026-06-20T10:00:18Z',
        },
      );

      final msgs = container.read(conversationProvider(_peer));
      expect(msgs.length, 2, reason: 'user turn + Lumina reply');
      final reply = msgs.firstWhere((m) => m.id == 'l-1');
      expect(reply.isOutbound, isFalse);
      expect(reply.content, "Received. I'm here.");
      final mine = msgs.firstWhere((m) => m.id == 'u-1');
      expect(mine.isOutbound, isTrue);

      container.dispose();
    });

    test('reply ingestion dedupes the optimistic user bubble by content',
        () async {
      when(() => client.isAlive()).thenAnswer((_) async => true);
      when(() => client.getConversationFull(_peer))
          .thenAnswer((_) async => []);

      final container = makeContainer();
      final notifier = container.read(conversationProvider(_peer).notifier);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Optimistic user bubble inserted by the composer (synthetic id).
      await notifier.addMessage(ChatMessage(
        id: 'temp-123',
        peerId: _peer,
        content: 'hi Lumina',
        timestamp: DateTime.utc(2026, 6, 20, 10, 0, 0),
        isOutbound: true,
      ));

      // Then the server echo (same content+direction, different id) + reply.
      await notifier.ingestSendResponse(
        _peer,
        echoedMessage: {
          'id': 'u-1',
          'sender': _me,
          'body': 'hi Lumina',
          'ts': '2026-06-20T10:00:01Z',
        },
        reply: {
          'id': 'l-1',
          'sender': _peer,
          'body': 'hello back',
          'ts': '2026-06-20T10:00:18Z',
        },
      );

      final msgs = container.read(conversationProvider(_peer));
      // The duplicate user echo is collapsed → 1 user bubble + 1 reply.
      expect(msgs.where((m) => m.content == 'hi Lumina').length, 1);
      expect(msgs.any((m) => m.id == 'l-1'), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      container.dispose();
    });
  });

  // CARD E: Lumina's sealed reply renders on the web/PWA leg
  group('CARD E: sealed reply on the web leg', () {
    // A pqdm1: token this device can't open (no key). Two DISTINCT replies both
    // seal to opaque tokens; on the web leg they must BOTH render as visible
    // locked placeholders, never collapse to one (or zero) so Lumina looks
    // silent even though she replied twice.
    const token1 = 'pqdm1:x25519-mlkem768:AAAAreply1';
    const token2 = 'pqdm1:x25519-mlkem768:BBBBreply2';

    test('two undecryptable replies BOTH render as locked bubbles', () async {
      when(() => client.isAlive()).thenAnswer((_) async => true);
      when(() => client.getConversationFull(_peer)).thenAnswer((_) async => [
            {
              'id': 'u-1',
              'sender': _me,
              'body': 'hello',
              'ts': '2026-07-31T20:00:00Z',
            },
            {
              'id': 'l-1',
              'sender': _peer,
              'body': token1,
              'ts': '2026-07-31T20:00:05Z',
            },
            {
              'id': 'l-2',
              'sender': _peer,
              'body': token2,
              'ts': '2026-07-31T20:00:09Z',
            },
          ]);

      final container = makeContainer(noPqKey: true);
      container.read(conversationProvider(_peer));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final msgs = container.read(conversationProvider(_peer));
      final locked = msgs.where((x) => x.pqLocked).toList();
      expect(locked.length, 2,
          reason: "both of Lumina's sealed replies must be visible");
      expect(locked.every((x) => !x.isOutbound), isTrue);
      expect(locked.map((x) => x.id).toSet(), {'l-1', 'l-2'});
      // The locked bubbles carry a visible, non-empty placeholder body.
      expect(
          locked.every((x) => x.content.contains('Encrypted message')), isTrue);
      // The operator's own turn still renders alongside.
      expect(msgs.any((x) => x.id == 'u-1' && x.isOutbound), isTrue);

      container.dispose();
    });

    test('an async-arrived reply lands in the OPEN thread on a later poll',
        () async {
      when(() => client.isAlive()).thenAnswer((_) async => true);
      // First poll: only the user's turn (async reply not generated yet).
      // Second poll: the reply has arrived (SKCHAT_ASYNC_REPLY path).
      var polls = 0;
      when(() => client.getConversationFull(_peer)).thenAnswer((_) async {
        polls++;
        return [
          {
            'id': 'u-1',
            'sender': _me,
            'body': 'you there?',
            'ts': '2026-07-31T21:00:00Z',
          },
          if (polls >= 2)
            {
              'id': 'l-9',
              'sender': _peer,
              'body': "Yes, I'm here.",
              'ts': '2026-07-31T21:00:04Z',
            },
        ];
      });

      final container = makeContainer();
      final notifier = container.read(conversationProvider(_peer).notifier);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // After the first poll the reply is not present yet.
      expect(
        container.read(conversationProvider(_peer)).any((m) => m.id == 'l-9'),
        isFalse,
      );

      // Simulate the next history poll (the provider's 4s timer / WS "new").
      await notifier.ingestSendResponse(_peer); // no-op batch, exercises path
      // Directly drive a refetch as the timer would.
      when(() => client.getConversationFull(_peer)).thenAnswer((_) async => [
            {
              'id': 'u-1',
              'sender': _me,
              'body': 'you there?',
              'ts': '2026-07-31T21:00:00Z',
            },
            {
              'id': 'l-9',
              'sender': _peer,
              'body': "Yes, I'm here.",
              'ts': '2026-07-31T21:00:04Z',
            },
          ]);
      // ingestSendResponse with the reply is the immediate path; simulate the
      // WS/poll delivery of the reply into the open thread.
      await notifier.ingestSendResponse(
        _peer,
        reply: {
          'id': 'l-9',
          'sender': _peer,
          'body': "Yes, I'm here.",
          'ts': '2026-07-31T21:00:04Z',
        },
      );

      final msgs = container.read(conversationProvider(_peer));
      final reply = msgs.where((m) => m.id == 'l-9').toList();
      expect(reply.length, 1, reason: 'async reply landed in the open thread');
      expect(reply.first.isOutbound, isFalse);
      expect(reply.first.content, "Yes, I'm here.");

      container.dispose();
    });
  });
}
