import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/profile/widgets/capabilities_section.dart';
import 'package:skchat/services/capabilities_service.dart';

NodeCapabilities _mockDoc() {
  return NodeCapabilities.fromJson(const {
    'node': {'id': 'lumina@chef.skworld', 'label': 'lumina', 'host': 'noroc2027'},
    'transports': [
      {'id': 'file', 'protocol': 'filesystem', 'status': 'up', 'roles': ['send', 'recv']},
      {'id': 'syncthing', 'protocol': 'syncthing', 'status': 'up', 'roles': ['send', 'recv']},
      {'id': 'webrtc', 'protocol': 'webrtc', 'status': 'unconfigured', 'roles': ['send', 'recv'], 'media': ['audio', 'video']},
      {'id': 'nostr', 'protocol': 'nostr', 'status': 'down', 'roles': ['send', 'recv']},
      {'id': 'tailscale', 'protocol': 'wireguard', 'status': 'configured', 'roles': ['send', 'recv']},
    ],
    'services': [
      {'id': 'text', 'status': 'up', 'via': ['file', 'syncthing']},
      {'id': 'voice', 'status': 'down', 'via': ['webrtc', 'websocket']},
      {'id': 'geo-cot', 'status': 'up', 'via': ['cot']},
    ],
  });
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  group('capabilities_service parsing', () {
    test('parses node + transports + services', () {
      final doc = _mockDoc();
      expect(doc.nodeId, 'lumina@chef.skworld');
      expect(doc.label, 'lumina');
      expect(doc.transports.length, 5);
      expect(doc.services.length, 3);

      final webrtc = doc.transports.firstWhere((t) => t.id == 'webrtc');
      expect(webrtc.status, CapStatus.unconfigured);
      expect(webrtc.media, ['audio', 'video']);

      final text = doc.services.firstWhere((s) => s.id == 'text');
      expect(text.status, CapStatus.up);
      expect(text.via, ['file', 'syncthing']);
    });

    test('unknown status string falls back to unknown', () {
      expect(capStatusFromString('bogus'), CapStatus.unknown);
      expect(capStatusFromString(null), CapStatus.unknown);
    });

    test('empty document detected', () {
      const empty = NodeCapabilities();
      expect(empty.isEmpty, isTrue);
    });
  });

  group('CapabilitiesView rendering', () {
    testWidgets('renders Transports + Services groups', (tester) async {
      await tester.pumpWidget(_wrap(CapabilitiesView(caps: _mockDoc())));
      await tester.pump();

      // Group headers.
      expect(find.text('TRANSPORTS'), findsOneWidget);
      expect(find.text('SERVICES'), findsOneWidget);

      // Each transport renders a keyed row.
      expect(find.byKey(const Key('transport-file')), findsOneWidget);
      expect(find.byKey(const Key('transport-webrtc')), findsOneWidget);
      expect(find.byKey(const Key('transport-nostr')), findsOneWidget);
      expect(find.byKey(const Key('transport-tailscale')), findsOneWidget);

      // Each service renders a keyed row.
      expect(find.byKey(const Key('service-text')), findsOneWidget);
      expect(find.byKey(const Key('service-voice')), findsOneWidget);
      expect(find.byKey(const Key('service-geo-cot')), findsOneWidget);

      // Human labels + protocol subtitles present.
      expect(find.text('File'), findsOneWidget);
      expect(find.text('WebRTC'), findsOneWidget);
      expect(find.text('Geo / CoT'), findsOneWidget);
      expect(find.text('filesystem'), findsOneWidget);

      // Status labels surface honestly (up / unconfigured / down / configured).
      expect(find.text('unconfigured'), findsWidgets);
      expect(find.text('down'), findsWidgets);
      expect(find.text('configured'), findsWidgets);
      expect(find.text('up'), findsWidgets);

      // WebRTC media trailing.
      expect(find.text('audio · video'), findsOneWidget);
    });
  });
}
