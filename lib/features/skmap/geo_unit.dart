import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// Classification of a geo entity on the tactical map.
///
/// Mirrors the CoT (Cursor-on-Target) type taxonomy used by the skcomms CoT
/// bridge (see `skcomms/docs/cot-bridge.md` + `src/skcomms/cot.py`):
///   * `a-f-*`  → a **friendly unit** (an affiliated entity: a person/vehicle
///                with a callsign and a live position), e.g. BLACK LION, PURE,
///                LUMINA.
///   * `b-m-*`  → a **marker** (a map graphic / point of interest placed by an
///                operator), e.g. a waypoint, an objective.
///   * `a-h-*`  → a **hostile** unit (affiliation = hostile).
///   * `a-n-*`  → a **neutral** unit.
///   * `a-u-*`  → an **unknown** affiliation.
///
/// We only need the coarse bucket for rendering (icon + colour); the full CoT
/// type string is preserved in [GeoUnit.cotType] for fidelity.
enum GeoUnitKind {
  /// Friendly affiliated unit (`a-f-*`). Rendered blue.
  friendly,

  /// Map marker / point of interest (`b-m-*`). Rendered yellow.
  marker,

  /// Hostile unit (`a-h-*`). Rendered red.
  hostile,

  /// Neutral unit (`a-n-*`). Rendered green.
  neutral,

  /// Unknown affiliation (`a-u-*` / anything unmatched). Rendered grey.
  unknown,
}

/// Map a CoT type string (e.g. `a-f-G-U-C`, `b-m-p-w`) to a [GeoUnitKind].
GeoUnitKind geoUnitKindFromCotType(String? cotType) {
  if (cotType == null || cotType.isEmpty) return GeoUnitKind.unknown;
  final t = cotType.toLowerCase();
  if (t.startsWith('b-m')) return GeoUnitKind.marker;
  if (t.startsWith('a-f')) return GeoUnitKind.friendly;
  if (t.startsWith('a-h')) return GeoUnitKind.hostile;
  if (t.startsWith('a-n')) return GeoUnitKind.neutral;
  // `a-u-*` and everything else → unknown.
  return GeoUnitKind.unknown;
}

/// A single live entity on the tactical map: a unit or a marker.
///
/// This is the app-side view model the [SkMap] watches. It is intentionally
/// transport-agnostic, it is produced by an adapter ([GeoUnitsSource]) from
/// whatever the geo feed delivers (a daemon REST poll, an SSE/WebSocket stream,
/// a CoT envelope, or the v1 mock). The fields map 1:1 onto the backend
/// `GeoUnit` being added in skcomms `geo.py` (callsign / lat / lon / last_seen)
/// plus the CoT identity (`uid` / `type`).
@immutable
class GeoUnit {
  const GeoUnit({
    required this.uid,
    required this.callsign,
    required this.lat,
    required this.lon,
    required this.lastSeen,
    this.cotType,
    this.kind = GeoUnitKind.unknown,
    this.remarks,
    this.staleAfter = const Duration(minutes: 5),
  });

  /// Globally-unique entity id (CoT `uid`); stable per entity/marker.
  final String uid;

  /// Human callsign shown on the map (e.g. `BLACK LION`, `LUMINA`).
  final String callsign;

  /// Latitude in decimal degrees.
  final double lat;

  /// Longitude in decimal degrees.
  final double lon;

  /// When this unit last reported a position (server clock).
  final DateTime lastSeen;

  /// The raw CoT type string, if known (preserved for fidelity / debugging).
  final String? cotType;

  /// Coarse rendering bucket (icon + colour).
  final GeoUnitKind kind;

  /// Optional free-text remarks attached to the entity.
  final String? remarks;

  /// How long after [lastSeen] the unit is considered stale (dimmed).
  final Duration staleAfter;

  /// Convenience [LatLng] for flutter_map.
  LatLng get position => LatLng(lat, lon);

