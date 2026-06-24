import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/features/groups/groups_provider.dart';
import 'package:skchat/features/groups/groups_screen.dart';
import 'package:skchat/features/groups/widgets/group_tile.dart';
import 'package:skchat/models/conversation.dart';

/// GroupsNotifier seeded with fixed groups (no daemon/Hive).
class _FakeGroupsNotifier extends GroupsNotifier {
  _FakeGroupsNotifier(this._seed);
  final List<Conversation> _seed;
  @override
  List<Conversation> build() => _seed;
}

Conversation _grp(String id, String name, int members) => Conversation(
      peerId: id,
      displayName: name,
      lastMessage: 'hi',
      lastMessageTime: DateTime(2026),
      isGroup: true,
      memberCount: members,
    );

Widget _wrap(List<Conversation> groups) {
  final router = GoRouter(
    initialLocation: '/groups',
    routes: [
      GoRoute(
        path: '/groups',
        builder: (_, __) => const GroupsScreen(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, __) => const Scaffold(body: Text('CREATE GROUP')),
          ),
        ],
      ),
      GoRoute(
        path: '/chats/:id',
        builder: (_, s) =>
            Scaffold(body: Text('CONVO ${s.pathParameters['id']}')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      groupsProvider.overrideWith(() => _FakeGroupsNotifier(groups)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('GroupsScreen', () {
    testWidgets('renders each group (name + tile)', (tester) async {
      await tester.pumpWidget(_wrap([
        _grp('g-1', 'Penguins', 3),
        _grp('g-2', 'Builders', 2),
      ]));
      await tester.pumpAndSettle();

      expect(find.byType(GroupTile), findsNWidgets(2));
      expect(find.text('Penguins'), findsOneWidget);
      expect(find.text('Builders'), findsOneWidget);
    });

    testWidgets('tapping a group opens its conversation', (tester) async {
      await tester.pumpWidget(_wrap([_grp('g-1', 'Penguins', 3)]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Penguins'));
      await tester.pumpAndSettle();

      expect(find.text('CONVO g-1'), findsOneWidget);
    });

    testWidgets('empty state offers a New group action', (tester) async {
      await tester.pumpWidget(_wrap(const []));
      await tester.pumpAndSettle();

      expect(find.text('No groups yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'New group'));
      await tester.pumpAndSettle();
      expect(find.text('CREATE GROUP'), findsOneWidget);
    });
  });
}
