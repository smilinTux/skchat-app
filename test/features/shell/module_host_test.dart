import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/shell/app_shell_context.dart';
import 'package:skchat/features/shell/module_host_screen.dart';
import 'package:skchat/services/identity_service.dart';
import 'package:skchat_ui/skchat_ui.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

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
/// the live feed renders without touching Hive / the daemon in a test.
class _StubChats extends ChatsNotifier {
  @override
  List<Conversation> build() => _fixture;
}

/// A sentinel destination that records the route it was reached on, so a test
/// can assert the module's deep link mapped onto the real GoRouter.
class _SpyScreen extends StatelessWidget {
  const _SpyScreen({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('SPY:$label')));
}

/// Pumps the module-host route inside a real GoRouter whose skchat targets are
/// spy sentinels, with the live feed stubbed and identity resolved to null.
Future<void> _pumpHost(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: AppRoutes.moduleSkchat,
    routes: [
      GoRoute(
        path: AppRoutes.moduleSkchat,
        builder: (_, _) => const SkchatModuleHostScreen(),
      ),
      // Declared before the :peerId route so /chats/new resolves to the peer
      // picker, mirroring the real app router's sub-route precedence.
      GoRoute(
        path: AppRoutes.peerPicker, // /chats/new
        builder: (_, _) => const _SpyScreen(label: 'compose'),
      ),
      GoRoute(
        path: AppRoutes.conversation, // /chats/:peerId
        builder: (_, state) =>
            _SpyScreen(label: 'thread:${state.pathParameters['peerId']}'),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatsProvider.overrideWith(_StubChats.new),
        identityKeyPairProvider.overrideWith((ref) async => null),
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
    Hive.init(Directory.systemTemp.createTempSync('skchat_mount_hive').path);
  });

  group('mapSkchatDeeplink', () {
    test('thread deep link maps to the conversation route', () {
      expect(mapSkchatDeeplink('skworld://skchat/thread/abc'), '/chats/abc');
    });

    test('compose deep link maps to the peer picker route', () {
      expect(mapSkchatDeeplink('skworld://skchat/compose'), '/chats/new');
    });

    test('bare authority maps to the chats list', () {
      expect(mapSkchatDeeplink('skworld://skchat/'), '/chats');
    });

    test('unknown segment and thread-with-no-id map to null', () {
      expect(mapSkchatDeeplink('skworld://skchat/bogus'), isNull);
      expect(mapSkchatDeeplink('skworld://skchat/thread'), isNull);
    });

    test('a foreign authority or unparseable link maps to null', () {
      expect(mapSkchatDeeplink('skworld://skcode/thread/abc'), isNull);
      expect(mapSkchatDeeplink('not a uri at all ::://'), isNull);
    });
  });

  group('AppShellBus', () {
    test('navigate on a mapped deep link calls onNavigate with the route', () {
      final seen = <String>[];
      final bus = AppShellBus(onNavigate: seen.add);
      bus.navigate('skworld://skchat/thread/x');
      expect(seen, ['/chats/x']);
      bus.dispose();
    });

    test('navigate on an unmapped deep link degrades to onUnhandled', () {
      final navigated = <String>[];
      final unhandled = <String>[];
      final bus = AppShellBus(
        onNavigate: navigated.add,
        onUnhandled: unhandled.add,
      );
      bus.navigate('skworld://skchat/bogus');
      expect(navigated, isEmpty);
      expect(unhandled, ['skworld://skchat/bogus']);
      bus.dispose();
    });

    test('emit publishes events on the stream', () async {
      final bus = AppShellBus(onNavigate: (_) {});
      final received = <String>[];
      final sub = bus.events.listen((e) => received.add(e.name));
      bus.emit(const ShellEvent('unreadChanged'));
      await Future<void>.delayed(Duration.zero);
      expect(received, ['unreadChanged']);
      await sub.cancel();
      bus.dispose();
    });
  });

  group('AppAuthContext', () {
    test('is scoped to the skchat audience with chat scopes; token stubbed',
        () async {
      const auth = AppAuthContext(subjectFqid: 'fp-123');
      expect(auth.audience, 'skchat');
      expect(auth.subjectFqid, 'fp-123');
      expect(auth.hasScope('chat.read'), isTrue);
      expect(auth.hasScope('chat.send'), isTrue);
      expect(auth.hasScope('admin'), isFalse);
      expect(await auth.token(), isNull);
    });
  });

  group('SkchatModuleHostScreen (mount)', () {
    testWidgets('mounts the live skchat module and renders ChatsSurface',
        (tester) async {
      await _pumpHost(tester);

      // The concrete ShellContext drove a MOUNTED render: the real chats
      // surface appears with the injected live row.
      expect(find.byType(ChatsSurface), findsOneWidget);
      expect(find.text('Xerus'), findsOneWidget);
    });

    testWidgets(
        'tapping a row fires the thread deep link and the bus navigates the '
        'real router to the mapped route', (tester) async {
      await _pumpHost(tester);

      // Precondition: on the host, not the spy destination yet.
      expect(find.textContaining('SPY:'), findsNothing);

      // Tapping the row calls shell.bus.navigate('skworld://skchat/thread/x'),
      // which AppShellBus maps to /chats/x and drives via the real GoRouter.
      await tester.tap(find.text('Xerus'));
      await tester.pumpAndSettle();

      expect(find.text('SPY:thread:x'), findsOneWidget);
    });

    testWidgets('the compose FAB fires the compose deep link onto the router',
        (tester) async {
      await _pumpHost(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('SPY:compose'), findsOneWidget);
    });
  });
}
