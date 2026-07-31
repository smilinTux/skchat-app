import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/core/modules/module_registry.dart';
import 'package:skchat/services/module_prefs.dart';

// Hive key/box names are private in module_prefs.dart; mirror the literals here
// (the persisted wire format is what these tests pin down).
const _kBox = 'module_prefs';
const _kEnabledKey = 'enabled_ids';
const _kSeedVersionKey = 'seed_version';

/// A returning user's pre-skcode enabled set (skcode absent by construction).
const _preSkcodeEnabled = ['chats', 'spaces', 'activity', 'profile', 'skmap'];

/// Build the notifier via a real container and wait for the async Hive load to
/// settle (build() fires _loadPersisted without awaiting).
Future<ModulePrefs> _loadPrefs(ProviderContainer c) async {
  c.read(modulePrefsProvider); // trigger build() → _loadPersisted()
  for (var i = 0; i < 100 && !c.read(modulePrefsProvider).initialized; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return c.read(modulePrefsProvider);
}

Future<void> _seedBox({
  required List<String> enabled,
  int? seedVersion,
}) async {
  final box = await Hive.openBox(_kBox);
  await box.put(_kEnabledKey, enabled);
  if (seedVersion != null) await box.put(_kSeedVersionKey, seedVersion);
}

void main() {
  setUpAll(() {
    Hive.init(Directory.systemTemp.createTempSync('skchat_prefs_seed').path);
  });

  setUp(() async {
    // Start each test from a clean, closed box so loads are deterministic.
    if (Hive.isBoxOpen(_kBox)) await Hive.box(_kBox).close();
    await Hive.deleteBoxFromDisk(_kBox);
  });

  test('sanity: the migration table introduces skcode at v1', () {
    expect(kCurrentSeedVersion, greaterThanOrEqualTo(1));
    expect(modulesIntroducedAfter(0), contains('skcode'));
    // A current user picks up nothing new.
    expect(modulesIntroducedAfter(kCurrentSeedVersion), isEmpty);
  });

  test('new module appears for an existing user (seedVersion < current)',
      () async {
    // Existing user persisted BEFORE skcode existed: no skcode, no seed_version
    // (absent → 0).
    await _seedBox(enabled: _preSkcodeEnabled);

    final c = ProviderContainer();
    addTearDown(c.dispose);
    final prefs = await _loadPrefs(c);

    expect(prefs.initialized, isTrue);
    expect(prefs.enabledIds, contains('skcode'),
        reason: 'newly-introduced default-on module unions in');
    // Prior choices untouched.
    for (final id in _preSkcodeEnabled) {
      expect(prefs.enabledIds, contains(id));
    }
    expect(prefs.seedVersion, kCurrentSeedVersion,
        reason: 'version is bumped after the additive union');
  });

  test('a module the user disabled stays disabled (seedVersion == current)',
      () async {
    // Same enabled set, but stamped at the CURRENT version, meaning the user
    // has already seen skcode and deliberately left it off.
    await _seedBox(
      enabled: _preSkcodeEnabled,
      seedVersion: kCurrentSeedVersion,
    );

    final c = ProviderContainer();
    addTearDown(c.dispose);
    final prefs = await _loadPrefs(c);

    expect(prefs.initialized, isTrue);
    expect(prefs.enabledIds, isNot(contains('skcode')),
        reason: 'no migration runs at the current version; choice is honored');
    expect(prefs.seedVersion, kCurrentSeedVersion);
  });

  test('the migrated union + version bump is persisted (does not re-run)',
      () async {
    await _seedBox(enabled: _preSkcodeEnabled); // seedVersion absent → 0

    final c1 = ProviderContainer();
    addTearDown(c1.dispose);
    await _loadPrefs(c1);
    // _loadPersisted flips `initialized` before its async _persist() resolves;
    // give that best-effort write time to land before inspecting the box.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Re-open the box directly and confirm the durable state was written.
    final box = await Hive.openBox(_kBox);
    expect((box.get(_kSeedVersionKey) as int?), kCurrentSeedVersion);
    expect(
      (box.get(_kEnabledKey) as List).map((e) => e.toString()),
      contains('skcode'),
    );
  });

  test('fresh install seeds every module at the current seed version',
      () async {
    // Empty box → _loadPersisted leaves prefs uninitialized so seedFrom() runs
    // (this is what enabledModulesProvider does on first frame).
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final loaded = await _loadPrefs(c);
    expect(loaded.initialized, isFalse,
        reason: 'nothing persisted → awaits the registry seed');

    c.read(modulePrefsProvider.notifier).seedFrom(kBuiltinModules);
    final prefs = c.read(modulePrefsProvider);

    expect(prefs.initialized, isTrue);
    expect(prefs.enabledIds, {for (final m in kBuiltinModules) m.id},
        reason: 'first run enables the full registry');
    expect(prefs.enabledIds, contains('skcode'));
    expect(prefs.seedVersion, kCurrentSeedVersion,
        reason: 'first run stamps the current version so migration is a no-op');
  });
}
