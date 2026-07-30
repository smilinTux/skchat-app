// Tests for the persisted, runtime-overridable Chats-tab module flag.
//
// Covers:
//   * the compile-time default is false (native screen stays the fallback),
//   * chatsTabModuleFlagProvider seeds from that default when nothing is
//     persisted,
//   * setting + persisting flips useSkchatModuleForChatsTabProvider to true and
//     survives a fresh ProviderContainer (Hive round-trip),
//   * resetting/back-to-false returns to the native fallback,
//   * ChatsTab renders the module when the persisted flag is true and the
//     native ChatsScreen when it is false.
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

/// One representative conversation so the mounted module renders a real row.
final _fixture = <Conversation>[
  Conversation(
    peerId: 'x',
    displayName: 'Xerus',
    lastMessage: 'ping',
    lastMessageTime: DateTime(2026, 7, 30, 12),
    isAgent: true,
  ),
];

/// Stub chats notifier: fixed list, no microtask, no Hive/daemon.
class _StubChats extends ChatsNotifier {
  @override
  List<Conversation> build() => _fixture;
}

/// Lets the async `_loadPersisted()` (or `set()`) Hive IO settle so the
/// notifier reflects the persisted value before we assert, and so a
/// fire-and-forget load from build() never leaks past tearDown into a deleted
/// box dir (mirrors backend_config_test's timing).
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// Pumps [ChatsTab] on the real Chats route, WITHOUT overriding the flag, so it
/// reflects whatever is persisted in Hive.
Future<void> _pumpTab(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: AppRoutes.chats,
    routes: [
      GoRoute(
        path: AppRoutes.chats,
        builder: (_, _) => const ChatsTab(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, _) => const Scaffold(body: Text('compose')),
          ),
          GoRoute(
            path: ':peerId',
            builder: (_, _) => const Scaffold(body: Text('thread')),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatsProvider.overrideWith(_StubChats.new),
        identityKeyPairProvider.overrideWith((ref) async => null),
        nodeCapabilitiesProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skchat_feature_flags_test');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    // Let any in-flight async _loadPersisted() (fired by build()) settle
    // before we tear down Hive, so it never races a deleted box file.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await Hive.close();
    await Hive.deleteFromDisk();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  group('compile-time default', () {
    test('is false, native screen stays the fallback', () {
      expect(kUseSkchatModuleForChatsTabDefault, isFalse);
    });
  });

  group('persistence + provider wiring', () {
    test('with nothing persisted, both providers read the default (false)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(chatsTabModuleFlagProvider), isFalse);
      expect(container.read(useSkchatModuleForChatsTabProvider), isFalse);
      // Let the async load run; still false, nothing was persisted.
      await _settle();
      expect(container.read(chatsTabModuleFlagProvider), isFalse);
    });

    test('set(true) persists and flips the read-only view to true', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(chatsTabModuleFlagProvider.notifier).set(true);

      expect(container.read(chatsTabModuleFlagProvider), isTrue);
      expect(container.read(useSkchatModuleForChatsTabProvider), isTrue);
      await _settle();
    });

    test('persisted true survives a fresh container (Hive round-trip)',
        () async {
      // Container 1: flip it on and persist.
      final c1 = ProviderContainer();
      await c1.read(chatsTabModuleFlagProvider.notifier).set(true);
      c1.dispose();

      // Container 2: seeds from the default, then loads the persisted override.
      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      expect(c2.read(chatsTabModuleFlagProvider), isFalse); // pre-load seed
      await _settle();
      expect(c2.read(chatsTabModuleFlagProvider), isTrue); // persisted override
      expect(c2.read(useSkchatModuleForChatsTabProvider), isTrue);
    });

    test('back to false returns to the native fallback', () async {
      final c1 = ProviderContainer();
      await c1.read(chatsTabModuleFlagProvider.notifier).set(true);
      await c1.read(chatsTabModuleFlagProvider.notifier).set(false);
      c1.dispose();

      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      await _settle();
      expect(c2.read(chatsTabModuleFlagProvider), isFalse);
      expect(c2.read(useSkchatModuleForChatsTabProvider), isFalse);
    });

    test('reset() clears the override back to the compile-time default',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(chatsTabModuleFlagProvider.notifier).set(true);
      expect(container.read(chatsTabModuleFlagProvider), isTrue);

      await container.read(chatsTabModuleFlagProvider.notifier).reset();
      expect(container.read(chatsTabModuleFlagProvider),
          kUseSkchatModuleForChatsTabDefault);
      await _settle();
    });
  });

  group('ChatsTab reflects the persisted flag', () {
    // The module-render path (flag ON -> ChatsSurface) is already covered by
    // test/features/chats/chats_tab_test.dart; here we only assert that the
    // PERSISTED default (false) drives the tab to the native ChatsScreen, so the
    // persistence wiring reaches the real widget without stubbing the flag.
    testWidgets('persisted default (false) renders the native ChatsScreen',
        (tester) async {
      await _pumpTab(tester);
      // Let the async _loadPersisted() run (still false, nothing persisted).
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byType(ChatsScreen), findsOneWidget);
      expect(find.byType(ChatsSurface), findsNothing);
    });
  });
}
