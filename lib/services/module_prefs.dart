import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/modules/module_manifest.dart';
import '../core/modules/module_registry.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Module preferences, the *settings* half of the availability/placement
/// split (mirrors `daemon_config.dart`'s Hive-backed Notifier pattern).
/// ─────────────────────────────────────────────────────────────────────────
///
/// Availability is capability-gated and global (see [ModuleAvailability]).
/// Placement/visibility is per-user and persisted here:
///   * [ModulePrefs.enabledIds] , modules the user has turned on
///   * [ModulePrefs.placement]  , per-module slot override (nav/toolbar/drawer)
///   * [ModulePrefs.order]      , per-module sort override within a slot
///
/// The **final shown set = settings ∩ availability**: a module renders only
/// when the user has it enabled AND the node backs its required capabilities.
/// (Disabled-by-user modules simply don't render; capability-down-but-enabled
/// modules render greyed-with-a-reason, that distinction lives in the
/// registry providers, not here.)

const _kModulePrefsBox = 'module_prefs';
const _kEnabledKey = 'enabled_ids';
const _kPlacementKey = 'placement'; // Map<id, slotWire>
const _kOrderKey = 'order'; // Map<id, int>
const _kSeedVersionKey = 'seed_version'; // int, monotonic seed/migration marker

/// Immutable snapshot of the user's module preferences.
class ModulePrefs {
  const ModulePrefs({
    this.enabledIds = const {},
    this.placement = const {},
    this.order = const {},
    this.seedVersion = 0,
    this.initialized = false,
  });

  /// Ids the user has enabled. When [initialized] is false this is a seed
  /// placeholder, the registry seeds defaults from the manifest list on first
  /// run (every module's `defaultPlacement` + enabled).
  final Set<String> enabledIds;

  /// Per-module placement override. Absent → use the manifest default.
  final Map<String, ModulePlacement> placement;

  /// Per-module order override. Absent → use the manifest order.
  final Map<String, int> order;

  /// The module seed version this snapshot was last seeded/migrated at (see
  /// [kCurrentSeedVersion]). Newly-introduced default-on modules are unioned in
  /// on load whenever this trails the current version, then this is bumped.
  final int seedVersion;

  /// Whether prefs have been loaded/seeded from storage at least once.
  final bool initialized;

  bool isEnabled(String id) => enabledIds.contains(id);

  /// Effective placement for [m], user override if any, else manifest default.
  ModulePlacement placementFor(ModuleManifest m) =>
      placement[m.id] ?? m.defaultPlacement;

  /// Effective order for [m], user override if any, else manifest order.
  int orderFor(ModuleManifest m) => order[m.id] ?? m.order;

  ModulePrefs copyWith({
    Set<String>? enabledIds,
    Map<String, ModulePlacement>? placement,
    Map<String, int>? order,
    int? seedVersion,
    bool? initialized,
  }) {
    return ModulePrefs(
      enabledIds: enabledIds ?? this.enabledIds,
      placement: placement ?? this.placement,
      order: order ?? this.order,
      seedVersion: seedVersion ?? this.seedVersion,
      initialized: initialized ?? this.initialized,
    );
  }
}

/// Hive-backed notifier holding the user's module preferences.
///
/// Seeds from the registry on first run (when nothing is persisted yet): every
/// declared module is enabled at its default placement, so the app behaves
/// exactly as before this spine landed. Subsequent toggles/placement changes
/// persist and survive restarts / web reloads.
class ModulePrefsNotifier extends Notifier<ModulePrefs> {
  /// Default enabled-id seed + default placements, taken from the registry. The
  /// registry calls [seedFrom] once it has the manifest list; until then we
  /// return an empty, uninitialized snapshot.
  @override
  ModulePrefs build() {
    _loadPersisted();
    return const ModulePrefs();
  }

