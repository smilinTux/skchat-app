import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/shell/app_shell_scaffold.dart';

/// Widget tests for the responsive shell renderer [AppShellScaffold].
///
/// The repo has no golden-test infrastructure (no `flutter_test_config.dart`),
/// and goldens are font-fragile in a headless CI, so these assert the concrete
/// responsive contract instead: the left [NavigationRail] renders at
/// >= [kRailBreakpoint] and the bottom [GlassNavBar] renders below it, both
/// fed by the same destination + badge model.
void main() {
  const tabs = <AppNavTab>[
    AppNavTab(
      label: 'Chats',
      icon: Icons.chat_bubble_outline_rounded,
      activeIcon: Icons.chat_bubble_rounded,
      path: AppRoutes.chats,
    ),
    AppNavTab(
      label: 'Spaces',
      icon: Icons.podcasts_outlined,
      activeIcon: Icons.podcasts_rounded,
      path: AppRoutes.spaces,
    ),
    AppNavTab(
      label: 'Activity',
      icon: Icons.notifications_outlined,
      activeIcon: Icons.notifications_rounded,
      path: AppRoutes.activity,
    ),
    AppNavTab(
      label: 'Ops',
      icon: Icons.grid_view_outlined,
      activeIcon: Icons.grid_view_rounded,
      path: AppRoutes.hub,
    ),
    AppNavTab(
      label: 'Me',
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      path: AppRoutes.profile,
    ),
  ];

  final railFinder = find.byKey(const Key('sovereign-nav-rail'));
  final bottomBarFinder = find.byKey(const Key('glass-nav-bar'));

  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    List<int>? badgeCounts,
    int currentIndex = 0,
    void Function(String path)? onSelect,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: AppShellScaffold(
          tabs: tabs,
          currentIndex: currentIndex,
          isOffline: false,
          badgeCounts: badgeCounts ?? List<int>.filled(tabs.length, 0),
          onSelect: onSelect ?? (_) {},
          banner: const SizedBox.shrink(),
          child: const Text('body'),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders the left rail (not the bottom bar) at >= 900px',
      (tester) async {
    await pumpAt(tester, const Size(1000, 800));

    expect(railFinder, findsOneWidget);
    expect(bottomBarFinder, findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('renders the bottom bar (not the rail) below 900px',
      (tester) async {
    await pumpAt(tester, const Size(500, 800));

    expect(bottomBarFinder, findsOneWidget);
    expect(railFinder, findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('renders exactly at the 900px breakpoint as the rail',
      (tester) async {
    await pumpAt(tester, const Size(900, 800));

    expect(railFinder, findsOneWidget);
    expect(bottomBarFinder, findsNothing);
  });

  testWidgets('rail shows badge counts from the shared model', (tester) async {
    // Chats (index 0) = 3 unread, Ops (index 3) = 2 pending.
    await pumpAt(
      tester,
      const Size(1000, 800),
      badgeCounts: const [3, 0, 0, 2, 0],
    );

    expect(railFinder, findsOneWidget);
    expect(find.byType(Badge), findsNWidgets(2));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('rail collapse/expand toggle is present and tappable',
      (tester) async {
    await pumpAt(tester, const Size(1000, 800));

    final toggle = find.byKey(const Key('nav-rail-toggle'));
    expect(toggle, findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Still rendered after expanding; labels are now visible in extended mode.
    expect(railFinder, findsOneWidget);
    expect(find.text('Chats'), findsWidgets);
  });

  testWidgets('selecting a rail destination reports its path', (tester) async {
    String? tapped;
    await pumpAt(
      tester,
      const Size(1000, 800),
      onSelect: (p) => tapped = p,
    );

    await tester.tap(find.text('Spaces').first);
    await tester.pump();

    expect(tapped, AppRoutes.spaces);
  });
}
