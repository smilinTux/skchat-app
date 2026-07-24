import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/data/conversation_repository.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/groups/create_group_screen.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/skcomms_client.dart';

class MockSKCommsClient extends Mock implements SKCommsClient {}

class MockConversationRepository extends Mock
    implements ConversationRepository {}

final _dummyConversation = Conversation(
  peerId: '',
  displayName: '',
  lastMessage: '',
  lastMessageTime: DateTime(2026),
);

/// A ChatsNotifier seeded with fixed peers so the member picker has real,
/// selectable contacts (humans + agents) without touching the daemon.
class _FakeChatsNotifier extends ChatsNotifier {
  _FakeChatsNotifier(this._seed);
  final List<Conversation> _seed;
  @override
  List<Conversation> build() => _seed;
}

Conversation _peer(String id, {bool isAgent = false}) => Conversation(
      peerId: id,
      displayName: id,
      lastMessage: 'hi',
      lastMessageTime: DateTime(2026),
      isAgent: isAgent,
    );

/// Wrap with a GoRouter so post-create navigation (context.go('/chats'))
/// resolves to a real route instead of throwing.
Widget _wrap({
  required MockSKCommsClient client,
  required MockConversationRepository repo,
  List<Conversation> peers = const [],
}) {
  final router = GoRouter(
    initialLocation: '/groups/new',
    routes: [
      GoRoute(
        path: '/chats',
        builder: (_, __) => const Scaffold(body: Text('CHATS LIST')),
      ),
      GoRoute(
        path: '/groups/new',
        builder: (_, __) => const CreateGroupScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      skcommsClientProvider.overrideWithValue(client),
      conversationRepositoryProvider.overrideWithValue(repo),
      chatsProvider.overrideWith(() => _FakeChatsNotifier(peers)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late MockSKCommsClient mockClient;
  late MockConversationRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_dummyConversation);
  });

  setUp(() {
    mockClient = MockSKCommsClient();
    mockRepo = MockConversationRepository();
    when(() => mockRepo.getAll()).thenAnswer((_) async => []);
    when(() => mockRepo.save(any())).thenAnswer((_) async {});
    when(() => mockRepo.saveAll(any())).thenAnswer((_) async {});
    when(() => mockRepo.delete(any())).thenAnswer((_) async {});
    // The real GroupsNotifier refreshes from the daemon on build — keep it
    // offline so it doesn't hit un-stubbed client methods.
    when(() => mockClient.isAlive()).thenAnswer((_) async => false);
    when(() => mockClient.getConversations()).thenAnswer((_) async => []);
    when(() => mockClient.getPeers()).thenAnswer((_) async => []);
  });

  group('CreateGroupScreen', () {
    testWidgets('renders name and description fields', (tester) async {
      await tester.pumpWidget(_wrap(client: mockClient, repo: mockRepo));
      await tester.pump();

      expect(find.text('New Group'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Group name'), findsWidgets);
    });

    testWidgets('Create button disabled when name is empty', (tester) async {
      await tester.pumpWidget(_wrap(client: mockClient, repo: mockRepo));
      await tester.pump();

      final btn = find.text('Create');
      expect(btn, findsOneWidget);
      final textBtn = tester.widget<TextButton>(
        find.ancestor(of: btn, matching: find.byType(TextButton)),
      );
      expect(textBtn.onPressed, isNull);
    });

    testWidgets('Create button enabled after typing name', (tester) async {
      await tester.pumpWidget(_wrap(client: mockClient, repo: mockRepo));
      await tester.pump();

      await tester.enterText(
          find.widgetWithText(TextField, 'Group name'), 'Builders');
      await tester.pump();

      final textBtn = tester.widget<TextButton>(
        find.ancestor(
            of: find.text('Create'), matching: find.byType(TextButton)),
      );
      expect(textBtn.onPressed, isNotNull);
    });

    testWidgets('shows encryption info banner', (tester) async {
      await tester.pumpWidget(_wrap(client: mockClient, repo: mockRepo));
      await tester.pump();
      expect(find.textContaining('AES-256-GCM'), findsOneWidget);
    });

    testWidgets('lists REAL conversation peers (humans + agents) as selectable',
        (tester) async {
      await tester.pumpWidget(_wrap(
        client: mockClient,
        repo: mockRepo,
        peers: [_peer('chef'), _peer('lumina', isAgent: true)],
      ));
      await tester.pump();

      // Both a human and an agent peer are offered as members.
      expect(find.byKey(const Key('member-tile-chef')), findsOneWidget);
      expect(find.byKey(const Key('member-tile-lumina')), findsOneWidget);
    });

    testWidgets('tapping a member toggles its selection (checkmark count)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        client: mockClient,
        repo: mockRepo,
        peers: [_peer('chef'), _peer('lumina', isAgent: true)],
      ));
      await tester.pump();

      expect(find.text('1 selected'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('member-tile-chef')));
      await tester.tap(find.byKey(const Key('member-tile-chef')));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('member-tile-lumina')));
      await tester.tap(find.byKey(const Key('member-tile-lumina')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets(
        'Create builds the POST with the selected members and navigates '
        '(no spinner hang)', (tester) async {
      // A taller surface so the key-distribution bottom sheet's button is on
      // screen (default 800x600 clips it).
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Capture the createGroup args.
      List<String>? sentMembers;
      String? sentName;
      when(() => mockClient.createGroup(
            name: any(named: 'name'),
            description: any(named: 'description'),
            memberUris: any(named: 'memberUris'),
          )).thenAnswer((inv) async {
        sentName = inv.namedArguments[#name] as String;
        sentMembers =
            (inv.namedArguments[#memberUris] as List).cast<String>();
        return const CreateGroupResult(
          groupId: 'g-123',
          name: 'Builders',
          memberCount: 2,
          keyId: 'v1',
        );
      });

      await tester.pumpWidget(_wrap(
        client: mockClient,
        repo: mockRepo,
        peers: [_peer('chef'), _peer('lumina', isAgent: true)],
      ));
      await tester.pump();

      // Select one real member first (keyboard closed → tile reachable).
      await tester.ensureVisible(find.byKey(const Key('member-tile-chef')));
      await tester.tap(find.byKey(const Key('member-tile-chef')));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'Group name'), 'Builders');
      await tester.pump();

      // Submit.
      await tester.tap(find.byKey(const Key('create-group-submit')));
      await tester.pump(); // start the async submit
      await tester.pumpAndSettle();

      // The POST carried the name + the selected member.
      expect(sentName, 'Builders');
      expect(sentMembers, contains('chef'));

      // Dismiss the key-distribution sheet -> navigation completes to the list.
      await tester.ensureVisible(find.text('Got it'));
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      // No spinner left hanging, and we landed on the unified Chats list.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('CHATS LIST'), findsOneWidget);
    });

    testWidgets('daemon offline → creates locally and still navigates',
        (tester) async {
      when(() => mockClient.createGroup(
            name: any(named: 'name'),
            description: any(named: 'description'),
            memberUris: any(named: 'memberUris'),
          )).thenThrow(Exception('offline'));

      await tester.pumpWidget(_wrap(
        client: mockClient,
        repo: mockRepo,
        peers: [_peer('chef')],
      ));
      await tester.pump();

      await tester.enterText(
          find.widgetWithText(TextField, 'Group name'), 'Offline Group');
      await tester.pump();
      await tester.tap(find.byKey(const Key('create-group-submit')));
      await tester.pumpAndSettle();

      // No key sheet on the offline path; navigation still completes cleanly.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('CHATS LIST'), findsOneWidget);
    });
  });
}
