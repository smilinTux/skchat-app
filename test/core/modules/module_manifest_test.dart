import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/modules/module_manifest.dart';
import 'package:skchat/services/capabilities_service.dart';

NodeCapabilities _caps({
  String geoStatus = 'up',
  String textStatus = 'up',
  int? api,
  List<String> moduleHints = const [],
}) {
  return NodeCapabilities.fromJson({
    'node': {'id': 'lumina@chef.skworld', 'label': 'lumina'},
    'api': ?api,
    if (moduleHints.isNotEmpty) 'modules': moduleHints,
    'transports': const [
      {'id': 'webrtc', 'protocol': 'webrtc', 'status': 'up'},
    ],
    'services': [
      {'id': 'text', 'status': textStatus},
      {'id': 'geo-cot', 'status': geoStatus},
    ],
  });
}

void main() {
  group('CapabilityRef', () {
    test('parses kind + id from compact string', () {
      const ref = CapabilityRef('service:geo-cot');
      expect(ref.kind, 'service');
      expect(ref.id, 'geo-cot');
      expect(ref.isService, isTrue);
      expect(ref.isTransport, isFalse);
    });

    test('resolves to the matching service status', () {
      const ref = CapabilityRef('service:geo-cot');
      expect(ref.resolve(_caps(geoStatus: 'up')), CapStatus.up);
      expect(ref.resolve(_caps(geoStatus: 'down')), CapStatus.down);
    });

    test('resolves transports', () {
      const ref = CapabilityRef('transport:webrtc');
      expect(ref.resolve(_caps()), CapStatus.up);
    });

    test('missing capability resolves to unconfigured', () {
      const ref = CapabilityRef('service:nonexistent');
      expect(ref.resolve(_caps()), CapStatus.unconfigured);
    });

    test('null caps resolves to unknown', () {
      const ref = CapabilityRef('service:geo-cot');
      expect(ref.resolve(null), CapStatus.unknown);
    });
  });

  group('capStatusAvailable', () {
    test('up / configured / degraded count as available', () {
      expect(capStatusAvailable(CapStatus.up), isTrue);
      expect(capStatusAvailable(CapStatus.configured), isTrue);
      expect(capStatusAvailable(CapStatus.degraded), isTrue);
    });
    test('down / unconfigured / unknown are NOT available', () {
      expect(capStatusAvailable(CapStatus.down), isFalse);
      expect(capStatusAvailable(CapStatus.unconfigured), isFalse);
      expect(capStatusAvailable(CapStatus.unknown), isFalse);
    });
  });

  group('ModuleAvailability.resolve', () {
    const skmap = ModuleManifest(
      id: 'skmap',
      title: 'SkMap',
      icon: Icons.radar_outlined,
      route: '/skmap',
      requires: [CapabilityRef('service:geo-cot')],
    );

    test('available when every required capability is available', () {
      final a = ModuleAvailability.resolve(skmap, _caps(geoStatus: 'up'));
      expect(a.available, isTrue);
      expect(a.reason, isNull);
    });

    test('greys with a reason when a required capability is down', () {
      final a = ModuleAvailability.resolve(skmap, _caps(geoStatus: 'down'));
      expect(a.available, isFalse);
      expect(a.reason, contains('Geo / CoT'));
      expect(a.reason, contains('down'));
    });

    test('greys when a required capability is unconfigured', () {
      final a = ModuleAvailability.resolve(skmap, _caps(geoStatus: 'unconfigured'));
      expect(a.available, isFalse);
      expect(a.reason, contains('unconfigured'));
    });

    test('module with no requires is always available', () {
      const free = ModuleManifest(
        id: 'activity',
        title: 'Activity',
        icon: Icons.notifications_outlined,
        route: '/activity',
      );
      expect(ModuleAvailability.resolve(free, null).available, isTrue);
    });

    test('minDaemonApi floor gates the module', () {
      const needsApi = ModuleManifest(
        id: 'future',
        title: 'Future',
        icon: Icons.bolt,
        route: '/future',
        minDaemonApi: 2,
      );
      // No api advertised → unknown → blocked.
      expect(
        ModuleAvailability.resolve(needsApi, _caps()).available,
        isFalse,
      );
      // api too low → blocked.
      expect(
        ModuleAvailability.resolve(needsApi, _caps(api: 1), daemonApi: 1)
            .available,
        isFalse,
      );
      // api meets floor → allowed.
      expect(
        ModuleAvailability.resolve(needsApi, _caps(api: 2), daemonApi: 2)
            .available,
        isTrue,
      );
    });
  });

  group('NodeCapabilities api + moduleHints parsing', () {
    test('parses top-level api integer', () {
      expect(_caps(api: 3).api, 3);
      expect(_caps().api, isNull);
    });

    test('parses modules hint list (strings)', () {
      final c = _caps(moduleHints: ['skmap', 'chats']);
      expect(c.moduleHints, ['skmap', 'chats']);
    });

    test('parses modules hint list (objects with id)', () {
      final c = NodeCapabilities.fromJson({
        'modules': [
          {'id': 'skmap'},
          {'id': 'chats'},
        ],
      });
      expect(c.moduleHints, ['skmap', 'chats']);
    });
  });
}
