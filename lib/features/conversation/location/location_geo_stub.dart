import 'location_geo.dart';

/// Native (non-web) stub: this app ships as a web build, so a one-shot browser
/// geolocation read is unavailable here. Throwing keeps the call site honest
/// (it surfaces "location unavailable" rather than silently returning junk).
Future<GeoFix> readCurrentLocation() async {
  throw const GeoError('Location sharing is only available on the web build.');
}
