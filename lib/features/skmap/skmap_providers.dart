import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/daemon_config.dart';
import '../../services/operator_auth_interceptor.dart';
import '../../services/operator_session_service.dart';
import 'geo_unit.dart';
import 'geo_units_source.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// SkMap Riverpod wiring.
/// ─────────────────────────────────────────────────────────────────────────

/// The active geo feed adapter.
///
/// **LIVE** = [DaemonGeoUnitsSource], polling `GET /api/v1/geo/units` on the
/// skcomms daemon (base = [daemonUrlProvider]). The daemon publishes the CoT
/// bridge's situational picture (units / markers / waypoints); when nothing has
/// beaconed yet it returns an empty set, so the map degrades to "no units"
/// rather than erroring.
///
/// The endpoint returns `{"units": [...], "count": N}` (flat GeoUnit dicts); it
/// also supports `?format=geojson` for a `FeatureCollection`. The fetcher below
/// reads `features` then `units`, so either shape works via [GeoUnit.fromJson].
///
/// ◀ To demo without a backend, swap the body back to `MockGeoUnitsSource()`.
/// Everything downstream (the provider + the screen) is feed-agnostic.
final geoUnitsSourceProvider = Provider<GeoUnitsSource>((ref) {
  final base = ref.watch(daemonUrlProvider);
  final session = ref.watch(operatorSessionServiceProvider);
  final dio = Dio(BaseOptions(baseUrl: base));
  // On web the geo feed is fetched from the funnel origin, where the skcomms
  // /api/v1 plane is operator-gated (unit positions are operational). Attach the
  // operator-session Bearer, same as the peers/conversations plane. No-ops on an
  // unenrolled device, so native (direct :9384, ungated) is unaffected.
  dio.interceptors.add(buildOperatorAuthInterceptor(session, () => dio));
  final source = DaemonGeoUnitsSource(
    fetcher: () async {
      final r = await dio.get('/api/v1/geo/units');
      final data = r.data;
      final list = (data is Map)
          ? (data['features'] ?? data['units'] ?? const [])
          : (data ?? const []);
      return (list as List).cast<Map<String, dynamic>>();
    },
  );
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
