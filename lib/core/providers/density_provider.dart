import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../theme/theme.dart';

/// Hive box + key used to persist the user's density preference. Same
/// `settings` box `daemonUrlProvider` uses (opened at startup in
/// `main.dart`), a different key.
const _kSettingsBox = 'settings';
const _kDensityKey = 'sovereign_density';

/// Reactive holder for the app-wide [SovereignDensity] preference.
///
/// This is the density spec's Settings > Appearance > Font Size row (PRD.md
/// promised it, it was never built until this pass). [SovereignTheme]
/// consumers watch this so a single user setting repoints the whole app's
/// type + spacing scale. Persisted in Hive, survives app restarts / web
/// reloads, mirroring [daemonUrlProvider]'s pattern exactly.
class DensityNotifier extends Notifier<SovereignDensity> {
  @override
  SovereignDensity build() {
    // Synchronously seed the compile-time default (compact); asynchronously
    // load any persisted override. Hive may not be open yet.
    _loadPersisted();
    return SovereignDensity.compact;
  }

  Future<void> _loadPersisted() async {
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      final saved = box.get(_kDensityKey);
      final parsed = _parse(saved);
      if (parsed != null && parsed != state) state = parsed;
    } catch (_) {
      // Hive unavailable, keep the compile-time default.
    }
  }

  /// Update the density and persist it.
  Future<void> setDensity(SovereignDensity density) async {
    state = density;
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      await box.put(_kDensityKey, density.name);
    } catch (_) {
      // Best-effort persistence; in-memory state already updated.
    }
  }

  SovereignDensity? _parse(String? raw) {
    if (raw == null) return null;
    for (final d in SovereignDensity.values) {
      if (d.name == raw) return d;
    }
    return null;
  }
}

/// The current density preference. Watch this to rebuild the theme when it
/// changes.
final densityProvider = NotifierProvider<DensityNotifier, SovereignDensity>(
  DensityNotifier.new,
);
