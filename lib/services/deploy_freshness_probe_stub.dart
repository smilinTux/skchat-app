/// Compile-time fallback for a target with no `dart:html` (mirrors
/// `device_label_stub.dart`'s / `browser_notifier_stub.dart`'s role). The
/// "already-open tab kept running stale JS" failure this whole feature
/// exists for is a browser-tab problem; off web there is no served build to
/// probe, so this always fails silently rather than doing anything.
Future<String?> fetchServedBuildMarker() async => null;

/// No-op off web: there is no browser tab to reload.
void reloadPage() {}
