import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/modules/module_manifest.dart';
import 'package:skchat/core/modules/module_registry.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/core/theme/glass_widgets.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/shell/app_shell.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/consent_service.dart';
import 'package:skchat/services/module_prefs.dart';
import 'package:skchat/services/skcomms_sync.dart';

/// Stub the daemon sync notifier so tests never start the real 5s/15s poll
/// timers or touch the network. Reports "connecting" (banner stays hidden).
class _StubSync extends SKCommsSyncNotifier {
  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.connecting);
}

/// Stub the chats notifier so the shell's unread badge does not touch Hive /
/// the daemon in a widget test. Empty list = zero unread.
class _StubChats extends ChatsNotifier {
  @override
  List<Conversation> build() => const [];
}

/// A prefs notifier seeded with an explicit state so the shell's nav pipeline
/// is deterministic and never touches Hive. Every builtin module enabled at its
/// default placement, stamped at the current seed version.
class _StubPrefs extends ModulePrefsNotifier {
  @override
  ModulePrefs build() => ModulePrefs(
        enabledIds: {for (final m in kBuiltinModules) m.id},
        seedVersion: kCurrentSeedVersion,
        initialized: true,
      );
}

/// A fixed node-capability document. The primary nav now flows through the
/// availability pipeline (registry ∩ caps ∩ prefs), so tests must pin caps,
/// otherwise [nodeCapabilitiesProvider] would spin its real fetch timer + touch
/// Hive. `text`/`voice` up keeps the core nav tabs ungreyed by default; pass
/// down statuses to exercise the greyed-but-present path.
NodeCapabilities _caps({
  String textStatus = 'up',
  String voiceStatus = 'up',
}) {
  return NodeCapabilities.fromJson({
    'node': {'id': 'lumina@chef.skworld'},
    'services': [
      {'id': 'text', 'status': textStatus},
      {'id': 'voice', 'status': voiceStatus},
    ],
    'transports': const [],
  });
}

/// Active (filled) icon shown for the currently selected tab.
const _activeIcons = <String, IconData>{
  'chats': Icons.chat_bubble_rounded,
  'spaces': Icons.podcasts_rounded,
  'skcode': Icons.terminal_rounded,
  'activity': Icons.notifications_rounded,
  'ops': Icons.grid_view_rounded,
  'me': Icons.person_rounded,
};

/// Every active icon that must NOT be present for a given selected tab.
Iterable<IconData> _otherActiveIcons(String selected) =>
    _activeIcons.entries.where((e) => e.key != selected).map((e) => e.value);

/// A trivial shell child that owns a nested Scaffold + FAB, mirroring the real
/// Chats/Spaces screens whose purple FAB used to bleed through the frosted nav
/// bar. Used to prove the shell body no longer extends behind the bar.
class _FabChild extends StatelessWidget {
  const _FabChild();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: const SizedBox.expand(),
        floatingActionButton: FloatingActionButton(
          onPressed: () {},
          child: const Icon(Icons.edit_rounded),
        ),
      );
}

Widget _app(
  String initialLocation, {
  Widget child = const _FabChild(),
  NodeCapabilities? caps,
}) {
  final resolvedCaps = caps ?? _caps();
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, c) => AppShell(child: c),
        routes: [
          for (final path in const [
            AppRoutes.chats,
            AppRoutes.spaces,
            AppRoutes.code,
            AppRoutes.activity,
            AppRoutes.hub,
            AppRoutes.profile,
            AppRoutes.cluster,
            AppRoutes.skmap,
            AppRoutes.coord,
            AppRoutes.recordings,
          ])
            GoRoute(path: path, builder: (_, _) => child),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      skcommsSyncProvider.overrideWith(_StubSync.new),
      chatsProvider.overrideWith(_StubChats.new),
      consentPendingCountProvider.overrideWith((ref) => 0),
      // The nav pipeline reads caps + prefs; pin both so no fetch timer starts
      // and Hive is never touched in these widget tests.
      nodeCapabilitiesProvider.overrideWith((ref) async => resolvedCaps),
      modulePrefsProvider.overrideWith(_StubPrefs.new),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// Assert exactly the [selected] tab renders its active icon and no other tab
/// is highlighted (no cross-highlight).
void _expectOnlyActive(String selected) {
  expect(
    find.byIcon(_activeIcons[selected]!),
    findsOneWidget,
    reason: '$selected tab should show its filled active icon',
  );
  for (final other in _otherActiveIcons(selected)) {
    expect(
      find.byIcon(other),
      findsNothing,
      reason: 'no other tab should be active when on $selected',
    );
  }
}

void main() {
  // route -> which single tab must be highlighted.
  const cases = <String, String>{
    AppRoutes.chats: 'chats',
    AppRoutes.spaces: 'spaces',
    AppRoutes.code: 'skcode',
    AppRoutes.activity: 'activity',
    AppRoutes.hub: 'ops',
    AppRoutes.profile: 'me',
    // Operator surfaces gated by the Ops hub keep Ops lit.
    AppRoutes.cluster: 'ops',
    AppRoutes.skmap: 'ops',
    AppRoutes.coord: 'ops',
    AppRoutes.recordings: 'ops',
  };

  cases.forEach((route, tab) {
    testWidgets('route $route highlights only the $tab tab', (tester) async {
      await tester.pumpWidget(_app(route));
      await tester.pump(); // let go_router settle the shell child
      _expectOnlyActive(tab);
    });
  });

  testWidgets(
      'primary nav renders every nav-placed module plus the Ops hub, in order',
      (tester) async {
    await tester.pumpWidget(_app(AppRoutes.chats));
    await tester.pump();

    // chats(0), spaces(10), skcode(15), activity(20), [Ops before Me], me(40).
    for (final label in const ['Chats', 'Spaces', 'Code', 'Activity', 'Ops',
      'Me']) {
      expect(find.text(label), findsOneWidget, reason: '$label tab present');
    }

    // The rendered order matches the manifest order with Ops wedged before Me.
    final labels = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(const Key('glass-nav-bar')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(
      labels,
      const ['Chats', 'Spaces', 'Code', 'Activity', 'Ops', 'Me'],
      reason: 'nav order = manifest order, Ops inserted just before Me',
    );
  });

  testWidgets(
      'a capability-down module stays in the nav rendered greyed (never hidden)',
      (tester) async {
    // Voice down → Spaces (requires service:voice) is unavailable. It must NOT
    // vanish from the nav; it renders dimmed with its tab still tappable.
    await tester.pumpWidget(
      _app(AppRoutes.chats, caps: _caps(voiceStatus: 'down')),
    );
    await tester.pump();

    expect(find.text('Spaces'), findsOneWidget,
        reason: 'unavailable module is greyed, never hidden');
    // The dim treatment (Opacity 0.45) is applied to at least the Spaces tab.
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.45),
      findsWidgets,
      reason: 'capability-down tab is dimmed, not removed',
    );
  });

  testWidgets('shell body does not extend behind the frosted nav bar '
      '(FAB bleed-through regression)', (tester) async {
    await tester.pumpWidget(_app(AppRoutes.chats));
    await tester.pump();

    final shell = tester
        .widgetList<Scaffold>(find.byType(Scaffold))
        .firstWhere((s) => s.bottomNavigationBar is GlassNavBar);
    expect(
      shell.extendBody,
      isFalse,
      reason: 'extendBody must stay false so a child screen FAB never renders '
          'behind the GlassNavBar BackdropFilter and blurs into a false '
          'selection highlight',
    );
  });
}
