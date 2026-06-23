/// Shared location types + the platform seam for reading the device location
/// ONCE, opt-in.
///
/// The web half (`location_geo_web.dart`) calls the browser **Geolocation API**
/// (`navigator.geolocation.getCurrentPosition`) which itself shows the browser's
/// permission prompt — so a location read NEVER happens without (a) the user
/// tapping "Share location" and (b) granting the browser prompt. There is no
/// watch/stream here: one-shot only (Phase 4 = static pin, no live tracking).
///
/// `readCurrentLocation()` is provided by the conditional export below; the stub
/// (non-web) throws, the web impl reads the browser geolocation.
library;

export 'location_geo_stub.dart'
    if (dart.library.html) 'location_geo_web.dart';

/// A one-shot location fix: WGS84 coordinates + the device's accuracy estimate.
class GeoFix {
  const GeoFix({required this.lat, required this.lon, this.accuracyM});

  final double lat;
  final double lon;

  /// Reported horizontal accuracy in metres (null if unknown).
  final double? accuracyM;
}

/// Thrown when a location read fails or is denied. [denied] distinguishes a
/// user/browser permission denial (show "you declined") from a transient error.
class GeoError implements Exception {
  const GeoError(this.message, {this.denied = false});
  final String message;
  final bool denied;

  @override
  String toString() => 'GeoError($message)';
}
