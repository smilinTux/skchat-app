import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/modules/module_manifest.dart';
import 'package:skchat/core/modules/module_registry.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/module_prefs.dart';

NodeCapabilities _caps({String geoStatus = 'up'}) {
  return NodeCapabilities.fromJson({
    'node': {'id': 'lumina@chef.skworld'},
    'services': [
      {'id': 'text', 'status': 'up'},
      {'id': 'voice', 'status': 'up'},
      {'id': 'geo-cot', 'status': geoStatus},
      {'id': 'access-plane', 'status': 'up'},
    ],
    'transports': const [],
  });
}

/// A prefs notifier seeded with an explicit state (no Hive in tests).
class _StubPrefs extends ModulePrefsNotifier {
  _StubPrefs(this._initial);
  final ModulePrefs _initial;
  @override
  ModulePrefs build() => _initial;
}

ProviderContainer _container({
  required NodeCapabilities caps,
  required ModulePrefs prefs,
}) {
  return ProviderContainer(
    overrides: [
      nodeCapabilitiesProvider.overrideWith((ref) async => caps),
      modulePrefsProvider.overrideWith(() => _StubPrefs(prefs)),
    ],
  );
}

/// Enabled set with all builtin modules enabled at their default placement.
ModulePrefs _allEnabled({Map<String, ModulePlacement> placement = const {}}) {
  return ModulePrefs(
    enabledIds: {for (final m in kBuiltinModules) m.id},
    placement: placement,
    initialized: true,
  );
}

void main() {
  test('moduleRegistry exposes the builtin manifests incl. skmap', () {
    final c = _container(caps: _caps(), prefs: _allEnabled());
    addTearDown(c.dispose);
    final reg = c.read(moduleRegistryProvider);
    expect(reg.any((m) => m.id == 'skmap'), isTrue);
  });

  test('availability: skmap is available when geo-cot is up', () async {
    final c = _container(caps: _caps(geoStatus: 'up'), prefs: _allEnabled());
    addTearDown(c.dispose);
    // Force the FutureProvider to resolve.
    await c.read(nodeCapabilitiesProvider.future);
    final byId = c.read(moduleAvailabilityByIdProvider);
    expect(byId['skmap']!.available, isTrue);
  });

  test('availability: skmap greys with a reason when geo-cot is down',
      () async {
    final c = _container(caps: _caps(geoStatus: 'down'), prefs: _allEnabled());
    addTearDown(c.dispose);
    await c.read(nodeCapabilitiesProvider.future);
    final byId = c.read(moduleAvailabilityByIdProvider);
    expect(byId['skmap']!.available, isFalse);
    expect(byId['skmap']!.reason, contains('Geo / CoT'));
  });

  test('placement providers route a module to nav / toolbar / drawer',
      () async {
    // skmap default placement is drawer.
    final c = _container(caps: _caps(), prefs: _allEnabled());
    addTearDown(c.dispose);
    await c.read(nodeCapabilitiesProvider.future);

    final nav = c.read(navModulesProvider).map((p) => p.manifest.id).toSet();
    final drawer =
        c.read(drawerModulesProvider).map((p) => p.manifest.id).toSet();
    final toolbar =
        c.read(toolbarModulesProvider).map((p) => p.manifest.id).toSet();

    expect(nav.contains('chats'), isTrue, reason: 'chats defaults to nav');
    expect(drawer.contains('skmap'), isTrue, reason: 'skmap defaults to drawer');
    expect(toolbar, isEmpty, reason: 'nothing promoted to toolbar by default');
  });

  test('promote skmap drawer→toolbar moves it between providers', () async {
    final c = _container(
      caps: _caps(),
      prefs: _allEnabled(placement: {'skmap': ModulePlacement.toolbar}),
    );
    addTearDown(c.dispose);
    await c.read(nodeCapabilitiesProvider.future);

    final drawer =
        c.read(drawerModulesProvider).map((p) => p.manifest.id).toSet();
    final toolbar =
        c.read(toolbarModulesProvider).map((p) => p.manifest.id).toSet();

    expect(drawer.contains('skmap'), isFalse,
        reason: 'no longer in the drawer once promoted');
    expect(toolbar.contains('skmap'), isTrue,
        reason: 'now rendered on the toolbar');
  });

  test('disabling skmap hides it from every placement provider', () async {
    final disabled = ModulePrefs(
      enabledIds: {for (final m in kBuiltinModules) m.id}..remove('skmap'),
      initialized: true,
    );
    final c = _container(caps: _caps(), prefs: disabled);
    addTearDown(c.dispose);
    await c.read(nodeCapabilitiesProvider.future);

    final all = [
      ...c.read(navModulesProvider),
      ...c.read(toolbarModulesProvider),
      ...c.read(drawerModulesProvider),
    ].map((p) => p.manifest.id).toSet();
    expect(all.contains('skmap'), isFalse);
  });

  test('enabled-but-unavailable module stays in the drawer (greyed)',
      () async {
    // skmap enabled, but geo-cot down → it must still appear so the drawer can
    // render it greyed-with-a-reason (honesty), not silently vanish.
    final c = _container(caps: _caps(geoStatus: 'down'), prefs: _allEnabled());
    addTearDown(c.dispose);
    await c.read(nodeCapabilitiesProvider.future);
    final drawer = c.read(drawerModulesProvider);
    final skmap = drawer.firstWhere((p) => p.manifest.id == 'skmap');
    expect(skmap.available, isFalse);
    expect(skmap.reason, isNotNull);
  });

  test('node modules hint filters the registry to declared ids', () async {
    final caps = NodeCapabilities.fromJson({
      'node': {'id': 'n'},
      'modules': ['chats', 'skmap'],
      'services': [
        {'id': 'text', 'status': 'up'},
        {'id': 'geo-cot', 'status': 'up'},
      ],
    });
    final c = _container(caps: caps, prefs: _allEnabled());
    addTearDown(c.dispose);
    await c.read(nodeCapabilitiesProvider.future);
    final ids =
        c.read(moduleAvailabilityProvider).map((a) => a.manifest.id).toSet();
    expect(ids, {'chats', 'skmap'});
  });
}
