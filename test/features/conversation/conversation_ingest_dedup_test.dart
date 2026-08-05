import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/data/conversation_repository.dart';
import 'package:skchat/data/message_repository.dart';
import 'package:skchat/features/conversation/conversation_provider.dart';
import 'package:skchat/models/chat_message.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/daemon_service.dart';
import 'package:skchat/services/skcomms_client.dart';
import 'package:skchat/services/daemon_config.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_prekey_service.dart';

class MockMessageRepository extends Mock implements MessageRepository {}

class MockConversationRepository extends Mock
    implements ConversationRepository {}

class MockSKCommsClient extends Mock implements SKCommsClient {}

/// A daemon whose CLI history returns nothing (no `skchat` binary is spawned in
/// the unit test) and whose identity is a fixed operator, so ingestion classi-
/// fies `chef@skworld.io` senders as OUTBOUND deterministically.
class _StubDaemon extends DaemonService {
  _StubDaemon() : super(identity: 'chef@skworld.io');
  @override
  Future<List<SkchatCliMessage>> getConversation(
    String peerId, {
    int limit = 100,
  }) async =>
      const [];
  @override
  Future<bool> isAlive() async => false;
}

class _StubDaemonConfig extends DaemonConfigNotifier {
  @override
  String build() => 'http://localhost:9384';
}

class _StubPrekeyService implements PqPrekeyService {
  @override
  Future<bool> ensureKeyPair() async => false;
  @override
  Future<List<PrekeyBundle>> fetchPeer(String peer, {bool force = false}) async =>
      const [];
  @override
  Future<PrekeyBundle> fetchPeerNewest(String peer, {bool force = false}) async =>
      const PrekeyBundle();
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockMessageRepository mockMsgRepo;
  late MockConversationRepository mockConvoRepo;
  late MockSKCommsClient mockClient;

  setUpAll(() {
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
    mockMsgRepo = MockMessageRepository();
    mockConvoRepo = MockConversationRepository();
    mockClient = MockSKCommsClient();
    when(() => mockMsgRepo.getMessages(any())).thenAnswer((_) async => []);
    when(() => mockMsgRepo.saveMessage(any())).thenAnswer((_) async {});
    when(() => mockConvoRepo.getAll()).thenAnswer((_) async => []);
    when(() => mockConvoRepo.save(any())).thenAnswer((_) async {});
    when(() => mockClient.isAlive()).thenAnswer((_) async => false);
    when(() => mockClient.getConversationFull(any()))
        .thenAnswer((_) async => const []);
    when(() => mockClient.getInbox()).thenAnswer((_) async => const []);
    when(() => mockClient.getStatus())
        .thenAnswer((_) async => <String, dynamic>{});
  });

  ProviderContainer createContainer() {
    return ProviderContainer(
      overrides: [
        messageRepositoryProvider.overrideWithValue(mockMsgRepo),
        conversationRepositoryProvider.overrideWithValue(mockConvoRepo),
        skcommsClientProvider.overrideWithValue(mockClient),
        daemonServiceProvider.overrideWithValue(_StubDaemon()),
        pqConversationServiceProvider.overrideWithValue(
          PqConversationService(
            prekeys: _StubPrekeyService(),
            localShort: 'chef',
          ),
        ),
        daemonUrlProvider.overrideWith(_StubDaemonConfig.new),
      ],
    );
  }

  /// A persisted server-contract message map (UUID id, no is_outbound; the
  /// ingestion path derives direction from the sender).
  Map<String, dynamic> serverMsg({
    required String id,
    required String body,
    required DateTime ts,
    String sender = 'chef@skworld.io',
    String? replyToId,
  }) =>
      {
        'id': id,
        'sender': sender,
        'body': body,
        'ts': ts.toIso8601String(),
        if (replyToId != null) 'reply_to_id': replyToId,
      };

