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

/// A bus that records the deep links it is asked to navigate.
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
  _FakeShell({ShellBus? bus}) : _bus = bus ?? _RecordingBus();

  final ShellBus _bus;

  @override
  AuthContext get auth => _FakeAuth();
  @override
  ShellBus get bus => _bus;
  @override
  ThemeData get theme => ThemeData();
}

List<Conversation> _threeConversations() {
  final now = DateTime.now();
  return [
    Conversation(
      peerId: 'lumina',
      displayName: 'Lumina',
      lastMessage: 'The fleet is green.',
      lastMessageTime: now,
    ),
    Conversation(
      peerId: 'jarvis',
      displayName: 'Jarvis',
      lastMessage: 'Overnight build running.',
      lastMessageTime: now.subtract(const Duration(hours: 1)),
    ),
    Conversation(
      peerId: 'skworld-ops',
      displayName: 'SKWorld Ops',
      lastMessage: 'Deploy window at 22:00.',
      lastMessageTime: now.subtract(const Duration(days: 1)),
    ),
  ];
}

void main() {
  group('compose FAB', () {
    testWidgets('is present and, mounted, navigates the compose deep link',
        (tester) async {
      final bus = _RecordingBus();
      final ShellContext shell = _FakeShell(bus: bus);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatsSurface(shell: shell, conversations: _threeConversations()),
        ),
      );

      final fab = find.byType(FloatingActionButton);
      expect(fab, findsOneWidget);

      await tester.tap(fab);
      await tester.pump();
      expect(bus.navigated, contains('skworld://skchat/compose'));
    });

    testWidgets('standalone, tapping degrades to a local SnackBar (no bus)',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: _threeConversations())),
      );

      final fab = find.byType(FloatingActionButton);
      expect(fab, findsOneWidget);

      await tester.tap(fab);
      await tester.pump();
      // No shell bus to navigate; a SnackBar acknowledges the tap instead.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('New message'), findsOneWidget);
    });

    testWidgets('is present in standalone mode too', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: _threeConversations())),
      );
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  group('local search', () {
    testWidgets('typing filters the injected list by name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: _threeConversations())),
      );
      // All three render before searching.
      expect(find.byType(ConversationListTile), findsNWidgets(3));

      // Open search and type a name fragment.
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'jarv');
      await tester.pumpAndSettle();

      expect(find.byType(ConversationListTile), findsOneWidget);
      expect(find.text('Jarvis'), findsOneWidget);
      expect(find.text('Lumina'), findsNothing);
    });

    testWidgets('matches on the preview text as well', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: _threeConversations())),
      );
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'overnight');
      await tester.pumpAndSettle();

      expect(find.byType(ConversationListTile), findsOneWidget);
      expect(find.text('Jarvis'), findsOneWidget);
    });

    testWidgets('no matches shows the empty state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: _threeConversations())),
      );
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz-no-such-peer');
      await tester.pumpAndSettle();

      expect(find.byType(ConversationListTile), findsNothing);
      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('clearing the query shows all again', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ChatsSurface(conversations: _threeConversations())),
      );
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'jarv');
      await tester.pumpAndSettle();
      expect(find.byType(ConversationListTile), findsOneWidget);

      // Close/clear search restores the full list.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationListTile), findsNWidgets(3));
    });

    testWidgets('search works in mounted mode too', (tester) async {
      final ShellContext shell = _FakeShell();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatsSurface(shell: shell, conversations: _threeConversations()),
        ),
      );
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ops');
      await tester.pumpAndSettle();
      expect(find.text('SKWorld Ops'), findsOneWidget);
      expect(find.text('Lumina'), findsNothing);
    });
  });

  group('filterConversations (pure)', () {
    test('empty query returns the list unchanged', () {
      final all = _threeConversations();
      expect(filterConversations(all, ''), same(all));
      expect(filterConversations(all, '   '), same(all));
    });

    test('filters case-insensitively by name, key, and preview', () {
      final all = _threeConversations();
      expect(filterConversations(all, 'LUMINA').length, 1);
      expect(filterConversations(all, 'deploy').length, 1);
      expect(filterConversations(all, 'nope').isEmpty, isTrue);
    });
  });
}
