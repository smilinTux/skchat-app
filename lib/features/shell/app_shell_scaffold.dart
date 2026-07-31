import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme/theme.dart';
import 'app_drawer_sheet.dart';

/// Width (logical px) at or above which the shell renders a persistent left
/// [NavigationRail] instead of the bottom [GlassNavBar]. Below it, the bottom
/// bar is rendered exactly as before (untouched).
const double kRailBreakpoint = 900;

/// Number of primary destinations kept directly on the narrow bottom
/// [GlassNavBar] before the rest collapse behind a trailing "More" item.
///
/// The dynamic-modules pipeline can now hand the shell up to ~8 destinations
/// (Chats, Spaces, Code, Activity, Ops, Me + discovered Board/OS), which is far
/// too many for a phone-width bottom bar. So the bar shows at most the first
/// [kPrimaryBottomNavCount] tabs **in nav order**, and every tab past that folds
/// into a single "More" item that opens an overflow sheet. This is a pure
/// renderer split over the SAME [AppNavTab] model the shell already builds, keyed
/// only on nav order, it never forks or re-curates the destination list.
///
/// When the shell supplies few enough tabs that overflow would leave a lone item
/// behind "More" (i.e. `tabs.length <= kPrimaryBottomNavCount + 1`), the bar
/// renders every tab directly instead, so the common fleet (6 tabs) is unchanged
/// and "More" only ever appears once it holds two or more destinations.
const int kPrimaryBottomNavCount = 5;

/// A single primary navigation destination.
///
/// This is the ONE model both renderers (the bottom [GlassNavBar] and the wide
/// [_SovereignNavRail]) consume. The responsive layout adds a new renderer over
/// the same destinations, it never adds a second navigation model or state.
class AppNavTab {
  const AppNavTab({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.path,
    this.available = true,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String path;

  /// Whether the module backing this tab is currently available (its required
  /// node capabilities resolve). Unavailable tabs are NOT hidden, they render
  /// dimmed so the nav is honest ("grey with a reason, never hide"); the subapp
  /// screen itself explains why. The Ops hub and core tabs are always true.
  final bool available;
}

/// The presentational shell scaffold: given a fully-resolved navigation model
/// (destinations, the selected index, badge counts, offline flag) it renders
/// either the bottom [GlassNavBar] (narrow) or the left [NavigationRail]
/// (>= [kRailBreakpoint]). It holds no providers of its own: every value is
/// passed in by [AppShell], which remains the single source that reads the
/// existing providers. This keeps the widget cheaply testable at both widths.
class AppShellScaffold extends StatelessWidget {
  const AppShellScaffold({
    super.key,
    required this.tabs,
    required this.currentIndex,
    required this.isOffline,
    required this.badgeCounts,
    required this.onSelect,
    required this.banner,
    required this.child,
  }) : assert(badgeCounts.length == tabs.length,
            'badgeCounts must align 1:1 with tabs');

  /// The shared destination model.
  final List<AppNavTab> tabs;

  /// Index into [tabs] of the currently-selected destination.
  final int currentIndex;

  /// Whether the SKComms daemon is currently unreachable.
  final bool isOffline;

  /// Per-tab unread/pending badge counts, aligned 1:1 with [tabs]. A count of
  /// 0 renders no badge.
  final List<int> badgeCounts;

  /// Called with a destination path when the user selects a destination.
  final void Function(String path) onSelect;

  /// The incoming-call banner widget, injected so this scaffold stays free of
  /// call-feature provider dependencies (and trivially testable).
  final Widget banner;

  /// The active tab screen.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kRailBreakpoint;
        final body = _buildBody(context);

        if (wide) {
          // Wide layout: persistent left rail + body. No bottom bar. The
          // swipe-up app-drawer gesture on the body still works.
          return Scaffold(
            backgroundColor: SovereignColors.surfaceBase,
            body: SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SovereignNavRail(
                    tabs: tabs,
                    currentIndex: currentIndex,
                    badgeCounts: badgeCounts,
                    onSelect: onSelect,
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          );
        }

        // Narrow layout: unchanged bottom-bar shell.
        return Scaffold(
          backgroundColor: SovereignColors.surfaceBase,
          // extendBody must stay FALSE. When true, each child screen's body
          // (and its FloatingActionButton) extends behind the frosted
          // GlassNavBar; the nav bar's BackdropFilter then blurs a child FAB
          // (Chats' round FAB, Spaces' wide extended FAB) into a diffuse purple
          // glow that reads as a spurious selection highlight over the bar
          // (NAVBUG: "Spaces lights up the whole menu background", "Chats
          // lights up Me"). Keeping the body above the bar stops that
          // bleed-through, so each tab highlights only its own item. Screens
          // without a FAB (Activity, Ops, Me) were already unaffected.
          extendBody: false,
          body: body,
          bottomNavigationBar: _buildBottomNav(context),
        );
      },
    );
  }

