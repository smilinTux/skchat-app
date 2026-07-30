import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/data/conversation_repository.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/chats/live_chats_surface.dart';
import 'package:skchat/services/skcomms_client.dart';
import 'package:skchat_ui/skchat_ui.dart';

class MockSKCommsClient extends Mock implements SKCommsClient {}

class MockConversationRepository extends Mock
    implements ConversationRepository {}

final _dummyConversation = Conversation(
  peerId: '',
  displayName: '',
  lastMessage: '',
  lastMessageTime: DateTime(2026),
);

void main() {
  late MockSKCommsClient mockClient;
  late MockConversationRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_dummyConversation);
  });

  setUp(() {
    mockClient = MockSKCommsClient();
    mockRepo = MockConversationRepository();
    // Daemon offline so the REAL ChatsNotifier hydrates from the repo only,
    // deterministically, no network.
    when(() => mockClient.isAlive()).thenAnswer((_) async => false);
    when(() => mockRepo.save(any())).thenAnswer((_) async {});
  });

  Widget wrap(Widget child) => ProviderScope(
        overrides: [
          skcommsClientProvider.overrideWithValue(mockClient),
          conversationRepositoryProvider.overrideWithValue(mockRepo),
        ],
        child: MaterialApp(home: child),
      );

  testWidgets('LiveChatsSurface renders the REAL chatsProvider list',
      (tester) async {
    when(() => mockRepo.getAll()).thenAnswer((_) async => [
          Conversation(
            peerId: 'lumina',
            displayName: 'Lumina',
            lastMessage: 'fleet is green',
            lastMessageTime: DateTime(2026, 7, 30),
          ),
        ]);

    await tester.pumpWidget(wrap(const LiveChatsSurface()));
    // Let the ChatsNotifier build microtask hydrate from the repo.
    await tester.pump();
    await tester.pump();

    // Real conversation flows from the provider into the pure ChatsSurface.
    expect(find.byType(ChatsSurface), findsOneWidget);
    expect(find.text('Lumina'), findsOneWidget);
    expect(find.text('fleet is green'), findsWidgets);
    // NOT the package's sample fallback (which includes Jarvis + SKWorld Ops).
    expect(find.text('SKWorld Ops'), findsNothing);
  });

  testWidgets('LiveChatsSurface updates live when the provider changes',
      (tester) async {
    when(() => mockRepo.getAll()).thenAnswer((_) async => []);

    final container = ProviderContainer(overrides: [
      skcommsClientProvider.overrideWithValue(mockClient),
      conversationRepositoryProvider.overrideWithValue(mockRepo),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LiveChatsSurface()),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Empty list -> empty state, no rows.
    expect(find.byType(ConversationListTile), findsNothing);
    expect(find.text('Opus'), findsNothing);

    // A new conversation arrives on the REAL notifier; the ConsumerWidget must
    // rebuild and re-inject it into ChatsSurface (the live-feed contract).
    await container.read(chatsProvider.notifier).addConversation(
          Conversation(
            peerId: 'opus',
            displayName: 'Opus',
            lastMessage: 'branch pushed',
            lastMessageTime: DateTime(2026, 7, 30),
          ),
        );
    await tester.pump();

    expect(find.byType(ConversationListTile), findsOneWidget);
    expect(find.text('Opus'), findsOneWidget);
    expect(find.text('branch pushed'), findsWidgets);
  });

  testWidgets('buildLiveSkchatModule wires the live feed through SkchatModule',
      (tester) async {
    when(() => mockRepo.getAll()).thenAnswer((_) async => [
          Conversation(
            peerId: 'jarvis',
            displayName: 'Jarvis',
            lastMessage: 'overnight build done',
            lastMessageTime: DateTime(2026, 7, 30),
          ),
        ]);

    final module = buildLiveSkchatModule();
    await tester.pumpWidget(
      wrap(Builder(builder: (context) => module.build(context, null))),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(LiveChatsSurface), findsOneWidget);
    expect(find.text('Jarvis'), findsOneWidget);
  });
}
