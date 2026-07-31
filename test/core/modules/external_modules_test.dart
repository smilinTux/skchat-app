import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/modules/external_modules.dart';
import 'package:skchat/core/modules/module_manifest.dart';
import 'package:skchat/core/modules/module_registry.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/module_prefs.dart';

/// A prefs notifier that enables ONLY the builtin ids (mirrors a real user with
/// initialized prefs who has never seen the discovered module). Proves external
/// modules render without being in the persisted enabled set.
class _BuiltinsOnlyPrefs extends ModulePrefsNotifier {
  @override
  ModulePrefs build() => ModulePrefs(
        enabledIds: {for (final m in kBuiltinModules) m.id},
        seedVersion: kCurrentSeedVersion,
        initialized: true,
      );
}

NodeCapabilities _caps() => NodeCapabilities.fromJson({
      'node': {'id': 'lumina@chef.skworld'},
      'services': [
        {'id': 'text', 'status': 'up'},
        {'id': 'voice', 'status': 'up'},
      ],
      'transports': const [],
    });

/// A minimal well-formed subapp manifest (spec 5.2) for skdashboard.
Map<String, dynamic> _dashManifest() => {
      'id': 'skdashboard',
      'name': 'SKDashboard',
      'grade': 'B',
      'entry': {'url': 'http://host:7778/'},
      'nav': {'icon': 'dashboard', 'order': 40, 'label': 'Dashboard'},
      'deeplink_prefix': 'skworld://skdashboard/',
    };

