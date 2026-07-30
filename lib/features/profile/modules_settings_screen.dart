import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/modules/module_manifest.dart';
import '../../core/modules/module_registry.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../services/module_prefs.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Modules settings, the "promote to toolbar" + enable/disable surface.
/// ─────────────────────────────────────────────────────────────────────────
///
/// Lists every declared module with:
///   * an enable/disable toggle (writes [modulePrefsProvider].setEnabled)
///   * a placement chooser (nav / toolbar / drawer)  ← the promote control
///   * an availability badge (greyed-with-a-reason when a capability is down)
///
/// The final shown set = settings ∩ availability, so toggling here flows
/// straight through [enabledModulesProvider] → nav/toolbar/drawer providers and
/// the live surfaces rebuild.
class ModulesSettingsScreen extends ConsumerWidget {
  const ModulesSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final availability = ref.watch(moduleAvailabilityProvider);
    final prefs = ref.watch(modulePrefsProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: Text('Modules', style: tt.displayLarge?.copyWith(fontSize: 24)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 80, top: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              'Enable modules and choose where each one lives, the bottom nav, '
              'the toolbar, or the swipe-up app drawer. A module greys out when '
              'the node it needs is offline.',
              style: tt.bodySmall?.copyWith(
                color: SovereignColors.textSecondary,
              ),
            ),
          ),
          // Dev-only: mount and preview the LIVE skchat_ui SkworldModule via a
          // concrete ShellContext (U3). Pushed (not go'd) so system back pops
          // it; never shown in release builds.
          if (kDebugMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ListTile(
                key: const Key('dev-mount-skchat-module'),
                tileColor: SovereignColors.surfaceRaised,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: const Icon(
                  Icons.science_outlined,
                  color: SovereignColors.soulLumina,
                ),
                title: Text('Preview skchat module (dev)', style: tt.bodyLarge),
                subtitle: Text(
                  'Mount the live skchat_ui module via a concrete ShellContext',
                  style: tt.bodySmall
                      ?.copyWith(color: SovereignColors.textSecondary),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.moduleSkchat),
              ),
            ),
          for (final a in availability)
            _ModuleCard(
              key: Key('module-card-${a.manifest.id}'),
              availability: a,
              enabled: prefs.isEnabled(a.manifest.id),
              placement: prefs.placementFor(a.manifest),
              onToggle: (v) => ref
                  .read(modulePrefsProvider.notifier)
                  .setEnabled(a.manifest.id, v),
              onPlacement: (p) => ref
                  .read(modulePrefsProvider.notifier)
                  .setPlacement(a.manifest.id, p),
            ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    super.key,
    required this.availability,
    required this.enabled,
    required this.placement,
    required this.onToggle,
    required this.onPlacement,
  });

  final ModuleAvailability availability;
  final bool enabled;
  final ModulePlacement placement;
  final ValueChanged<bool> onToggle;
  final ValueChanged<ModulePlacement> onPlacement;

  @override
  Widget build(BuildContext context) {
    final m = availability.manifest;
    final tt = Theme.of(context).textTheme;
    final available = availability.available;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: SovereignColors.soulLumina.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(m.icon,
                      color: SovereignColors.soulLumina, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            m.title,
                            style: tt.titleMedium?.copyWith(
                              color: SovereignColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (m.role == ModuleRole.operator) ...[
                            const SizedBox(width: 6),
                            _RolePill(label: m.role.label),
                          ],
                        ],
                      ),
                      if (m.description != null)
                        Text(
                          m.description!,
                          style: tt.bodySmall?.copyWith(
                            color: SovereignColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                Switch(
                  key: Key('module-toggle-${m.id}'),
                  value: enabled,
                  onChanged: onToggle,
                  activeThumbColor: SovereignColors.soulLumina,
                ),
              ],
            ),
            // Availability reason (honesty, greyed with a reason).
            if (!available) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.lock_outline_rounded,
                      size: 13, color: SovereignColors.accentWarning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Unavailable, ${availability.reason}',
                      key: Key('module-reason-${m.id}'),
                      style: tt.labelSmall?.copyWith(
                        color: SovereignColors.accentWarning,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            // Placement chooser (the promote control). Disabled when the module
            // is off, placement is meaningless until it's enabled.
            const SizedBox(height: 12),
            Opacity(
              opacity: enabled ? 1.0 : 0.4,
              child: IgnorePointer(
                ignoring: !enabled,
                child: SegmentedButton<ModulePlacement>(
                  key: Key('module-placement-${m.id}'),
                  segments: const [
                    ButtonSegment(
                      value: ModulePlacement.nav,
                      icon: Icon(Icons.dock_outlined, size: 16),
                      label: Text('Nav'),
                    ),
                    ButtonSegment(
                      value: ModulePlacement.toolbar,
                      icon: Icon(Icons.web_asset_outlined, size: 16),
                      label: Text('Toolbar'),
                    ),
                    ButtonSegment(
                      value: ModulePlacement.drawer,
                      icon: Icon(Icons.apps_outlined, size: 16),
                      label: Text('Drawer'),
                    ),
                  ],
                  selected: {placement},
                  showSelectedIcon: false,
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) onPlacement(set.first);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: SovereignColors.soulJarvis.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          color: SovereignColors.soulJarvis,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
