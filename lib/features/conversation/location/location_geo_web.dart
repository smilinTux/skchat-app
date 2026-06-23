import 'dart:async';
import 'dart:html' as html;

import 'location_geo.dart';

/// Web one-shot geolocation read via the browser **Geolocation API**.
///
/// `navigator.geolocation.getCurrentPosition` triggers the browser's own
/// permission prompt (the opt-in gate) and returns a single fix — no watch, no
/// background tracking. `enableHighAccuracy` is requested so a user who chose
/// "precise" gets a GPS-grade fix; the coarse/approximate decision is applied
/// afterwards (server-side rounding + the client `precise` flag), so requesting
/// high accuracy here never leaks: an approximate share is still coarsened.
Future<GeoFix> readCurrentLocation() async {
  final geo = html.window.navigator.geolocation;
  try {
    final pos = await geo.getCurrentPosition(
      enableHighAccuracy: true,
      timeout: const Duration(seconds: 15),
      maximumAge: const Duration(seconds: 0),
    );
    final coords = pos.coords;
    final lat = coords?.latitude;
    final lon = coords?.longitude;
    if (lat == null || lon == null) {
      throw const GeoError('Browser returned no coordinates.');
    }
    return GeoFix(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      accuracyM: coords?.accuracy?.toDouble(),
    );
  } on GeoError {
    rethrow;
  } catch (e) {
    // A PositionError with code 1 == PERMISSION_DENIED. We can't always read the
    // code across browsers, so match on the message as a fallback.
    final msg = e.toString().toLowerCase();
    final denied = msg.contains('denied') || msg.contains('permission');
    throw GeoError(
      denied
          ? 'Location permission was denied.'
          : 'Could not read your location: $e',
      denied: denied,
    );
  }
}
