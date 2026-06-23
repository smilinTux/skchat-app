import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/skmap/geo_unit.dart';
import 'package:skchat/features/skmap/geo_units_source.dart';
import 'package:skchat/features/skmap/skmap_providers.dart';
import 'package:skchat/features/skmap/skmap_screen.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/module_prefs.dart';

/// A deterministic, non-animating source returning a fixed set of units.
class _FixedSource implements GeoUnitsSource {
  _FixedSource(this.units);
  final List<GeoUnit> units;
  @override
  Stream<List<GeoUnit>> watch() => Stream<List<GeoUnit>>.value(units);
  @override
  Future<List<GeoUnit>> fetchOnce() async => units;
  @override
  void dispose() {}
}

List<GeoUnit> _mockUnits() {
  final now = DateTime.now().toUtc();
  return [
    GeoUnit(
      uid: 'BLACK-LION',
      callsign: 'BLACK LION',
      lat: 40.7589,
      lon: -73.9851,
      lastSeen: now,
      cotType: 'a-f-G-U-C-I',
      kind: GeoUnitKind.friendly,
    ),
    GeoUnit(
      uid: 'OBJ-RALLY',
      callsign: 'RALLY POINT',
      lat: 40.7625,
      lon: -73.9840,
      lastSeen: now,
      cotType: 'b-m-p-w',
      kind: GeoUnitKind.marker,
      remarks: 'Operator-placed waypoint',
    ),
  ];
}

/// Module-spine overrides so SkMapScreen's toolbar-module surface (which
/// reads the capability/prefs chain) doesn't open Hive / fire a network
/// timer in the test. SkMap now hosts a ToolbarModuleActions in its header.
List<Override> _spineOverrides() => [
      geoUnitsSourceProvider.overrideWithValue(_FixedSource(_mockUnits())),
      nodeCapabilitiesProvider.overrideWith((ref) async => null),
      modulePrefsProvider.overrideWith(_StubModulePrefs.new),
    ];

class _StubModulePrefs extends ModulePrefsNotifier {
  @override
  ModulePrefs build() => const ModulePrefs(initialized: true);
}

void main() {
  testWidgets('SkMap renders the map + unit markers from the feed',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _spineOverrides(),
        child: const MaterialApp(home: SkMapScreen()),
      ),
    );
    await tester.pump(); // resolve the stream snapshot

    // The OSM map renders.
    expect(find.byType(FlutterMap), findsOneWidget);
    // Both callsigns are labelled on their markers.
    expect(find.text('BLACK LION'), findsOneWidget);
    expect(find.text('RALLY POINT'), findsOneWidget);
    // The header summary counts friendly units + markers.
    expect(find.textContaining('1 unit'), findsOneWidget);
    // Recenter + fit-all controls are present.
    expect(find.byTooltip('Recenter on me'), findsOneWidget);
    expect(find.byTooltip('Fit all units'), findsOneWidget);
  });

  testWidgets('Tapping a unit opens a details sheet with coords + last-seen',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _spineOverrides(),
        child: const MaterialApp(home: SkMapScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('BLACK LION'));
    await tester.pumpAndSettle();

    // Details sheet surfaces callsign, coords + last-seen labels.
    expect(find.text('Coordinates'), findsOneWidget);
    expect(find.text('Last seen'), findsOneWidget);
    expect(find.textContaining('40.75890'), findsOneWidget);
  });

  test('GeoUnit.fromJson parses flat + GeoJSON shapes and CoT type', () {
    final flat = GeoUnit.fromJson({
      'uid': 'PURE',
      'callsign': 'PURE',
      'lat': 40.5,
      'lon': -73.5,
      'type': 'a-f-G-U-C',
      'last_seen': '2026-06-22T12:00:00Z',
    });
    expect(flat.callsign, 'PURE');
    expect(flat.kind, GeoUnitKind.friendly);
    expect(flat.lat, 40.5);

    final geojson = GeoUnit.fromJson({
      'id': 'OBJ',
      'geometry': {
        'type': 'Point',
        'coordinates': [-73.9, 40.9],
      },
      'properties': {'callsign': 'OBJ-1', 'type': 'b-m-p-w'},
    });
    expect(geojson.lon, -73.9);
    expect(geojson.lat, 40.9);
    expect(geojson.kind, GeoUnitKind.marker);
    expect(geojson.callsign, 'OBJ-1');
  });

  test('MockGeoUnitsSource emits the seed units once', () async {
    final src = MockGeoUnitsSource(animate: false);
    final snap = await src.watch().first;
    expect(snap.length, 4);
    expect(snap.map((u) => u.callsign), contains('LUMINA'));
    src.dispose();
  });
}
