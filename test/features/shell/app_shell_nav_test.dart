import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/core/theme/glass_widgets.dart';
import 'package:skchat/features/shell/app_shell.dart';
import 'package:skchat/services/skcomms_sync.dart';

/// Stub the daemon sync notifier so tests never start the real 5s/15s poll
/// timers or touch the network. Reports "connecting" (banner stays hidden).
class _StubSync extends SKCommsSyncNotifier {
  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.connecting);
}

/// Active (filled) icon shown for the currently selected tab.
const _activeIcons = <String, IconData>{
  'chats': Icons.chat_bubble_rounded,
  'spaces': Icons.podcasts_rounded,
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

Widget _app(String initialLocation, {Widget child = const _FabChild()}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, c) => AppShell(child: c),
        routes: [
          for (final path in const [
            AppRoutes.chats,
            AppRoutes.spaces,
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
