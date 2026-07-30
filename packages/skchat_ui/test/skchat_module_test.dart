import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skworld_module_api/skworld_module_api.dart';
import 'package:skchat_ui/skchat_ui.dart';

// --- Minimal shell fakes so the mounted path has a non-null ShellContext. ----

class _FakeAuth implements AuthContext {
  @override
  String get audience => 'skchat';
  @override
  String? get subjectFqid => 'agent:lumina@skworld.io';
  @override
  Set<String> get scopes => const {'chat.read', 'chat.send'};
  @override
  bool hasScope(String scope) => scopes.contains(scope);
  @override
  Future<String?> token() async => 'audience-scoped-token';
}

class _FakeBus implements ShellBus {
  @override
  void navigate(String deeplink) {}
  @override
  void emit(ShellEvent event) {}
  @override
  Stream<ShellEvent> get events => const Stream.empty();
}

/// A bus that records the deep links it is asked to navigate, so the mounted
/// navigation wiring can be asserted.
class _RecordingBus implements ShellBus {
  final List<String> navigated = [];
  @override
  void navigate(String deeplink) => navigated.add(deeplink);
  @override
  void emit(ShellEvent event) {}
  @override
  Stream<ShellEvent> get events => const Stream.empty();
}

class _FakeShell implements ShellContext {
  _FakeShell({ShellBus? bus}) : _bus = bus ?? _FakeBus();

  final ShellBus _bus;

  @override
  AuthContext get auth => _FakeAuth();
  @override
  ShellBus get bus => _bus;
  @override
  ThemeData get theme => ThemeData();
}

void main() {
  test('SkchatModule instantiates and is a SkworldModule', () {
    const module = SkchatModule();
    expect(module, isA<SkworldModule>());
  });

  test('nav metadata matches the skchat manifest block (spec 3.1)', () {
    const module = SkchatModule();
    expect(module.id, 'skchat');
    expect(module.nav.label, 'Chats');
    expect(module.nav.icon, Icons.chat);
    expect(module.nav.order, 20);
    expect(module.nav.deeplinkPrefix, 'skworld://skchat/');
  });

  testWidgets('build(null) renders the real chats surface standalone',
      (tester) async {
    const module = SkchatModule();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          // ShellContext? null == standalone signal.
          builder: (context) => module.build(context, null),
        ),
      ),
    );
    expect(find.byType(ChatsSurface), findsOneWidget);
    // The real list renders the sample rows (not a placeholder message).
    expect(find.byType(ConversationListTile), findsWidgets);
    expect(find.text('Lumina'), findsOneWidget);
  });

  testWidgets('build(shell) renders the real chats surface mounted',
      (tester) async {
    const module = SkchatModule();
    final ShellContext shell = _FakeShell();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => module.build(context, shell)),
      ),
    );
    expect(find.byType(ChatsSurface), findsOneWidget);
    expect(find.byType(ConversationListTile), findsWidgets);
  });

  testWidgets('ChatsSurface renders injected conversations', (tester) async {
    final convos = [
      Conversation(
        peerId: 'p1',
        displayName: 'Test Peer',
        lastMessage: 'hi there',
        lastMessageTime: DateTime.now(),
        unreadCount: 3,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(home: ChatsSurface(conversations: convos)),
    );
    expect(find.byType(ConversationListTile), findsOneWidget);
    expect(find.text('Test Peer'), findsOneWidget);
    expect(find.text('hi there'), findsOneWidget);
    // Unread badge renders the count.
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('ChatsSurface renders the empty state for an empty list',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ChatsSurface(conversations: [])),
    );
    expect(find.byType(ConversationListTile), findsNothing);
    expect(find.text('No conversations yet'), findsOneWidget);
  });

  testWidgets('tapping a row asks the shell bus to navigate the deep link',
      (tester) async {
    final bus = _RecordingBus();
    final ShellContext shell = _FakeShell(bus: bus);
    final convos = [
      Conversation(
        peerId: 'lumina',
        displayName: 'Lumina',
        lastMessage: 'hey',
        lastMessageTime: DateTime.now(),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(home: ChatsSurface(shell: shell, conversations: convos)),
    );
    await tester.tap(find.byType(ConversationListTile).first);
    await tester.pump();
    expect(bus.navigated, contains('skworld://skchat/thread/lumina'));
  });

  testWidgets(
      'build renders the injected bodyBuilder (live-feed seam) over the sample',
      (tester) async {
    // The app injects a live body through bodyBuilder; here a marker widget
    // stands in for the app's Riverpod LiveChatsSurface adapter.
    final module = SkchatModule(
      bodyBuilder: (context, shell) => const Text('LIVE-FEED'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => module.build(context, null)),
      ),
    );
    // The injected body renders; the sample-backed surface does NOT.
    expect(find.text('LIVE-FEED'), findsOneWidget);
    expect(find.byType(ChatsSurface), findsNothing);
  });

  testWidgets('bodyBuilder receives the same nullable shell build was given',
      (tester) async {
    final ShellContext shell = _FakeShell();
    ShellContext? seenMounted;
    ShellContext? seenStandalone = _FakeShell();

    final mounted = SkchatModule(
      bodyBuilder: (context, s) {
        seenMounted = s;
        return const SizedBox.shrink();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => mounted.build(context, shell)),
      ),
    );
    expect(identical(seenMounted, shell), isTrue);

    final standalone = SkchatModule(
      bodyBuilder: (context, s) {
        seenStandalone = s;
        return const SizedBox.shrink();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => standalone.build(context, null)),
      ),
    );
    expect(seenStandalone, isNull);
  });

  test('extracted leaf ChatMessage round-trips through JSON', () {
    final msg = ChatMessage(
      id: 'm1',
      peerId: 'p1',
      content: 'hello',
      timestamp: DateTime.parse('2026-07-30T00:00:00.000Z'),
      isOutbound: true,
    );
    final restored = ChatMessage.fromJson(msg.toJson());
    expect(restored.id, 'm1');
    expect(restored.content, 'hello');
    expect(restored.isOutbound, isTrue);
  });
}
