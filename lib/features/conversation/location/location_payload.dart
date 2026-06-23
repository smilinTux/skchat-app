import 'dart:math' as math;

/// Builds the `location` typed-message payload the conversation sends, and
/// parses an inbound location `rich` map for rendering.
///
/// Contract (P1 typed message):
///   content_type: "location"
///   body:         "📍 Shared location: `<lat>,<lon>`"  (Golden-rule fallback)
///   rich:         {lat, lon, accuracy_m?, label?, precise: bool}
///
/// Security posture (operator-mandated): coarse is the DEFAULT. When the user
/// picks "Approximate" we coarsen to ~3 decimals (~1 km) on the client too, so
/// no fine-grained coordinate ever leaves the device; the server independently
/// re-coarsens (defence in depth). "Precise" is an explicit per-share opt-in.
class LocationPayload {
  const LocationPayload({
    required this.lat,
    required this.lon,
    required this.precise,
    this.accuracyM,
    this.label,
  });

  final double lat;
  final double lon;
  final bool precise;
  final double? accuracyM;
  final String? label;

  /// ~3 decimals ≈ ~1 km — the approximate grid.
  static const int coarseDecimals = 3;
  static const int preciseDecimals = 6;

  static double _round(double v, int decimals) {
    final f = math.pow(10, decimals).toDouble();
    return (v * f).round() / f;
  }

  /// Build a send payload from a raw device fix. When [precise] is false the
  /// coordinates are coarsened before they ever leave the device.
  factory LocationPayload.fromFix({
    required double lat,
    required double lon,
    required bool precise,
    double? accuracyM,
    String? label,
  }) {
    if (precise) {
      return LocationPayload(
        lat: _round(lat, preciseDecimals),
        lon: _round(lon, preciseDecimals),
        precise: true,
        accuracyM: accuracyM,
        label: label,
      );
    }
    return LocationPayload(
      lat: _round(lat, coarseDecimals),
      lon: _round(lon, coarseDecimals),
      precise: false,
      // Surface the coarse-grid uncertainty so the card can draw an honest
      // ~1 km radius even when the device accuracy was tighter.
      accuracyM: 1000,
      label: label,
    );
  }

  /// Parse an inbound `rich` map (tolerant: any missing/odd field degrades).
  static LocationPayload? tryParse(Map<String, dynamic>? rich) {
    if (rich == null) return null;
    final lat = _asDouble(rich['lat']);
    final lon = _asDouble(rich['lon']);
    if (lat == null || lon == null) return null;
    return LocationPayload(
      lat: lat,
      lon: lon,
      precise: rich['precise'] == true,
      accuracyM: _asDouble(rich['accuracy_m']),
      label: (rich['label'] as String?)?.trim().isNotEmpty == true
          ? (rich['label'] as String).trim()
          : null,
    );
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// The `rich` map sent on the wire.
  Map<String, dynamic> toRich() => {
        'lat': lat,
        'lon': lon,
        'precise': precise,
        if (accuracyM != null) 'accuracy_m': accuracyM,
        if (label != null && label!.isNotEmpty) 'label': label,
      };

  /// The mandatory human-readable body (Golden-rule fallback).
  String toBody() {
    final approx = precise ? '' : ' (approx.)';
    if (label != null && label!.isNotEmpty) {
      return '📍 $label: $lat,$lon$approx';
    }
    return '📍 Shared location: $lat,$lon$approx';
  }

  /// External-map deep link (OpenStreetMap) for "Open in Maps".
  String mapsUrl() =>
      'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=15/$lat/$lon';

  /// A static OSM thumbnail of the pin (no native map SDK). Uses the public
  /// staticmap.openstreetmap.de renderer; if it fails to load the card falls
  /// back to a drawn placeholder, so this is best-effort, not load-bearing.
  String staticThumbUrl({int width = 320, int height = 160, int zoom = 14}) =>
      'https://staticmap.openstreetmap.de/staticmap.php'
      '?center=$lat,$lon&zoom=$zoom&size=${width}x$height'
      '&markers=$lat,$lon,red-pushpin';
}
