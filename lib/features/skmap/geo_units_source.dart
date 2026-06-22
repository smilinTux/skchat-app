import 'dart:async';
import 'dart:math' as math;

import 'geo_unit.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// GeoUnitsSource — the ADAPTER SEAM for the live geo / CoT feed.
/// ─────────────────────────────────────────────────────────────────────────
///
/// The [SkMap] screen + [geoUnitsProvider] watch a *stream of unit snapshots*
/// and never care where they come from. To wire the real feed, implement this
/// one interface and swap which source [geoUnitsSourceProvider] returns — no
/// UI changes required.
///
/// The parallel CB4 backend is adding to **skcomms**:
///   * `geo.py` → a `GeoStore` (the live unit/marker table, fed by the CoT
///     bridge: `a-f-*` units + `b-m-*` markers, with callsign/lat/lon/last_seen),
///   * an `application/geo+json` envelope kind (so geo updates ride the SKFed
///     transport like any other message), and
///   * an agent-readable API (a daemon/MCP endpoint).
///
/// So the eventual live source is expected to be ONE of:
///   (a) an HTTP poll of a daemon endpoint (e.g. `GET /api/v1/geo/units`)
///       returning a GeoJSON `FeatureCollection` / list of GeoUnit JSON, or
///   (b) a push stream (SSE / WebSocket) of `application/geo+json` envelopes,
///       or the CoT envelope stream already flowing through skcomms.
///
/// Both map cleanly onto [GeoUnitsSource.watch] — see [DaemonGeoUnitsSource]
/// below for the polling skeleton (TODO marks the single line to wire).
abstract class GeoUnitsSource {
  /// A live stream of the *full current set* of units/markers. Each event is a
  /// complete snapshot (the provider de-dupes by uid downstream is not needed —
  /// the snapshot IS the truth). Implementations should emit an initial
  /// snapshot promptly and then on every change / poll tick.
  Stream<List<GeoUnit>> watch();

  /// Optional one-shot fetch (used by "refresh"); defaults to the first
  /// snapshot off [watch].
  Future<List<GeoUnit>> fetchOnce() => watch().first;

  /// Free any resources (timers, sockets). Called when the provider disposes.
  void dispose() {}
}

/// ─────────────────────────────────────────────────────────────────────────
/// MockGeoUnitsSource — v1 demonstrable feed (no backend required).
/// ─────────────────────────────────────────────────────────────────────────
///
/// Emits BLACK LION / PURE / LUMINA plus a marker, then gently jitters the
/// unit positions every few seconds so the live-map plumbing (markers moving,
/// last-seen updating, recenter/fit controls) is visibly exercised in the UI
/// and in widget tests. Centred on lower Manhattan to match the CoT bridge's
/// sample coordinates (cot_agent.py defaults to 40.758, -73.986).
class MockGeoUnitsSource implements GeoUnitsSource {
  MockGeoUnitsSource({this.animate = true});

  /// When false, emits a single static snapshot (deterministic — for tests).
  final bool animate;

  static const _seedUnits = <_Seed>[
    _Seed('BLACK-LION', 'BLACK LION', 40.7589, -73.9851, 'a-f-G-U-C-I'),
    _Seed('PURE', 'PURE', 40.7614, -73.9776, 'a-f-G-U-C'),
    _Seed('LUMINA', 'LUMINA', 40.7580, -73.9855, 'a-f-G-U-C'),
    _Seed('OBJ-RALLY', 'RALLY POINT', 40.7625, -73.9840, 'b-m-p-w'),
  ];

  Timer? _timer;
  final _rng = math.Random(42);
  StreamController<List<GeoUnit>>? _controller;

