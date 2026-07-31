import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/core/theme/theme.dart';
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

  // ── Narrow-screen overflow ("More") behaviour ────────────────────────────

  /// Eight destinations: past [kPrimaryBottomNavCount] so the bottom bar folds.
  const manyTabs = <AppNavTab>[
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
      label: 'Code',
      icon: Icons.terminal_outlined,
      activeIcon: Icons.terminal_rounded,
      path: AppRoutes.code,
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
    AppNavTab(
      label: 'Board',
      icon: Icons.dashboard_customize_outlined,
      activeIcon: Icons.dashboard_customize_rounded,
      path: AppRoutes.coord,
    ),
    AppNavTab(
      label: 'OS',
      icon: Icons.dns_outlined,
      activeIcon: Icons.dns_rounded,
      path: AppRoutes.skosControl,
    ),
  ];

  Future<void> pumpManyAt(
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
          tabs: manyTabs,
          currentIndex: currentIndex,
          isOffline: false,
          badgeCounts: badgeCounts ?? List<int>.filled(manyTabs.length, 0),
          onSelect: onSelect ?? (_) {},
          banner: const SizedBox.shrink(),
          child: const Text('body'),
        ),
      ),
    );
    await tester.pump();
  }

  final moreItemFinder = find.byKey(const Key('nav-more-item'));

  testWidgets('narrow bar folds tabs past the primary count into "More"',
      (tester) async {
    await pumpManyAt(tester, const Size(400, 800));

    expect(bottomBarFinder, findsOneWidget);
    // First kPrimaryBottomNavCount (5) tabs render directly...
    for (final label in const ['Chats', 'Spaces', 'Code', 'Activity', 'Ops']) {
      expect(find.text(label), findsOneWidget, reason: '$label is primary');
    }
    // ...the rest are hidden behind "More" (not on the bar).
    expect(find.text('Me'), findsNothing);
    expect(find.text('Board'), findsNothing);
    expect(find.text('OS'), findsNothing);
    expect(find.text('More'), findsOneWidget);
    expect(moreItemFinder, findsOneWidget);
  });

  testWidgets('few tabs render directly with no "More" item', (tester) async {
    // The 5-tab default fits (<= kPrimaryBottomNavCount + 1), no fold.
    await pumpAt(tester, const Size(400, 800));
    expect(find.text('More'), findsNothing);
    expect(moreItemFinder, findsNothing);
    expect(find.text('Me'), findsOneWidget);
  });

  testWidgets('tapping "More" opens the overflow sheet listing folded tabs',
      (tester) async {
    await pumpManyAt(tester, const Size(400, 800));

    await tester.tap(moreItemFinder);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('nav-overflow-sheet')), findsOneWidget);
    // The folded destinations appear in the sheet.
    expect(find.text('Me'), findsOneWidget);
    expect(find.text('Board'), findsOneWidget);
    expect(find.text('OS'), findsOneWidget);
  });

  testWidgets('selecting an overflowed destination navigates via onSelect',
      (tester) async {
    String? tapped;
    await pumpManyAt(
      tester,
      const Size(400, 800),
      onSelect: (p) => tapped = p,
    );

    await tester.tap(moreItemFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('nav-overflow-item-${AppRoutes.coord}')));
    await tester.pumpAndSettle();

    expect(tapped, AppRoutes.coord);
    // Sheet is dismissed after selection.
    expect(find.byKey(const Key('nav-overflow-sheet')), findsNothing);
  });

  testWidgets('an active overflowed tab lights the "More" item', (tester) async {
    // currentIndex 6 = "Board", which lives in the overflow.
    await pumpManyAt(tester, const Size(400, 800), currentIndex: 6);

    // "More" renders as the active item: its label goes bold + accent-coloured
    // (the same treatment a selected primary tab gets), and the folded active
    // tab does not appear on the bar itself.
    expect(moreItemFinder, findsOneWidget);
    expect(find.text('Board'), findsNothing);
    final moreLabel = tester.widget<Text>(
      find.descendant(of: moreItemFinder, matching: find.text('More')),
    );
    expect(moreLabel.style?.fontWeight, FontWeight.w600);
    expect(
      moreLabel.style?.color,
      isNot(equals(SovereignColors.textSecondary)),
      reason: 'active More item is accent-coloured, not the inactive grey',
    );
  });

  testWidgets('overflowed badge counts are summed onto the "More" item',
      (tester) async {
    // Ops (index 4, primary) = 0; Me(5)=2, Board(6)=3, OS(7)=1 => More badge 6.
    await pumpManyAt(
      tester,
      const Size(400, 800),
      badgeCounts: const [0, 0, 0, 0, 0, 2, 3, 1],
    );

    expect(moreItemFinder, findsOneWidget);
    // The aggregate (2+3+1) shows as a badge on the More item.
    expect(
      find.descendant(of: moreItemFinder, matching: find.text('6')),
      findsOneWidget,
    );
  });
}
