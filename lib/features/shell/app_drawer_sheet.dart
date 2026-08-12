import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/modules/module_manifest.dart';
import '../../core/modules/module_registry.dart';
import '../../core/theme/theme.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Swipe-up app drawer, the "all enabled sub-apps" grid.
/// ─────────────────────────────────────────────────────────────────────────
///
/// A [DraggableScrollableSheet] (the 2026 bottom-sheet standard) fed by
/// [drawerModulesProvider]: a grid of every enabled module placed in the
/// `drawer` slot, grouped by role (Everyone / Operator).
///
/// Availability honesty: an enabled-but-capability-down module renders greyed
/// with its reason instead of vanishing, tapping it is disabled and a snack
/// explains why.
///
/// Z-order: presented via `showModalBottomSheet`, which sits *below* the app's
/// Overlay-based PiP / incoming-call surfaces (those use OverlayEntry in the
/// root Overlay), so an active call's PiP window keeps floating above the
/// drawer rather than being covered. No manual stacking needed.
class AppDrawerSheet extends ConsumerWidget {
  const AppDrawerSheet({super.key});

  /// Show the drawer as a modal bottom sheet.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AppDrawerSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placed = ref.watch(drawerModulesProvider);
    final everyone =
        placed.where((p) => p.manifest.role == ModuleRole.everyone).toList();
    final operator =
        placed.where((p) => p.manifest.role == ModuleRole.operator).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: SovereignColors.surfaceRaised,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              const SliverToBoxAdapter(child: _DrawerHandle()),
              if (placed.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyDrawer(),
                ),
              if (everyone.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: _DrawerGroupLabel(label: 'Modules'),
                ),
                _ModuleGrid(modules: everyone),
              ],
              if (operator.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: _DrawerGroupLabel(label: 'Operator'),
                ),
                _ModuleGrid(modules: operator),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      },
    );
  }
}

class _DrawerHandle extends StatelessWidget {
  const _DrawerHandle();

  @override
  Widget build(BuildContext context) {
    return Column(
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
      ],
    );
  }
}

class _DrawerGroupLabel extends StatelessWidget {
  const _DrawerGroupLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: SovereignColors.textTertiary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _ModuleGrid extends StatelessWidget {
  const _ModuleGrid({required this.modules});
  final List<PlacedModule> modules;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.85,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _DrawerModuleTile(placed: modules[i]),
          childCount: modules.length,
        ),
      ),
    );
  }
}

class _DrawerModuleTile extends StatelessWidget {
  const _DrawerModuleTile({required this.placed});
  final PlacedModule placed;

  @override
  Widget build(BuildContext context) {
    final m = placed.manifest;
    final available = placed.available;
    final tint = available
        ? SovereignColors.soulLumina
        : SovereignColors.textTertiary;

    return InkWell(
      key: Key('drawer-module-${m.id}'),
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        if (!available) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${m.title} unavailable, ${placed.reason}'),
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }
        Navigator.of(context).pop();
        context.go(m.route);
      },
      child: Opacity(
        opacity: available ? 1.0 : 0.45,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(m.icon, color: tint, size: 26),
            ),
            const SizedBox(height: 6),
            Text(
              m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: available
                        ? SovereignColors.textPrimary
                        : SovereignColors.textTertiary,
                  ),
            ),
            if (!available)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: 11,
                  color: SovereignColors.textTertiary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDrawer extends StatelessWidget {
  const _EmptyDrawer();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.widgets_outlined,
              size: 40,
              color: SovereignColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(
              'No modules in the drawer',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: SovereignColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Enable or move modules here from Me → Modules.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: SovereignColors.textTertiary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
