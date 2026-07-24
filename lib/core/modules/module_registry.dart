import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/capabilities_service.dart';
import '../../services/module_prefs.dart';
import '../router/app_router.dart';
import 'module_manifest.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Module registry, the declared set of app surfaces (Phase 0).
/// ─────────────────────────────────────────────────────────────────────────
///
/// A `const` list of [ModuleManifest] declaring the surfaces the app exposes.
/// Phase 0 declares them all so the spine is provably complete, but only the
/// **skmap pilot** is fully wired through the registry (its Hub tile is removed
/// and its placement/availability flow is end-to-end). The other surfaces keep
/// their existing hand-coded wiring for now, later phases migrate the routes
/// and bottom-nav off the constants and onto these manifests.
///
/// Each manifest's `requires` references the EXISTING capability ids verbatim
/// (`service:text`, `service:geo-cot`, `transport:webrtc`, …) so no backend
/// contract change is needed to gate them.
const List<ModuleManifest> kBuiltinModules = [
  // ── Core comms (nav) ──────────────────────────────────────────────────────
  ModuleManifest(
    id: 'chats',
    title: 'Chats',
    icon: Icons.chat_bubble_outline_rounded,
    activeIcon: Icons.chat_bubble_rounded,
    route: AppRoutes.chats,
    requires: [CapabilityRef('service:text')],
    defaultPlacement: ModulePlacement.nav,
    order: 0,
    description: '1:1 and group messages',
  ),
  ModuleManifest(
    id: 'spaces',
    title: 'Spaces',
    icon: Icons.podcasts_outlined,
    activeIcon: Icons.podcasts_rounded,
    route: AppRoutes.spaces,
    requires: [CapabilityRef('service:voice')],
    defaultPlacement: ModulePlacement.nav,
    order: 10,
    description: 'Live audio rooms',
  ),
  ModuleManifest(
    id: 'activity',
    title: 'Activity',
    icon: Icons.notifications_outlined,
    activeIcon: Icons.notifications_rounded,
    route: AppRoutes.activity,
    defaultPlacement: ModulePlacement.nav,
    order: 20,
    description: 'Mentions, replies, reactions',
  ),
  ModuleManifest(
    id: 'profile',
    title: 'Me',
    icon: Icons.person_outline_rounded,
    activeIcon: Icons.person_rounded,
    route: AppRoutes.profile,
    defaultPlacement: ModulePlacement.nav,
    order: 40,
    description: 'Identity, presence, settings',
  ),

  // ── PILOT: SkMap (drawer-by-default, geo-cot gated) ───────────────────────
  ModuleManifest(
    id: 'skmap',
    title: 'SkMap',
    icon: Icons.radar_outlined,
    route: AppRoutes.skmap,
    requires: [CapabilityRef('service:geo-cot')],
    defaultPlacement: ModulePlacement.drawer,
    order: 30,
    description: 'Tactical map, live unit positions',
  ),

  // ── Operator surfaces (drawer) ────────────────────────────────────────────
  ModuleManifest(
    id: 'cluster',
    title: 'Cluster',
    icon: Icons.hub_outlined,
    route: AppRoutes.cluster,
    defaultPlacement: ModulePlacement.drawer,
    role: ModuleRole.operator,
    order: 100,
    description: 'skbloom cluster control',
  ),
  ModuleManifest(
    id: 'skos-files',
    title: 'skos Files',
    icon: Icons.folder_special_outlined,
    route: AppRoutes.skosFiles,
    requires: [CapabilityRef('service:access-plane')],
    defaultPlacement: ModulePlacement.drawer,
    role: ModuleRole.operator,
    order: 110,
    description: 'Browse + search the sovereign disk',
  ),
  ModuleManifest(
    id: 'skos-control',
    title: 'skos Control',
    icon: Icons.dns_outlined,
    route: AppRoutes.skosControl,
    requires: [CapabilityRef('service:access-plane')],
    defaultPlacement: ModulePlacement.drawer,
    role: ModuleRole.operator,
    order: 120,
    description: 'Per-node health & access-plane status',
  ),
  ModuleManifest(
    id: 'coord',
    title: 'Coord Board',
    icon: Icons.dashboard_customize_outlined,
    route: AppRoutes.coord,
    defaultPlacement: ModulePlacement.drawer,
    role: ModuleRole.operator,
    order: 130,
    description: 'Agent coordination tasks',
  ),
  ModuleManifest(
    id: 'recordings',
    title: 'Recordings',
    icon: Icons.fiber_manual_record_outlined,
    route: AppRoutes.recordings,
    defaultPlacement: ModulePlacement.drawer,
    role: ModuleRole.operator,
    order: 140,
    description: 'Call & space recordings',
  ),
];

// ── Providers ───────────────────────────────────────────────────────────────

/// All declared module manifests (the static registry).
final moduleRegistryProvider = Provider<List<ModuleManifest>>((ref) {
  return kBuiltinModules;
});