  group('ingestion dedup by id (sibling-device drops)', () {
    test(
        'non-authoring device renders BOTH distinct same-text outbound sends',
        () async {
      final container = createContainer();
      final notifier =
          container.read(conversationProvider('lumina').notifier);
      // Let build()/first fetch settle (CLI empty, HTTP not alive).
      await Future<void>.delayed(Duration.zero);

      // A sibling device has NO optimistic echo in state; it holds only the two
      // distinct server copies. Both "reply purple" sends carry unique ids and
      // MUST both render.
      final base = DateTime(2026, 8, 5, 12, 0, 0);
      await notifier.ingestSendResponse(
        'lumina',
        echoedMessage:
            serverMsg(id: 'srv-uuid-1', body: 'reply purple', ts: base),
        reply: serverMsg(
            id: 'srv-uuid-2',
            body: 'reply purple',
            ts: base.add(const Duration(seconds: 5))),
      );

      final state = container.read(conversationProvider('lumina'));
      final purples =
          state.where((m) => m.content == 'reply purple').toList();
      expect(purples.length, 2,
          reason:
              'both distinct-id sends of identical text must survive on a sibling device');
      expect(purples.map((m) => m.id).toSet(),
          {'srv-uuid-1', 'srv-uuid-2'});
      expect(purples.every((m) => m.isOutbound), isTrue);

      await Future<void>.delayed(Duration.zero);
      container.dispose();
    });

    test('author device collapses optimistic bubble against its server copy',
        () async {
      final container = createContainer();
      final notifier =
          container.read(conversationProvider('lumina').notifier);
      await Future<void>.delayed(Duration.zero);

      // Optimistic local echo inserted at send time: id = epoch-millis string.
      final now = DateTime(2026, 8, 5, 12, 0, 0);
      await notifier.addMessage(ChatMessage(
        id: '1717000000000',
        peerId: 'lumina',
        content: 'reply purple',
        timestamp: now,
        isOutbound: true,
        sender: 'chef',
      ));
      expect(container.read(conversationProvider('lumina')).length, 1);

      // Its own persisted server copy arrives seconds later (UUID id).
      await notifier.ingestSendResponse(
        'lumina',
        echoedMessage: serverMsg(
            id: 'srv-uuid-9',
            body: 'reply purple',
            ts: now.add(const Duration(seconds: 2))),
      );

      final state = container.read(conversationProvider('lumina'));
      final purples =
          state.where((m) => m.content == 'reply purple').toList();
      expect(purples.length, 1,
          reason:
              'the optimistic bubble and its own server copy are one logical message');

      await Future<void>.delayed(Duration.zero);
      container.dispose();
    });

    test('a reply quoting the second same-text send resolves to a real target',
        () async {
      final container = createContainer();
      final notifier =
          container.read(conversationProvider('lumina').notifier);
      await Future<void>.delayed(Duration.zero);

      final base = DateTime(2026, 8, 5, 12, 0, 0);
      await notifier.ingestSendResponse(
        'lumina',
        echoedMessage:
            serverMsg(id: 'srv-uuid-1', body: 'reply purple', ts: base),
        reply: serverMsg(
            id: 'srv-uuid-2',
            body: 'reply purple',
            ts: base.add(const Duration(seconds: 5))),
      );
      // A follow-up outbound message that quotes the SECOND "reply purple".
      await notifier.ingestSendResponse(
        'lumina',
        echoedMessage: serverMsg(
            id: 'srv-uuid-3',
            body: 'yes, that one',
            ts: base.add(const Duration(seconds: 10)),
            replyToId: 'srv-uuid-2'),
      );

      final state = container.read(conversationProvider('lumina'));
      final quoter = state.firstWhere((m) => m.id == 'srv-uuid-3');
      expect(quoter.replyToId, 'srv-uuid-2');
      // The quote target is present in the thread (both same-text sends kept),
      // so the quoted-reply widget can resolve it.
      expect(state.any((m) => m.id == quoter.replyToId), isTrue);

      await Future<void>.delayed(Duration.zero);
      container.dispose();
    });
  });
}