  /// The shared body column: incoming-call banner, offline banner, then the
  /// active screen wrapped in the swipe-up drawer gesture detector. Identical
  /// in both layouts.
  Widget _buildBody(BuildContext context) {
    return Column(
      children: [
        // Ringing incoming-call banner (Accept/Decline). Sits above the
        // offline banner so a ring is never buried under it.
        banner,
        // Offline banner, shown when daemon is unreachable.
        if (isOffline)
          Material(
            color: SovereignColors.accentWarning.withValues(alpha: 0.15),
            child: const SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 14,
                      color: SovereignColors.accentWarning,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'SKComms daemon offline, messages will queue',
                      style: TextStyle(
                        fontSize: 12,
                        color: SovereignColors.accentWarning,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // Swipe up anywhere -> reveal the app drawer (the user's
            // swipe-up-from-bottom instinct is honored). A fast upward fling
            // opens the module drawer.
            onVerticalDragEnd: (details) {
              final v = details.primaryVelocity ?? 0;
              if (v < -350) {
                AppDrawerSheet.show(context);
              }
            },
            child: child,
          ),
        ),
      ],
    );
  }

  /// The frosted bottom navigation bar (narrow layout only).
  ///
  /// When the shell hands us more than [kPrimaryBottomNavCount] (+1) tabs, the
  /// first [kPrimaryBottomNavCount] render directly and the rest collapse into a
  /// trailing "More" item that opens [_NavOverflowSheet]. The active highlight,
  /// the Ops-hub gating, and every badge are preserved: an overflowed selection
  /// lights the "More" item, and any badge counts on overflowed tabs are summed
  /// onto it so a pending count is never silently hidden behind the fold.
  Widget _buildBottomNav(BuildContext context) {
    // Split by nav order. Only fold into "More" once it would hold >= 2 tabs;
    // otherwise show everything directly (keeps the common fleet unchanged).
    final bool hasOverflow = tabs.length > kPrimaryBottomNavCount + 1;
    final int primaryCount = hasOverflow ? kPrimaryBottomNavCount : tabs.length;

    // Overflow slice (empty when there is no overflow) and its aggregate badge.
    final overflowTabs = hasOverflow ? tabs.sublist(primaryCount) : const <AppNavTab>[];
    final overflowBadges =
        hasOverflow ? badgeCounts.sublist(primaryCount) : const <int>[];
    final overflowBadgeTotal = overflowBadges.fold<int>(0, (a, b) => a + b);
    // The selected tab is inside the overflow => the "More" item is the active
    // one, and the sheet should mark that destination.
    final bool overflowActive = hasOverflow && currentIndex >= primaryCount;
    final String? activeOverflowPath =
        overflowActive ? tabs[currentIndex].path : null;

    return GlassNavBar(
      key: const Key('glass-nav-bar'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tappable grip, opens the swipe-up app drawer (discoverability for
          // the swipe-up gesture).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => AppDrawerSheet.show(context),
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -200) {
                AppDrawerSheet.show(context);
              }
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Container(
                key: const Key('app-drawer-grip'),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: SovereignColors.textTertiary.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < primaryCount; i++)
                _bottomNavItem(
                  context,
                  icon: tabs[i].icon,
                  activeIcon: tabs[i].activeIcon,
                  label: tabs[i].label,
                  isActive: i == currentIndex,
                  available: tabs[i].available,
                  badgeCount: badgeCounts[i],
                  onTap: () => onSelect(tabs[i].path),
                ),
              if (hasOverflow)
                _bottomNavItem(
                  context,
                  key: const Key('nav-more-item'),
                  icon: Icons.more_horiz_rounded,
                  activeIcon: Icons.more_horiz_rounded,
                  label: 'More',
                  isActive: overflowActive,
                  available: true,
                  badgeCount: overflowBadgeTotal,
                  onTap: () => _NavOverflowSheet.show(
                    context,
                    tabs: overflowTabs,
                    badgeCounts: overflowBadges,
                    activePath: activeOverflowPath,
                    onSelect: onSelect,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// One bottom-bar cell: icon (badged when [badgeCount] > 0), label, active
  /// highlight, and honest dimming for a capability-down destination. Shared by
  /// the primary tabs and the trailing "More" item so they render identically.
  Widget _bottomNavItem(
    BuildContext context, {
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required bool isActive,
    required bool available,
    required int badgeCount,
    required VoidCallback onTap,
    Key? key,
  }) {
    final accentColor = Theme.of(context).colorScheme.primary;
    // Dim a capability-down tab (unless it's the current screen, where full
    // contrast keeps the active highlight legible). Honest grey, never hidden.
    final dimmed = !available && !isActive;

    Widget iconWidget = Icon(
      isActive ? activeIcon : icon,
      key: ValueKey(isActive),
      size: 24,
      color: isActive ? accentColor : SovereignColors.textSecondary,
    );
    if (badgeCount > 0) {
      iconWidget = Badge(
        label: Text(badgeCount > 99 ? '99+' : '$badgeCount'),
        backgroundColor: SovereignColors.accentDanger,
        child: iconWidget,
      );
    }

    return Expanded(
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Opacity(
            opacity: dimmed ? 0.45 : 1.0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: iconWidget,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: isActive
                            ? accentColor
                            : SovereignColors.textSecondary,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The overflow sheet behind the narrow bottom bar's "More" item: a modal
/// bottom sheet listing every destination that did not fit as a primary tab.
/// Tapping a row navigates via the same [onSelect] (`context.go`) the bar uses
/// and closes the sheet, so an overflowed destination is reached in one gesture.
/// The currently-active overflowed destination (if any) is highlighted, and each
/// row carries its own badge + honest capability dimming.
class _NavOverflowSheet extends StatelessWidget {
  const _NavOverflowSheet({
    required this.tabs,
    required this.badgeCounts,
    required this.activePath,
    required this.onSelect,
  });

  final List<AppNavTab> tabs;
  final List<int> badgeCounts;
  final String? activePath;
  final void Function(String path) onSelect;

  static Future<void> show(
    BuildContext context, {
    required List<AppNavTab> tabs,
    required List<int> badgeCounts,
    required String? activePath,
    required void Function(String path) onSelect,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _NavOverflowSheet(
        tabs: tabs,
        badgeCounts: badgeCounts,
        activePath: activePath,
        onSelect: onSelect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Material(
      key: const Key('nav-overflow-sheet'),
      color: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SovereignColors.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < tabs.length; i++)
              _overflowRow(context, tabs[i], badgeCounts[i], accent),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _overflowRow(
    BuildContext context,
    AppNavTab tab,
    int badgeCount,
    Color accent,
  ) {
    final isActive = tab.path == activePath;
    final dimmed = !tab.available && !isActive;
    final color = isActive ? accent : SovereignColors.textPrimary;

    Widget leading = Icon(
      isActive ? tab.activeIcon : tab.icon,
      color: isActive ? accent : SovereignColors.textSecondary,
    );
    if (badgeCount > 0) {
      leading = Badge(
        label: Text(badgeCount > 99 ? '99+' : '$badgeCount'),
        backgroundColor: SovereignColors.accentDanger,
        child: leading,
      );
    }

    return Opacity(
      opacity: dimmed ? 0.45 : 1.0,
      child: ListTile(
        key: Key('nav-overflow-item-${tab.path}'),
        selected: isActive,
        selectedTileColor: accent.withValues(alpha: 0.10),
        leading: leading,
        title: Text(
          tab.label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: color,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
        ),
        onTap: () {
          Navigator.of(context).pop();
          onSelect(tab.path);
        },
      ),
    );
  }
}

/// The wide-layout left navigation rail, styled to the Sovereign Glass tokens
/// (frosted surface, hairline right border) and fed by the SAME destinations,
/// selection, and badge counts as the bottom [GlassNavBar]. Collapses to
/// icons-only, expands to icons + labels via the leading toggle.
class _SovereignNavRail extends StatefulWidget {
  const _SovereignNavRail({
    required this.tabs,
    required this.currentIndex,
    required this.badgeCounts,
    required this.onSelect,
  });

  final List<AppNavTab> tabs;
  final int currentIndex;
  final List<int> badgeCounts;
  final void Function(String path) onSelect;

  @override
  State<_SovereignNavRail> createState() => _SovereignNavRailState();
}

class _SovereignNavRailState extends State<_SovereignNavRail> {
  // Collapsed (icons only) by default, matching the compact bottom bar. The
  // leading button toggles labels on.
  bool _extended = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    final rail = NavigationRail(
      key: const Key('sovereign-nav-rail'),
      backgroundColor: Colors.transparent,
      // With the dynamic-modules pipeline the rail can carry 8+ destinations;
      // on a short viewport that would overflow a fixed Column. `scrollable`
      // wraps the destinations so the rail scrolls instead of overflowing.
      scrollable: true,
      extended: _extended,
      // NavigationRail forbids an explicit labelType while extended; when
      // collapsed we show labels under each icon.
      labelType: _extended ? null : NavigationRailLabelType.all,
      selectedIndex: widget.currentIndex,
      useIndicator: true,
      indicatorColor: accent.withValues(alpha: 0.15),
      selectedIconTheme: IconThemeData(color: accent),
      unselectedIconTheme:
          const IconThemeData(color: SovereignColors.textSecondary),
      selectedLabelTextStyle: TextStyle(
        color: accent,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: SovereignColors.textSecondary,
        fontWeight: FontWeight.w400,
        fontSize: 12,
      ),
      leading: _RailToggle(
        extended: _extended,
        onToggle: () => setState(() => _extended = !_extended),
      ),
      onDestinationSelected: (i) => widget.onSelect(widget.tabs[i].path),
      destinations: [
        for (var i = 0; i < widget.tabs.length; i++)
          NavigationRailDestination(
            icon: _railIcon(
              widget.tabs[i].icon,
              widget.badgeCounts[i],
              dimmed: !widget.tabs[i].available,
            ),
            selectedIcon:
                _railIcon(widget.tabs[i].activeIcon, widget.badgeCounts[i]),
            label: Text(widget.tabs[i].label),
          ),
      ],
    );

    // Frosted glass chrome to match GlassNavBar, with a hairline right border
    // instead of a top border.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: const BoxDecoration(
            color: SovereignColors.surfaceGlass,
            border: Border(
              right: BorderSide(
                color: SovereignColors.surfaceGlassBorder,
                width: 1,
              ),
            ),
          ),
          child: rail,
        ),
      ),
    );
  }

  /// Wraps a destination icon in a [Badge] when its count is non-zero, and dims
  /// it when the backing module is capability-down (honest grey, never hidden).
  Widget _railIcon(IconData icon, int count, {bool dimmed = false}) {
    Widget iconWidget = Icon(icon);
    if (count > 0) {
      iconWidget = Badge(
        label: Text(count > 99 ? '99+' : '$count'),
        backgroundColor: SovereignColors.accentDanger,
        child: iconWidget,
      );
    }
    if (dimmed) {
      iconWidget = Opacity(opacity: 0.45, child: iconWidget);
    }
    return iconWidget;
  }
}

/// Leading hamburger toggle for the rail: flips between icons-only and
/// icons + labels.
class _RailToggle extends StatelessWidget {
  const _RailToggle({required this.extended, required this.onToggle});

  final bool extended;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: IconButton(
        key: const Key('nav-rail-toggle'),
        tooltip: extended ? 'Collapse menu' : 'Expand menu',
        icon: Icon(
          extended ? Icons.menu_open_rounded : Icons.menu_rounded,
          color: SovereignColors.textSecondary,
        ),
        onPressed: onToggle,
      ),
    );
  }
}