  /// True if [lastSeen] is older than [staleAfter] relative to [now].
  bool isStaleAt(DateTime now) => now.difference(lastSeen) > staleAfter;

  /// Build from a decoded JSON map (the shape skcomms `geo.py` GeoStore + the
  /// `application/geo+json` envelope is expected to deliver). Tolerant of the
  /// common key spellings so wiring the live feed is a drop-in.
  ///
  /// Accepts both flat keys (`lat`/`lon`) and GeoJSON-ish nesting
  /// (`geometry.coordinates: [lon, lat]`), and both `last_seen` (snake, the
  /// backend convention) and `lastSeen`.
  factory GeoUnit.fromJson(Map<String, dynamic> json) {
    double? num2double(Object? v) =>
        v == null ? null : (v as num).toDouble();

    double? lat = num2double(json['lat'] ?? json['latitude']);
    double? lon = num2double(json['lon'] ?? json['lng'] ?? json['longitude']);

    // GeoJSON geometry fallback: coordinates are [lon, lat].
    final geometry = json['geometry'];
    if ((lat == null || lon == null) && geometry is Map<String, dynamic>) {
      final coords = geometry['coordinates'];
      if (coords is List && coords.length >= 2) {
        lon ??= num2double(coords[0]);
        lat ??= num2double(coords[1]);
      }
    }

    // Properties bag (GeoJSON Feature) is searched as a fallback for the
    // descriptive fields.
    final props = (json['properties'] is Map<String, dynamic>)
        ? json['properties'] as Map<String, dynamic>
        : const <String, dynamic>{};

    final cotType = (json['type'] ?? json['cot_type'] ?? props['type'])
        as String?;
    final callsign = (json['callsign'] ??
            props['callsign'] ??
            json['name'] ??
            props['name'] ??
            'UNKNOWN')
        .toString();

    final lastSeenRaw =
        json['last_seen'] ?? json['lastSeen'] ?? props['last_seen'];

    return GeoUnit(
      uid: (json['uid'] ?? json['id'] ?? props['uid'] ?? '').toString(),
      callsign: callsign,
      lat: lat ?? 0,
      lon: lon ?? 0,
      lastSeen: _parseTime(lastSeenRaw),
      cotType: cotType,
      kind: geoUnitKindFromCotType(cotType),
      remarks: (json['remarks'] ?? props['remarks']) as String?,
    );
  }

  GeoUnit copyWith({
    double? lat,
    double? lon,
    DateTime? lastSeen,
    String? callsign,
    String? cotType,
    GeoUnitKind? kind,
    String? remarks,
  }) {
    return GeoUnit(
      uid: uid,
      callsign: callsign ?? this.callsign,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      lastSeen: lastSeen ?? this.lastSeen,
      cotType: cotType ?? this.cotType,
      kind: kind ?? this.kind,
      remarks: remarks ?? this.remarks,
      staleAfter: staleAfter,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GeoUnit &&
      other.uid == uid &&
      other.callsign == callsign &&
      other.lat == lat &&
      other.lon == lon &&
      other.lastSeen == lastSeen &&
      other.cotType == cotType &&
      other.kind == kind &&
      other.remarks == remarks;

  @override
  int get hashCode =>
      Object.hash(uid, callsign, lat, lon, lastSeen, cotType, kind, remarks);
}

/// Parse a timestamp that may arrive as an ISO-8601 string, an epoch-seconds /
/// epoch-millis number, or null. Falls back to "now" so a unit without a clock
/// is treated as fresh rather than perma-stale.
DateTime _parseTime(Object? raw) {
  if (raw is String && raw.isNotEmpty) {
    final p = DateTime.tryParse(raw);
    if (p != null) return p.toUtc();
  }
  if (raw is num) {
    // Heuristic: > 10^11 ⇒ milliseconds, else seconds.
    final v = raw.toInt();
    return v > 100000000000
        ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
        : DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
  }
  return DateTime.now().toUtc();
}