void main() {
  group('externalManifestFromJson', () {
    test('maps a full manifest onto a ModuleManifest', () {
      final m = externalManifestFromJson(_dashManifest())!;
      expect(m.id, 'skdashboard');
      expect(m.title, 'Dashboard'); // nav.label wins
      expect(m.order, 40);
      expect(m.external, isTrue);
      expect(m.grade, 'B');
      expect(m.externalEntryUrl, 'http://host:7778/');
      expect(m.route, AppRoutes.externalModulePath('skdashboard'));
      expect(m.defaultPlacement, ModulePlacement.nav);
      expect(m.icon, iconForToken('dashboard'));
    });

    test('falls back to name / id and order 900 when nav is absent', () {
      final m = externalManifestFromJson({
        'id': 'skos',
        'name': 'skOS',
        'entry': {'url': '/skos/app'},
      })!;
      expect(m.title, 'skOS');
      expect(m.order, 900);
      expect(m.icon, Icons.widgets_outlined); // unknown/absent token -> generic
    });

    test('returns null without an id or an entry.url', () {
      expect(externalManifestFromJson({'entry': {'url': 'x'}}), isNull);
      expect(externalManifestFromJson({'id': 'x'}), isNull);
      expect(externalManifestFromJson({'id': 'x', 'entry': {}}), isNull);
    });
  });

  group('parseShellModules', () {
    test('reads the {modules:[...]} envelope, skipping malformed entries', () {
      final list = parseShellModules({
        'modules': [
          _dashManifest(),
          {'no': 'id'}, // skipped
          {'id': 'skos', 'entry': {'url': '/skos/app'}},
        ],
      });
      expect(list.map((m) => m.id), ['skdashboard', 'skos']);
    });

    test('tolerates a bare list and rejects junk', () {
      expect(parseShellModules([_dashManifest()]).single.id, 'skdashboard');
      expect(parseShellModules('nonsense'), isEmpty);
      expect(parseShellModules(null), isEmpty);
    });
  });

  group('iconForToken', () {
    test('known tokens resolve, unknown falls back to a generic glyph', () {
      expect(iconForToken('terminal'), Icons.terminal_outlined);
      expect(iconForToken('DNS'), Icons.dns_outlined); // case-insensitive
      expect(iconForToken('totally-unknown'), Icons.widgets_outlined);
      expect(iconForToken(null), Icons.widgets_outlined);
    });
  });

  group('mergeModules', () {
    test('adds new ids, lets a builtin win an id collision, sorts by order', () {
      final external = [
        externalManifestFromJson(_dashManifest())!, // order 40, new id
        // Collides with a builtin id: must be dropped in favour of the builtin.
        externalManifestFromJson({
          'id': 'skcode',
          'entry': {'url': 'http://host/skcode'},
          'nav': {'order': 1, 'label': 'Impostor'},
        })!,
      ];
      final merged = mergeModules(kBuiltinModules, external);

      // skdashboard added; count grows by exactly one (the collision dropped).
      expect(merged.length, kBuiltinModules.length + 1);
      expect(merged.where((m) => m.id == 'skdashboard'), hasLength(1));
      // The surviving skcode is the builtin (native route), not the impostor.
      final skcode = merged.firstWhere((m) => m.id == 'skcode');
      expect(skcode.external, isFalse);
      // Sorted ascending by nav order.
      for (var i = 1; i < merged.length; i++) {
        expect(merged[i - 1].order <= merged[i].order, isTrue);
      }
    });
  });

  group('signature gate (Fable A2, client-side belt)', () {
    test('kUseShellRequireSigned defaults to false (behavior unchanged)', () {
      expect(kUseShellRequireSigned, isFalse);
    });

    test('gate off: every manifest passes, verified marker irrelevant', () {
      expect(
        manifestPassesSignatureGate(_dashManifest(), requireSigned: false),
        isTrue,
      );
      expect(
        manifestPassesSignatureGate(
          {..._dashManifest(), 'verified': true},
          requireSigned: false,
        ),
        isTrue,
      );
    });

    test('gate on: only manifests marked verified:true pass', () {
      // Unverified (no marker) -> rejected.
      expect(
        manifestPassesSignatureGate(_dashManifest(), requireSigned: true),
        isFalse,
      );
      // Explicit non-true marker -> rejected (no truthy coercion).
      expect(
        manifestPassesSignatureGate(
          {..._dashManifest(), 'verified': 'true'},
          requireSigned: true,
        ),
        isFalse,
      );
      // Verified by the enforcing aggregator -> accepted.
      expect(
        manifestPassesSignatureGate(
          {..._dashManifest(), 'verified': true},
          requireSigned: true,
        ),
        isTrue,
      );
    });

    test('parseShellModules default (gate off) keeps unverified entries', () {
      // Default build: no filtering, an unverified manifest still parses.
      final list = parseShellModules({
        'modules': [_dashManifest()],
      });
      expect(list.single.id, 'skdashboard');
    });
  });

  group('SAFETY: flag gates discovery (default OFF)', () {
    test('kUseShellDynamicModules defaults to false', () {
      expect(kUseShellDynamicModules, isFalse);
    });

    test('registry is exactly kBuiltinModules even if discovery is overridden',
        () {
      // With the compile-time flag OFF, the registry provider must NOT fold in
      // externalModulesProvider, even when it resolves a non-empty list. This
      // proves the deployed app is unchanged until Chef flips the flag.
      final c = ProviderContainer(overrides: [
        externalModulesProvider.overrideWith(
          (ref) async => [externalManifestFromJson(_dashManifest())!],
        ),
      ]);
      addTearDown(c.dispose);
      final reg = c.read(moduleRegistryProvider);
      expect(reg, same(kBuiltinModules));
      expect(reg.any((m) => m.id == 'skdashboard'), isFalse);
    });
  });

  group('external modules flow through the nav pipeline', () {
    test(
        'a discovered nav module is available + enabled without being in prefs',
        () async {
      // Inject the external manifest via the registry (this bypasses the
      // compile-time flag, which is what the flag gate itself is unit-tested
      // for above). The user prefs enable ONLY builtins.
      final external = externalManifestFromJson(_dashManifest())!;
      final c = ProviderContainer(overrides: [
        moduleRegistryProvider
            .overrideWithValue([...kBuiltinModules, external]),
        nodeCapabilitiesProvider.overrideWith((ref) async => _caps()),
        modulePrefsProvider.overrideWith(_BuiltinsOnlyPrefs.new),
      ]);
      addTearDown(c.dispose);
      await c.read(nodeCapabilitiesProvider.future);

      // No capability requires -> available.
      final byId = c.read(moduleAvailabilityByIdProvider);
      expect(byId['skdashboard']!.available, isTrue);

      // Placed into the nav despite not being in the persisted enabled set.
      final nav = c.read(navModulesProvider);
      expect(nav.any((p) => p.manifest.id == 'skdashboard'), isTrue,
          reason: 'external module renders as a nav section');
    });
  });
}
