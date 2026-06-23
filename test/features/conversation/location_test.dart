import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/conversation/location/location_payload.dart';
import 'package:skchat/features/conversation/widgets/location_card.dart';
import 'package:skchat/features/conversation/widgets/message_content.dart';
import 'package:skchat/models/chat_message.dart';

void main() {
  group('LocationPayload — share payload shape (precise flag)', () {
    test('approximate is the default and reduces precision (~1 km)', () {
      final p = LocationPayload.fromFix(
        lat: 40.748817,
        lon: -73.985428,
        precise: false,
        accuracyM: 5,
      );
      expect(p.precise, isFalse);
      // Coarsened to 3 decimals — fine-grained position is gone.
      expect(p.lat, 40.749);
      expect(p.lon, -73.985);
      // Honest ~1 km radius surfaced for the coarse pin.
      expect(p.accuracyM, 1000);
    });

    test('precise opt-in keeps full precision', () {
      final p = LocationPayload.fromFix(
        lat: 40.748817,
        lon: -73.985428,
        precise: true,
        accuracyM: 5,
      );
      expect(p.precise, isTrue);
      expect(p.lat, 40.748817);
      expect(p.lon, -73.985428);
      expect(p.accuracyM, 5);
    });

    test('toRich carries the precise flag + coords', () {
      final rich = LocationPayload.fromFix(
        lat: 1.0,
        lon: 2.0,
        precise: true,
      ).toRich();
      expect(rich['content_type'], isNull); // rich is the payload, not the env
      expect(rich['lat'], 1.0);
      expect(rich['lon'], 2.0);
      expect(rich['precise'], true);
    });

    test('toBody is the Golden-rule fallback and marks approx', () {
      final approx = LocationPayload.fromFix(lat: 1.2345, lon: 2.0, precise: false);
      expect(approx.toBody(), contains('📍'));
      expect(approx.toBody().toLowerCase(), contains('approx'));

      final precise = LocationPayload.fromFix(lat: 1.0, lon: 2.0, precise: true);
      expect(precise.toBody().toLowerCase(), isNot(contains('approx')));
    });

    test('mapsUrl points at OpenStreetMap with the coords', () {
      final url =
          LocationPayload.fromFix(lat: 40.7, lon: -74.0, precise: true).mapsUrl();
      expect(url, contains('openstreetmap.org'));
      expect(url, contains('mlat=40.7'));
      expect(url, contains('mlon=-74.0'));
    });
  });

  group('LocationPayload.tryParse — inbound parsing', () {
    test('parses a well-formed rich map', () {
      final p = LocationPayload.tryParse(
          {'lat': 1.0, 'lon': 2.0, 'precise': true, 'label': 'Home'});
      expect(p, isNotNull);
      expect(p!.lat, 1.0);
      expect(p.precise, isTrue);
      expect(p.label, 'Home');
    });

    test('null/garbled rich → null (caller falls back to body)', () {
      expect(LocationPayload.tryParse(null), isNull);
      expect(LocationPayload.tryParse({'lat': 1.0}), isNull); // missing lon
      expect(LocationPayload.tryParse({'lat': 'x', 'lon': 'y'}), isNull);
    });

    test('precise defaults to false when flag absent', () {
      final p = LocationPayload.tryParse({'lat': 1.0, 'lon': 2.0});
      expect(p!.precise, isFalse);
    });
  });

  group('Render — MessageContent dispatch for content_type:location', () {
    Future<void> pump(WidgetTester tester, ChatMessage m) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageContent(message: m)),
      ));
    }

    testWidgets('a location message with rich renders the pin card',
        (tester) async {
      final m = ChatMessage(
        id: 'm1',
        peerId: 'lumina',
        content: '📍 Shared location: 1.0,2.0',
        timestamp: DateTime(2026, 1, 1),
        isOutbound: true,
        contentType: 'location',
        rich: const {'lat': 1.0, 'lon': 2.0, 'precise': true, 'label': 'Cafe'},
      );
      await pump(tester, m);
      expect(find.byType(LocationCard), findsOneWidget);
      expect(find.text('Open in Maps'), findsOneWidget);
      expect(find.text('Cafe'), findsOneWidget);
    });

    testWidgets('approximate location shows the approx. badge', (tester) async {
      final m = ChatMessage(
        id: 'm2',
        peerId: 'lumina',
        content: '📍 Shared location: 1.0,2.0 (approx.)',
        timestamp: DateTime(2026, 1, 1),
        isOutbound: true,
        contentType: 'location',
        rich: const {'lat': 1.0, 'lon': 2.0, 'precise': false},
      );
      await pump(tester, m);
      expect(find.byType(LocationCard), findsOneWidget);
      expect(find.text('approx.'), findsOneWidget);
    });

    testWidgets('GOLDEN RULE: a location message with NO rich shows the body',
        (tester) async {
      final m = ChatMessage(
        id: 'm3',
        peerId: 'lumina',
        content: '📍 Shared location: 1.0,2.0',
        timestamp: DateTime(2026, 1, 1),
        isOutbound: true,
        contentType: 'location',
        rich: null,
      );
      await pump(tester, m);
      // No card — degrades to the human-readable body fallback.
      expect(find.byType(LocationCard), findsNothing);
      expect(find.text('📍 Shared location: 1.0,2.0'), findsOneWidget);
    });
  });
}
