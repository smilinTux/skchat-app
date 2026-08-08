/// Compile-time fallback for a target with neither `dart:io` nor `dart:html`
/// (mirrors `guest_identity_stub.dart`'s role). Web itself resolves here too
/// (this app has no web-specific device-name source): no device-name API is
/// available without `device_info_plus`, which is deliberately not a
/// dependency for this feature, so the label is omitted entirely and the
/// server's User-Agent-derived guess stands in instead.
String? guessDeviceLabel() => null;
