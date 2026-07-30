import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/core/config/feature_flags.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/chats/chats_screen.dart';
import 'package:skchat/features/chats/chats_tab.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/identity_service.dart';
import 'package:skchat_ui/skchat_ui.dart';

/// One representative conversation the stubbed feed injects, so the mounted
/// module renders a real row that can be tapped to fire a deep link.
final _fixture = <Conversation>[
  Conversation(
    peerId: 'x',
    displayName: 'Xerus',
    lastMessage: 'ping',
    lastMessageTime: DateTime(2026, 7, 30, 12),
    isAgent: true,
  ),
];

/// Stub chats notifier: returns a fixed list from [build] with NO microtask, so
/// both the native screen and the mounted module render without touching Hive /
/// the daemon in a test.
class _StubChats extends ChatsNotifier {
  @override
  List<Conversation> build() => _fixture;
}

/// A sentinel destination that records the route it was reached on, so a test
/// can assert the module's deep link mapped onto the real GoRouter that the tab
/// lives inside.
class _SpyScreen extends StatelessWidget {
  const _SpyScreen({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('SPY:$label')));
}

/// Pumps [ChatsTab] on the real Chats route inside a GoRouter whose skchat
/// targets are spy sentinels, with the flag set to [useModule]. The tab renders
/// inside the router subtree exactly like the app's ShellRoute, so the module's
/// bus resolves `context.go` against THIS router.
Future<void> _pumpTab(WidgetTester tester, {required bool useModule}) async {
  final router = GoRouter(
    initialLocation: AppRoutes.chats,
    routes: [
      GoRoute(
        path: AppRoutes.chats,
        builder: (_, _) => const ChatsTab(),
        routes: [
          // Declared before :peerId so /chats/new resolves to the peer picker,
          // mirroring the real router's sub-route precedence.
          GoRoute(
            path: 'new',
            builder: (_, _) => const _SpyScreen(label: 'compose'),
          ),
          GoRoute(
            path: ':peerId',
            builder: (_, state) =>
                _SpyScreen(label: 'thread:${state.pathParameters['peerId']}'),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        useSkchatModuleForChatsTabProvider.overrideWithValue(useModule),
        chatsProvider.overrideWith(_StubChats.new),
        identityKeyPairProvider.overrideWith((ref) async => null),
        // The native ChatsScreen's toolbar watches node capabilities; stub it
        // so no Dio network call leaves a pending timer in the test.
        nodeCapabilitiesProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() {
    // Some provider chains open Hive during build; seed a throwaway dir so no
    // HiveError is thrown even though our stubs avoid Hive directly.
    Hive.init(Directory.systemTemp.createTempSync('skchat_tab_hive').path);
  });

  test('flag default is false (native screen stays the fallback)', () {
    expect(kUseSkchatModuleForChatsTabDefault, isFalse);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(useSkchatModuleForChatsTabProvider), isFalse);
  });

  group('ChatsTab flag switch', () {
    testWidgets('flag OFF renders the native ChatsScreen, not the module',
        (tester) async {
      await _pumpTab(tester, useModule: false);

      expect(find.byType(ChatsScreen), findsOneWidget);
      expect(find.byType(ChatsSurface), findsNothing);
    });

    testWidgets('flag ON renders the mounted module (ChatsSurface), not native',
        (tester) async {
      await _pumpTab(tester, useModule: true);

      expect(find.byType(ChatsSurface), findsOneWidget);
      expect(find.byType(ChatsScreen), findsNothing);
      // The live feed is injected: the stubbed row renders inside the module.
      expect(find.text('Xerus'), findsOneWidget);
    });

    testWidgets(
        'flag ON: tapping a row drives the in-tab module bus onto THIS router',
        (tester) async {
      await _pumpTab(tester, useModule: true);

      // Precondition: on the tab, not the spy destination yet.
      expect(find.textContaining('SPY:'), findsNothing);

      // Tapping the row calls shell.bus.navigate('skworld://skchat/thread/x'),
      // mapped to /chats/x and driven via the router the tab is mounted in.
      await tester.tap(find.text('Xerus'));
      await tester.pumpAndSettle();

      expect(find.text('SPY:thread:x'), findsOneWidget);
    });

    testWidgets('flag ON: the compose FAB drives the bus onto THIS router',
        (tester) async {
      await _pumpTab(tester, useModule: true);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('SPY:compose'), findsOneWidget);
    });
  });
}
