import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/modules/module_registry.dart';
import '../../core/theme/theme.dart';

/// AppBar action icons for every module the user promoted to the `toolbar`
/// slot. Drop into a screen's `AppBar.actions` to render promoted modules'
/// icons; tapping one routes to that module. Unavailable (capability-down)
/// promoted modules render greyed and show their reason on tap (honesty).
///
/// This is the render side of "promote-to-toolbar": the Modules settings tab
/// moves a module's placement to `toolbar`, [toolbarModulesProvider] picks it
/// up, and this widget surfaces it.
class ToolbarModuleActions extends ConsumerWidget {
  const ToolbarModuleActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placed = ref.watch(toolbarModulesProvider);
    if (placed.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in placed)
          IconButton(
            key: Key('toolbar-module-${p.manifest.id}'),
            icon: Icon(p.manifest.icon),
            color: p.available
                ? null
                : SovereignColors.textTertiary.withValues(alpha: 0.5),
            tooltip: p.available
                ? p.manifest.title
                : '${p.manifest.title}, ${p.reason}',
            onPressed: () {
              if (!p.available) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '${p.manifest.title} unavailable, ${p.reason}',
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
                return;
              }
              context.go(p.manifest.route);
            },
          ),
      ],
    );
  }
}