  Future<void> _loadPersisted() async {
    try {
      final box = await Hive.openBox(_kModulePrefsBox);
      final enabledRaw = box.get(_kEnabledKey);
      final placementRaw = box.get(_kPlacementKey);
      final orderRaw = box.get(_kOrderKey);
      final seedVersionRaw = box.get(_kSeedVersionKey);

      // Nothing persisted yet → leave uninitialized so seedFrom() runs.
      if (enabledRaw == null && placementRaw == null && orderRaw == null) {
        return;
      }

      final enabled = <String>{
        if (enabledRaw is List) ...enabledRaw.map((e) => e.toString()),
      };
      final placement = <String, ModulePlacement>{};
      if (placementRaw is Map) {
        placementRaw.forEach((k, v) {
          final p = modulePlacementFromString(v?.toString());
          if (p != null) placement[k.toString()] = p;
        });
      }
      final order = <String, int>{};
      if (orderRaw is Map) {
        orderRaw.forEach((k, v) {
          final n = v is int ? v : int.tryParse(v?.toString() ?? '');
          if (n != null) order[k.toString()] = n;
        });
      }

      final persistedSeedVersion = seedVersionRaw is int
          ? seedVersionRaw
          : int.tryParse(seedVersionRaw?.toString() ?? '') ?? 0;

      // Seed-version migration: additively union the ids introduced above the
      // user's stored version (new default-on modules), then bump the version.
      // Never removes ids and never re-enables ones the user explicitly turned
      // off (an id introduced at version N is only reachable once the user is
      // already at version >= N, so a below-N user never had the chance to
      // disable it). See [kCurrentSeedVersion] / [modulesIntroducedAfter].
      var effectiveEnabled = enabled;
      var effectiveSeedVersion = persistedSeedVersion;
      var migrated = false;
      if (persistedSeedVersion < kCurrentSeedVersion) {
        effectiveEnabled = {
          ...enabled,
          ...modulesIntroducedAfter(persistedSeedVersion),
        };
        effectiveSeedVersion = kCurrentSeedVersion;
        migrated = true;
      }

      state = ModulePrefs(
        enabledIds: effectiveEnabled,
        placement: placement,
        order: order,
        seedVersion: effectiveSeedVersion,
        initialized: true,
      );

      // Persist the migrated set so the union + bump is durable (and the
      // migration doesn't re-run every launch).
      if (migrated) await _persist();
    } catch (_) {
      // Hive unavailable, leave defaults; seedFrom() will populate in-memory.
    }
  }

  /// Seed defaults from the declared module list the FIRST time (no persisted
  /// prefs). Idempotent: once [ModulePrefs.initialized] is true this is a no-op
  /// so a user who disabled a module doesn't get it re-enabled on next launch.
  void seedFrom(List<ModuleManifest> modules) {
    if (state.initialized) return;
    final enabled = {for (final m in modules) m.id};
    // First run seeds every module AND stamps the current seed version, so the
    // additive migration in _loadPersisted is a no-op on the next launch.
    state = state.copyWith(
      enabledIds: enabled,
      seedVersion: kCurrentSeedVersion,
      initialized: true,
    );
    // Persist the seed so subsequent launches load it instead of re-seeding.
    _persist();
  }

  /// Toggle a module on/off and persist.
  Future<void> setEnabled(String id, bool enabled) async {
    final next = {...state.enabledIds};
    if (enabled) {
      next.add(id);
    } else {
      next.remove(id);
    }
    state = state.copyWith(enabledIds: next, initialized: true);
    await _persist();
  }

  /// Set a module's placement slot and persist.
  Future<void> setPlacement(String id, ModulePlacement slot) async {
    final next = {...state.placement, id: slot};
    state = state.copyWith(placement: next, initialized: true);
    await _persist();
  }

  /// Set a module's order within its slot and persist.
  Future<void> setOrder(String id, int order) async {
    final next = {...state.order, id: order};
    state = state.copyWith(order: next, initialized: true);
    await _persist();
  }

  /// Reset all module prefs (clears overrides; next read re-seeds defaults).
  Future<void> reset() async {
    state = const ModulePrefs();
    try {
      final box = await Hive.openBox(_kModulePrefsBox);
      await box.delete(_kEnabledKey);
      await box.delete(_kPlacementKey);
      await box.delete(_kOrderKey);
      await box.delete(_kSeedVersionKey);
    } catch (_) {
      // best-effort
    }
  }

  Future<void> _persist() async {
    try {
      final box = await Hive.openBox(_kModulePrefsBox);
      await box.put(_kEnabledKey, state.enabledIds.toList());
      await box.put(
        _kPlacementKey,
        {for (final e in state.placement.entries) e.key: e.value.wire},
      );
      await box.put(_kOrderKey, Map<String, int>.from(state.order));
      await box.put(_kSeedVersionKey, state.seedVersion);
    } catch (_) {
      // best-effort persistence; in-memory state already updated.
    }
  }
}

/// The user's module preferences. Watch to rebuild placement-filtered lists.
final modulePrefsProvider =
    NotifierProvider<ModulePrefsNotifier, ModulePrefs>(ModulePrefsNotifier.new);
