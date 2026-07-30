import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme/theme.dart';
import 'app_drawer_sheet.dart';

/// Width (logical px) at or above which the shell renders a persistent left
/// [NavigationRail] instead of the bottom [GlassNavBar]. Below it, the bottom
/// bar is rendered exactly as before (untouched).
const double kRailBreakpoint = 900;

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
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String path;
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

  /// The unchanged frosted bottom navigation bar (narrow layout only).
  Widget _buildBottomNav(BuildContext context) {
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
            children: List.generate(tabs.length, (i) {
              final tab = tabs[i];
              final isActive = i == currentIndex;
              final accentColor = Theme.of(context).colorScheme.primary;

              return Expanded(
                child: InkWell(
                  onTap: () => onSelect(tab.path),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            isActive ? tab.activeIcon : tab.icon,
                            key: ValueKey(isActive),
                            size: 24,
                            color: isActive
                                ? accentColor
                                : SovereignColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tab.label,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: isActive
                                        ? accentColor
                                        : SovereignColors.textSecondary,
                                    fontWeight: isActive
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
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
            icon: _railIcon(widget.tabs[i].icon, widget.badgeCounts[i]),
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

  /// Wraps a destination icon in a [Badge] when its count is non-zero.
  Widget _railIcon(IconData icon, int count) {
    final iconWidget = Icon(icon);
    if (count <= 0) return iconWidget;
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      backgroundColor: SovereignColors.accentDanger,
      child: iconWidget,
    );
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