  @override
  Stream<List<GeoUnit>> watch() {
    final controller = StreamController<List<GeoUnit>>.broadcast(
      onCancel: dispose,
    );
    _controller = controller;

    var current = _build(0);
    // Emit the initial snapshot on the next microtask so listeners attach.
    scheduleMicrotask(() {
      if (!controller.isClosed) controller.add(current);
    });

    if (animate) {
      var tick = 0;
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (controller.isClosed) return;
        tick++;
        current = _build(tick);
        controller.add(current);
      });
    }
    return controller.stream;
  }

  List<GeoUnit> _build(int tick) {
    final now = DateTime.now().toUtc();
    return _seedUnits.map((s) {
      final isMarker = s.cotType.startsWith('b-m');
      // Markers are fixed; units drift a touch each tick.
      final jitterLat =
          isMarker || !animate ? 0.0 : (_rng.nextDouble() - 0.5) * 0.0006 * tick;
      final jitterLon =
          isMarker || !animate ? 0.0 : (_rng.nextDouble() - 0.5) * 0.0006 * tick;
      return GeoUnit(
        uid: s.uid,
        callsign: s.callsign,
        lat: s.lat + jitterLat,
        lon: s.lon + jitterLon,
        lastSeen: now,
        cotType: s.cotType,
        kind: geoUnitKindFromCotType(s.cotType),
        remarks: isMarker ? 'Operator-placed waypoint' : null,
      );
    }).toList();
  }

  @override
  Future<List<GeoUnit>> fetchOnce() async => _build(0);

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _controller?.close();
    _controller = null;
  }
}

class _Seed {
  const _Seed(this.uid, this.callsign, this.lat, this.lon, this.cotType);
  final String uid;
  final String callsign;
  final double lat;
  final double lon;
  final String cotType;
}

/// ─────────────────────────────────────────────────────────────────────────
/// DaemonGeoUnitsSource — LIVE-FEED SKELETON (the integration point).
/// ─────────────────────────────────────────────────────────────────────────
///
/// Polls a daemon/MCP endpoint that returns the current units (GeoJSON
/// FeatureCollection or a `{"units": [...]}` list of GeoUnit JSON) and republishes
/// each poll as a snapshot. This is the *only* file that needs to change to go
/// live: implement [_fetch] against the real endpoint (see the single TODO).
///
/// Swap it in by editing [geoUnitsSourceProvider] in `skmap_providers.dart`:
///   return DaemonGeoUnitsSource(baseUrl: ref.watch(daemonUrlProvider));
///
/// (Left intentionally transport-light here — it takes a [fetcher] callback so
/// the actual HTTP/Dio call lives at the wiring site with the rest of the app's
/// `dio` clients, and so this class stays unit-testable without a network.)
class DaemonGeoUnitsSource implements GeoUnitsSource {
  DaemonGeoUnitsSource({
    required this.fetcher,
    this.pollInterval = const Duration(seconds: 5),
  });

  /// Returns the decoded list of GeoUnit JSON maps for one poll. Wire this to
  /// the real daemon call, e.g.:
  ///
  /// ```dart
  /// fetcher: () async {
  ///   final r = await dio.get('$base/api/v1/geo/units');   // TODO live endpoint
  ///   final feats = (r.data['features'] ?? r.data['units']) as List;
  ///   return feats.cast<Map<String, dynamic>>();
  /// }
  /// ```
  final Future<List<Map<String, dynamic>>> Function() fetcher;

  final Duration pollInterval;

  Timer? _timer;
  StreamController<List<GeoUnit>>? _controller;

  @override
  Stream<List<GeoUnit>> watch() {
    final controller = StreamController<List<GeoUnit>>.broadcast(
      onCancel: dispose,
    );
    _controller = controller;

    Future<void> poll() async {
      if (controller.isClosed) return;
      try {
        final units = await _fetch();
        if (!controller.isClosed) controller.add(units);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    scheduleMicrotask(poll);
    _timer = Timer.periodic(pollInterval, (_) => poll());
    return controller.stream;
  }

  Future<List<GeoUnit>> _fetch() async {
    final raw = await fetcher();
    return raw.map(GeoUnit.fromJson).toList();
  }

  @override
  Future<List<GeoUnit>> fetchOnce() => _fetch();

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _controller?.close();
    _controller = null;
  }
}
