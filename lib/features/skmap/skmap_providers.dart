import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'geo_unit.dart';
import 'geo_units_source.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// SkMap Riverpod wiring.
/// ─────────────────────────────────────────────────────────────────────────

/// The active geo feed adapter.
///
/// **v1 default = [MockGeoUnitsSource]** so the map is demonstrable without a
/// backend.
///
/// ▶ TO GO LIVE: replace the body with the daemon source once the skcomms
///   `geo.py` endpoint exists, e.g.
///
/// ```dart
/// final geoUnitsSourceProvider = Provider<GeoUnitsSource>((ref) {
///   final base = ref.watch(daemonUrlProvider);          // existing provider
///   final dio = Dio();
///   return DaemonGeoUnitsSource(fetcher: () async {
///     final r = await dio.get('$base/api/v1/geo/units'); // TODO: live route
///     final feats = (r.data['features'] ?? r.data['units']) as List;
///     return feats.cast<Map<String, dynamic>>();
///   });
/// });
/// ```
///
/// Everything downstream (the provider + the screen) is feed-agnostic, so this
/// is the single line that flips mock → live.
final geoUnitsSourceProvider = Provider<GeoUnitsSource>((ref) {
  final source = MockGeoUnitsSource();
  ref.onDispose(source.dispose);
  return source;
});

/// The live set of units/markers the map renders. A [StreamProvider] so the UI
/// gets loading / error / data states for free and rebuilds on every snapshot.
final geoUnitsProvider = StreamProvider<List<GeoUnit>>((ref) {
  final source = ref.watch(geoUnitsSourceProvider);
  return source.watch();
});

/// The currently selected unit uid (tapped marker → details sheet), or null.
final selectedUnitProvider = StateProvider<String?>((ref) => null);