/// Registry ∩ node capabilities, each module paired with its resolved
/// [ModuleAvailability]. A module is **available** only when EVERY `requires`
/// ref resolves to an up/configured/degraded [CapStatus] and the daemon API
/// floor is met; otherwise it stays in the list but `available == false` with a
/// `reason` (honesty principle: grey with a reason, never silently hide).
///
/// When the node advertises a `modules` hint block, modules NOT named there are
/// dropped from this list entirely (operator policy, "this deployment doesn't
/// ship that sub-app"). An empty/absent hint list = ship the full registry.
final moduleAvailabilityProvider =
    Provider<List<ModuleAvailability>>((ref) {
  final modules = ref.watch(moduleRegistryProvider);
  final capsAsync = ref.watch(nodeCapabilitiesProvider);
  final caps = capsAsync.asData?.value;

  final hints = caps?.moduleHints ?? const <String>[];
  final filtered = hints.isEmpty
      ? modules
      : modules.where((m) => hints.contains(m.id)).toList();

  return [
    for (final m in filtered)
      ModuleAvailability.resolve(m, caps, daemonApi: caps?.api),
  ];
});

/// Convenience: id → availability lookup.
final moduleAvailabilityByIdProvider =
    Provider<Map<String, ModuleAvailability>>((ref) {
  final list = ref.watch(moduleAvailabilityProvider);
  return {for (final a in list) a.manifest.id: a};
});

/// The user-enabled, capability-gated, placement-resolved modules, the FINAL
/// shown set = settings ∩ availability, carrying each module's effective slot
/// and order. Disabled-by-user modules are excluded entirely; enabled modules
/// are included even when unavailable (so the drawer/settings can show them
/// greyed with a reason).
final enabledModulesProvider = Provider<List<PlacedModule>>((ref) {
  final availability = ref.watch(moduleAvailabilityProvider);
  final prefs = ref.watch(modulePrefsProvider);

  // Seed defaults from the registry the first time (no persisted prefs yet).
  if (!prefs.initialized) {
    final manifests = availability.map((a) => a.manifest).toList();
    // Capture the notifier NOW, during build, while `ref` is guaranteed
    // current. Defer only the mutation itself so we don't mutate a
    // provider during build. Calling `ref.read(...)` again later, inside
    // the microtask, is unsafe: if this provider rebuilds (or a watched
    // dependency changes) before the microtask runs, the captured `ref` is
    // outdated and Riverpod's `!_didChangeDependency` assertion fires.
    // The notifier reference itself stays valid across rebuilds, and
    // `seedFrom` is idempotent (a no-op once prefs are initialized), so a
    // stale call here is harmless even if seeding already happened.
    final prefsNotifier = ref.read(modulePrefsProvider.notifier);
    Future.microtask(() => prefsNotifier.seedFrom(manifests));
    // Until the seed lands, treat all-enabled at default placement so the app
    // renders normally on the very first frame.
    return [
      for (final a in availability)
        PlacedModule(
          availability: a,
          placement: a.manifest.defaultPlacement,
          order: a.manifest.order,
        ),
    ]..sort(_byOrder);
  }

  final out = <PlacedModule>[];
  for (final a in availability) {
    if (!prefs.isEnabled(a.manifest.id)) continue;
    out.add(PlacedModule(
      availability: a,
      placement: prefs.placementFor(a.manifest),
      order: prefs.orderFor(a.manifest),
    ));
  }
  out.sort(_byOrder);
  return out;
});

int _byOrder(PlacedModule a, PlacedModule b) =>
    a.order.compareTo(b.order);

/// Modules the user placed in the bottom nav (enabled set, nav slot).
final navModulesProvider = Provider<List<PlacedModule>>((ref) {
  return ref
      .watch(enabledModulesProvider)
      .where((p) => p.placement == ModulePlacement.nav)
      .toList();
});

/// Modules the user promoted to the toolbar (enabled set, toolbar slot).
final toolbarModulesProvider = Provider<List<PlacedModule>>((ref) {
  return ref
      .watch(enabledModulesProvider)
      .where((p) => p.placement == ModulePlacement.toolbar)
      .toList();
});

/// Modules in the swipe-up app drawer (enabled set, drawer slot).
final drawerModulesProvider = Provider<List<PlacedModule>>((ref) {
  return ref
      .watch(enabledModulesProvider)
      .where((p) => p.placement == ModulePlacement.drawer)
      .toList();
});

/// A module manifest resolved with its availability + the user's effective
/// placement/order, what the nav/toolbar/drawer widgets render.
@immutable
class PlacedModule {
  const PlacedModule({
    required this.availability,
    required this.placement,
    required this.order,
  });

  final ModuleAvailability availability;
  final ModulePlacement placement;
  final int order;

  ModuleManifest get manifest => availability.manifest;
  bool get available => availability.available;
  String? get reason => availability.reason;
}
